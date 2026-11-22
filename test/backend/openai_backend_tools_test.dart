// OpenAI 后端原生工具:流式 tool_calls 累计、多调用顺序、A1 语义翻转
// (tools 请求纯工具=成功 vs 无 tools=契约错误)、请求体序列化往返。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/backend/backend_factory.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/upstream_error.dart';

void main() {
  const config = BackendConfig(
    provider: BackendProvider.openai,
    baseUrl: 'https://x',
    apiKey: 'k',
    model: 'm',
  );
  const tool = LlmTool(
    name: 'setVariables',
    description: 'stage updates',
    parameters: {'type': 'object', 'properties': {}},
  );

  MockClient sse(String body, {void Function(Map<String, dynamic>)? onBody}) =>
      MockClient((req) async {
        onBody?.call(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response.bytes(utf8.encode(body), 200);
      });

  LlmRequest req({List<LlmTool> tools = const [tool], List<ChatMessage>? messages}) =>
      LlmRequest(
        model: 'm',
        systemPrompt: 'sys',
        messages: messages ?? const [ChatMessage(ChatRole.user, 'hi')],
        tools: tools,
        temperature: 1,
      );

  test('accumulates streamed tool_call arguments by index into ToolCallsEvent', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"setVariables","arguments":"{\\"up"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"dates\\":{}}"}}]}}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();

    final toolEvents = events.whereType<ToolCallsEvent>().toList();
    expect(toolEvents, hasLength(1));
    final call = toolEvents.single.calls.single;
    expect(call.id, 'call_1');
    expect(call.name, 'setVariables');
    expect(call.arguments, '{"updates":{}}');
    expect(events.whereType<ErrorEvent>(), isEmpty);
  });

  test('multiple tool calls are emitted in index order', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c2","function":{"name":"finish","arguments":"{}"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"readVariables","arguments":"{}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();

    final calls = events.whereType<ToolCallsEvent>().single.calls;
    expect(calls.map((c) => c.id).toList(), ['c1', 'c2']);
    expect(calls.map((c) => c.name).toList(), ['readVariables', 'finish']);
  });

  test('A1 flip: tool-only round WITH tools is success (ToolCallsEvent, no error)', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"finish","arguments":"{}"}}]}}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();

    expect(events.whereType<ToolCallsEvent>(), hasLength(1));
    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('tool-only round WITHOUT tools stays a contractViolation error', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"finish","arguments":"{}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body))
        .generate(req(tools: const []))
        .toList();

    expect(events.whereType<ToolCallsEvent>(), isEmpty);
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.kind, UpstreamErrorKind.contractViolation);
  });

  test('content and tool calls coexist: TextDelta then ToolCallsEvent', () async {
    final body = [
      'data: {"choices":[{"delta":{"content":"thinking aloud"}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"finish","arguments":"{}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'thinking aloud');
    expect(events.whereType<ToolCallsEvent>().single.calls.single.name, 'finish');
  });

  test('request body carries tools + tool_choice:auto and block-aware messages', () async {
    late Map<String, dynamic> sent;
    final body = 'data: [DONE]';
    final messages = [
      const ChatMessage(ChatRole.user, 'hi'),
      const ChatMessage(
        ChatRole.assistant,
        '',
        toolCalls: [ToolCall(id: 'c1', name: 'setVariables', arguments: '{"updates":{}}')],
      ),
      const ChatMessage(ChatRole.tool, '{"ok":true}', toolCallId: 'c1'),
    ];
    await createBackend(config, client: sse(body, onBody: (b) => sent = b))
        .generate(req(messages: messages))
        .toList();

    expect(sent['tool_choice'], 'auto');
    expect(sent.containsKey('parallel_tool_calls'), isFalse);
    final tools = sent['tools'] as List;
    expect(tools.single['function']['name'], 'setVariables');
    expect(tools.single['function']['parameters'], {'type': 'object', 'properties': {}});

    final msgs = sent['messages'] as List;
    // system + user + assistant(tool_calls) + tool
    expect(msgs[0]['role'], 'system');
    expect(msgs[1]['role'], 'user');
    final assistant = msgs[2] as Map;
    expect(assistant['role'], 'assistant');
    expect(assistant['content'], isNull);
    expect(assistant['tool_calls'].single['id'], 'c1');
    expect(assistant['tool_calls'].single['function']['arguments'], '{"updates":{}}');
    final toolMsg = msgs[3] as Map;
    expect(toolMsg['role'], 'tool');
    expect(toolMsg['tool_call_id'], 'c1');
    expect(toolMsg['content'], '{"ok":true}');
  });

  test('no tools key sent when request.tools is empty (regression)', () async {
    late Map<String, dynamic> sent;
    await createBackend(config, client: sse('data: [DONE]', onBody: (b) => sent = b))
        .generate(req(tools: const []))
        .toList();
    expect(sent.containsKey('tools'), isFalse);
    expect(sent.containsKey('tool_choice'), isFalse);
  });

  test('missing index is keyed by id instead of merging into slot 0', () async {
    // 网关省略 index 时,旧实现把每个调用都并进 index 0:多个调用被合并,
    // assistant 回放与 tool_result 数量对不上。
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":"readVariables","arguments":"{}"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"id":"c2","function":{"name":"finish","arguments":"{}"}}]}}]}',
      'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    final calls = events.whereType<ToolCallsEvent>().single.calls;
    expect(calls.map((c) => c.id).toList(), ['c1', 'c2']);
    expect(calls.map((c) => c.name).toList(), ['readVariables', 'finish']);
  });

  test('a new non-empty id creates a new slot even when index repeats', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"a","arguments":"{}"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c2","function":{"name":"b","arguments":"{}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    final calls = events.whereType<ToolCallsEvent>().single.calls;
    expect(calls.map((c) => c.id).toList(), ['c1', 'c2']);
  });

  test('a repeated full tool_call block overwrites instead of appending', () async {
    // 重连/重放时网关会整块重发同一调用:追加会把 JSON 拼坏。
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"finish","arguments":"{\\"a\\":1}"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"finish","arguments":"{\\"a\\":1}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    expect(events.whereType<ToolCallsEvent>().single.calls.single.arguments, '{"a":1}');
  });

  test('a complete-looking continuation fragment is still appended', () async {
    // 半截累计后的 `{}` 是合法续块,不能因为"单看是完整 JSON"就覆盖掉前缀。
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"finish","arguments":"{\\"a\\":"}}]}}]}',
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"finish","arguments":"{}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    expect(events.whereType<ToolCallsEvent>().single.calls.single.arguments, '{"a":{}');
  });

  test('missing id is synthesized as call_<index> for replay consistency', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"finish","arguments":"{}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    expect(events.whereType<ToolCallsEvent>().single.calls.single.id, 'call_0');
  });

  test('tool calls with empty name never reach ToolCallsEvent', () async {
    final body = [
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"arguments":"{}"}}]}}]}',
      'data: [DONE]',
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    expect(events.whereType<ToolCallsEvent>(), isEmpty);
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors.single.kind, UpstreamErrorKind.contractViolation);
  });
}