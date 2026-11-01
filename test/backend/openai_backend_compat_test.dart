// 端点兼容选项(noncePrefix)与错误分类的后端测试。
// replyViaTool 的工具通道行为见 openai_backend_reply_channel_test.dart。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/openai_backend.dart';
import 'package:microscritt/backend/upstream_error.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/endpoint_compat.dart';

void main() {
  const plainConfig = BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm');
  const request = LlmRequest(
    model: 'm',
    systemPrompt: 'sys',
    messages: [ChatMessage(ChatRole.user, 'hi')],
  );

  test('without a compat option no tools key is sent (劣质网关对未知字段回 400)', () async {
    late Map<String, dynamic> body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();

    expect(body.containsKey('tools'), isFalse);
  });

  test('SSE keep-alive comment lines are ignored', () async {
    final body = [
      ': keep-alive',
      '',
      ': keep-alive',
      '',
      'data: {"choices":[{"delta":{"content":"pong"}}]}',
      '',
      'data: [DONE]',
      '',
    ].join('\n\n');
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(body), 200));

    final events = await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'pong');
    expect(events.whereType<ErrorEvent>(), isEmpty);
  });

  test('tool-call-only response errors instead of a silent empty reply', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":""}}]}}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      'data: [DONE]',
    ].join('\n\n');
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(body), 200));

    final events = await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors.single.kind, UpstreamErrorKind.contractViolation);
    expect(errors.single.message, contains('仅返回工具调用'));
  });

  test('tool calls alongside content do not fail the round', () async {
    final body = [
      'data: {"choices":[{"delta":{"content":"回答正文"}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":""}}]}}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      'data: [DONE]',
    ].join('\n\n');
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(body), 200));

    final events = await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '回答正文');
    expect(events.whereType<ErrorEvent>(), isEmpty);
  });

  test('HTTP failures carry their stable classification kind and status code', () async {
    final cases = <(int, String, UpstreamErrorKind)>[
      (401, '{"error":{"message":"Invalid API key"}}', UpstreamErrorKind.auth),
      (402, '{"error":{"message":"密钥额度不足,无法生成图片。"}}', UpstreamErrorKind.quota),
      (
        403,
        '{"type":"error","error":{"type":"FreeTierError","message":"free tier can only be used from within the provider"}}',
        UpstreamErrorKind.gatewayPolicy,
      ),
      (429, '{"error":{"message":"rate limit exceeded"}}', UpstreamErrorKind.rateLimit),
      (500, 'Internal server error', UpstreamErrorKind.transient),
      (400, '{"error":{"message":"Invalid request"}}', UpstreamErrorKind.contractViolation),
    ];
    for (final (status, bodyText, expectedKind) in cases) {
      final client = MockClient((req) async => http.Response.bytes(utf8.encode(bodyText), status));
      final events =
          await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();
      final errors = events.whereType<ErrorEvent>().toList();
      expect(errors, hasLength(1), reason: 'HTTP $status should produce one ErrorEvent');
      expect(errors.single.statusCode, status, reason: 'HTTP $status');
      expect(errors.single.kind, expectedKind, reason: 'HTTP $status: $bodyText');
    }
  });

  test('mid-stream error payload carries its classified kind', () async {
    final body = [
      'data: {"choices":[{"delta":{"content":"Hel"}}]}',
      'data: {"error":{"message":"rate limited upstream","type":"server_error"}}',
      'data: [DONE]',
    ].join('\n\n');
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(body), 200));

    final events = await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors.single.message, contains('rate limited upstream'));
    expect(errors.single.kind, UpstreamErrorKind.rateLimit);
  });

  test('structural stream failures are classified (bad payload / early end / content_filter)', () async {
    // bad SSE payload → contractViolation
    final badPayload = MockClient((req) async => http.Response.bytes(utf8.encode('data: {oops}\n\n'), 200));
    var events = await OpenAiBackend(config: plainConfig, client: badPayload).generate(request).toList();
    expect(events.whereType<ErrorEvent>().single.kind, UpstreamErrorKind.contractViolation);

    // 连接提前掐断 → transient
    final earlyEnd = MockClient((req) async => http.Response.bytes(utf8.encode('data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n'), 200));
    events = await OpenAiBackend(config: plainConfig, client: earlyEnd).generate(request).toList();
    expect(events.whereType<ErrorEvent>().single.kind, UpstreamErrorKind.transient);

    // content_filter 截停 → contentFlag
    final filtered = [
      'data: {"choices":[{"delta":{"content":"Par"}}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}',
      'data: [DONE]',
    ].join('\n\n');
    final filterClient = MockClient((req) async => http.Response.bytes(utf8.encode(filtered), 200));
    events = await OpenAiBackend(config: plainConfig, client: filterClient).generate(request).toList();
    expect(events.whereType<ErrorEvent>().single.kind, UpstreamErrorKind.contentFlag);
  });

  test('noncePrefix prepends a fresh random prefix to the system row each request', () async {
    final seen = <String>[];
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      seen.add(((body['messages'] as List).first as Map)['content'] as String);
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    const nonceConfig = BackendConfig(
      provider: BackendProvider.openai,
      baseUrl: 'https://x',
      apiKey: 'k',
      model: 'm',
      compat: EndpointCompat(noncePrefix: true),
    );
    final backend = OpenAiBackend(config: nonceConfig, client: client);
    await backend.generate(request).toList();
    await backend.generate(request).toList();

    // 形状:6–8 位小写字母数字 nonce + 换行 + 原 system,且每轮前缀不同。
    final nonceRe = RegExp(r'^[a-z0-9]{6,8}\nsys$');
    expect(nonceRe.hasMatch(seen[0]), isTrue, reason: seen[0]);
    expect(nonceRe.hasMatch(seen[1]), isTrue, reason: seen[1]);
    expect(seen[0], isNot(seen[1]));
  });

  test('noncePrefix off leaves the system row verbatim', () async {
    late Map<String, dynamic> body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode('data: [DONE]\n\n'), 200);
    });
    await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();

    expect(((body['messages'] as List).first as Map)['content'], 'sys');
  });
}
