// Anthropic 后端原生工具:tool_use 流式累计、thinking 块回放带出、块感知
// 序列化(tool_use/tool_result/合并 user 消息)、无工具请求扁平序列化回归。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/backend/backend_factory.dart';
import 'package:microscritt/backend/llm_backend.dart';

void main() {
  const config = BackendConfig(
    provider: BackendProvider.anthropic,
    baseUrl: 'https://x',
    apiKey: 'k',
    model: 'm',
    maxTokens: 4096,
  );
  const tool = LlmTool(
    name: 'setVariables',
    description: 'stage updates',
    parameters: {'type': 'object', 'properties': {}},
  );

  String line(Map<String, dynamic> m) => 'data: ${jsonEncode(m)}';
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

  test('accumulates tool_use input_json_delta into ToolCallsEvent', () async {
    final body = [
      line({'type': 'message_start', 'message': {'usage': {'input_tokens': 10, 'output_tokens': 0}}}),
      line({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 'tu_1', 'name': 'setVariables', 'input': {}}}),
      line({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{"updates":'}}),
      line({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{}}'}}),
      line({'type': 'content_block_stop', 'index': 0}),
      line({'type': 'message_delta', 'usage': {'output_tokens': 5}}),
      line({'type': 'message_stop'}),
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();

    final call = events.whereType<ToolCallsEvent>().single.calls.single;
    expect(call.id, 'tu_1');
    expect(call.name, 'setVariables');
    expect(call.arguments, '{"updates":{}}');
    expect(events.whereType<DoneEvent>(), isNotEmpty);
    expect(events.whereType<ErrorEvent>(), isEmpty);
  });

  test('multiple tool_use blocks emitted in index order', () async {
    final body = [
      line({'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'tool_use', 'id': 't2', 'name': 'finish', 'input': {}}}),
      line({'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'input_json_delta', 'partial_json': '{}'}}),
      line({'type': 'content_block_stop', 'index': 1}),
      line({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'tool_use', 'id': 't1', 'name': 'readVariables', 'input': {}}}),
      line({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': '{}'}}),
      line({'type': 'content_block_stop', 'index': 0}),
      line({'type': 'message_stop'}),
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    final calls = events.whereType<ToolCallsEvent>().single.calls;
    expect(calls.map((c) => c.id).toList(), ['t1', 't2']);
  });

  test('thinking blocks are captured into replayBlocks for faithful replay', () async {
    final body = [
      line({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''}}),
      line({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'thinking_delta', 'thinking': 'let me think'}}),
      line({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'sig123'}}),
      line({'type': 'content_block_stop', 'index': 0}),
      line({'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'tool_use', 'id': 't1', 'name': 'finish', 'input': {}}}),
      line({'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'input_json_delta', 'partial_json': '{}'}}),
      line({'type': 'content_block_stop', 'index': 1}),
      line({'type': 'message_stop'}),
    ].join('\n\n');
    final events = await createBackend(config, client: sse(body)).generate(req()).toList();
    final ev = events.whereType<ToolCallsEvent>().single;
    expect(ev.calls.single.name, 'finish');
    expect(ev.replayBlocks, [
      {'type': 'thinking', 'thinking': 'let me think', 'signature': 'sig123'},
    ]);
  });

  test('request body: tools input_schema + block-aware messages with thinking replay', () async {
    late Map<String, dynamic> sent;
    final messages = [
      const ChatMessage(ChatRole.user, 'hi'),
      ChatMessage(
        ChatRole.assistant,
        '',
        toolCalls: const [ToolCall(id: 't1', name: 'setVariables', arguments: '{"updates":{}}')],
        opaqueBlocks: const [
          {'type': 'thinking', 'thinking': 'hmm', 'signature': 's'},
        ],
      ),
      const ChatMessage(ChatRole.tool, '{"ok":true}', toolCallId: 't1'),
    ];
    await createBackend(config, client: sse(line({'type': 'message_stop'}), onBody: (b) => sent = b))
        .generate(req(messages: messages))
        .toList();

    expect((sent['tools'] as List).single['input_schema'], {'type': 'object', 'properties': {}});
    final msgs = sent['messages'] as List;
    expect(msgs[0]['role'], 'user');
    expect((msgs[0]['content'] as List).single, {'type': 'text', 'text': 'hi'});
    final assistant = msgs[1] as Map;
    expect(assistant['role'], 'assistant');
    final blocks = assistant['content'] as List;
    expect(blocks[0], {'type': 'thinking', 'thinking': 'hmm', 'signature': 's'});
    expect(blocks[1]['type'], 'tool_use');
    expect(blocks[1]['id'], 't1');
    expect(blocks[1]['input'], {'updates': {}});
    final toolResult = msgs[2] as Map;
    expect(toolResult['role'], 'user');
    expect((toolResult['content'] as List).single, {
      'type': 'tool_result',
      'tool_use_id': 't1',
      'content': '{"ok":true}',
    });
  });

  test('consecutive tool results merge into one user message', () async {
    late Map<String, dynamic> sent;
    final messages = [
      const ChatMessage(
        ChatRole.assistant,
        '',
        toolCalls: [
          ToolCall(id: 't1', name: 'a', arguments: '{}'),
          ToolCall(id: 't2', name: 'b', arguments: '{}'),
        ],
      ),
      const ChatMessage(ChatRole.tool, 'r1', toolCallId: 't1'),
      const ChatMessage(ChatRole.tool, 'r2', toolCallId: 't2'),
    ];
    await createBackend(config, client: sse(line({'type': 'message_stop'}), onBody: (b) => sent = b))
        .generate(req(messages: messages))
        .toList();
    final msgs = sent['messages'] as List;
    expect(msgs, hasLength(2)); // assistant + 单条合并 user
    final userBlocks = (msgs[1]['content'] as List);
    expect(userBlocks, hasLength(2));
    expect(userBlocks[0]['tool_use_id'], 't1');
    expect(userBlocks[1]['tool_use_id'], 't2');
  });

  test('no tools: flat message serialization unchanged (regression)', () async {
    late Map<String, dynamic> sent;
    await createBackend(config, client: sse(line({'type': 'message_stop'}), onBody: (b) => sent = b))
        .generate(req(tools: const []))
        .toList();
    expect(sent.containsKey('tools'), isFalse);
    final msgs = sent['messages'] as List;
    expect(msgs.single, {'role': 'user', 'content': 'hi'});
  });
}