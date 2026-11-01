import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/backend_factory.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/openai_backend.dart';
import 'package:microscritt/models/chat_message.dart';

void main() {
  test('streams text deltas from OpenAI SSE', () async {
    final body = [
      'data: {"choices":[{"delta":{"content":"Hel"}}]}\n',
      'data: {"choices":[{"delta":{"content":"lo"}}]}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      expect(req.url.path, '/chat/completions');
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    final text = events.whereType<TextDelta>().map((e) => e.text).join();
    expect(text, 'Hello');
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('malformed SSE data yields ErrorEvent, not a stream error', () async {
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode('data: {not valid json}\n\n'), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    expect(events.whereType<ErrorEvent>(), isNotEmpty);
  });

  test('mid-stream error payload yields ErrorEvent with the provider message (not swallowed)', () async {
    // 限流/过载/内容过滤时,OpenAI 兼容网关常在流中途推 {"error": {...}} 块:
    // 没有 choices 也没有 usage,不显式处理会被静默吞掉,上层误判成"解析失败"。
    final body = [
      'data: {"choices":[{"delta":{"content":"Hel"}}]}\n',
      'data: {"error":{"message":"rate limited upstream","type":"server_error"}}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Hel');
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('rate limited upstream'));
  });

  test('content_filter finish_reason surfaces an ErrorEvent instead of a silent empty response', () async {
    // 内容过滤截停:流正常结束但正文为空 —— 不透出就会表现为"模型未返回任何
    // 内容"的解析失败,用户无从知道是内容被上游过滤。
    final body = [
      'data: {"choices":[{"delta":{"content":"Par"}}]}\n',
      'data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('content filter'));
  });

  test('stream ending without [DONE] surfaces an ErrorEvent (connection closed early)', () async {
    // 连接被提前掐断时 http 层静默完成、不抛错 —— 不检测就会表现为"模型未返回
    // 任何内容"的解析失败;透出后上层按可重试的后端故障处理。
    final client = MockClient((req) async {
      return http.Response.bytes(
        utf8.encode('data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n'),
        200,
      );
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    expect(events.whereType<DoneEvent>(), isEmpty);
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('[DONE]'));
  });

  test('finish_reason=length with zero content surfaces an ErrorEvent (budget burned by reasoning)', () async {
    // 推理模型把 max_tokens 全烧在不可见思考上:零正文、finish_reason=length、
    // 流以 [DONE] 正常收尾 —— 不透出就表现为"模型未返回任何内容"的解析失败。
    final body = [
      'data: {"choices":[{"delta":{"reasoning_content":"thinking hard about the memory..."}}]}\n',
      'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('max_tokens'));
  });

  test('finish_reason=length after content does NOT error (truncation is handled upstream)', () async {
    // 有正文的 length 截断:截断 JSON 交由上层修复解析兜底,这里保持正常事件流。
    final body = [
      'data: {"choices":[{"delta":{"content":"{\\"memory\\":\\"par"}}]}\n',
      'data: {"choices":[{"delta":{"content":"tial"}}]}\n',
      'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), isNotEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('reasoning-only stream ending with [DONE] surfaces an ErrorEvent, not a silent empty response', () async {
    // 网关把"只思考未作答"包装成正常完成:reasoning_content 有、正文零、
    // finish_reason=stop —— 不透出就是无法归因的"模型未返回任何内容"。
    final body = [
      'data: {"choices":[{"delta":{"reasoning_content":"let me think this through"}}]}\n',
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('reasoning'));
  });

  test('per-chunk cumulative usage is merged into ONE final UsageEvent (not summed per chunk)', () async {
    // 不少 OpenAI 兼容网关(尤其推理模型中转)在每个 SSE 块都附带**累计** usage:
    // 逐块透出会被上层当增量求和 —— 几千个块 × 累计值 = 百万/千万级虚高用量
    // (实测两轮对话 input/out 冲到几千万)。合并取最大、只发一次终值快照。
    final body = [
      'data: {"choices":[{"delta":{"reasoning_content":"t1"}}],"usage":{"prompt_tokens":100,"completion_tokens":5}}\n',
      'data: {"choices":[{"delta":{"content":"Hel"}}],"usage":{"prompt_tokens":100,"completion_tokens":40}}\n',
      'data: {"choices":[{"delta":{"content":"lo"}}],"usage":{"prompt_tokens":100,"completion_tokens":80}}\n',
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":120,"prompt_tokens_details":{"cached_tokens":60}}}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Hello');
    final usages = events.whereType<UsageEvent>().toList();
    expect(usages, hasLength(1));
    expect(usages.single.usage.inputTokens, 100);
    expect(usages.single.usage.outputTokens, 120);
    expect(usages.single.usage.cachedInputTokens, 60);
  });

  test('final-chunk-only usage is reported once as-is', () async {
    final body = [
      'data: {"choices":[{"delta":{"content":"Hi"}}]}\n',
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":33,"completion_tokens":7}}\n',
      'data: [DONE]\n',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    final usages = events.whereType<UsageEvent>().toList();
    expect(usages, hasLength(1));
    expect(usages.single.usage.inputTokens, 33);
    expect(usages.single.usage.outputTokens, 7);
  });

  test('messages map verbatim after the system row (CW: no trailing bypass anymore)', () async {
    late Map<String, dynamic> body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [
        ChatMessage(ChatRole.user, '<system-reminder>memory</system-reminder>'),
        ChatMessage(ChatRole.user, 'hi'),
        ChatMessage(ChatRole.assistant, 'hello'),
      ],
      temperature: 0.7,
    )).toList();

    // CW 批:不再有尾部状态旁路 —— 消息数组逐条原样映射(含附件/通知在内),
    // 用户输入始终是最后一条。
    final msgs = body['messages'] as List;
    expect(msgs.length, 4); // system + 3 数组消息
    expect((msgs[1] as Map)['content'], '<system-reminder>memory</system-reminder>');
    expect((msgs[2] as Map)['content'], 'hi');
    expect((msgs[3] as Map)['content'], 'hello');
  });

  test('cancelling the subscription closes the connection (abort)', () async {
    // 回归防护「打断后请求在服务端跑到自然结束」:响应字节流永不完成(模型
    // 思考中、首字节未到),消费方取消订阅必须立即关闭底层连接 —— 服务端
    // 生成随断链停止,不再白烧 token。
    final client = _CloseTrackingClient.streaming(
      (req, body) async => http.StreamedResponse(
        Stream<Uint8List>.fromFuture(Completer<Uint8List>().future), // 永不发出字节
        200,
      ),
    );
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = <LlmEvent>[];
    final sub = backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).listen(events.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    expect(client.closes, 1); // 取消即断链
  });

  test('completing the stream normally does not close the injected client', () async {
    // 正常收尾后的补位 cancel(消费方流结束后取消订阅)不能把复用中的注入
    // client 标成 closed —— 否则同一测试/多轮请求的后续 send 会全部失败。
    final body = 'data: {"choices":[{"delta":{"content":"ok"}}]}\ndata: [DONE]\n\n';
    final client = _CloseTrackingClient((req) async => http.Response.bytes(utf8.encode(body), 200));
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = <LlmEvent>[];
    final done = Completer<void>();
    final sub = backend
        .generate(LlmRequest(
          model: 'm',
          systemPrompt: 'sys',
          messages: const [ChatMessage(ChatRole.user, 'hi')],
          temperature: 0.7,
        ))
        .listen(events.add, onDone: done.complete);
    await done.future;
    await sub.cancel();
    expect(client.closes, 0);
  });

  test('provider extra headers are sent verbatim with the request', () async {
    // 头放行的网关:provider 上配置的自定义请求头
    // 必须逐字随请求发出,否则网关 403。
    late http.Request sent;
    final client = MockClient((req) async {
      sent = req;
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.openai,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
        extraHeaders: {
          'origin': 'https://client.example.com',
          'referer': 'https://client.example.com/',
          'user-agent': 'PostmanRuntime-ApipostRuntime/1.1.0',
        },
      ),
      client: client,
    );

    await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    expect(sent.headers['origin'], 'https://client.example.com');
    expect(sent.headers['referer'], 'https://client.example.com/');
    expect(sent.headers['user-agent'], 'PostmanRuntime-ApipostRuntime/1.1.0');
  });

  test('extra header overrides a built-in default (e.g. authorization)', () async {
    // http 包的 headers map 大小写不敏感,同名(不区分大小写)头只会有一个
    // 条目:用户值必须完全顶掉内置默认,而不是叠出同头双值。
    late http.Request sent;
    final client = MockClient((req) async {
      sent = req;
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.openai,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
        extraHeaders: {'authorization': 'Bearer sk-custom'},
      ),
      client: client,
    );

    await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    expect(sent.headers.keys.where((k) => k.toLowerCase() == 'authorization'), hasLength(1));
    expect(sent.headers['authorization'], 'Bearer sk-custom');
  });

  test('403 response carries the custom-header hint in the error message', () async {
    // 头放行的网关拒绝时只回一个裸 403:错误信息要指向「自定义请求头」配置,
    // 不让用户对着状态码猜。
    final client = MockClient((req) async => http.Response('forbidden', 403));
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('OpenAI 403'));
    expect(errors.single.message, contains('自定义请求头'));
  });

  test('modernParams wire style: max_completion_tokens + stream_options usage', () async {
    // 官方 OpenAI 端点两件事:① o 系列推理模型只认 max_completion_tokens
    //(发 max_tokens 直接 400);② 流式默认不带 usage,不开 include_usage
    // 用量统计恒为零。跟随 provider 级开关而非无条件发(劣质网关对未知字段
    // 会 400)。
    late Map<String, dynamic> modernBody;
    late Map<String, dynamic> legacyBody;
    final modernClient = MockClient((req) async {
      modernBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    final legacyClient = MockClient((req) async {
      legacyBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    final request = LlmRequest(
      model: 'o4-mini',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
      maxTokens: 4096,
    );

    await OpenAiBackend(
      config: const BackendConfig(
        provider: BackendProvider.openai,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
        modernParams: true,
      ),
      client: modernClient,
    ).generate(request).toList();
    expect(modernBody['max_completion_tokens'], 4096);
    expect(modernBody.containsKey('max_tokens'), isFalse);
    expect(modernBody['stream_options'], {'include_usage': true});

    await OpenAiBackend(
      config: const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: legacyClient,
    ).generate(request).toList();
    expect(legacyBody['max_tokens'], 4096);
    expect(legacyBody.containsKey('max_completion_tokens'), isFalse);
    expect(legacyBody.containsKey('stream_options'), isFalse);
  });

  test('connect timeout cuts the request instead of hanging forever', () async {
    // 网络黑洞:send() 永不完成。修复前无超时,await 永久挂起(后台/压缩
    // 路径无人盯,直接挂死管线)。
    final client = _NeverRespondingClient();
    final backend = OpenAiBackend(
      config: const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
      connectTimeout: const Duration(milliseconds: 50),
      idleTimeout: const Duration(seconds: 5),
    );

    final events = await backend.generate(LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: const [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('请求超时'));
    expect(client.closes, greaterThanOrEqualTo(1)); // 超时即断链,不留僵尸连接
  });

  test('idle SSE stream is cut after the idle timeout instead of hanging forever', () async {
    // 半开连接:响应头已到(200),流却停滞不产出任何数据。
    final client = MockClient.streaming((req, body) async => http.StreamedResponse(
          Stream<Uint8List>.fromFuture(Completer<Uint8List>().future),
          200,
        ));
    final backend = OpenAiBackend(
      config: const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
      idleTimeout: const Duration(milliseconds: 50),
    );

    // 空闲超时经传输层抛 TimeoutException(与真实网络错误同一条通道),
    // 不是业务 ErrorEvent。
    await expectLater(
      backend.generate(LlmRequest(
        model: 'm',
        systemPrompt: 'sys',
        messages: const [ChatMessage(ChatRole.user, 'hi')],
        temperature: 0.7,
      )).toList(),
      throwsA(isA<TimeoutException>()),
    );
  });
}

/// send() 永不完成的假 client:模拟网络黑洞(连接建立后无任何响应)。
class _NeverRespondingClient extends http.BaseClient {
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
  @override
  void close() {
    closes++;
    super.close();
  }
}

/// 记录 close 次数的 MockClient:断链回归要断言「取消订阅 → 连接被关闭」。
class _CloseTrackingClient extends MockClient {
  int closes = 0;
  _CloseTrackingClient(super.fn);
  // 显式转发到 streaming 具名构造:super 参数会错误绑定到无名构造的形参类型。
  // ignore: use_super_parameters
  _CloseTrackingClient.streaming(
    Future<http.StreamedResponse> Function(http.BaseRequest, http.ByteStream) fn,
  ) : super.streaming(fn);
  @override
  void close() {
    closes++;
    super.close();
  }
}
