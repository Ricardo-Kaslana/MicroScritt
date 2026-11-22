/// 消息行(`messages` 表)的持久化:追加、窗口读取与导入落库。
///
/// 消息只追加、seq 单调;消息行只保存图片资产哈希,业务写与引用计数同事务。
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import '../models/image_ref.dart';
import '../models/message.dart';
import 'database.dart';

/// 消息仓储:单行追加、显示/组装双口径窗口读取与内存缓存。
///
/// 缓存按 `(Database, sessionId)` 跨实例共享,任一实例的写路径都会精确失效
/// 对应会话;窗口读取不进缓存(形状由调用方游标决定)。
class MessageRepository {
  final AppDatabase db;

  /// 内存级读取缓存:缓存某会话按 seq 排序的完整消息列表,避免同一轮生成
  /// (send → _generateReply → 后台维护)里重复执行全表查询与行映射。
  ///
  /// **跨实例共享**(static):任一实例的写路径都精确失效该 (db,sessionId)
  /// 的所有读者。`Message` 不可变,缓存列表也只按不可变快照共享。
  static final LinkedHashMap<_MessageCacheKey, List<Message>> _cache =
      LinkedHashMap<_MessageCacheKey, List<Message>>();

  /// 容量 12:只服务同轮交互里的重复读,逐出按插入序(FIFO)。
  static const int _cacheCap = 12;

  MessageRepository(this.db);

  static void _invalidate(Database db, int sessionId) {
    // 代次让「失效前派发、提交后才返回」的读不把旧快照回填缓存。
    _cacheGeneration++;
    _cache.removeWhere((k, _) => k.db == db && k.sessionId == sessionId);
  }

  static int _cacheGeneration = 0;

  /// 供不经过本仓库的写路径(会话/角色级联删除)失效缓存。
  static void invalidateSession(Database db, int sessionId) =>
      _invalidate(db, sessionId);

  static List<Message>? _peek(Database db, int sessionId) =>
      _cache[_MessageCacheKey(db, sessionId)];

  static void _store(Database db, int sessionId, List<Message> messages) {
    if (_cache.length >= _cacheCap) {
      _cache.remove(_cache.keys.first);
    }
    _cache[_MessageCacheKey(db, sessionId)] = messages;
  }

  static String? _localHash(String? hash) =>
      hash == null || hash.isEmpty ? null : hash;

