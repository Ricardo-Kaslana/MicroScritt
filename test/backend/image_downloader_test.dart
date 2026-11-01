import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/backend/image_downloader.dart';

void main() {
  test('downloadImageBytes fetches a 200 response body', () async {
    final client = MockClient((req) async => http.Response.bytes(utf8.encode('hello'), 200));
    expect(await downloadImageBytes('https://example.com/a.png', client: client), utf8.encode('hello'));
  });

  test('downloadImageBytes returns null on non-200 and on throw', () async {
    final bad = MockClient((req) async => http.Response('boom', 500));
    expect(await downloadImageBytes('https://example.com/a.png', client: bad), isNull);
    final down = MockClient((req) async => throw Exception('network down'));
    expect(await downloadImageBytes('https://example.com/a.png', client: down), isNull);
  });

  test('downloadImageBytes retries once on a stall (timeout), then returns bytes', () async {
    var calls = 0;
    final flaky = MockClient((req) async {
      calls++;
      if (calls == 1) throw TimeoutException('connection stalled (NAT idle cut)');
      return http.Response.bytes(utf8.encode('ok'), 200);
    });
    expect(await downloadImageBytes('https://example.com/a.png', client: flaky), utf8.encode('ok'));
    expect(calls, 2, reason: '连接停滞(超时)应重试一次');
  });

  test('downloadImageBytes gives up after two stalls (timeouts)', () async {
    var calls = 0;
    final stalled = MockClient((req) async {
      calls++;
      throw TimeoutException('still stalled');
    });
    expect(await downloadImageBytes('https://example.com/a.png', client: stalled), isNull);
    expect(calls, 2, reason: '两次停滞后放弃');
  });

  test('downloadImageBytes does not retry an immediate connection refusal', () async {
    var calls = 0;
    final refused = MockClient((req) async {
      calls++;
      throw Exception('Connection refused');
    });
    expect(await downloadImageBytes('https://example.com/a.png', client: refused), isNull);
    expect(calls, 1, reason: '连接拒绝是确定性失败,不应重试(重试只会把已知失败拖成两倍时长)');
  });

  test('downloadImageBytes does not retry a deterministic HTTP failure', () async {
    var calls = 0;
    final bad = MockClient((req) async {
      calls++;
      return http.Response('denied', 403);
    });
    expect(await downloadImageBytes('https://example.com/a.png', client: bad), isNull);
    expect(calls, 1, reason: '服务端确定性拒绝不应重试');
  });

  test('downloadImageBytes treats an empty 200 body as a failure (no useless URL-only rows)', () async {
    var calls = 0;
    final empty = MockClient((req) async {
      calls++;
      return http.Response('', 200);
    });
    expect(await downloadImageBytes('https://example.com/a.png', client: empty), isNull);
    expect(calls, 1, reason: '空 body 是确定性失败,不重试');
  });

  test('downloadImageBase64 fetches a 200 response body as base64', () async {
    final client = MockClient((req) async => http.Response.bytes(utf8.encode('hello'), 200));
    expect(await downloadImageBase64('https://example.com/a.png', client: client), base64Encode(utf8.encode('hello')));
  });

  test('downloadImageBase64 returns null on non-200', () async {
    final client = MockClient((req) async => http.Response('boom', 500));
    expect(await downloadImageBase64('https://example.com/a.png', client: client), isNull);
  });

  test('downloadImageBase64 returns null when the request throws', () async {
    final client = MockClient((req) async => throw Exception('network down'));
    expect(await downloadImageBase64('https://example.com/a.png', client: client), isNull);
  });
}
