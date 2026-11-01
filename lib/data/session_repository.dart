/// 会话(`sessions` 表)与列表聚合查询的持久化。
///
/// 持久化每会话的 token 用量;删除会话时手动级联清理依赖行
/// (sqflite 默认不启用外键级联)。
library;

import 'database.dart';

/// 一个会话及其累计 token 用量。
class Session {
  final int id;
  final int characterId;
  final String title;
  final DateTime createdAt;

  /// 会话累计的 token 用量(主写流 + 后台引擎 + 压缩摘要,随每次生成持久化)。
  /// 重启/重进会话后从 sessions 表恢复,供上下文面板展示。
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int backgroundInputTokens;
  final int backgroundOutputTokens;
  final int backgroundCachedInputTokens;

  /// 压缩摘要(compact)调用的 token 用量(主写/后台之外的第三桶)。
  final int compactInputTokens;
  final int compactOutputTokens;
  final int compactCachedInputTokens;

  const Session({
    required this.id,
    required this.characterId,
    required this.title,
    required this.createdAt,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.backgroundInputTokens = 0,
    this.backgroundOutputTokens = 0,
    this.backgroundCachedInputTokens = 0,
    this.compactInputTokens = 0,
    this.compactOutputTokens = 0,
    this.compactCachedInputTokens = 0,
  });
}

/// 会话列表展示用:消息数 + 最后一条消息预览(会话卡片)。
class SessionInfo {
  final int id;
  final int characterId;
  final String title;
  final DateTime createdAt;
  final int messageCount;

  /// 其中带图的消息数(image_base64/image_url 任一非空);图文混排消息
  /// 也计入此项 —— 与 [messageCount] 构成"文本 = 总数 - 图片"的干净划分。
  final int imageCount;
  final String? lastMessage;
  const SessionInfo({
    required this.id,
    required this.characterId,
    required this.title,
    required this.createdAt,
    required this.messageCount,
    this.imageCount = 0,
    required this.lastMessage,
  });
}

/// 会话仓储:CRUD、token 用量持久化与列表聚合。
class SessionRepository {
  final AppDatabase db;
  SessionRepository(this.db);

  Future<int> create(int characterId, String title) async {
    return db.db.insert('sessions', {
      'character_id': characterId,
      'title': title,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<Session?> get(int id) async {
    final rows = await db.db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<Session>> byCharacter(int characterId) async {
    final rows = await db.db.query(
      'sessions',
      where: 'character_id = ?',
      whereArgs: [characterId],
      orderBy: 'id',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> rename(int id, String title) async {
    await db.db.update(
      'sessions',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 持久化会话累计的 token 用量(主写流 + 后台引擎 + 压缩摘要),随每轮生成落库。
  Future<void> updateTokenUsage({
    required int sessionId,
    required int inputTokens,
    required int outputTokens,
    required int cachedInputTokens,
    required int backgroundInputTokens,
    required int backgroundOutputTokens,
    required int backgroundCachedInputTokens,
    int compactInputTokens = 0,
    int compactOutputTokens = 0,
    int compactCachedInputTokens = 0,
  }) async {
    await db.db.update(
      'sessions',
      {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'cached_input_tokens': cachedInputTokens,
        'background_input_tokens': backgroundInputTokens,
        'background_output_tokens': backgroundOutputTokens,
        'background_cached_input_tokens': backgroundCachedInputTokens,
        'compact_input_tokens': compactInputTokens,
        'compact_output_tokens': compactOutputTokens,
        'compact_cached_input_tokens': compactCachedInputTokens,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// sqflite 默认不启用外键级联,手动在单事务内清理依赖行(消息/变量/记忆/
  /// 生图指导)。技能是全局目录,不随会话删除。
  Future<void> deleteWithCascade(int id) async {
    await db.db.transaction((txn) async {
      await txn.delete('messages', where: 'session_id = ?', whereArgs: [id]);
      await txn.delete('variables', where: 'session_id = ?', whereArgs: [id]);
      await txn.delete('memories', where: 'session_id = ?', whereArgs: [id]);
      await txn.delete(
        'image_guides',
        where: 'session_id = ?',
        whereArgs: [id],
      );
      await txn.delete('sessions', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 角色的全部会话 + 消息数 + 带图数 + 最后一条消息预览,单条聚合查询。
  /// 口径与聊天页可见消息一致(`role != 'system' && kind == 'chat'`):
  /// 附件旁路行、压缩摘要等内部行不计入条数、也不作末条预览。
  /// 带图口径与气泡一致(image_base64 非空串或 image_url 非空);
  /// 末条是图片消息(正文为空)时预览显示「图片消息」而非空白。
  /// 排序按「最近有可见消息」倒序(messages.id 全局自增,可直接当活动时间轴);
  /// 空会话排在最后,彼此按创建时间倒序。
  Future<List<SessionInfo>> infosByCharacter(int characterId) async {
    final rows = await db.db.rawQuery(
      '''
      SELECT s.id AS id, s.character_id AS character_id, s.title AS title, s.created_at AS created_at,
             COUNT(m.id) AS message_count,
             SUM(CASE WHEN (m.image_base64 IS NOT NULL AND m.image_base64 != '') OR m.image_url IS NOT NULL
                      THEN 1 ELSE 0 END) AS image_count,
             MAX(m.id) AS last_activity,
             (SELECT CASE
                       WHEN (m2.image_base64 IS NOT NULL AND m2.image_base64 != '')
                            OR m2.image_url IS NOT NULL THEN '图片消息'
                       ELSE m2.content
                      END
                FROM messages m2
                WHERE m2.session_id = s.id AND m2.kind = 'chat' AND m2.role != 'system'
                ORDER BY m2.seq DESC LIMIT 1) AS last_message
      FROM sessions s
      LEFT JOIN messages m
        ON m.session_id = s.id AND m.kind = 'chat' AND m.role != 'system'
      WHERE s.character_id = ?
      GROUP BY s.id
      ORDER BY (last_activity IS NULL), last_activity DESC, s.created_at DESC, s.id DESC
    ''',
      [characterId],
    );
    return rows
        .map(
          (r) => SessionInfo(
            id: r['id'] as int,
            characterId: r['character_id'] as int,
            title: r['title'] as String? ?? '',
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              r['created_at'] as int,
            ),
            messageCount: r['message_count'] as int,
            imageCount: r['image_count'] as int? ?? 0,
            lastMessage: r['last_message'] as String?,
          ),
        )
        .toList();
  }

  Session _fromRow(Map<String, Object?> r) => Session(
    id: r['id'] as int,
    characterId: r['character_id'] as int,
    title: r['title'] as String? ?? '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    inputTokens: r['input_tokens'] as int? ?? 0,
    outputTokens: r['output_tokens'] as int? ?? 0,
    cachedInputTokens: r['cached_input_tokens'] as int? ?? 0,
    backgroundInputTokens: r['background_input_tokens'] as int? ?? 0,
    backgroundOutputTokens: r['background_output_tokens'] as int? ?? 0,
    backgroundCachedInputTokens:
        r['background_cached_input_tokens'] as int? ?? 0,
    compactInputTokens: r['compact_input_tokens'] as int? ?? 0,
    compactOutputTokens: r['compact_output_tokens'] as int? ?? 0,
    compactCachedInputTokens: r['compact_cached_input_tokens'] as int? ?? 0,
  );
}
