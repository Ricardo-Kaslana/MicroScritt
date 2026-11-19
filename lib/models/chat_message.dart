/// 发送给 LLM 的单条消息。
///
/// 只用于上下文组装与后端请求,不直接落库;落库使用 `Message`。正文恒为纯
/// 文本(不含图片/富媒体);工具调用以结构化字段携带,由后端映射为协议的
/// 工具块。agent 转录是内存态消息列表,同样不落 `messages` 表。
library;

import 'llm_tool.dart';

/// 消息角色。
enum ChatRole { system, user, assistant, tool }

/// 一条待发送的聊天消息。
class ChatMessage {
  /// 消息角色。
  final ChatRole role;

  /// 消息正文(纯文本)。assistant 工具调用轮可为空串或与调用并存。
  final String content;

  /// assistant 发起工具调用的轮:携带调用列表;其它角色为 null。
  final List<ToolCall>? toolCalls;

  /// tool 结果消息:配对的工具调用 id;其它角色为 null。
  final String? toolCallId;

  /// assistant 轮需**原样回传**的后端专属内容块(如 Anthropic 的
  /// thinking/redacted_thinking 块,多轮工具调用时协议要求未改且原序回放,
  /// 否则 400)。由后端经 [ToolCallsEvent.replayBlocks] 带出、消费方存于此,
  /// 下一轮序列化时前置回 assistant 内容;其它后端忽略。中立模型不解释其语义。
  final List<Map<String, dynamic>>? opaqueBlocks;

  const ChatMessage(
    this.role,
    this.content, {
    this.toolCalls,
    this.toolCallId,
    this.opaqueBlocks,
  });

  /// OpenAI 协议的角色字面值。Anthropic 后端对 tool 角色另行映射为 user
  /// 消息内的 tool_result 块,不走此字面值。
  String get wireRole => switch (role) {
        ChatRole.system => 'system',
        ChatRole.user => 'user',
        ChatRole.assistant => 'assistant',
        ChatRole.tool => 'tool',
      };
}