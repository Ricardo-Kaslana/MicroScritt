// 生图插件宿主测试:http/sleep/done 状态机、预算与截断、origin 权限。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/plugin_image_backend.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/models/image_plugin.dart';

import '../support/held_sse_server.dart';
import '../support/plugin_js_engine.dart';

void main() {
  const imageBase64 = 'AQID';
  const pollingCode = r'''
function step(ctx) {
  if (ctx.operation !== "generate") return {action: "error", message: "op"};
  if (ctx.phase === "start") {
    return {action: "http", state: {}, request: {method: "POST", url: "jobs", json: {prompt: ctx.prompt}}};
  }
  if (ctx.phase === "http" && !ctx.state.job) {
    return {action: "sleep", state: {job: JSON.parse(ctx.response.text).id}, milliseconds: 0};
  }
  if (ctx.phase === "sleep") {
    return {action: "http", state: ctx.state, request: {method: "GET", url: "jobs/" + ctx.state.job}};
  }
  return {action: "done", images: [{base64: JSON.parse(ctx.response.text).image}]};
}
''';

  ImagePlugin plugin({
    bool enabled = true,
    bool test = false,
    bool list = false,
  }) => ImagePlugin(
    id: 'test.polling',
    name: 'Polling',
    version: '1.0.0',
    code: pollingCode,
    enabled: enabled,
    supportsTest: test,
    supportsListModels: list,
    fields: const [
      ImagePluginField(
        key: 'size',
        label: '尺寸',
        type: ImagePluginFieldType.text,
      ),
    ],
    permissions: const ImagePluginPermissions(endpointSetting: 'baseUrl'),
  );

  // baseUrl 由核心配置列提供,宿主合并进 ctx.settings;pluginSettings 只放
  // 插件声明的动态字段。
  ImageConfig config(String baseUrl) => ImageConfig(
    kind: ImageBackendKind.plugin,
    apiKey: 'k',
    model: 'm',
    baseUrl: baseUrl,
    pluginId: 'test.polling',
  );

  Future<HttpServer> startServer(
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await handler(request);
    });
    return server;
  }

  String origin(HttpServer server) =>
      'http://${server.address.host}:${server.port}';

  test(
    'Dart host executes http, sleep and polling before returning base64 images',
    () async {
      final requests = <String>[];
      final server = await startServer((request) {
        requests.add('${request.method} ${request.uri.path}');
        request.response.write(
          jsonEncode(
            request.method == 'POST' ? {'id': 'job-1'} : {'image': imageBase64},
          ),
        );
        request.response.close();
      });
      final actions = <Map<String, dynamic>>[
        {
          'action': 'http',
          'state': {},
          'request': {
            'method': 'POST',
            'url': 'jobs',
            'json': {'prompt': 'a cat'},
          },
        },
        {
          'action': 'sleep',
          'state': {'job': 'job-1'},
          'milliseconds': 0,
        },
        {
          'action': 'http',
          'state': {'job': 'job-1'},
          'request': {'method': 'GET', 'url': 'jobs/job-1'},
        },
        {
          'action': 'done',
          'images': [
            {'base64': imageBase64},
          ],
        },
      ];
      var index = 0;
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        evaluator: (_) async => jsonEncode(actions[index++]),
      );

      final result = await backend.generateImage('a cat');

      expect(result.images.single.base64, imageBase64);
      expect(requests, ['POST /jobs', 'GET /jobs/job-1']);
      expect(index, 4);
    },
  );

  test(
    'real JS runs the plugin state machine against a local job API',
    () async {
      final engine = await probePluginJsEngine();
      if (engine == null) {
        return markTestSkipped('QuickJS 与 Node 均不可用,插件状态机未执行');
      }
      addTearDown(engine.dispose);
      final server = await startServer((request) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            request.method == 'POST' ? {'id': 'job-2'} : {'image': imageBase64},
          ),
        );
        request.response.close();
      });
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        evaluator: engine.evaluate,
      );

      final result = await backend.generateImage('a real JS request');

      expect(result.images.single.base64, imageBase64);
    },
  );

  test(
    'bundled OpenAI Images example imports and generates via core baseUrl',
    () async {
      final engine = await probePluginJsEngine();
      if (engine == null) {
        return markTestSkipped('QuickJS 与 Node 均不可用,插件状态机未执行');
      }
      addTearDown(engine.dispose);
      final example = ImagePlugin.fromPackageJson(
        await File('examples/image_plugins/openai_images.json').readAsString(),
      );
      String? path;
      String? authorization;
      Map<String, dynamic>? body;
      final server = await startServer((request) async {
        path = request.uri.path;
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'data': [
              {'b64_json': imageBase64},
            ],
          }),
        );
        await request.response.close();
      });
      final backend = PluginImageBackend(
        config: ImageConfig(
          kind: ImageBackendKind.plugin,
          apiKey: 'secret',
          model: 'test-model',
          baseUrl: '${origin(server)}/v1',
          pluginId: example.id,
          pluginSettings: const {'size': '1024x1024'},
        ),
        plugin: example,
        evaluator: engine.evaluate,
      );

      final result = await backend.generateImage('a plugin-only image');

      expect(result.images.single.base64, imageBase64);
      expect(path, '/v1/images/generations');
      expect(authorization, 'Bearer secret');
      expect(body, {
        'model': 'test-model',
        'prompt': 'a plugin-only image',
        'size': '1024x1024',
        'response_format': 'b64_json',
      });
    },
  );

  test(
    'request timeoutMs may exceed the injected requestTimeout (queued generation)',
    () async {
      // 对话式生图网关的生成 POST 要 5 分钟;若宿主把插件请求的 timeoutMs 再夹回
      // requestTimeout,等于该能力不存在 —— 正在排队出图的请求被稳定掐死。
      final server = await startServer((request) async {
        await utf8.decoder.bind(request).join();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        request.response
          ..headers.contentType = ContentType.json
          ..write('{}');
        await request.response.close();
      });
      var evaluations = 0;
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        requestTimeout: const Duration(milliseconds: 300),
        timeout: const Duration(seconds: 20),
        evaluator: (_) async {
          evaluations++;
          if (evaluations == 1) {
            return jsonEncode({
              'action': 'http',
              'state': null,
              'request': {
                'method': 'POST',
                'url': 'slow',
                'json': {'a': 1},
                'timeoutMs': 300000,
              },
            });
          }
          return jsonEncode({
            'action': 'done',
            'images': [
              {'base64': imageBase64},
            ],
          });
        },
      );

      final result = await backend.generateImage('x');
      expect(result.images.single.base64, imageBase64);
    },
  );

  test(
    'stopWhen aborts the body read as soon as the pattern matches',
    () async {
      // 服务端把链接发完就保活 2s 才关流:没有 stopWhen,generateImage 就得等满
      // 这 2s(真实网关是数十秒),把已经到手的图拖成超时。
      final server = await serveHeldEventStream([
        'data: partial\n\n',
        'data: ![image](https://cdn.example.com/a.png)\n\n',
      ]);
      addTearDown(() => server.close(force: true));
      var evaluations = 0;
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        timeout: const Duration(seconds: 20),
        evaluator: (script) async {
          evaluations++;
          if (evaluations == 1) {
            return jsonEncode({
              'action': 'http',
              'state': null,
              'request': {
                'method': 'POST',
                'url': 'stream',
                'json': {'a': 1},
                'stopWhen': {'contains': '](', 'regex': r'!\[[^\]]*\]\((https?://[^)\s]+)\)'},
              },
            });
          }
          expect(script, contains('cdn.example.com'));
          expect(script, contains(r'\"partial\":true'));
          return jsonEncode({
            'action': 'done',
            'images': [
              {'url': 'https://cdn.example.com/a.png'},
            ],
          });
        },
      );

      final sw = Stopwatch()..start();
      final result = await backend.generateImage('x');
      sw.stop();
      expect(result.images.single.url, 'https://cdn.example.com/a.png');
      expect(sw.elapsedMilliseconds, lessThan(1000));
    },
  );

  test(
    'without stopWhen the whole stream is read (no silent truncation)',
    () async {
      final server = await serveHeldEventStream([
        'data: partial\n\n',
        'data: tail\n\n',
      ]);
      addTearDown(() => server.close(force: true));
      var evaluations = 0;
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        evaluator: (script) async {
          evaluations++;
          if (evaluations == 1) {
            return jsonEncode({
              'action': 'http',
              'state': null,
              'request': {'method': 'POST', 'url': 'stream', 'json': {'a': 1}},
            });
          }
          expect(script, isNot(contains(r'\"partial\":true')));
          expect(script, contains('data: tail'));
          return jsonEncode({
            'action': 'done',
            'images': [
              {'base64': imageBase64},
            ],
          });
        },
      );

      await backend.generateImage('x');
      expect(evaluations, 2);
    },
  );

  test('malformed stopWhen is rejected as plugin misbehaviour', () async {
    Future<void> runWith(Map<String, dynamic> stopWhen) async {
      var evaluations = 0;
      final backend = PluginImageBackend(
        config: config('http://127.0.0.1:12345'),
        plugin: plugin(),
        evaluator: (_) async {
          evaluations++;
          if (evaluations == 1) {
            return jsonEncode({
              'action': 'http',
              'state': null,
              'request': {
                'method': 'POST',
                'url': 'x',
                'json': {'a': 1},
                'stopWhen': stopWhen,
              },
            });
          }
          return null;
        },
      );
      await expectLater(
        backend.generateImage('x'),
        throwsA(isA<ImagePluginException>()),
      );
    }

    await runWith({'contains': ']', 'regex': '(((('});
    await runWith({'contains': ''});
  });

  test(
    'text and base64 request bodies use bounded Dart host encoding',
    () async {
      final bodies = <String>[];
      final contentTypes = <String?>[];
      final server = await startServer((request) async {
        contentTypes.add(request.headers.contentType?.mimeType);
        bodies.add(await utf8.decoder.bind(request).join());
        request.response.write('{}');
        await request.response.close();
      });
      var index = 0;
      final actions = <Map<String, dynamic>>[
        {
          'action': 'http',
          'state': null,
          'request': {'method': 'POST', 'url': 'text', 'text': 'hello'},
        },
        {
          'action': 'http',
          'state': null,
          'request': {'method': 'PUT', 'url': 'binary', 'base64': 'AQID'},
        },
        {
          'action': 'done',
          'images': [
            {'base64': imageBase64},
          ],
        },
      ];
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        evaluator: (_) async => jsonEncode(actions[index++]),
      );

      await backend.generateImage('x');

      expect(bodies[0], 'hello');
      expect(bodies[1].codeUnits, [1, 2, 3]);
      expect(contentTypes, ['text/plain', 'application/octet-stream']);
    },
  );

  test(
    'transport timeout is surfaced to JS as a retryable failure (host never retries)',
    () async {
      var hits = 0;
      final server = await startServer((request) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await request.response.close();
      });
      var evaluations = 0;
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        requestTimeout: const Duration(milliseconds: 20),
        evaluator: (script) async {
          evaluations++;
          if (evaluations == 1) {
            return jsonEncode({
              'action': 'http',
              'state': null,
              'request': {'method': 'POST', 'url': 'slow'},
            });
          }
          expect(script, contains(r'\"error\":\"timeout\"'));
          expect(script, contains(r'\"receivedBytes\":false'));
          return jsonEncode({'action': 'error', 'message': '放弃'});
        },
      );

      await expectLater(
        backend.generateImage('x'),
        throwsA(isA<ImagePluginException>()),
      );
      expect(hits, 1, reason: '宿主不自动重试,交由 JS 决策');
    },
  );

  test('JS can drive a second attempt after a no-data failure', () async {
    var hits = 0;
    final server = await startServer((request) async {
      hits++;
      request.response.write('{}');
      await request.response.close();
    });
    var evaluations = 0;
    final backend = PluginImageBackend(
      config: config(origin(server)),
      plugin: plugin(),
      evaluator: (script) async {
        evaluations++;
        if (evaluations == 1) {
          return jsonEncode({
            'action': 'http',
            'state': {'retried': false},
            'request': {'method': 'POST', 'url': 'a'},
          });
        }
        // 第一次成功返回后,JS 主动再发一次(模拟重试)。
        if (evaluations == 2) {
          return jsonEncode({
            'action': 'http',
            'state': {'retried': true},
            'request': {'method': 'POST', 'url': 'b'},
          });
        }
        return jsonEncode({
          'action': 'done',
          'images': [
            {'base64': imageBase64},
          ],
        });
      },
    );

    await backend.generateImage('x');
    expect(hits, 2);
  });

  test(
    'done may return a remote URL, handed to the upper-layer downloader as-is',
    () async {
      final backend = PluginImageBackend(
        config: config('http://127.0.0.1:12345'),
        plugin: plugin(),
        evaluator: (_) async => jsonEncode({
          'action': 'done',
          'images': [
            {'url': 'https://cdn.example.com/img.png'},
          ],
        }),
      );

      final result = await backend.generateImage('x');
      expect(result.images.single.url, 'https://cdn.example.com/img.png');
      expect(result.images.single.base64, isNull);
    },
  );

  test('standard params and negativePrompt are injected into ctx', () async {
    final backend = PluginImageBackend(
      config: ImageConfig(
        kind: ImageBackendKind.plugin,
        apiKey: 'k',
        model: 'm',
        baseUrl: 'http://127.0.0.1:12345',
        size: '横图',
        scale: 7,
        pluginId: 'test.polling',
      ),
      plugin: plugin(),
      evaluator: (script) async {
        expect(script, contains(r'\"params\"'));
        expect(script, contains('横图'));
        expect(script, contains(r'\"negativePrompt\"'));
        return jsonEncode({
          'action': 'done',
          'images': [
            {'base64': imageBase64},
          ],
        });
      },
    );
    await backend.generateImage('x');
  });

  test(
    'probe/listModels run the state machine under their operation',
    () async {
      final probeBackend = PluginImageBackend(
        config: config('http://127.0.0.1:12345'),
        plugin: plugin(test: true),
        evaluator: (script) async {
          expect(script, contains(r'\"operation\":\"test\"'));
          return jsonEncode({'action': 'done', 'message': '密钥有效 · 余额 10 点'});
        },
      );
      final probe = await probeBackend.probe();
      expect(probe?.summary, contains('余额'));

      final listBackend = PluginImageBackend(
        config: config('http://127.0.0.1:12345'),
        plugin: plugin(list: true),
        evaluator: (script) async {
          expect(script, contains(r'\"operation\":\"listModels\"'));
          return jsonEncode({
            'action': 'done',
            'models': ['nai-a', 'nai-b'],
          });
        },
      );
      expect(await listBackend.listModels(), ['nai-a', 'nai-b']);
    },
  );

  test(
    'unsupported probe/listModels short-circuit without running JS',
    () async {
      var evaluated = false;
      final backend = PluginImageBackend(
        config: config('http://127.0.0.1:12345'),
        plugin: plugin(),
        evaluator: (_) async {
          evaluated = true;
          return null;
        },
      );
      expect(await backend.probe(), isNull);
      expect(await backend.listModels(), isEmpty);
      expect(evaluated, isFalse);
    },
  );

  test('request origin must be granted by the endpoint or manifest', () async {
    final backend = PluginImageBackend(
      config: config('http://127.0.0.1:12345'),
      plugin: plugin(),
      evaluator: (_) async => jsonEncode({
        'action': 'http',
        'state': null,
        'request': {'method': 'GET', 'url': 'https://example.com/image'},
      }),
    );
    await expectLater(
      backend.generateImage('x'),
      throwsA(isA<ImagePluginException>()),
    );
  });

  test(
    'invalid final base64 is rejected instead of persisted as an image',
    () async {
      final backend = PluginImageBackend(
        config: config('http://127.0.0.1:12345'),
        plugin: plugin(),
        evaluator: (_) async => jsonEncode({
          'action': 'done',
          'images': [
            {'base64': 'not base64!'},
          ],
        }),
      );
      await expectLater(
        backend.generateImage('x'),
        throwsA(isA<ImagePluginException>()),
      );
    },
  );

  test(
    'redirect responses are returned to JS without following them',
    () async {
      var hits = 0;
      final server = await startServer((request) {
        hits++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/image');
        request.response.close();
      });
      var evaluations = 0;
      final backend = PluginImageBackend(
        config: config(origin(server)),
        plugin: plugin(),
        evaluator: (script) async {
          evaluations++;
          if (evaluations == 1) {
            return jsonEncode({
              'action': 'http',
              'state': null,
              'request': {'method': 'GET', 'url': 'start'},
            });
          }
          expect(script, contains(r'\"isRedirect\":true'));
          return jsonEncode({
            'action': 'done',
            'images': [
              {'base64': imageBase64},
            ],
          });
        },
      );

      await backend.generateImage('x');
      expect(hits, 1);
    },
  );

  test('missing, disabled or runtime-less plugins fail explicitly', () async {
    final cfg = config('http://127.0.0.1:12345');
    for (final backend in [
      PluginImageBackend(
        config: cfg,
        plugin: null,
        evaluator: (_) async => null,
      ),
      PluginImageBackend(
        config: cfg,
        plugin: plugin(enabled: false),
        evaluator: (_) async => null,
      ),
      PluginImageBackend(config: cfg, plugin: plugin(), evaluator: null),
    ]) {
      await expectLater(
        backend.generateImage('x'),
        throwsA(isA<ImagePluginException>()),
      );
    }
  });
}
