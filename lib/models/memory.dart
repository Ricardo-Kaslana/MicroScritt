class Memory {
  final int? id;
  final int sessionId;
  final String content;
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
