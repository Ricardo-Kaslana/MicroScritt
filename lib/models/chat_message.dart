/// 发送给 LLM 的单条纯文本消息。
///
/// 只用于上下文组装与后端请求,不直接落库;落库使用 `Message`。
library;

/// 消息角色。
enum ChatRole { system, user, assistant }

/// 一条待发送的聊天消息(纯文本,不含图片/富媒体)。
class ChatMessage {
  /// 消息角色。
  final ChatRole role;

  /// 消息正文。
  final String content;

  const ChatMessage(this.role, this.content);

  /// OpenAI/Anthropic 共用的角色字面值。
  String get wireRole => switch (role) {
        ChatRole.system => 'system',
        ChatRole.user => 'user',
        ChatRole.assistant => 'assistant',
      };
}
