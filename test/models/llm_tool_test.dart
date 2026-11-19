// 原生工具中立类型与 ChatMessage/LlmRequest 的工具扩展回归。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/llm_tool.dart';

void main() {
  test('LlmTool carries name/description/parameters', () {
    const tool = LlmTool(
      name: 'setVariables',
      description: 'stage variable updates',
      parameters: {'type': 'object', 'properties': {}},
    );
    expect(tool.name, 'setVariables');
    expect(tool.description, 'stage variable updates');
    expect(tool.parameters['type'], 'object');
  });

  test('ToolCall keeps arguments as raw JSON string', () {
    const call = ToolCall(id: 'c1', name: 'finish', arguments: '{"summary":"ok"}');
    expect(call.id, 'c1');
    expect(call.name, 'finish');
    expect(call.arguments, '{"summary":"ok"}');
  });

  test('ChatRole.tool wire literal is tool (OpenAI)', () {
    expect(const ChatMessage(ChatRole.tool, '').wireRole, 'tool');
    expect(const ChatMessage(ChatRole.assistant, '').wireRole, 'assistant');
  });

  test('ChatMessage positional constructor stays backward compatible', () {
    const m = ChatMessage(ChatRole.user, 'hi');
    expect(m.role, ChatRole.user);
    expect(m.content, 'hi');
    expect(m.toolCalls, isNull);
    expect(m.toolCallId, isNull);
  });

  test('ChatMessage carries assistant toolCalls and tool result id', () {
    const assistant = ChatMessage(
      ChatRole.assistant,
      '',
      toolCalls: [ToolCall(id: 'c1', name: 'readVariables', arguments: '{}')],
    );
    expect(assistant.toolCalls, hasLength(1));
    expect(assistant.toolCalls!.single.name, 'readVariables');

    const result = ChatMessage(ChatRole.tool, '{"location":"图书馆"}', toolCallId: 'c1');
    expect(result.role, ChatRole.tool);
    expect(result.toolCallId, 'c1');
  });

  test('LlmRequest.tools defaults to empty (old requests unchanged)', () {
    const req = LlmRequest(
      model: 'm',
      systemPrompt: 'sys',
      messages: [ChatMessage(ChatRole.user, 'hi')],
      temperature: 1,
    );
    expect(req.tools, isEmpty);
  });

  test('ToolCallsEvent carries the calls list', () {
    const event = ToolCallsEvent([ToolCall(id: 'c1', name: 'finish', arguments: '{}')]);
    expect(event, isA<LlmEvent>());
    expect(event.calls.single.id, 'c1');
  });
}