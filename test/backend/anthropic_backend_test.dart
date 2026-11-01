import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/backend_factory.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/chat_message.dart';

void main() {
  test('streams text deltas from Anthropic SSE with system field', () async {
    final body = [
      'event: content_block_delta',
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}',
      '',
      'event: content_block_delta',
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"!"}}',
      '',
      'event: message_stop',
      'data: {"type":"message_stop"}',
      '',
    ].join('\n');
    final client = MockClient((req) async {
      expect(req.url.path, '/v1/messages');
      final decoded = jsonDecode(req.body) as Map<String, dynamic>;
      expect(decoded['system'], 'sys');
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
      ),
      client: client,
    );

    final events = await backend
        .generate(
          LlmRequest(
            model: 'm',
            systemPrompt: 'sys',
            messages: const [ChatMessage(ChatRole.user, 'hi')],
            temperature: 0.7,
          ),
        )
        .toList();

    final text = events.whereType<TextDelta>().map((e) => e.text).join();
    expect(text, 'Hi!');
  });

  test('provider extra headers are sent verbatim with the request', () async {
    late http.Request sent;
    final body = [
      'event: message_stop',
      'data: {"type":"message_stop"}',
      '',
    ].join('\n');
    final client = MockClient((req) async {
      sent = req;
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
        extraHeaders: {'origin': 'https://example.com'},
      ),
      client: client,
    );

    final events = await backend
        .generate(
          LlmRequest(
            model: 'm',
            systemPrompt: 'sys',
            messages: const [ChatMessage(ChatRole.user, 'hi')],
            temperature: 0.7,
          ),
        )
        .toList();

    expect(events.whereType<DoneEvent>(), isNotEmpty);
    expect(sent.headers['origin'], 'https://example.com');
    expect(sent.headers['x-api-key'], 'k');
  });

  test('message_start + message_delta usage snapshots merge into ONE UsageEvent', () async {
    // message_start 报 input(+初始 output)、message_delta 报最终 output —— 都是
    // 请求内累计快照;合并取最大、流结束时只发一次,上层按"每请求一次"累加。
    final body = [
      'event: message_start',
      'data: {"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1,"cache_read_input_tokens":10}}}',
      '',
      'event: content_block_delta',
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi!"}}',
      '',
      'event: message_delta',
      'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}',
      '',
      'event: message_stop',
      'data: {"type":"message_stop"}',
      '',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
      ),
      client: client,
    );

    final events = await backend
        .generate(
          LlmRequest(
            model: 'm',
            systemPrompt: 'sys',
            messages: const [ChatMessage(ChatRole.user, 'hi')],
            temperature: 0.7,
          ),
        )
        .toList();

    final usages = events.whereType<UsageEvent>().toList();
    expect(usages, hasLength(1));
    expect(usages.single.usage.inputTokens, 25);
    expect(usages.single.usage.outputTokens, 42);
    expect(usages.single.usage.cachedInputTokens, 10);
  });

  test(
    'cacheContext adds an ephemeral cache_control on the last message',
    () async {
      final client = MockClient((req) async {
        final decoded = jsonDecode(req.body) as Map<String, dynamic>;
        final msgs = decoded['messages'] as List;
        // 没有 cacheContext 时,消息保持纯字符串 content、不带 cache_control。
        final last = msgs.last as Map<String, dynamic>;
        expect(last['content'], isA<String>());
        expect(last.containsKey('cache_control'), isFalse);
        return http.Response.bytes(utf8.encode(''), 200);
      });
      final backend = createBackend(
        const BackendConfig(
          provider: BackendProvider.anthropic,
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        client: client,
      );
      // 先跑一次非缓存调用,验证默认无 cache_control。
      await backend
          .generate(
            const LlmRequest(
              model: 'm',
              systemPrompt: 'sys',
              messages: [ChatMessage(ChatRole.user, 'hi')],
            ),
          )
          .toList();

      late Map<String, dynamic> withCache;
      final cacheClient = MockClient((req) async {
        withCache = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(''), 200);
      });
      final cachingBackend = createBackend(
        const BackendConfig(
          provider: BackendProvider.anthropic,
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        client: cacheClient,
      );
      await cachingBackend
          .generate(
            const LlmRequest(
              model: 'm',
              systemPrompt: 'sys',
              messages: [
                ChatMessage(ChatRole.user, 'hello'),
                ChatMessage(ChatRole.assistant, 'world'),
              ],
              cacheContext: true,
            ),
          )
          .toList();
      // API schema:cache_control 是 content block 级字段 —— 末条消息 content 改为
      // 块数组,断点放在 {type: text} 块内;message 对象顶层不再携带该键
      // (顶层放置会被服务端静默忽略,缓存段不会建立)。
      final lastMsg =
          (withCache['messages'] as List).last as Map<String, dynamic>;
      expect(lastMsg.containsKey('cache_control'), isFalse);
      final content = lastMsg['content'] as List;
      expect(content.length, 1);
      final block = content.single as Map<String, dynamic>;
      expect(block['type'], 'text');
      expect(block['text'], 'world');
      expect(block['cache_control'], {'type': 'ephemeral'});
      // 非末条消息不加 cache_control,保持字符串 content,把断点只锚在末条。
      final firstMsg =
          (withCache['messages'] as List).first as Map<String, dynamic>;
      expect(firstMsg.containsKey('cache_control'), isFalse);
      expect(firstMsg['content'], 'hello');
    },
  );

  test(
    'multi-breakpoint: stableSystemPart turns system into content-block array with cache_control',
    () async {
      late Map<String, dynamic> withCache;
      final cacheClient = MockClient((req) async {
        withCache = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(''), 200);
      });
      final cachingBackend = createBackend(
        const BackendConfig(
          provider: BackendProvider.anthropic,
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        client: cacheClient,
      );
      await cachingBackend
          .generate(
            const LlmRequest(
              model: 'm',
              systemPrompt: 'stable part\n\nvariable part',
              messages: [ChatMessage(ChatRole.user, 'hello')],
              cacheContext: true,
              stableSystemPart: 'stable part',
              variableSystemPart: 'variable part',
            ),
          )
          .toList();
      // system 拆为 content block 数组:稳定块带断点,可变块不带。
      final system = withCache['system'] as List;
      expect(system.length, 2);
      final stableBlock = system[0] as Map<String, dynamic>;
      expect(stableBlock['type'], 'text');
      expect(stableBlock['text'], 'stable part');
      expect(stableBlock['cache_control'], {'type': 'ephemeral'});
      final variableBlock = system[1] as Map<String, dynamic>;
      expect(variableBlock['text'], 'variable part');
      expect(variableBlock.containsKey('cache_control'), isFalse);
      // 消息末条断点仍保留(双断点:system 稳定块 + messages 末条),断点在块内。
      final lastMsg = (withCache['messages'] as List).last as Map<String, dynamic>;
      final block = (lastMsg['content'] as List).single as Map<String, dynamic>;
      expect(block['cache_control'], {'type': 'ephemeral'});
    },
  );

  test(
    'cacheMessageBreakpoint=false caches only the stable system block',
    () async {
      late Map<String, dynamic> body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(''), 200);
      });
      final backend = createBackend(
        const BackendConfig(
          provider: BackendProvider.anthropic,
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        client: client,
      );
      await backend
          .generate(
            const LlmRequest(
              model: 'm',
              systemPrompt: 'stable part\n\nvariable part',
              messages: [ChatMessage(ChatRole.user, 'hi')],
              cacheContext: true,
              cacheMessageBreakpoint: false,
              stableSystemPart: 'stable part',
              variableSystemPart: 'variable part',
            ),
          )
          .toList();
      // system 仍拆成稳定/可变两块,断点只在稳定块。
      final system = body['system'] as List;
      expect(system.length, 2);
      expect(
        (system.first as Map<String, dynamic>)['cache_control'],
        {'type': 'ephemeral'},
      );
      expect(
        (system.last as Map<String, dynamic>).containsKey('cache_control'),
        isFalse,
      );
      // 后台只有一条固定指令:不再给末条消息打全前缀断点。
      final lastMsg = (body['messages'] as List).last as Map<String, dynamic>;
      expect(lastMsg['content'], 'hi');
      expect(lastMsg.containsKey('cache_control'), isFalse);
    },
  );

  test(
    'cache breakpoint anchors on the true last message (CW: no trailing bypass anymore)',
    () async {
      late Map<String, dynamic> withCache;
      final cacheClient = MockClient((req) async {
        withCache = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(''), 200);
      });
      final cachingBackend = createBackend(
        const BackendConfig(
          provider: BackendProvider.anthropic,
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        client: cacheClient,
      );
      await cachingBackend
          .generate(
            const LlmRequest(
              model: 'm',
              systemPrompt: 'stable part',
              messages: [
                ChatMessage(ChatRole.user, 'hello'),
                ChatMessage(ChatRole.assistant, 'world'),
                ChatMessage(ChatRole.user, 'the actual question'),
              ],
              cacheContext: true,
              stableSystemPart: 'stable part',
            ),
          )
          .toList();
      // system 只含稳定块(可变内容已全部移出 system)。
      final system = withCache['system'] as List;
      expect(system.length, 1);
      // CW 批:断点锚在真正的最后一条消息(用户实际输入)上 —— 附件/通知都在
      // 数组内部,不再有旁路消息排在用户输入之后。
      final msgs = withCache['messages'] as List;
      expect(msgs.length, 3);
      final last = msgs.last as Map<String, dynamic>;
      final block = (last['content'] as List).single as Map<String, dynamic>;
      expect(block['text'], 'the actual question');
      expect(block['cache_control'], {'type': 'ephemeral'});
      // 其余消息保持纯字符串 content。
      expect((msgs[0] as Map)['content'], 'hello');
      expect((msgs[1] as Map)['content'], 'world');
    },
  );

  test(
    'empty/absent stableSystemPart falls back to plain string system even when caching',
    () async {
      late Map<String, dynamic> withCache;
      final cacheClient = MockClient((req) async {
        withCache = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(''), 200);
      });
      final cachingBackend = createBackend(
        const BackendConfig(
          provider: BackendProvider.anthropic,
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        client: cacheClient,
      );
      // cacheContext=true 但未给 stableSystemPart(hook 改写 system 的路):纯字符串。
      await cachingBackend
          .generate(
            const LlmRequest(
              model: 'm',
              systemPrompt: 'sys',
              messages: [ChatMessage(ChatRole.user, 'hi')],
              cacheContext: true,
            ),
          )
          .toList();
      expect(withCache['system'], 'sys');
    },
  );

  test(
    'empty variableSystemPart omits the second system content block',
    () async {
      late Map<String, dynamic> withCache;
      final cacheClient = MockClient((req) async {
        withCache = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(''), 200);
      });
      final cachingBackend = createBackend(
        const BackendConfig(
          provider: BackendProvider.anthropic,
          baseUrl: 'https://x',
          apiKey: 'k',
          model: 'm',
        ),
        client: cacheClient,
      );
      await cachingBackend
          .generate(
            const LlmRequest(
              model: 'm',
              systemPrompt: 'stable part',
              messages: [ChatMessage(ChatRole.user, 'hi')],
              cacheContext: true,
              stableSystemPart: 'stable part',
              variableSystemPart: '',
            ),
          )
          .toList();
      final system = withCache['system'] as List;
      expect(system.length, 1);
    },
  );

  test('reasoningLevel off omits the thinking parameter', () async {
    late Map<String, dynamic> body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode(''), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
      ),
      client: client,
    );
    await backend
        .generate(
          const LlmRequest(
            model: 'm',
            systemPrompt: 'sys',
            messages: [ChatMessage(ChatRole.user, 'hi')],
          ),
        )
        .toList();
    expect(body.containsKey('thinking'), isFalse);
  });

  test('non-off reasoningLevel maps to thinking budget', () async {
    late Map<String, dynamic> body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode(''), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
      ),
      client: client,
    );
    await backend
        .generate(
          const LlmRequest(
            model: 'm',
            systemPrompt: 'sys',
            messages: [ChatMessage(ChatRole.user, 'hi')],
            reasoningLevel: ReasoningLevel.high,
            // 显式给出能容纳 high 档(30000)预算的输出上限。
            maxTokens: 40000,
          ),
        )
        .toList();
    expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 30000});
    expect(body['max_tokens'], 40000);
  });

  test('thinking clamps budget to max_tokens and omits temperature (API hard constraints)', () async {
    // API 硬性约束:max_tokens 必须 > budget_tokens(≥1024),且开启 thinking
    // 时不得携带 temperature —— 修复前默认 max_tokens=1024 携带 medium 档
    // (10000)预算 + temperature,组合几乎必被 400 拒绝。
    late Map<String, dynamic> body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode(''), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
      ),
      client: client,
    );

    // ① 默认/小 max_tokens:预算收缩到最低档,max_tokens 抬高到能容纳它。
    await backend.generate(const LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: [ChatMessage(ChatRole.user, 'hi')],
      reasoningLevel: ReasoningLevel.medium,
      temperature: 0.7,
    )).toList();
    expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 1024});
    expect(body['max_tokens'], 2048);
    expect(body.containsKey('temperature'), isFalse);

    // ② 中等 max_tokens:预算收缩到 max_tokens − 1024,上限不动。
    await backend.generate(const LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: [ChatMessage(ChatRole.user, 'hi')],
      reasoningLevel: ReasoningLevel.high,
      maxTokens: 8192,
    )).toList();
    expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 7168});
    expect(body['max_tokens'], 8192);
    expect(body.containsKey('temperature'), isFalse);

    // ③ off:temperature 正常携带。
    await backend.generate(const LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: [ChatMessage(ChatRole.user, 'hi')],
      temperature: 0.7,
    )).toList();
    expect(body.containsKey('thinking'), isFalse);
    expect(body['temperature'], 0.7);
  });

  test('mid-stream type:error event yields ErrorEvent with the provider message (not swallowed)', () async {
    // overloaded/rate-limit 等错误以 SSE 事件形态出现在流中途:不在 switch 里
    // 显式处理就会被静默漏过,缓冲区空/半截,上层误判成"解析失败"。
    final body = [
      'event: content_block_delta',
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}',
      '',
      'event: error',
      'data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
      '',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
      ),
      client: client,
    );

    final events = await backend
        .generate(
          LlmRequest(
            model: 'm',
            systemPrompt: 'sys',
            messages: const [ChatMessage(ChatRole.user, 'hi')],
            temperature: 0.7,
          ),
        )
        .toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Hi');
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('Overloaded'));
  });

  test('stream ending without message_stop surfaces an ErrorEvent (connection closed early)', () async {
    // 连接被提前掐断时 http 层静默完成、不抛错 —— 不检测就会表现为"模型未返回
    // 任何内容"的解析失败;透出后上层按可重试的后端故障处理。
    final body = [
      'event: content_block_delta',
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}',
      '',
    ].join('\n');
    final client = MockClient((req) async {
      return http.Response.bytes(utf8.encode(body), 200);
    });
    final backend = createBackend(
      const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
      ),
      client: client,
    );

    final events = await backend
        .generate(
          LlmRequest(
            model: 'm',
            systemPrompt: 'sys',
            messages: const [ChatMessage(ChatRole.user, 'hi')],
            temperature: 0.7,
          ),
        )
        .toList();

    expect(events.whereType<DoneEvent>(), isEmpty);
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('message_stop'));
  });

  test('cancelling the subscription closes the connection (abort)', () async {
    // 回归防护「打断后请求在服务端跑到自然结束」:响应字节流永不完成(模型
    // 思考中、首字节未到),消费方取消订阅必须立即关闭底层连接。与 OpenAI
    // 后端同款断链语义。
    final client = _CloseTrackingClient.streaming(
      (req, body) async => http.StreamedResponse(
        Stream<Uint8List>.fromFuture(Completer<Uint8List>().future), // 永不发出字节
        200,
      ),
    );
    final backend = createBackend(
      const BackendConfig(provider: BackendProvider.anthropic, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      client: client,
    );

    final events = <LlmEvent>[];
    final sub = backend
        .generate(LlmRequest(
          model: 'm',
          systemPrompt: 'sys',
          messages: const [ChatMessage(ChatRole.user, 'hi')],
          temperature: 0.7,
        ))
        .listen(events.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    expect(client.closes, 1); // 取消即断链
  });
}

/// 记录 close 次数的 MockClient:断链回归要断言「取消订阅 → 连接被关闭」。
class _CloseTrackingClient extends MockClient {
  int closes = 0;
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