  /// 追加一条消息,返回落库后的完整行(id/seq 已定)。
  ///
  /// seq 计算、资产引用增加与消息插入在同一事务内完成;任一步失败都会回滚,
  /// 不产生已指向业务行但未计数(或已计数但无业务行)的资产。
  Future<Message> append({
    required int sessionId,
    required String role,
    required String content,
    String? imageHash,
    String? imageUrl,
    String? imagePrompt,
    MessageKind kind = MessageKind.chat,
    String? refId,
  }) async {
    late final Message appended;
    final hash = _localHash(imageHash);
    await db.db.transaction((txn) async {
      final next = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE session_id = ?',
          [sessionId],
        ),
      )!;
      if (hash != null) await db.images.acquire(txn, hash);
      final id = await txn.insert('messages', {
        'session_id': sessionId,
        'role': role,
        'content': content,
        'seq': next,
        'kind': kind.wire,
        if (refId != null) 'ref_id': refId,
        if (hash != null) 'image_hash': hash,
        if (imageUrl != null) 'image_url': imageUrl,
        if (imagePrompt != null) 'image_prompt': imagePrompt,
      });
      appended = Message(
        id: id,
        sessionId: sessionId,
        role: role,
        content: content,
        seq: next,
        imageHash: hash,
        imageUrl: imageUrl,
        imagePrompt: imagePrompt,
        kind: kind,
        refId: refId,
      );
    });
    _refreshCacheAfterAppend(db.db, sessionId, appended);
    return appended;
  }

  /// append 成功后的缓存维护(只在事务成功后调用)。
  static void _refreshCacheAfterAppend(
    Database db,
    int sessionId,
    Message appended,
  ) {
    final key = _MessageCacheKey(db, sessionId);
    final cached = _cache[key];
    if (cached != null) _cache[key] = [...cached, appended];
  }

  static const String _messageProjection =
      'id, session_id, role, content, seq, is_compacted, compact_of, '
      'image_hash, image_url, image_prompt, kind, ref_id';

  /// 某会话的全部消息,按 seq 升序;哈希是轻量元数据,随列表直接返回。
  Future<List<Message>> bySession(int sessionId) async {
    final cached = _peek(db.db, sessionId);
    if (cached != null) return cached;
    final generation = _cacheGeneration;
    final dbRows = await db.db.rawQuery(
      'SELECT $_messageProjection '
      'FROM messages WHERE session_id = ? ORDER BY seq',
      [sessionId],
    );
    final rows = dbRows.map(Message.fromMap).toList();
    // 查询期间发生过任何失效:结果可能早于某个提交,丢弃本次回填。
    if (generation == _cacheGeneration) {
      _store(db.db, sessionId, rows);
    }
    return rows;
  }

  // ===== 窗口化读取 =====
  //
  // 长会话的全量读取成本随行数线性涨(进入延迟/内存/行映射全如此)。本组
  // 原语只服务 **UI 显示窗口**(聊天页尾部若干行 + 分页游标);**上下文组装
  // 不走这里** —— 组装不按条数裁剪,必须看到全部未折叠活跃行,由
  // [activeWindow] 独立取。两者分离是刻意的:分页会下移显示游标,
  // 若组装共用同一游标,用户翻阅历史就会改变发给 LLM 的上下文。
  // [bySession] 全量读取保留给压缩/导出/后台引擎等确需全量转录的调用方,
  // 静态缓存亦只服务全量口径。

  /// 显示窗口下界的 seq:第 [displayCount] 倒数条显示行(`kind=chat` 且
  /// `role != system`)的 seq;行数不足 [displayCount] 时返回 null(全量在窗)。
  ///
  /// **只服务 UI 显示窗口**(聊天页渲染 + 分页游标)。组装窗口**不共用**它 ——
  /// 组装需要全部未折叠活跃行,由 [activeWindow] 独立取。
  /// 两者必须分离:分页([bySessionPageBefore])会下移显示游标,若组装共用
  /// 同一游标,用户翻阅历史就会改变发给 LLM 的上下文。
  /// 边界的 OFFSET 定位依赖 `(session_id, seq)` 索引。
  Future<int?> sessionWindowFloor({
    required int sessionId,
    required int displayCount,
  }) async {
    return Sqflite.firstIntValue(
      await db.db.rawQuery(
        'SELECT seq FROM messages '
        "WHERE session_id = ? AND COALESCE(kind, 'chat') = 'chat' AND role != 'system' "
        'ORDER BY seq DESC LIMIT 1 OFFSET ?',
        [sessionId, displayCount - 1],
      ),
    );
  }

  /// 单次往返的窗口读取:`sessionWindowFloor` + `bySessionSince` 的合并形态
  /// —— 显示/组装双口径边界以内联标量子查询计算,消息行与窗口下界一次取回。
  /// 进入会话的加载链路里每一次 DB 往返都对总延迟有贡献,也影响测试环境
  /// (FakeAsync)下事件循环的推进预算,能合并则合并。
  /// 返回 [SessionMessageWindow.floor] 为 null 表示无需窗口化(全量在窗)。
  Future<SessionMessageWindow> sessionWindow({
    required int sessionId,
    required int displayCount,
  }) async {
    // 边界是标量子查询(0 或 1 行):OFFSET 越界返回空集,COALESCE(-1) 兜底
    // "装得下 => 全量在窗"。定位依赖 `(session_id, seq)` 索引。
    const boundarySubquery = '''
        SELECT seq FROM messages
        WHERE session_id = ? AND COALESCE(kind, 'chat') = 'chat' AND role != 'system'
        ORDER BY seq DESC LIMIT 1 OFFSET ?''';
    final rows = await db.db.rawQuery(
      'SELECT $_messageProjection, COALESCE(($boundarySubquery), -1) AS window_floor '
      "FROM messages WHERE session_id = ? AND (role = 'system' OR seq >= COALESCE(($boundarySubquery), -1)) "
      'ORDER BY seq',
      [
        sessionId, displayCount - 1, // 投影列的边界
        sessionId, // 行范围
        sessionId, displayCount - 1, // 范围内的边界
      ],
    );
    if (rows.isEmpty) {
      return const SessionMessageWindow(rows: [], floor: null);
    }
    final floorValue = rows.first['window_floor'] as int?;
    final floor = floorValue == null || floorValue < 0 ? null : floorValue;
    return SessionMessageWindow(
      rows: rows.map(Message.fromMap).toList(),
      floor: floor,
    );
  }

  /// 组装窗口:全部 system 行 + **全部未折叠活跃行**,按 seq 升序。
  ///
  /// 与 [sessionWindow] 的分工是刻意的:后者服务 UI 显示(尾部若干行 +
  /// 分页游标),本方法服务**上下文组装** —— 组装不按条数裁剪,必须看到
  /// 全部未折叠活跃行,少一行就是上下文缺内容。
  /// 用独立的活跃下界(最早未折叠活跃行的 seq)而非显示游标:分页会下移显示
  /// 游标,共用它会让"用户翻阅历史"改变发给 LLM 的上下文。
  /// 活跃行规模由压缩按 token 占用率控制(压缩把旧行标 `is_compacted=1`),
  /// 因此行数有界;未压缩过的会话读全量,长会话此时本就会被占用率驱动的
  /// 压缩接管。
  Future<List<Message>> activeWindow(int sessionId) async {
    final floor = Sqflite.firstIntValue(
      await db.db.rawQuery(
        'SELECT MIN(seq) FROM messages '
        "WHERE session_id = ? AND role != 'system' AND COALESCE(is_compacted, 0) = 0 "
        "AND content != ''",
        [sessionId],
      ),
    );
    return bySessionSince(sessionId, sinceSeq: floor);
  }

  /// 窗口读取:全部 system 行(任意 seq —— 每次压缩落一条摘要行,组装把
  /// 它们全部拼进上下文,漏一条即上下文回归)+ `seq >= [sinceSeq]` 的所有行
  /// (任何 kind —— 附件行必须与其所属用户消息同窗,组装期位置校正依赖完整
  /// 相邻关系),按 seq 升序。[sinceSeq] 为 null 时等价全量(直接走 [bySession]
  /// 的缓存路径)。
  ///
  /// 不进静态缓存:窗口形状由调用方的分页游标决定,与全量缓存口径不同;
  /// 窗口读取本身就轻(数百行),缓存收益为负。
  Future<List<Message>> bySessionSince(int sessionId, {int? sinceSeq}) async {
    if (sinceSeq == null) return bySession(sessionId);
    final rows = await db.db.rawQuery(
      'SELECT $_messageProjection '
      "FROM messages WHERE session_id = ? AND (seq >= ? OR role = 'system') "
      'ORDER BY seq',
      [sessionId, sinceSeq],
    );
    return rows.map(Message.fromMap).toList();
  }

  /// 向上分页:取 `seq < [beforeSeq]` 的**显示口径**行(同 sessionWindowFloor
  /// 的显示口径)最后 [limit] 条,按 seq 升序返回。已折叠的历史行也是聊天流的
  /// 一部分(用户想看历史就必须看到),照常入页;附件行不显示、系统行自首次
  /// 窗口加载起就全部在内存,均不入页。只服务浏览历史:分页行严格老于首屏
  /// 窗口边界,永远落在组装尾部(maxHistoryMessages 条)之外,不影响发给
  /// LLM 的上下文。
  Future<List<Message>> bySessionPageBefore(
    int sessionId, {
    required int beforeSeq,
    required int limit,
  }) async {
    final rows = await db.db.rawQuery(
      'SELECT $_messageProjection '
      "FROM messages WHERE session_id = ? AND seq < ? "
      "AND COALESCE(kind, 'chat') = 'chat' AND role != 'system' "
      'ORDER BY seq DESC LIMIT ?',
      [sessionId, beforeSeq, limit],
    );
    final messages = rows.map(Message.fromMap).toList();
    return messages.reversed.toList();
  }

  /// 向下分页:取 `seq > [afterSeq]` 且 `seq < [beforeSeq]`(可选上限)的
  /// 聊天行,按 seq 升序返回。供后台 agent 在定位到某条消息后读取其后文
  /// (readHistory 的邻近窗口),与向上分页共用同一过滤口径。
  Future<List<Message>> bySessionPageAfter(
    int sessionId, {
    required int afterSeq,
    int? beforeSeq,
    required int limit,
  }) async {
    final rows = await db.db.rawQuery(
      'SELECT $_messageProjection '
      'FROM messages WHERE session_id = ? AND seq > ? AND seq < ? '
      "AND COALESCE(kind, 'chat') = 'chat' AND role != 'system' "
      'ORDER BY seq ASC LIMIT ?',
      [sessionId, afterSeq, beforeSeq ?? _seqCeiling, limit],
    );
    return rows.map(Message.fromMap).toList();
  }

  /// 无上限分页的哨兵值(sqflite 绑定 int,不用 double.infinity)。
  static const int _seqCeiling = 1 << 62;

  /// 删除单条消息(UI 长按删除),并在同一事务释放其图片资产引用。
  Future<void> delete(int id) async {
    int? sessionId;
    await db.db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['session_id', 'image_hash'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      sessionId = row['session_id'] as int;
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      final hash = _localHash(row['image_hash'] as String?);
      if (hash != null) await db.images.release(txn, hash);
    });
    final deletedSession = sessionId;
    if (deletedSession != null) _invalidate(db.db, deletedSession);
  }

  /// 删除单条消息并返回只含哈希的可恢复快照(聊天页"撤销删除"用)。
  ///
  /// 删除会在事务内释放业务引用;正常撤销窗口短于零引用资产的回收宽限期,
  /// 恢复时可按快照哈希重新获取引用。行不存在时返回 null。
  Future<DeletedMessageSnapshot?> deleteWithSnapshot(int id) async {
    final snapshot = await db.db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: const [
          'id',
          'session_id',
          'role',
          'content',
          'seq',
          'is_compacted',
          'compact_of',
          'image_hash',
          'image_url',
          'image_prompt',
          'kind',
          'ref_id',
        ],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      final hash = _localHash(row['image_hash'] as String?);
      if (hash != null) await db.images.release(txn, hash);
      return DeletedMessageSnapshot(
        sessionId: row['session_id'] as int,
        role: row['role'] as String? ?? 'user',
        content: row['content'] as String? ?? '',
        seq: row['seq'] as int,
        isCompacted: (row['is_compacted'] as int? ?? 0) != 0,
        compactOf: row['compact_of'] as int?,
        imageHash: hash,
        imageUrl: row['image_url'] as String?,
        imagePrompt: row['image_prompt'] as String?,
        kind: row['kind'] as String? ?? 'chat',
        refId: row['ref_id'] as String?,
      );
    });
    if (snapshot != null) _invalidate(db.db, snapshot.sessionId);
    return snapshot;
  }

  /// 批量删除当前会话的多条消息,并返回同一事务生成的恢复快照。
  ///
  /// 不属于 [sessionId] 或已不存在的 id 忽略;每条的图片引用随删除释放。
  /// 查询按 200 个 id 分块,避免 SQLite 变量上限;结果按 seq 升序返回,便于
  /// 撤销时按原顺序恢复。快照只含哈希,不复制图片字节。
  Future<List<DeletedMessageSnapshot>> deleteManyWithSnapshots(
    int sessionId,
    Iterable<int> ids,
  ) async {
    final unique = ids.toSet().toList(growable: false);
    if (unique.isEmpty) return const [];
    final snapshots = <DeletedMessageSnapshot>[];
    await db.db.transaction((txn) async {
      for (var offset = 0; offset < unique.length; offset += 200) {
        final end = offset + 200 < unique.length ? offset + 200 : unique.length;
        final chunk = unique.sublist(offset, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await txn.query(
          'messages',
          columns: const [
            'id',
            'session_id',
            'role',
            'content',
            'seq',
            'is_compacted',
            'compact_of',
            'image_hash',
            'image_url',
            'image_prompt',
            'kind',
            'ref_id',
          ],
          where: 'session_id = ? AND id IN ($placeholders)',
          whereArgs: [sessionId, ...chunk],
          orderBy: 'seq ASC',
        );
        for (final row in rows) {
          await txn.delete(
            'messages',
            where: 'id = ?',
            whereArgs: [row['id'] as int],
          );
          final hash = _localHash(row['image_hash'] as String?);
          if (hash != null) await db.images.release(txn, hash);
          snapshots.add(_snapshotFromRow(row));
        }
      }
    });
    if (snapshots.isEmpty) return const [];
    snapshots.sort((a, b) => a.seq.compareTo(b.seq));
    _invalidate(db.db, sessionId);
    return snapshots;
  }

  /// 恢复 [deleteManyWithSnapshots] 的结果,单事务内重建全部行与图片引用。
  ///
  /// 按 seq 升序恢复:原位置空着就保持,被撤销窗口内新落库的行占用时排到
  /// 末尾,批内不会再撞同一 seq。会话已切换时调用方应拒绝(控制器已校验)。
  Future<void> restoreManyDeleted(
    List<DeletedMessageSnapshot> snapshots,
  ) async {
    if (snapshots.isEmpty) return;
    final sessionId = snapshots.first.sessionId;
    for (final snapshot in snapshots) {
      if (snapshot.sessionId != sessionId) {
        throw ArgumentError('批量恢复的消息必须属于同一会话');
      }
    }
    final ordered = List<DeletedMessageSnapshot>.of(snapshots)
      ..sort((a, b) => a.seq.compareTo(b.seq));
    await db.db.transaction((txn) async {
      var nextSeq =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COALESCE(MAX(seq), -1) + 1 FROM messages '
              'WHERE session_id = ?',
              [sessionId],
            ),
          ) ??
          0;
      for (final snapshot in ordered) {
        final occupied = Sqflite.firstIntValue(
          await txn.rawQuery(
            'SELECT COUNT(*) FROM messages WHERE session_id = ? AND seq = ?',
            [sessionId, snapshot.seq],
          ),
        );
        var seq = snapshot.seq;
        if ((occupied ?? 0) > 0) {
          seq = nextSeq;
          nextSeq++;
        } else if (snapshot.seq >= nextSeq) {
          nextSeq = snapshot.seq + 1;
        }
        final hash = _localHash(snapshot.imageHash);
        if (hash != null) await db.images.acquire(txn, hash);
        await txn.insert('messages', {
          'session_id': sessionId,
          'role': snapshot.role,
          'content': snapshot.content,
          'seq': seq,
          'is_compacted': snapshot.isCompacted ? 1 : 0,
          'compact_of': snapshot.compactOf,
          'image_hash': hash,
          'image_url': snapshot.imageUrl,
          'image_prompt': snapshot.imagePrompt,
          'kind': snapshot.kind,
          'ref_id': snapshot.refId,
        });
      }
    });
    _invalidate(db.db, sessionId);
  }

  static DeletedMessageSnapshot _snapshotFromRow(Map<String, Object?> row) =>
      DeletedMessageSnapshot(
        sessionId: row['session_id'] as int,
        role: row['role'] as String? ?? 'user',
        content: row['content'] as String? ?? '',
        seq: row['seq'] as int,
        isCompacted: (row['is_compacted'] as int? ?? 0) != 0,
        compactOf: row['compact_of'] as int?,
        imageHash: _localHash(row['image_hash'] as String?),
        imageUrl: row['image_url'] as String?,
        imagePrompt: row['image_prompt'] as String?,
        kind: row['kind'] as String? ?? 'chat',
        refId: row['ref_id'] as String?,
      );

  /// 恢复 [deleteWithSnapshot] 删除的消息,并在同一事务重新获取图片引用。
  ///
  /// 原 seq 已被撤销窗口内新落库的行占用时改排到末尾,避免重复 seq。
  Future<void> restoreDeleted(DeletedMessageSnapshot snapshot) async {
    await db.db.transaction((txn) async {
      final occupied = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT COUNT(*) FROM messages WHERE session_id = ? AND seq = ?',
          [snapshot.sessionId, snapshot.seq],
        ),
      );
      var seq = snapshot.seq;
      if ((occupied ?? 0) > 0) {
        seq = Sqflite.firstIntValue(
          await txn.rawQuery(
            'SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE session_id = ?',
            [snapshot.sessionId],
          ),
        )!;
      }
      final hash = _localHash(snapshot.imageHash);
      if (hash != null) await db.images.acquire(txn, hash);
      await txn.insert('messages', {
        'session_id': snapshot.sessionId,
        'role': snapshot.role,
        'content': snapshot.content,
        'seq': seq,
        'is_compacted': snapshot.isCompacted ? 1 : 0,
        'compact_of': snapshot.compactOf,
        'image_hash': hash,
        'image_url': snapshot.imageUrl,
        'image_prompt': snapshot.imagePrompt,
        'kind': snapshot.kind,
        'ref_id': snapshot.refId,
      });
    });
    _invalidate(db.db, snapshot.sessionId);
  }

  /// 清空某条消息的图片:哈希、URL 与描述一并置空并释放旧引用,正文保留。
  Future<void> clearImage(int id) async {
    int? sessionId;
    var changed = 0;
    await db.db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['session_id', 'image_hash'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      sessionId = row['session_id'] as int;
      changed = await txn.update(
        'messages',
        {'image_hash': null, 'image_url': null, 'image_prompt': null},
        where: 'id = ?',
        whereArgs: [id],
      );
      if (changed > 0) {
        final hash = _localHash(row['image_hash'] as String?);
        if (hash != null) await db.images.release(txn, hash);
      }
    });
    final updatedSession = sessionId;
    if (changed > 0 && updatedSession != null) {
      _invalidate(db.db, updatedSession);
    }
  }

  /// 会话文本搜索(聊天页搜索入口 + 后台 agent 取证)。
  ///
  /// 口径与聊天流一致:`role != 'system'` 且 `kind = 'chat'` —— 压缩摘要与
  /// 附件旁路行不参与(它们本就不渲染);已折叠的原消息仍会命中(聊天流照常
  /// 显示)。只投影文本列,不携带图片哈希以外的资产数据,单次 LIMIT 封顶,避免长会话
  /// 把搜索结果整批搬进内存。[beforeSeq] 供后台 agent 把结果钳制在本轮可读
  /// 窗口内。SQLite LIKE 默认对 ASCII 大小写不敏感,中文等
  /// 无大小写语义。`%`/`_`/`\` 按字面量转义,用户输入不被当作通配符。
  Future<List<MessageSearchHit>> searchInSession(
    int sessionId,
    String query, {
    int limit = 200,
    int? beforeSeq,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final rows = await db.db.rawQuery(
      'SELECT id, role, content, seq FROM messages '
      "WHERE session_id = ? AND role != 'system' AND COALESCE(kind, 'chat') = 'chat' "
      "AND content != '' AND content LIKE ? ESCAPE '\\' AND seq < ? "
      'ORDER BY seq DESC LIMIT ?',
      [sessionId, '%${_escapeLike(term)}%', beforeSeq ?? _seqCeiling, limit],
    );
    return [
      for (final r in rows)
        MessageSearchHit(
          messageId: r['id'] as int,
          role: r['role'] as String? ?? '',
          content: r['content'] as String? ?? '',
          seq: r['seq'] as int,
        ),
    ];
  }

  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// 桌面端消息导航的全量 user 消息索引:只取定位坐标与单行摘要,不受
  /// 显示窗口裁剪(窗口只装尾部若干行,导航卡却要覆盖整段历史)。
  ///
  /// 摘要按字符截断到 160:卡片是单行省略展示,更长正文对 UI 无用,却会让
  /// 长会话的索引查询把整份转录搬进内存。空正文(图片消息)由 UI 兜底文案。
  Future<List<UserMessageRef>> userMessagesForNavigation(int sessionId) async {
    final rows = await db.db.rawQuery(
      'SELECT id, seq, substr(content, 1, 160) AS preview FROM messages '
      "WHERE session_id = ? AND COALESCE(kind, 'chat') = 'chat' "
      "AND role = 'user' ORDER BY seq",
      [sessionId],
    );
    return [
      for (final row in rows)
        UserMessageRef(
          messageId: row['id'] as int,
          seq: row['seq'] as int,
          preview: singleLinePreview(row['preview'] as String? ?? ''),
        ),
    ];
  }

  /// 按 id 读取定位目标的最小坐标(聊天页搜索跳转用)。不取正文/图片,
  /// 一条主键查询即可判断「消息还在不在、属于哪个会话、是否聊天流可见行」。
  Future<MessageLocation?> locate(int messageId) async {
    final rows = await db.db.query(
      'messages',
      columns: ['id', 'session_id', 'seq', 'role', 'kind'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final role = row['role'] as String? ?? '';
    final kind = row['kind'] as String? ?? 'chat';
    return MessageLocation(
      messageId: row['id'] as int,
      sessionId: row['session_id'] as int,
      seq: row['seq'] as int,
      visible: role != 'system' && kind == 'chat',
    );
  }

  /// 用远程 URL 下载到的字节修复一条消息的缺失本地资产。
  ///
  /// 只有内容哈希与消息引用的 hash 完全一致才修复,远程内容已变化时绝不把
  /// 业务行改指向另一张图。元数据缺失或计数意外为零时补一次引用;正常引用
  /// 不动计数。返回是否完成修复。
  Future<bool> repairImageAsset(int id, Uint8List bytes) async {
    final ref = await db.images.putBytes(bytes, compress: false);
    int? sessionId;
    final repaired = await db.db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['session_id', 'image_hash'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final expected = _localHash(rows.first['image_hash'] as String?);
      if (expected == null || expected != ref.hash) return false;
      final assets = await txn.query(
        'image_assets',
        columns: ['ref_count'],
        where: 'hash = ?',
        whereArgs: [ref.hash],
        limit: 1,
      );
      if (assets.isNotEmpty && (assets.first['ref_count'] as int? ?? 0) == 0) {
        await db.images.acquire(txn, ref.hash);
      }
      sessionId = rows.first['session_id'] as int;
      return true;
    });
    if (repaired && sessionId != null) _invalidate(db.db, sessionId!);
    return repaired;
  }

  /// 把远程 URL 取到的字节资产化,让原本只有 URL 的消息改走本地资产。
  ///
  /// 只在消息当前没有本地哈希、且 `image_url` 仍是 [url] 时写回;保留 URL
  /// 作为本地资产缺失时的回退。已有哈希的消息一律不动 —— 远程内容可能已
  /// 变化,不能把消息改指向另一张图。返回消息是否已指向该本地资产;坏图或
  /// 超限字节返回 false,不影响调用方的 URL 回退渲染。
  Future<bool> adoptRemoteImage(int id, String url, Uint8List bytes) async {
    final before = await db.db.query(
      'messages',
      columns: ['image_hash', 'image_url'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (before.isEmpty) return false;
    if (_localHash(before.first['image_hash'] as String?) != null) return false;
    if (before.first['image_url'] != url) return false;

    final ImageRef ref;
    try {
      // URL 回退会再次拿到**原图**:必须按原字节寻址,压缩后哈希永远对不上
      // 修复路径(归档导入/repair 都绕过压缩)。
      ref = await db.images.putBytes(bytes, compress: false);
    } on FormatException {
      return false;
    }
    int? sessionId;
    final adopted = await db.db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['session_id', 'image_hash', 'image_url'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final row = rows.first;
      if (row['image_url'] != url) return false;
      final existing = _localHash(row['image_hash'] as String?);
      sessionId = row['session_id'] as int;
      if (existing != null) {
        if (existing != ref.hash) return false;
        // 内容已经是期望的那张:并发回填可能先一步写完,只补缺失的计数,
        // 不重复 acquire。
        final assets = await txn.query(
          'image_assets',
          columns: ['ref_count'],
          where: 'hash = ?',
          whereArgs: [ref.hash],
          limit: 1,
        );
        if (assets.isNotEmpty &&
            (assets.first['ref_count'] as int? ?? 0) == 0) {
          await db.images.acquire(txn, ref.hash);
        }
        return true;
      }
      final changed = await txn.update(
        'messages',
        {'image_hash': ref.hash},
        where: 'id = ? AND image_hash IS NULL AND image_url = ?',
        whereArgs: [id, url],
      );
      if (changed == 0) return false;
      await db.images.acquire(txn, ref.hash);
      return true;
    });
    if (adopted && sessionId != null) _invalidate(db.db, sessionId!);
    return adopted;
  }

  /// 单条消息的生图原始描述(图片重新生成用;无描述/无此消息返回 null)。
  Future<String?> imagePromptFor(int id) async {
    final rows = await db.db.query(
      'messages',
      columns: ['image_prompt'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['image_prompt'] as String?;
  }

  /// 原地替换某条消息的图片(重新生成)。条件检查、增加新引用、更新业务行、
  /// 释放旧引用在同一事务完成;条件不匹配时不获取新引用,失败时整体回滚。
  ///
  /// [newImagePrompt] 提供时一并改写描述,条件判断始终使用替换前的
  /// [expectedPrompt]。返回是否实际更新。
  Future<bool> replaceImage(
    int id, {
    required String? imageHash,
    required String? imageUrl,
    required String expectedPrompt,
    String? newImagePrompt,
  }) async {
    final newHash = _localHash(imageHash);
    int? sessionId;
    final replaced = await db.db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['session_id', 'image_hash', 'image_url', 'image_prompt'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final row = rows.first;
      final oldHash = _localHash(row['image_hash'] as String?);
      if (row['image_prompt'] != expectedPrompt ||
          (oldHash == null && row['image_url'] == null)) {
        return false;
      }
      sessionId = row['session_id'] as int;
      if (newHash != null) await db.images.acquire(txn, newHash);
      final changed = await txn.update(
        'messages',
        {
          'image_hash': newHash,
          'image_url': imageUrl,
          if (newImagePrompt != null) 'image_prompt': newImagePrompt,
        },
        where:
            'id = ? AND image_prompt = ? AND (image_hash IS NOT NULL OR image_url IS NOT NULL)',
        whereArgs: [id, expectedPrompt],
      );
      if (changed == 0) {
        if (newHash != null) await db.images.release(txn, newHash);
        return false;
      }
      if (oldHash != null) await db.images.release(txn, oldHash);
      return true;
    });
    final updatedSession = sessionId;
    if (replaced && updatedSession != null) {
      _invalidate(db.db, updatedSession);
    }
    return replaced;
  }

  /// 覆盖某条消息的内容(UI 编辑消息)。保留 role/seq/图片,只改写文本。
  Future<void> updateContent(int id, String content) async {
    final rows = await db.db.query(
      'messages',
      columns: ['session_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    await db.db.update(
      'messages',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
    // 提交后再失效:提前失效会给并发读回填旧快照的机会(提交后无人再失效)。
    if (rows.isNotEmpty) _invalidate(db.db, rows.first['session_id'] as int);
  }

  /// 删除某条消息及其之后的所有消息(UI 重新生成时的"剪断尾巴")。
  /// 返回被删除的条数;每行的图片引用都在同一事务释放。
  Future<int> deleteFrom(int id) async {
    int? sessionId;
    final removed = await db.db.transaction((txn) async {
      final target = await txn.query(
        'messages',
        columns: ['session_id', 'seq'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (target.isEmpty) return 0;
      final targetSession = target.first['session_id'] as int;
      sessionId = targetSession;
      final seq = target.first['seq'] as int;
      final rows = await txn.query(
        'messages',
        columns: ['image_hash'],
        where: 'session_id = ? AND seq >= ? AND image_hash IS NOT NULL',
        whereArgs: [targetSession, seq],
      );
      // 摘要行也满足 seq >= 条件,但它是被折叠原文的唯一出口:连它一起删会
      // 让 is_compacted=1 的历史永久退出上下文(后续压缩只看未折叠行)。
      // 删除前收集摘要 id,删除后把存活且指向它们的折叠行恢复为未折叠 ——
      // 被删摘要覆盖的原文重新进入活跃窗口,可被下一次压缩重新摘要。
      final removedSummaries = await txn.query(
        'messages',
        columns: ['id'],
        where: "session_id = ? AND seq >= ? AND role = 'system'",
        whereArgs: [targetSession, seq],
      );
      final count = await txn.delete(
        'messages',
        where: 'session_id = ? AND seq >= ?',
        whereArgs: [targetSession, seq],
      );
      if (removedSummaries.isNotEmpty) {
        final ids = [for (final row in removedSummaries) row['id'] as int];
        final placeholders = List.filled(ids.length, '?').join(',');
        await txn.update(
          'messages',
          {'is_compacted': 0, 'compact_of': null},
          where: 'compact_of IN ($placeholders)',
          whereArgs: ids,
        );
      }
      for (final row in rows) {
        final hash = _localHash(row['image_hash'] as String?);
        if (hash != null) await db.images.release(txn, hash);
      }
      return count;
    });
    final deletedSession = sessionId;
    if (deletedSession != null) _invalidate(db.db, deletedSession);
    return removed;
  }

  /// 清空某会话的全部消息(含压缩摘要与原文),并释放全部图片引用。
  Future<void> clearSession(int sessionId) async {
    await db.db.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        columns: ['image_hash'],
        where: 'session_id = ? AND image_hash IS NOT NULL',
        whereArgs: [sessionId],
      );
      await txn.delete(
        'messages',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      for (final row in rows) {
        final hash = _localHash(row['image_hash'] as String?);
        if (hash != null) await db.images.release(txn, hash);
      }
    });
    _invalidate(db.db, sessionId);
  }

  /// 未被压缩折叠的附件行(attachments 去重记账用):返回按 seq 升序的
  /// `kind='attachment'` 行。调用方以"窗口内是否已出现同 ref_id"判定该来源
  /// 是否需要重复注入 —— 被压缩挤出的行(is_compacted=1)不在其中,对应
  /// 条目退出上下文后允许重新触发注入。
  Future<List<Message>> activeAttachments(int sessionId) async {
    final rows = await db.db.query(
      'messages',
      columns: [
        'id',
        'session_id',
        'role',
        'content',
        'seq',
        'is_compacted',
        'compact_of',
        'kind',
        'ref_id',
      ],
      where: "session_id = ? AND kind = 'attachment' AND is_compacted = 0",
      whereArgs: [sessionId],
      orderBy: 'seq',
    );
    return rows.map(Message.fromMap).toList();
  }

  /// 追加一条 system 行(压缩摘要等),返回新行 id。
  ///
  /// seq 读-写与 [append] 同款事务模板,防止并发插入拿到相同 seq。
  Future<int> insertSystem({
    required int sessionId,
    required String content,
  }) async {
    final id = await db.db.transaction((txn) async {
      final next = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE session_id = ?',
          [sessionId],
        ),
      )!;
      return txn.insert('messages', {
        'session_id': sessionId,
        'role': 'system',
        'content': content,
        'seq': next,
      });
    });
    _invalidate(db.db, sessionId);
    return id;
  }

  /// 把 [ids] 标记为已压缩折叠并指向摘要行 [compactOf]。
  ///
  /// 先按首条 id 反查会话以失效缓存(级联删除会绕过本仓库,见 [_cache]);
  /// 批量 update 放在普通 batch 中,不构成事务边界 —— 调用方需要原子性时
  /// 用 [insertSystemAndCompact]。
  Future<void> markCompacted(List<int> ids, {required int compactOf}) async {
    if (ids.isEmpty) return;
    // 需要知道受影响会话以失效其缓存;从任意一个 id 反查 session_id。
    final sample = await db.db.query(
      'messages',
      columns: ['session_id'],
      where: 'id = ?',
      whereArgs: [ids.first],
      limit: 1,
    );
    final batch = db.db.batch();
    for (final id in ids) {
      batch.update(
        'messages',
        {'is_compacted': 1, 'compact_of': compactOf},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
    if (sample.isNotEmpty) {
      _invalidate(db.db, sample.first['session_id'] as int);
    }
  }

  /// 会话导入的分块落库(流式归档用):列映射与 [importMessages] 一致,
  /// seq 从 [seqStart] 起连续。每块一个事务,消息哈希与资产引用同事务写入。
  Future<List<int>> insertMessageChunk({
    required int sessionId,
    required List<Message> messages,
    required int seqStart,
  }) async {
    if (messages.isEmpty) return const [];
    final ids = await db.db.transaction((txn) async {
      final batch = txn.batch();
      for (final (i, m) in messages.indexed) {
        final hash = _localHash(m.imageHash);
        if (hash != null) await db.images.acquire(txn, hash);
        batch.insert('messages', {
          'session_id': sessionId,
          'role': m.role,
          'content': m.content,
          'seq': seqStart + i,
          'is_compacted': m.isCompacted ? 1 : 0,
          'kind': m.kind.wire,
          if (m.refId != null) 'ref_id': m.refId,
          if (m.imageUrl != null) 'image_url': m.imageUrl,
          if (hash != null) 'image_hash': hash,
          if (m.imagePrompt != null) 'image_prompt': m.imagePrompt,
        });
      }
      final ids = await batch.commit(noResult: false);
      return [
        for (final id in ids)
          if (id is int) id,
      ];
    });
    _invalidate(db.db, sessionId);
    return ids;
  }

  /// 流式导入结束后统一换算 `compact_of`:归档里是**消息数组内索引**,
  /// 这里用 [rowIds](数组索引 → 新行 id)换回目标库行 id;越界索引丢弃
  /// (与 [importMessages] 语义一致)。[links] 为 (行索引, compact 索引)。
  Future<void> linkCompactOf({
    required int sessionId,
    required List<int> rowIds,
    required List<(int rowIndex, int compactIndex)> links,
  }) async {
    if (links.isEmpty) return;
    final batch = db.db.batch();
    for (final (rowIndex, compactIndex) in links) {
      if (rowIndex < 0 || rowIndex >= rowIds.length) continue;
      if (compactIndex < 0 || compactIndex >= rowIds.length) continue;
      final target = rowIds[compactIndex];
      final row = rowIds[rowIndex];
      if (target <= 0 || row <= 0) continue;
      batch.update(
        'messages',
        {'compact_of': target},
        where: 'id = ?',
        whereArgs: [row],
      );
    }
    await batch.commit(noResult: true);
    _invalidate(db.db, sessionId);
  }

  /// 会话导入:按列表顺序把消息落到全新会话,seq 重排为从 0 开始的连续
  /// 序列;图片哈希与引用计数在同一事务写入。入参 [Message.compactOf] 是
  /// **归档数组内索引**,批量插入后再换算成新行 id;越界索引按无指向处理。
  Future<void> importMessages({
    required int sessionId,
    required List<Message> messages,
  }) async {
    if (messages.isEmpty) return;
    await db.db.transaction((txn) async {
      final batch = txn.batch();
      for (final (i, m) in messages.indexed) {
        final hash = _localHash(m.imageHash);
        if (hash != null) await db.images.acquire(txn, hash);
        batch.insert('messages', {
          'session_id': sessionId,
          'role': m.role,
          'content': m.content,
          'seq': i,
          'is_compacted': m.isCompacted ? 1 : 0,
          'kind': m.kind.wire,
          if (m.refId != null) 'ref_id': m.refId,
          if (m.imageUrl != null) 'image_url': m.imageUrl,
          if (hash != null) 'image_hash': hash,
          if (m.imagePrompt != null) 'image_prompt': m.imagePrompt,
        });
      }
      // commit 返回各 insert 的新行 id(与 batch 顺序一致)。
      final newIds = await batch.commit(noResult: false);
      for (final (i, m) in messages.indexed) {
        final idx = m.compactOf;
        final newId = newIds[i] as int?;
        if (idx == null || newId == null) continue;
        if (idx < 0 || idx >= messages.length) continue;
        await txn.update(
          'messages',
          {'compact_of': newIds[idx]},
          where: 'id = ?',
          whereArgs: [newId],
        );
      }
    });
    _invalidate(db.db, sessionId);
  }

  /// 摘要写入 + 原文标记压缩原子完成(消除原先两写之间的失败窗口:
  /// insertSystem 成功但 markCompacted 失败会留下孤儿摘要)。
  /// 返回摘要行的 id。
  Future<int> insertSystemAndCompact({
    required int sessionId,
    required String content,
    required List<int> compactIds,
  }) async {
    final summaryId = await db.db.transaction((txn) async {
      final next = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE session_id = ?',
          [sessionId],
        ),
      )!;
      final summaryId = await txn.insert('messages', {
        'session_id': sessionId,
        'role': 'system',
        'content': content,
        'seq': next,
      });
      final batch = txn.batch();
      for (final id in compactIds) {
        batch.update(
          'messages',
          {'is_compacted': 1, 'compact_of': summaryId},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
      return summaryId;
    });
    _invalidate(db.db, sessionId);
    return summaryId;
  }
}

/// 消息列表缓存键:(Database, sessionId) 决定取哪个库的哪个会话。
/// 用底层 sqflite `Database` 对象区分不同连接,避免跨库串味。
class _MessageCacheKey {
  final Database db;
  final int sessionId;
  const _MessageCacheKey(this.db, this.sessionId);

  @override
  bool operator ==(Object other) =>
      other is _MessageCacheKey &&
      identical(other.db, db) &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(identityHashCode(db), sessionId);
}

/// 被删除消息的恢复快照(撤销删除用);只保存资产哈希,不保存图片字节。
class DeletedMessageSnapshot {
  final int sessionId;
  final String role;
  final String content;

  /// 删除时的 seq;恢复时若已被占用则改排到末尾。
  final int seq;
  final bool isCompacted;
  final int? compactOf;
  final String? imageHash;
  final String? imageUrl;
  final String? imagePrompt;
  final String kind;
  final String? refId;

  const DeletedMessageSnapshot({
    required this.sessionId,
    required this.role,
    required this.content,
    required this.seq,
    required this.isCompacted,
    required this.compactOf,
    required this.imageHash,
    required this.imageUrl,
    required this.imagePrompt,
    required this.kind,
    required this.refId,
  });
}

/// 把正文压成单行摘要:换行/连续空白折叠为一个空格,避免导航卡片里出现
/// 阶梯状排版。索引查询与窗口内同步合并共用同一口径。
String singleLinePreview(String content) =>
    content.replaceAll(_previewWhitespaceRe, ' ').trim();

final RegExp _previewWhitespaceRe = RegExp(r'\s+');

/// 桌面消息导航的一条 user 消息引用:定位坐标 + 单行摘要。
///
/// 刻意只带 [messageId]/[seq]/[preview] 三个字段 —— 导航卡列出的是**全量
/// 历史**,按完整 [Message] 投影在长会话里会让一次悬停展开前就搬运整份转录。
class UserMessageRef {
  final int messageId;
  final int seq;

  /// 去换行/压缩空白后的正文前缀(最多 160 字符);图片消息可能为空串。
  final String preview;

  const UserMessageRef({
    required this.messageId,
    required this.seq,
    required this.preview,
  });
}

/// 会话文本搜索的一条命中(轻量投影,不含图片字节)。
class MessageSearchHit {
  final int messageId;
  final String role;
  final String content;
  final int seq;
  const MessageSearchHit({
    required this.messageId,
    required this.role,
    required this.content,
    required this.seq,
  });
}

/// 定位目标行的最小坐标;`visible` 为聊天流口径(非 system、kind=chat)。
class MessageLocation {
  final int messageId;
  final int sessionId;
  final int seq;
  final bool visible;
  const MessageLocation({
    required this.messageId,
    required this.sessionId,
    required this.seq,
    required this.visible,
  });
}

/// [MessageRepository.sessionWindow] 的返回:窗口内的消息行(全部 system 行 +
/// 双口径尾部,按 seq 升序)与窗口下界 seq。下界 null = 无需窗口化(全量在窗)。
class SessionMessageWindow {
  final List<Message> rows;

  /// 窗口下界 seq;null 表示会话全部行都在 [rows] 里。
  final int? floor;

  const SessionMessageWindow({required this.rows, required this.floor});
}
