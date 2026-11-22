// 远程图片下载测试:流式限长、redirect/私网拒绝、类型/魔数校验、
// 超时重试、确定性失败与保留的 base64 协议转换。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/backend/image_downloader.dart';

/// 带 PNG 魔数的响应体,满足缺失 content-type 时的魔数校验。
final Uint8List _pngBytes = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
]);

http.Response _imageResponse(Uint8List body, {int status = 200}) =>
    http.Response.bytes(body, status, headers: {'content-type': 'image/png'});

void main() {
  test(
    'downloadImageBytes fetches the original binary response body',
    () async {
      final client = MockClient((req) async => _imageResponse(_pngBytes));
      expect(
        await downloadImageBytes('https://example.com/a.png', client: client),
        _pngBytes,
      );
    },
  );

  test('downloadImageBytes returns null on non-200 and on throw', () async {
    final bad = MockClient((req) async => http.Response('boom', 500));
    expect(
      await downloadImageBytes('https://example.com/a.png', client: bad),
      isNull,
    );
    final down = MockClient((req) async => throw Exception('network down'));
    expect(
      await downloadImageBytes('https://example.com/a.png', client: down),
      isNull,
    );
  });

  test(
    'downloadImageBytes retries once on a stall (timeout), then returns bytes',
    () async {
      var calls = 0;
      final flaky = MockClient((req) async {
        calls++;
        if (calls == 1) {
          throw TimeoutException('connection stalled (NAT idle cut)');
        }
        return _imageResponse(_pngBytes);
      });
      expect(
        await downloadImageBytes('https://example.com/a.png', client: flaky),
        _pngBytes,
      );
      expect(calls, 2, reason: '连接停滞(超时)应重试一次');
    },
  );

  test('downloadImageBytes gives up after two stalls (timeouts)', () async {
    var calls = 0;
    final stalled = MockClient((req) async {
      calls++;
      throw TimeoutException('still stalled');
    });
    expect(
      await downloadImageBytes('https://example.com/a.png', client: stalled),
      isNull,
    );
    expect(calls, 2, reason: '两次停滞后放弃');
  });

  test(
    'downloadImageBytes does not retry an immediate connection refusal',
    () async {
      var calls = 0;
      final refused = MockClient((req) async {
        calls++;
        throw Exception('Connection refused');
      });
      expect(
        await downloadImageBytes('https://example.com/a.png', client: refused),
        isNull,
      );
      expect(calls, 1, reason: '连接拒绝是确定性失败,不应重试(重试只会把已知失败拖成两倍时长)');
    },
  );

  test(
    'downloadImageBytes does not retry a deterministic HTTP failure',
    () async {
      var calls = 0;
      final bad = MockClient((req) async {
        calls++;
        return http.Response('denied', 403);
      });
      expect(
        await downloadImageBytes('https://example.com/a.png', client: bad),
        isNull,
      );
      expect(calls, 1, reason: '服务端确定性拒绝不应重试');
    },
  );

  test(
    'downloadImageBytes treats an empty 200 body as a failure (no useless URL-only rows)',
    () async {
      var calls = 0;
      final empty = MockClient((req) async {
        calls++;
        return _imageResponse(Uint8List(0));
      });
      expect(
        await downloadImageBytes('https://example.com/a.png', client: empty),
        isNull,
      );
      expect(calls, 1, reason: '空 body 是确定性失败,不重试');
    },
  );

  test('redirects are not followed and never reach the target', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      expect(req.followRedirects, isFalse, reason: '请求必须显式禁止跟随重定向');
      return http.Response(
        '',
        302,
        headers: {'location': 'http://169.254.169.254/latest/meta-data/'},
      );
    });
    expect(
      await downloadImageBytes('https://example.com/a.png', client: client),
      isNull,
    );
    expect(calls, 1, reason: '3xx 是确定性拒绝,不重试也不跟随');
  });

  test(
    'loopback/private/link-local hosts are rejected before any IO',
    () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return _imageResponse(_pngBytes);
      });
      final blocked = [
        'http://127.0.0.1/a.png',
        'http://10.0.0.1/a.png',
        'http://100.64.0.1/a.png',
        'http://172.16.0.1/a.png',
        'http://172.31.255.254/a.png',
        'http://192.168.1.1/a.png',
        'http://169.254.169.254/latest/meta-data/',
        'http://0.0.0.0/a.png',
        'http://localhost/a.png',
        'http://foo.localhost/a.png',
        'http://[::1]/a.png',
        'http://[fc00::1]/a.png',
        'http://[fe80::1]/a.png',
        'http://[::ffff:127.0.0.1]/a.png',
      ];
      for (final url in blocked) {
        expect(
          await downloadImageBytes(url, client: client),
          isNull,
          reason: url,
        );
      }
      expect(calls, 0, reason: '受限地址必须在发起请求前拒绝');
    },
  );

  test('only http(s) absolute URLs without userinfo are accepted', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return _imageResponse(_pngBytes);
    });
    for (final url in [
      'ftp://example.com/a.png',
      'file:///etc/passwd',
      'https://user:pass@example.com/a.png',
      'not a url',
    ]) {
      expect(
        await downloadImageBytes(url, client: client),
        isNull,
        reason: url,
      );
    }
    expect(calls, 0);
  });

  test(
    'non-image content types are rejected even for image-like bytes',
    () async {
      var calls = 0;
      final html = MockClient((req) async {
        calls++;
        return http.Response.bytes(
          _pngBytes,
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      expect(
        await downloadImageBytes('https://example.com/a.png', client: html),
        isNull,
      );
      expect(calls, 1);
    },
  );

  test('an image content type does not make HTML bytes acceptable', () async {
    final lying = MockClient(
      (req) async => http.Response(
        '<html>error</html>',
        200,
        headers: {'content-type': 'image/png'},
      ),
    );
    expect(
      await downloadImageBytes('https://example.com/a.png', client: lying),
      isNull,
    );
  });

  test('missing content type requires a real image magic', () async {
    final html = MockClient(
      (req) async => http.Response('<html>not an image</html>', 200),
    );
    expect(
      await downloadImageBytes('https://example.com/a.png', client: html),
      isNull,
    );
    final png = MockClient((req) async => http.Response.bytes(_pngBytes, 200));
    expect(
      await downloadImageBytes('https://example.com/a.png', client: png),
      _pngBytes,
    );
  });

  test(
    'octet-stream responses are accepted only with a real image magic',
    () async {
      final html = MockClient(
        (req) async => http.Response(
          '<!doctype html>',
          200,
          headers: {'content-type': 'application/octet-stream'},
        ),
      );
      expect(
        await downloadImageBytes('https://example.com/a.png', client: html),
        isNull,
      );
      final png = MockClient(
        (req) async => http.Response.bytes(
          _pngBytes,
          200,
          headers: {'content-type': 'binary/octet-stream'},
        ),
      );
      expect(
        await downloadImageBytes('https://example.com/a.png', client: png),
        _pngBytes,
      );
    },
  );

  test('oversized bodies are aborted without retrying', () async {
    var calls = 0;
    final tooLarge = Uint8List(maxDownloadImageBytes + 1)
      ..setRange(0, _pngBytes.length, _pngBytes);
    final client = MockClient((req) async {
      calls++;
      return _imageResponse(tooLarge);
    });
    expect(
      await downloadImageBytes('https://example.com/huge.png', client: client),
      isNull,
    );
    expect(calls, 1, reason: '超限是确定性失败,重试只会再传一遍 16MiB');
  });

  test('downloadImageBase64 fetches a 200 response body as base64', () async {
    final client = MockClient((req) async => _imageResponse(_pngBytes));
    expect(
      await downloadImageBase64('https://example.com/a.png', client: client),
      base64Encode(_pngBytes),
    );
  });

  test('downloadImageBase64 returns null on non-200', () async {
    final client = MockClient((req) async => http.Response('boom', 500));
    expect(
      await downloadImageBase64('https://example.com/a.png', client: client),
      isNull,
    );
  });

  test('downloadImageBase64 returns null when the request throws', () async {
    final client = MockClient((req) async => throw Exception('network down'));
    expect(
      await downloadImageBase64('https://example.com/a.png', client: client),
      isNull,
    );
  });
}
