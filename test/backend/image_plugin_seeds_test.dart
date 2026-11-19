// 内置生图协议插件测试:经真实 JS 引擎(QuickJS 优先、回落 Node)
// 驱动两条种子插件,覆盖 7 行字段体、链接截断、零字节重试与防重复计费。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/plugin_image_backend.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/models/image_plugin.dart';
import 'package:microscritt/models/image_plugin_seeds.dart';

import '../support/held_sse_server.dart';
import '../support/plugin_js_engine.dart';

void main() {
  PluginJsEngine? js;

  // Windows 的 flutter test 宿主加载不到 QuickJS 桥接库,引擎回落 Node;
  // 种子 JS 只用 ES5 语法,两引擎行为一致;都不可用时 markTestSkipped,不能静默 return。
  setUpAll(() async {
    js = await probePluginJsEngine();
  });
  tearDownAll(() => js?.dispose());

  ImagePlugin seed(String id) =>
      kDefaultImagePluginSeeds.firstWhere((p) => p.id == id);

  Future<HttpServer> serve(
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async => handler(request));
    return server;
  }

  String origin(HttpServer s) => 'http://${s.address.host}:${s.port}';

  /// 往裸 socket 写一帧 HTTP/1.1 chunked 数据(长度头 + 载荷 + CRLF)。
  /// 漏掉长度头,客户端解析器会报「expected to be a Hex digit」而不是收到数据后断流。
  void writeFrame(Socket socket, List<int> bytes) {
    socket.write('${bytes.length.toRadixString(16)}\r\n');
    socket.add(bytes);
    socket.write('\r\n');
  }

  /// 起一个「按脚本依次应答」的服务,记录每个请求的路径与 JSON 体。
  Future<HttpServer> scripted(
    List<FutureOr<void> Function(HttpRequest request, int hit)> replies,
  ) async {
    var hit = 0;
    return serve((request) async {
      final index = hit++;
      final reply = index < replies.length
          ? replies[index]
          : replies.last; // 超出脚本的命中重复最后一条(便于断言上限)
      await reply(request, index);
    });
  }

  PluginImageBackend chat(
    String baseUrl, {
    String? negative,
    String? size,
    int? steps,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration timeout = const Duration(minutes: 5),
  }) => PluginImageBackend(
    config: ImageConfig(
      kind: ImageBackendKind.plugin,
      apiKey: 'sk-abc',
      model: 'nai-diffusion-4-5-full:k_dpmpp_2m_sde',
      baseUrl: baseUrl,
      negative: negative,
      size: size,
      scale: 6,
      cfg: 0,
      steps: steps,
      pluginId: 'microscritt.chat-completions',
    ),
    plugin: seed('microscritt.chat-completions'),
    evaluator: js!.evaluate,
    requestTimeout: requestTimeout,
    timeout: timeout,
  );

  PluginImageBackend nai2(String baseUrl) => PluginImageBackend(
    config: ImageConfig(
      kind: ImageBackendKind.plugin,
      apiKey: 'nai-token',
      model: 'nai-diffusion-4-5-full',
      baseUrl: baseUrl,
      pluginId: 'microscritt.nai2',
    ),
    plugin: seed('microscritt.nai2'),
    evaluator: js!.evaluate,
  );

  String sseText(String content) =>
      'data: ${jsonEncode({'choices': [
        {'delta': {'content': content}},
      ]})}\n\n';

  // 返回字节而不是 String:HttpServer 对 String 写入按响应 content-type 的 charset
  // 编码,而 text/event-stream 默认 latin-1 —— 带中文的分片会把 mock 服务端自己
  // 炸掉(Invalid argument: Contains invalid characters),表现为客户端挂住超时。
  List<int> sse(String content) => utf8.encode(sseText(content));

  test('对话式网关:7 行字段块 + SSE 分片重组出链接', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    Map<String, dynamic>? body;
    final server = await serve((request) async {
      body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.parse('text/event-stream');
      // 真实网关会把 Markdown 链接从 URL 中间切断成分片。
      request.response
        ..add(sse('排队中… ![image](https://cdn'))
        ..add(sse('.example.com/a.png) 完成'))
        ..write('data: [DONE]\n\n');
      await request.response.close();
    });

    final result = await chat(origin(server), negative: 'lowres')
        .generateImage('一只  银发\n猫娘');

    expect(result.images.single.url, 'https://cdn.example.com/a.png');
    final content = (body!['messages'] as List).first['content'] as String;
    expect(content, contains('提示词:一只 银发 猫娘'));
    expect(content, contains('尺寸:竖图')); // size 未配置 → 兜底(留空必 400)
    expect(content, contains('提示词引导值:6'));
    expect(content, contains('缩放引导值:0'));
    expect(content, contains('负面提示词:lowres'));
    expect(content, contains('采样器:'));
    expect(content.split('\n').length, 7, reason: '缺行会 400「请求格式错误」');
    expect(body!['stream'], true);
    expect(body!.containsKey('n'), isFalse, reason: '多张由上层展开,网关不响应 n');
  });

  test('对话式网关:消毒剥引号(含反引号)但保留反斜杠', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    String? content;
    final server = await serve((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      content = body['messages'][0]['content'] as String;
      request.response
        ..headers.contentType = ContentType.parse('text/event-stream')
        ..add(sse('![image](https://cdn.example.com/a.png)'))
        ..write('data: [DONE]\n\n');
      await request.response.close();
    });

    await chat(origin(server), negative: "bad 'words`here").generateImage("a 'b`c\\d");

    // 单引号/反引号都该剥,反斜杠是 NovelAI tag 语法必须保留。
    expect(content, contains(r'提示词:a bc\d'));
    expect(content, contains('负面提示词:bad wordshere'));
  });

  test('对话式网关:nai 覆盖对象逐字段跟随显式配置,全空则整个不发', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final bodies = <Map<String, dynamic>>[];
    final server = await serve((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response
        ..headers.contentType = ContentType.parse('text/event-stream')
        ..add(sse('![image](https://cdn.example.com/a.png)'))
        ..write('data: [DONE]\n\n');
      await request.response.close();
    });

    // 显式配置了负面词 → nai.negative 用**用户原值**(不是默认负面词)。
    // steps 与 Nai2API 共用同一份标准参数,同样经 nai 覆盖下发。
    await chat(origin(server), negative: 'lowres', size: '横图', steps: 35)
        .generateImage('x');
    final nai = bodies.last['nai'] as Map<String, dynamic>;
    expect(nai['negative'], 'lowres');
    expect(nai['size'], '横图');
    expect(nai['steps'], 35);

    // 未配置负面词时,兜底默认词只进 7 行消息、不进 nai 覆盖:
    // 网关对未预期的 nai.negative 会 400,多发就是整轮生图失败。
    final bare = PluginImageBackend(
      config: ImageConfig(
        kind: ImageBackendKind.plugin,
        apiKey: 'sk-abc',
        model: 'm',
        baseUrl: origin(server),
        pluginId: 'microscritt.chat-completions',
      ),
      plugin: seed('microscritt.chat-completions'),
      evaluator: js!.evaluate,
    );
    final bareResult = await bare.generateImage('x');
    expect(bareResult.images.single.url, 'https://cdn.example.com/a.png');
    expect(
      bodies.last.containsKey('nai'),
      isFalse,
      reason: '所有可覆盖项都未配置时不发 nai(与旧后端 isNotEmpty 判定一致)',
    );
    expect(
      (bodies.last['messages'] as List).first['content'],
      contains('负面提示词:{{{bad anatomy}}}'),
      reason: '默认负面词只进消息行,不进覆盖对象',
    );
  });

  test('对话式网关:链接到位即断流,不等服务端关流', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final server = await serveHeldEventStream([
      sseText('排队中…'),
      sseText('![image](https://cdn.example.com/a.png)'),
      'data: [DONE]\n\n',
    ]);
    addTearDown(() => server.close(force: true));

    final sw = Stopwatch()..start();
    final result = await chat(origin(server), negative: 'lowres')
        .generateImage('x');
    sw.stop();

    expect(result.images.single.url, 'https://cdn.example.com/a.png');
    expect(
      sw.elapsedMilliseconds,
      lessThan(1000),
      reason: 'stopWhen 未生效:等了服务端保活的 2 秒才拿到已经到手的图',
    );
  });

  test('对话式网关:stopWhen 截断在半截 SSE 事件里仍能取到链接', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    // 真实网络分片不会照顾 SSE 事件边界:链接一出现宿主就断流,最后一个事件
    // 常只剩半截 JSON(甚至半截多字节字符)。此前 extractContent 解析不出它,
    // 整次生图被误判成「未找到图片链接」—— 偶发失败,重跑同一内容可能复现。
    final prefix = '完成 ![image](https://cdn.example.com/a.png)';
    final event = sseText('$prefix 中文尾巴');
    final bytes = utf8.encode(event);
    final cuts = <String, int>{
      // ')' 之后、JSON 事件闭合之前。
      'mid-event': utf8.encode(
        event.substring(0, event.indexOf('a.png)') + 'a.png)'.length),
      ).length,
      // 链接后的多字节字符中间(半截 UTF-8 编码单元)。
      'mid-utf8': utf8.encode(event.substring(0, event.indexOf('中') + 1)).length - 1,
    };
    for (final cut in cuts.entries) {
      final server = await serveHeldByteStream([bytes.sublist(0, cut.value)]);
      addTearDown(() => server.close(force: true));
      final result = await chat(
        origin(server),
        negative: 'lowres',
      ).generateImage('x');
      expect(
        result.images.single.url,
        'https://cdn.example.com/a.png',
        reason: cut.key,
      );
    }
  });

  test('对话式网关:timeoutMs 让生成 POST 用分钟级预算(不被压回 30s)', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final server = await serve((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 1200)); // 模拟排队
      request.response
        ..headers.contentType = ContentType.parse('text/event-stream')
        ..add(sse('![image](https://cdn.example.com/a.png)'))
        ..write('data: [DONE]\n\n');
      await request.response.close();
    });

    final result = await chat(
      origin(server),
      negative: 'lowres',
      requestTimeout: const Duration(milliseconds: 300),
      timeout: const Duration(seconds: 20),
    ).generateImage('x');

    expect(result.images.single.url, 'https://cdn.example.com/a.png');
  });

  test('对话式网关:零字节断连才重试一次', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    var hits = 0;
    final server = await scripted([
      (request, _) async {
        hits++;
        await utf8.decoder.bind(request).join(); // 读完请求体才允许改派 socket
        final socket = await request.response.detachSocket();
        socket.destroy(); // 请求送达前断连:未收到任何数据,可安全重试
      },
      (request, _) async {
        hits++;
        request.response
          ..headers.contentType = ContentType.parse('text/event-stream')
          ..add(sse('![image](https://cdn.example.com/b.png)'))
          ..write('data: [DONE]\n\n');
        await request.response.close();
      },
    ]);

    final result = await chat(origin(server), negative: 'lowres')
        .generateImage('x');

    expect(result.images.single.url, 'https://cdn.example.com/b.png');
    expect(hits, 2);
  });

  test('对话式网关:收到过排队数据后绝不重试(防重复计费)', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    var hits = 0;
    final server = await serve((request) async {
      hits++;
      await utf8.decoder.bind(request).join();
      // 裸 socket:先发一帧真实 SSE 数据,再不带 chunked 终止帧地掐断连接 ——
      // 客户端确实收到过字节(=服务端已受理并在出图),此时重试就是重复计费。
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n'
        'transfer-encoding: chunked\r\n\r\n',
      );
      writeFrame(socket, sse('排队中…'));
      await socket.flush();
      // 让客户端先把这一帧读走再断:立刻 close 会被解析器判成「chunked 响应未完成」
      // 并在交付缓冲数据前就报错,receivedBytes 仍是 false,测不到目标分支。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close();
    });

    await expectLater(
      chat(origin(server), negative: 'lowres').generateImage('x'),
      throwsA(isA<ImagePluginException>()),
    );
    expect(hits, 1, reason: '已收到 SSE 分片就不能再提交第二次');
  });

  test('对话式网关:4xx 回显服务端原因,未找到链接是确定性失败', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final server = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 400
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': {'message': '请求格式错误'},
        }));
      await request.response.close();
    });
    var message = '';
    try {
      await chat(origin(server), negative: 'lowres').generateImage('x');
    } on ImagePluginException catch (e) {
      message = e.message;
    }
    expect(message, contains('HTTP 400'));
    expect(message, contains('请求格式错误'), reason: '否则用户只能看到一个状态码');

    final noLink = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.parse('text/event-stream')
        ..add(sse('模型不支持生图'))
        ..write('data: [DONE]\n\n');
      await request.response.close();
    });
    await expectLater(
      chat(origin(noLink), negative: 'lowres').generateImage('x'),
      throwsA(
        predicate<ImagePluginException>(
          (e) => e.message.contains('未找到图片链接'),
        ),
      ),
    );
  });

  test('对话式网关:listModels 只回 nai- 前缀、test 汇总数量', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    String? auth;
    final server = await serve((request) {
      auth = request.headers.value(HttpHeaders.authorizationHeader);
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'data': [
            {'id': 'nai-diffusion-4-5-full'},
            {'id': 'gpt-image-1'},
          ],
        }));
      request.response.close();
    });
    final plugin = seed('microscritt.chat-completions');
    final cfg = ImageConfig(
      kind: ImageBackendKind.plugin,
      apiKey: 'sk-abc',
      model: 'm',
      baseUrl: origin(server),
      pluginId: plugin.id,
    );

    final models = await PluginImageBackend(
      config: cfg,
      plugin: plugin,
      evaluator: js!.evaluate,
    ).listModels();
    expect(models, ['nai-diffusion-4-5-full']);
    expect(auth, 'Bearer sk-abc');

    final probe = await PluginImageBackend(
      config: cfg,
      plugin: plugin,
      evaluator: js!.evaluate,
    ).probe();
    expect(probe?.summary, contains('其中生图 1 个'));
  });

  test('nai2:提交 + 首询前等待 + 相对 imageUrl 补全为绝对 URL', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final requests = <String>[];
    final server = await serve((request) async {
      requests.add('${request.method} ${request.uri.path}');
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        expect(body['nocache'], '1', reason: '多张并行任务命中同缓存会返回重复图');
        expect(body['token'], 'nai-token');
        expect(body['steps'], 28);
        expect(body['negative'], contains('bad anatomy'));
        request.response.write(jsonEncode({'id': 'job-9'}));
      } else {
        request.response.write(jsonEncode({
          'status': 'done',
          'imageUrl': '/api/images/job-9/content',
        }));
      }
      await request.response.close();
    });

    final sw = Stopwatch()..start();
    final result = await nai2(origin(server)).generateImage('a scene');
    sw.stop();

    expect(
      result.images.single.url,
      '${origin(server)}/api/images/job-9/content',
    );
    expect(requests.first, 'POST /api/web/jobs');
    expect(requests.last, 'GET /api/jobs/job-9');
    // 刚提交的任务必然在排队,立即问只是白打一次;插件在首询前先等 1s。
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(900));
  });

  test('nai2:轮询有节奏,不空转打服务端', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    var polls = 0;
    final server = await serve((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        request.response.write(jsonEncode({'id': 'job-p'}));
      } else {
        polls++;
        request.response.write(jsonEncode({
          'status': polls >= 3 ? 'done' : 'queued',
          'imageUrl': polls >= 3 ? '/api/images/job-p/content' : '',
        }));
      }
      await request.response.close();
    });

    final sw = Stopwatch()..start();
    await nai2(origin(server)).generateImage('x');
    sw.stop();

    expect(polls, 3);
    // 排队期 1s 一次:三次轮询至少 1s(首询)+ 1s + 1s;没有等待就会空转,
    // 几分钟内打满宿主步数上限。
    expect(
      sw.elapsedMilliseconds,
      greaterThanOrEqualTo(2500),
      reason: '轮询之间没有等待 → 空转热循环',
    );
  });

  test('nai2:拿到 job id 后绝不重提交,5xx 与断连只继续问', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    var posts = 0;
    var gets = 0;
    final server = await serve((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        posts++;
        request.response.write(jsonEncode({'id': 'job-r'}));
      } else {
        gets++;
        if (gets <= 2) {
          request.response.statusCode = 500; // 查询接口抖动
        } else {
          request.response.write(jsonEncode({
            'status': 'done',
            'imageUrl': '/api/images/job-r/content',
          }));
        }
      }
      await request.response.close();
    });

    final result = await nai2(origin(server)).generateImage('x');
    expect(result.images.single.url, endsWith('/api/images/job-r/content'));
    expect(posts, 1, reason: '重复提交 = 重复出图重复计费');
    expect(gets, 3);
  });

  test('nai2:2xx 但响应不是 JSON 对象是确定性失败,不闷头轮询', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    var gets = 0;
    final server = await serve((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        request.response.write(jsonEncode({'id': 'job-bad'}));
      } else {
        gets++;
        request.response.write('<html>SPA 兜底页</html>');
      }
      await request.response.close();
    });

    await expectLater(
      nai2(origin(server)).generateImage('x'),
      throwsA(
        predicate<ImagePluginException>(
          (e) => e.message.contains('不是 JSON 对象'),
        ),
      ),
    );
    expect(gets, 1, reason: '坏响应继续问只会轮到超时,把缺陷伪装成慢');
  });

  test('nai2:done 但 imageUrl 空的竞态有限次追问', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    var polls = 0;
    final server = await serve((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        request.response.write(jsonEncode({'id': 'job-x'}));
      } else {
        polls++;
        request.response.write(jsonEncode({
          'status': 'done',
          'imageUrl': polls >= 3 ? '/api/images/done' : '',
        }));
      }
      await request.response.close();
    });

    final result = await nai2(origin(server)).generateImage('x');
    expect(result.images.single.url, '${origin(server)}/api/images/done');
    expect(polls, 3);

    // 一直 done 却不给链接:最多追问 5 次就报错(计数必须随 sleep 传递,
    // 漏传就成了无限追问)。
    var alwaysEmpty = 0;
    final stuck = await serve((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST') {
        request.response.write(jsonEncode({'id': 'job-stuck'}));
      } else {
        alwaysEmpty++;
        request.response.write(jsonEncode({'status': 'done', 'imageUrl': ''}));
      }
      await request.response.close();
    });
    await expectLater(
      nai2(origin(stuck)).generateImage('x'),
      throwsA(
        predicate<ImagePluginException>(
          (e) => e.message.contains('任务完成但未返回图片链接'),
        ),
      ),
    );
    expect(alwaysEmpty, 5);
  });

  test('nai2:probe 严格 2xx —— 3xx 不能报成密钥有效,且绝不回显 token', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final server = await serve((request) {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, 'https://example.com/login');
      request.response.write('redirect');
      request.response.close();
    });

    var message = '';
    try {
      await nai2(origin(server)).probe();
    } on ImagePluginException catch (e) {
      message = e.message;
    }
    expect(message, contains('密钥校验不可用'));
    expect(message, isNot(contains('nai-token')));

    final ok = await serve((request) {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/api/me')) {
        request.response.write(jsonEncode({
          'enabled': true,
          'balance': 42,
          'token': 'SECRET-LEAK-ME',
        }));
      } else {
        request.response.write(jsonEncode({
          'defaultModel': 'nai-diffusion-5-full',
          'costPerImage': 1,
          'accountConcurrency': 3,
        }));
      }
      request.response.close();
    });
    final probe = await nai2(origin(ok)).probe();
    expect(probe?.summary, contains('余额 42 点'));
    expect(probe?.summary, contains('单张 1 点'));
    expect(probe?.summary, contains('服务端并发 3'));
    expect(probe?.summary, isNot(contains('SECRET-LEAK-ME')));
    // defaultModel 走独立字段:设置页自己拼「,默认模型 X」,JS 内联一次就重复显示。
    expect(probe?.defaultModel, 'nai-diffusion-5-full');
    expect(probe?.summary, isNot(contains('默认模型')));
  });

  test('nai2:disabled 密钥与提交被拒都报确定性失败', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final disabled = await serve((request) {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'enabled': false, 'token': 'SECRET-LEAK-ME'}));
      request.response.close();
    });
    await expectLater(
      nai2(origin(disabled)).probe(),
      throwsA(
        predicate<ImagePluginException>((e) => e.message.contains('已被禁用')),
      ),
    );

    final rejected = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 402
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': '额度不足'}));
      await request.response.close();
    });
    await expectLater(
      nai2(origin(rejected)).generateImage('x'),
      throwsA(
        predicate<ImagePluginException>((e) => e.message.contains('额度不足')),
      ),
    );
  });

  test('nai2:listModels 静态候选(该服务无 /api/models)', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final models = await PluginImageBackend(
      config: ImageConfig(
        kind: ImageBackendKind.plugin,
        apiKey: 't',
        model: '',
        baseUrl: 'http://127.0.0.1:12345',
        pluginId: 'microscritt.nai2',
      ),
      plugin: seed('microscritt.nai2'),
      evaluator: js!.evaluate,
    ).listModels();
    expect(models, ['nai-diffusion-4-5-full', 'nai-diffusion-5-full']);
  });

  PluginImageBackend novelai(
    String baseUrl, {
    String apiKey = 'pst-abc',
    String model = '',
    String? negative,
    String? size,
    int? scale,
    double? cfg,
    int? steps,
    String? sampler,
    String? noiseSchedule,
    String? artist,
    Duration timeout = const Duration(minutes: 5),
    Duration requestTimeout = const Duration(seconds: 30),
  }) => PluginImageBackend(
    config: ImageConfig(
      kind: ImageBackendKind.plugin,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      negative: negative,
      size: size,
      scale: scale,
      cfg: cfg,
      steps: steps,
      sampler: sampler,
      noiseSchedule: noiseSchedule,
      artist: artist,
      pluginId: 'microscritt.novelai',
    ),
    plugin: seed('microscritt.novelai'),
    evaluator: js!.evaluate,
    timeout: timeout,
    requestTimeout: requestTimeout,
  );

  List<int> jsonImages(String b64) => utf8.encode(
    jsonEncode({
      'images': [
        {'image': b64, 'index': 0, 'seed': 1},
      ],
    }),
  );

  test('novelai:Accept JSON + v4 结构、尺寸映射与默认参数', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    Map<String, dynamic>? body;
    String? path;
    String? accept;
    String? auth;
    String? contentType;
    final server = await serve((request) async {
      path = request.uri.path;
      accept = request.headers.value('accept');
      auth = request.headers.value(HttpHeaders.authorizationHeader);
      contentType = request.headers.contentType?.mimeType;
      body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response
        // 官方 JSON 分支回 201(默认的 ZIP 分支是 200)。
        ..statusCode = 201
        ..headers.contentType = ContentType.json
        ..add(jsonImages('UE5H'));
      await request.response.close();
    });

    final result = await novelai(
      origin(server),
      artist: 'best quality, anime illustration',
    ).generateImage('1girl, silver hair');

    // Accept: application/json 是整条路径的关键:官方端点默认回 ZIP,
    // 沙箱里没有解压库,缺这个头就只能失败。
    expect(path, '/ai/generate-image');
    expect(accept, 'application/json');
    expect(auth, 'Bearer pst-abc');
    expect(contentType, 'application/json');
    expect(result.images.single.base64, 'UE5H');

    expect(body!['action'], 'generate');
    expect(body!['model'], 'nai-diffusion-4-5-full', reason: '模型留空时回落到 V4.5');
    // 官方 API 没有画师串字段,画师/风格词并入正面提示词。
    expect(body!['input'], '1girl, silver hair, best quality, anime illustration');
    final p = body!['parameters'] as Map<String, dynamic>;
    expect(p['params_version'], 3);
    expect(p['width'], 832);
    expect(p['height'], 1216);
    expect(p['scale'], 5);
    expect(p['steps'], 28);
    expect(p['sampler'], 'k_euler_ancestral');
    expect(p['noise_schedule'], 'karras');
    expect(p['cfg_rescale'], 0);
    expect(p['n_samples'], 1, reason: '每次请求只画一张,多张由上层展开');
    expect(p['seed'], isA<int>());
    expect(p['negative_prompt'], contains('bad anatomy'), reason: '未配置时用兜底负面词');
    final v4 = p['v4_prompt'] as Map<String, dynamic>;
    expect(v4['caption']['base_caption'], body!['input']);
    expect(v4['use_coords'], false);
    expect(v4['use_order'], true);
    final uc = p['v4_negative_prompt'] as Map<String, dynamic>;
    expect(uc['caption']['base_caption'], p['negative_prompt']);
    expect(uc['legacy_uc'], false);
    expect(p.containsKey('prompt'), isFalse, reason: 'V5 才镜像平铺 prompt');
  });

  test('novelai:V5 用 params_version 4,模型后缀剥离,显式参数覆盖默认', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    Map<String, dynamic>? body;
    final server = await serve((request) async {
      body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response
        ..headers.contentType = ContentType.json
        ..add(jsonImages('UE5H'));
      await request.response.close();
    });

    await novelai(
      origin(server),
      model: 'nai-diffusion-5-full:k_euler',
      size: '横图',
      scale: 7,
      cfg: 1,
      steps: 35,
      sampler: 'k_dpmpp_2m',
      noiseSchedule: 'exponential',
      negative: 'lowres',
    ).generateImage('x');

    // 对话式网关时代的 `模型:采样器` 写法不能原样下发给官方 API。
    expect(body!['model'], 'nai-diffusion-5-full');
    final p = body!['parameters'] as Map<String, dynamic>;
    expect(p['params_version'], 4);
    expect(p['width'], 1216);
    expect(p['height'], 832);
    expect(p['scale'], 7);
    expect(p['cfg_rescale'], 1);
    expect(p['steps'], 35);
    expect(p['sampler'], 'k_dpmpp_2m');
    expect(p['noise_schedule'], 'exponential');
    expect(p['negative_prompt'], 'lowres');
    expect(p['prompt'], 'x', reason: 'V5 客户端把平铺 prompt 一并镜像');
    expect(p['extra_noise_seed'], p['seed']);
  });

  test('novelai:base URL 带 /ai 后缀时仍拼出官方固定路径', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    String? path;
    final server = await serve((request) async {
      path = request.uri.path;
      await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.json
        ..add(jsonImages('UE5H'));
      await request.response.close();
    });

    // 官方文档给的是 .../ai/generate-image;用户可能把 .../ai 直接当 base URL。
    final result = await novelai('${origin(server)}/ai').generateImage('x');
    expect(result.images.single.base64, 'UE5H');
    expect(path, '/ai/generate-image');
  });

  test('novelai:响应数组与 data URL 包装都能取到裸 base64', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final arrays = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode([
          {'image': 'UE5H'},
        ]));
      await request.response.close();
    });
    expect(
      (await novelai(origin(arrays)).generateImage('x')).images.single.base64,
      'UE5H',
    );

    final dataUrl = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'images': [
            {'image': 'data:image/png;base64,UE5H'},
          ],
        }));
      await request.response.close();
    });
    expect(
      (await novelai(origin(dataUrl)).generateImage('x')).images.single.base64,
      'UE5H',
      reason: '宿主只接受裸 base64,数据 URL 前缀必须剥掉',
    );
  });

  test('novelai:HTTP 402 回显服务端原因,鉴权失败提示持久令牌', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final server = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 402
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'statusCode': 402, 'message': 'Anlas depletion'}));
      await request.response.close();
    });
    var message = '';
    try {
      await novelai(origin(server)).generateImage('x');
    } on ImagePluginException catch (e) {
      message = e.message;
    }
    expect(message, contains('HTTP 402'));
    expect(message, contains('Anlas depletion'), reason: '否则用户只能看到状态码');

    final unauthorized = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        // 坏代理可能把请求头/令牌原样回显:横幅里必须脱敏。
        ..write(jsonEncode({
          'statusCode': 401,
          'message': 'bad key pst-secret',
        }));
      await request.response.close();
    });
    await expectLater(
      novelai(origin(unauthorized), apiKey: 'pst-secret').generateImage('x'),
      throwsA(
        predicate<ImagePluginException>(
          (e) =>
              e.message.contains('Persistent API Token') &&
              e.message.contains('***') &&
              !e.message.contains('pst-secret'),
        ),
      ),
    );

    // 免费试用账号:官方要求试用生图带 reCAPTCHA,第三方 API 无法也不该代过;
    // 英文原始报错要点成可操作的中文说明。
    final trial = await serve((request) async {
      await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 400
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'statusCode': 400,
          'message': 'Recaptcha token is required for trial generation',
        }));
      await request.response.close();
    });
    await expectLater(
      novelai(origin(trial)).generateImage('x'),
      throwsA(
        predicate<ImagePluginException>(
          (e) =>
              e.message.contains('免费试用账号') &&
              e.message.contains('reCAPTCHA') &&
              e.message.contains('订阅'),
        ),
      ),
    );
  });

  test('novelai:超时不重提,网络断连只在零字节且未重试时重提', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final plugin = seed('microscritt.novelai');
    Future<Map<String, dynamic>> stepWith(
      Map<String, dynamic> response, {
      bool retried = false,
    }) async {
      final context = <String, dynamic>{
        'operation': 'generate',
        'phase': 'http',
        'prompt': 'x',
        'negativePrompt': 'n',
        'params': <String, dynamic>{},
        'settings': {
          'baseUrl': 'https://image.novelai.net',
          'apiKey': 'pst-secret',
          'model': '',
        },
        'state': {'seed': 7, 'retried': retried},
        'response': response,
      };
      final result = await js!.evaluate(
        '(function(){var ctx=${jsonEncode(context)};\n${plugin.code}\n'
        'return JSON.stringify(step(ctx));})()',
      );
      expect(result, isNotNull, reason: 'JS 求值失败');
      return jsonDecode(result!) as Map<String, dynamic>;
    }

    // 非流式请求在出图前没有字节,超时后任务可能已受理:不重提。
    final timeout = await stepWith({
      'error': 'timeout',
      'receivedBytes': false,
    });
    expect(timeout['action'], 'error');
    expect(timeout['message'], contains('未自动重试'));

    // 连接级失败 + 零字节 + 未重试:请求很可能没送达,允许重提一次。
    final network = await stepWith({
      'error': 'network',
      'receivedBytes': false,
    });
    expect(network['action'], 'http');
    expect((network['state'] as Map)['retried'], true);
    expect((network['state'] as Map)['seed'], 7, reason: '重试沿用同一个种子');

    // 已重试过、或收到过任何字节:绝不再提。
    expect(
      (await stepWith({
        'error': 'network',
        'receivedBytes': false,
      }, retried: true))['action'],
      'error',
    );
    expect(
      (await stepWith({
        'error': 'network',
        'receivedBytes': true,
      }))['action'],
      'error',
    );
  });

  test('novelai:零字节断连才重试一次,已收到响应字节绝不重提', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    var hits = 0;
    final retrying = await scripted([
      (request, _) async {
        hits++;
        await utf8.decoder.bind(request).join();
        final socket = await request.response.detachSocket();
        socket.destroy(); // 请求送达前断连:未收到任何数据,可安全重试
      },
      (request, _) async {
        hits++;
        await utf8.decoder.bind(request).join();
        request.response
          ..headers.contentType = ContentType.json
          ..add(jsonImages('UE5H'));
        await request.response.close();
      },
    ]);
    final result = await novelai(origin(retrying)).generateImage('x');
    expect(result.images.single.base64, 'UE5H');
    expect(hits, 2);

    // 已收到分片(=服务端已受理)后断连:重发就是重复出图重复计费。
    var resubmits = 0;
    final poisoned = await serve((request) async {
      resubmits++;
      await utf8.decoder.bind(request).join();
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n'
        'transfer-encoding: chunked\r\n\r\n',
      );
      final frame = utf8.encode('{"images":[');
      socket.write('${frame.length.toRadixString(16)}\r\n');
      socket.add(frame);
      socket.write('\r\n');
      await socket.flush();
      // 先让客户端读走这一帧再断,否则解析器在交付缓冲前就报错。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await socket.close();
    });
    await expectLater(
      novelai(origin(poisoned)).generateImage('x'),
      throwsA(isA<ImagePluginException>()),
    );
    expect(resubmits, 1, reason: '收到过响应字节就不能再提交第二次');
  });

  test('novelai:probe 解析订阅用量且不回显账号信息', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    String? path;
    String? auth;
    final server = await serve((request) {
      path = request.uri.path;
      auth = request.headers.value(HttpHeaders.authorizationHeader);
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'tier': 3,
          'active': true,
          'trainingStepsLeft': {
            'fixedTrainingStepsLeft': 9000,
            'purchasedTrainingSteps': 88,
          },
          'usage': {'percent': 97, 'isNegative': false},
          'plainTextEmail': 'SECRET@example.com',
        }));
      request.response.close();
    });

    final probe = await novelai(origin(server)).probe();
    expect(path, '/user/subscription');
    expect(auth, 'Bearer pst-abc');
    expect(probe?.summary, contains('密钥有效'));
    expect(probe?.summary, contains('订阅等级 3'));
    expect(probe?.summary, contains('Anlas 9088'));
    expect(probe?.summary, contains('剩余电量 97%'));
    expect(probe?.summary, isNot(contains('SECRET')));

    final bad = await serve((request) {
      request.response
        ..statusCode = 401
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'statusCode': 401, 'message': 'Unauthorized'}));
      request.response.close();
    });
    await expectLater(
      novelai(origin(bad)).probe(),
      throwsA(
        predicate<ImagePluginException>(
          (e) => e.message.contains('鉴权失败') && e.message.contains('401'),
        ),
      ),
    );

    // 试用账号(tier 0 / active false):连接测试就暴露状态,别等生图撞 400。
    final trial = await serve((request) {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'tier': 0, 'active': false}));
      request.response.close();
    });
    final trialProbe = await novelai(origin(trial)).probe();
    expect(trialProbe?.summary, contains('试用账号(未订阅)'));
  });

  test('novelai:api.novelai.net 在发请求前给出可操作提示', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    await expectLater(
      novelai('https://api.novelai.net').generateImage('x'),
      throwsA(
        predicate<ImagePluginException>(
          (e) => e.message.contains('https://image.novelai.net'),
        ),
      ),
    );
  });

  test('novelai:listModels 静态候选(该服务无模型列表端点)', () async {
    if (js == null) return markTestSkipped('QuickJS 与 Node 均不可用,种子 JS 未执行');
    final models = await novelai('http://127.0.0.1:12345').listModels();
    expect(models, contains('nai-diffusion-5-full'));
    expect(models, contains('nai-diffusion-4-5-full'));
    expect(models, contains('nai-diffusion-3'));
  });
}
