/// 会话记忆模型(`memories` 表)。
///
/// 记忆是主写模型的长期事实,以冻结副本作为上下文第 0 条消息;由用户
/// 主动维护,后台不自动改写。
library;

/// 一条会话记忆(每会话至多一条)。
class Memory {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 所属会话 id。
  final int sessionId;

  /// 记忆正文(纯文本)。
  final String content;

  /// 最后更新时间(毫秒时间戳)。
  final int updatedAt;

  const Memory({this.id, required this.sessionId, required this.content, required this.updatedAt});

  Map<String, Object?> toMap() => {'id': id, 'session_id': sessionId, 'content': content, 'updated_at': updatedAt};

  factory Memory.fromMap(Map<String, Object?> m) => Memory(
    id: m['id'] as int?,
    sessionId: m['session_id'] as int,
    content: m['content'] as String,
    updatedAt: m['updated_at'] as int,
  );
}
