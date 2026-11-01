/// 消息行(`messages` 表)的持久化:追加、窗口读取、图片分块与导入落库。
///
/// 消息只追加、seq 单调;图片字节永不随列表查询整列加载(Android
/// CursorWindow 上限 2MB),一律按 id 分块读取。
library;

import 'dart:collection';

import 'package:sqflite/sqflite.dart';
import '../models/message.dart';
import 'database.dart';

/// 消息仓储:单行追加、显示/组装双口径窗口读取与内存缓存。
///
/// 缓存按 `(Database, sessionId, includeImages)` 跨实例共享,任一实例的写
/// 路径都会精确失效对应会话;窗口读取不进缓存(形状由调用方游标决定)。
class MessageRepository {
  final AppDatabase db;

  /// 内存级读取缓存:按 `(Database, sessionId, includeImages)` 缓存某会话按 seq
  /// 排序的完整消息列表,避免同一轮生成(send → _generateReply → 后台维护)里对
  /// 同一会话重复执行全表查询与行映射。
  ///
  /// **跨实例共享**(static):本项目多处会临时 `MessageRepository(db)` 建实例
  /// (chat_controller 走单例 provider,但导出/compact_service/测试常另建实例)。
  /// 若缓存是实例级,一个实例的写入无法让另一实例的读取失效,会产生陈旧读取
  /// (测试即抓到了这一点)。故缓存以底层 sqflite `Database` 对象为键做 static
  /// 共享 —— 任一实例的写路径都精确失效该 (db,sessionId) 的所有读者。
  ///
  /// 正确性要点:
  /// - `Message` 是不可变对象,返回的列表按不可变只读使用(chat_controller 把
  ///   它存进 state 后从不原地增删改),因此可直接共享同一 List 实例;
  /// - 所有写路径(append/delete/deleteFrom/updateContent/clearSession/insertSystem/
  ///   markCompacted/insertSystemAndCompact)都会失效该 (db,sessionId) 的缓存,
  ///   保证下次读从库重新取、不返回陈旧数据;
  /// - 角色的级联删除(character/session 删除)会绕过本仓库直删 messages 表,
  ///   但被删会话的 sessionId 永不复用(自增主键),遗留的陈旧缓存条目不可达。
  static final LinkedHashMap<_MessageCacheKey, List<Message>> _cache =
      LinkedHashMap<_MessageCacheKey, List<Message>>();

  /// 容量 12:缓存的意义是"同一轮生成/同一次交互里的重复读",活跃会话
  /// 同一时刻不过一两个;再大只会让重度多会话实例常驻几十份全量消息列表。
  /// 逐出按插入序(FIFO),被逐出的会话下次读照常回库重建。
  static const int _cacheCap = 12;

  MessageRepository(this.db);

  static void _invalidate(Database db, int sessionId) {
    _cache.removeWhere((k, _) => k.db == db && k.sessionId == sessionId);
  }

  static List<Message>? _peek(Database db, int sessionId, bool includeImages) =>
      _cache[_MessageCacheKey(db, sessionId, includeImages)];

  static void _store(Database db, int sessionId, bool includeImages, List<Message> messages) {
    if (_cache.length >= _cacheCap) {
      _cache.remove(_cache.keys.first);
    }
    _cache[_MessageCacheKey(db, sessionId, includeImages)] = messages;
  }

  /// 追加一条消息,返回落库后的完整行(id/seq 已定)。
  ///
  /// seq 的读-写在同一事务内完成:单连接下事务串行,消除"读 MAX(seq) 后
  /// 并发插入拿到相同 seq"的非原子窗口。
  ///
  /// 事务成功后把该会话的轻量缓存**替换为追加后的新列表**(替换而非原地
  /// 改动:旧列表实例保持冻结,持有旧快照的 ChatState/组装输入不受影响)——
  /// 发送管线每轮「落库 → bySession 刷新 state」的第二跳由此从整表重读
  /// (append 使缓存失效后必然回库)变成一次缓存命中,每轮成本从
  /// O(会话长度) 降为 O(1),会话越长收益越大。轻量缓存行按 [bySession]
  /// 同口径剥掉 image_base64(置 has_image 标志,字节走惰性单条读取);
  /// 带图缓存条目无法原地补行(图片字节逐条回填),连同失效等下次读库。
  /// 缓存本就不在(首次/被逐出)时维持旧行为:仅失效,等下次读库重建。
  Future<Message> append({
    required int sessionId,
    required String role,
    required String content,
    String? imageBase64,
    String? imageUrl,
    String? imagePrompt,
    MessageKind kind = MessageKind.chat,
    String? refId,
  }) async {
    late final Message appended;
    await db.db.transaction((txn) async {
      final next = Sqflite.firstIntValue(
        await txn.rawQuery('SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE session_id = ?', [sessionId]),
      )!;
      final id = await txn.insert('messages', {
        'session_id': sessionId,
        'role': role,
        'content': content,
        'seq': next,
        'kind': kind.wire,
        if (refId != null) 'ref_id': refId,
        if (imageBase64 != null) 'image_base64': imageBase64,
        if (imageUrl != null) 'image_url': imageUrl,
        if (imagePrompt != null) 'image_prompt': imagePrompt,
      });
      appended = Message(
        id: id,
        sessionId: sessionId,
        role: role,
        content: content,
        seq: next,
        imageBase64: imageBase64,
        imageUrl: imageUrl,
        imagePrompt: imagePrompt,
        hasImage: imageBase64 != null && imageBase64.isNotEmpty,
        kind: kind,
        refId: refId,
      );
    });
    _refreshCacheAfterAppend(db.db, sessionId, appended);
    return appended;
  }

  /// append 成功后的缓存维护(只在事务成功后调用)。轻量条目替换为
  /// 「旧列表 + 追加行」的新实例;带图条目整体失效。
  static void _refreshCacheAfterAppend(Database db, int sessionId, Message appended) {
    final lightKey = _MessageCacheKey(db, sessionId, false);
    final cached = _cache[lightKey];
    if (cached != null) {
      final image = appended.imageBase64;
      // 轻量口径与 bySession 的 SQL 投影逐字段对齐:不携带 base64 字节,
      // has_image = image_base64 非空,image_url 原样保留。
      final row = Message(
        id: appended.id,
        sessionId: appended.sessionId,
        role: appended.role,
        content: appended.content,
        seq: appended.seq,
        isCompacted: appended.isCompacted,
        compactOf: appended.compactOf,
        imageUrl: appended.imageUrl,
        imagePrompt: appended.imagePrompt,
        hasImage: image != null && image.isNotEmpty,
        kind: appended.kind,
        refId: appended.refId,
      );
      _cache[lightKey] = [...cached, row];
    }
    _cache.remove(_MessageCacheKey(db, sessionId, true));
  }

  // 轻量投影:不取 `image_base64`,只带 `has_image` 标志;图片字节由
  // [imageBase64For] 按需单条读取。
  static const String _messageProjection =
      'id, session_id, role, content, seq, is_compacted, compact_of, image_url, image_prompt, '
      "kind, ref_id, image_base64 IS NOT NULL AND image_base64 != '' AS has_image";

  /// 某会话的全部消息,按 seq 升序。
  ///
  /// 默认轻量:每张图片 2~4MB 的 base64,全量读会让聊天每次刷新都搬几十 MB,
  /// 故只回 has_image 标志,渲染层经 [imageBase64For] 按需读取。导出等确需
  /// 完整数据的调用方传 `includeImages: true`,图片同样逐条分块回填、不整列读。
  Future<List<Message>> bySession(int sessionId, {bool includeImages = false}) async {
    final cached = _peek(db.db, sessionId, includeImages);
    if (cached != null) return cached;
    final dbRows = await db.db.rawQuery(
      'SELECT $_messageProjection '
      'FROM messages WHERE session_id = ? ORDER BY seq',
      [sessionId],
    );
    var rows = dbRows.map(Message.fromMap).toList();
    if (includeImages) {
      // 不能整列 bulk SELECT image_base64:Android 的 CursorWindow 上限 2MB,
      // 任一行超限整批查询即抛 Row too big(见 [imageBase64For]),只能逐条回填。
      final full = <Message>[];
      for (final m in rows) {
        final id = m.id;
        full.add(m.hasImage && id != null ? m.copyWith(imageBase64: await imageBase64For(id)) : m);
      }
      rows = full;
    }
    _store(db.db, sessionId, includeImages, rows);
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
    return Sqflite.firstIntValue(await db.db.rawQuery(
      'SELECT seq FROM messages '
      "WHERE session_id = ? AND COALESCE(kind, 'chat') = 'chat' AND role != 'system' "
      'ORDER BY seq DESC LIMIT 1 OFFSET ?',
      [sessionId, displayCount - 1],
    ));
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
    final floor = Sqflite.firstIntValue(await db.db.rawQuery(
      'SELECT MIN(seq) FROM messages '
      "WHERE session_id = ? AND role != 'system' AND COALESCE(is_compacted, 0) = 0 "
      "AND content != ''",
      [sessionId],
    ));
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

  /// base64 分块读取的块大小(字符)。必须远小于 Android CursorWindow 的
  /// 2MB 上限 —— 每块查询只回**一行**,1MB 字符(ASCII base64 一字符一字节)
  /// 给窗口留足余量;相比旧的 512K 少一半往返,重启后逐张图的分块读取更快。
  static const int _imageChunkChars = 1024 * 1024;

  /// 按消息 id 读取单条的 image_base64(轻量查询后渲染层的按需加载入口)。
  ///
  /// Android 的 SQLite 游标窗口(CursorWindow)上限 2MB,单次 SELECT 整列时
  /// 超限的行会整行抛 Row too big(生图常 2~4MB base64;写库不受影响,只有
  /// 读取会炸)。因此先查长度,再用 substr 分块读取、Dart 侧拼接,任何平台的
  /// 单次返回都远低于窗口上限。
  Future<String?> imageBase64For(int id) async {
    final len = await _imageLength(id);
    if (len == null) return null;
    final buffer = StringBuffer();
    for (var start = 1; start <= len; start += _imageChunkChars) {
      final chunk = await db.db.rawQuery(
        'SELECT substr(image_base64, ?, ?) AS piece FROM messages WHERE id = ? LIMIT 1',
        [start, _imageChunkChars, id],
      );
      buffer.write(chunk.first['piece'] as String? ?? '');
    }
    return buffer.toString();
  }

  /// 流式读取图片 base64:与 [imageBase64For] 同一分块策略,但逐块 yield,
  /// 供会话归档导出直接写给文件,避免把整张图(乃至整会话)拼进内存。
  Stream<String> imageBase64Chunks(int id, {int chunkChars = _imageChunkChars}) async* {
    final len = await _imageLength(id);
    if (len == null) return;
    for (var start = 1; start <= len; start += chunkChars) {
      final chunk = await db.db.rawQuery(
        'SELECT substr(image_base64, ?, ?) AS piece FROM messages WHERE id = ? LIMIT 1',
        [start, chunkChars, id],
      );
      final piece = chunk.first['piece'] as String?;
      if (piece != null && piece.isNotEmpty) yield piece;
    }
  }

  Future<int?> _imageLength(int id) async {
    final lenRows = await db.db.rawQuery(
      'SELECT length(image_base64) AS len FROM messages WHERE id = ? LIMIT 1',
      [id],
    );
    if (lenRows.isEmpty) return null;
    return lenRows.first['len'] as int?;
  }

  /// 删除单条消息(UI 长按删除)。seq 允许留洞,组装管线只按顺序读。
  Future<void> delete(int id) async {
    final rows = await db.db.query('messages', columns: ['session_id'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty) _invalidate(db.db, rows.first['session_id'] as int);
    await db.db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空某条消息的图片(全屏查看器的"删除图片"):base64、URL 与描述一并置空,
  /// 正文保留(等价于"只删图不删话")。
  Future<void> clearImage(int id) async {
    final rows = await db.db.query('messages', columns: ['session_id'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty) _invalidate(db.db, rows.first['session_id'] as int);
    await db.db.update(
      'messages',
      {'image_base64': null, 'image_url': null, 'image_prompt': null},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 会话文本搜索(聊天页搜索入口)。
  ///
  /// 口径与聊天流一致:`role != 'system'` 且 `kind = 'chat'` —— 压缩摘要与
  /// 附件旁路行不参与(它们本就不渲染);已折叠的原消息仍会命中(聊天流照常
  /// 显示)。只投影文本列,绝不带 `image_base64`,单次 LIMIT 封顶,避免长会话
  /// 把搜索结果整批搬进内存。SQLite LIKE 默认对 ASCII 大小写不敏感,中文等
  /// 无大小写语义。`%`/`_`/`\` 按字面量转义,用户输入不被当作通配符。
  Future<List<MessageSearchHit>> searchInSession(
    int sessionId,
    String query, {
    int limit = 200,
  }) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final rows = await db.db.rawQuery(
      'SELECT id, role, content, seq FROM messages '
      "WHERE session_id = ? AND role != 'system' AND COALESCE(kind, 'chat') = 'chat' "
      "AND content != '' AND content LIKE ? ESCAPE '\\' "
      'ORDER BY seq DESC LIMIT ?',
      [sessionId, '%${_escapeLike(term)}%', limit],
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

  /// 原地替换某条消息的图片(重新生成)。条件更新:id 与原始描述都未变、且该行
  /// 仍有图片时才写入 —— 期间的删图/删消息/导入改写不会复活旧图。新 URL 原样
  /// 写入(下载成功时同时保留为回退);返回是否实际更新。
  ///
  /// [newImagePrompt] 提供时一并改写该行的生图描述(后台重跑换了场景描述仍原地
  /// 换图);条件判断用的始终是替换前的 [expectedPrompt]。
  Future<bool> replaceImage(
    int id, {
    required String? imageBase64,
    required String? imageUrl,
    required String expectedPrompt,
    String? newImagePrompt,
  }) async {
    final rows = await db.db.query('messages', columns: ['session_id'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return false;
    final changed = await db.db.update(
      'messages',
      {
        'image_base64': imageBase64,
        'image_url': imageUrl,
        if (newImagePrompt != null) 'image_prompt': newImagePrompt,
      },
      where: 'id = ? AND image_prompt = ? AND (image_base64 IS NOT NULL OR image_url IS NOT NULL)',
      whereArgs: [id, expectedPrompt],
    );
    if (changed > 0) _invalidate(db.db, rows.first['session_id'] as int);
    return changed > 0;
  }

  /// 覆盖某条消息的内容(UI 编辑消息)。保留 role/seq/图片,只改写文本。
  Future<void> updateContent(int id, String content) async {
    final rows = await db.db.query('messages', columns: ['session_id'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isNotEmpty) _invalidate(db.db, rows.first['session_id'] as int);
    await db.db.update('messages', {'content': content}, where: 'id = ?', whereArgs: [id]);
  }

  /// 删除某条消息及其之后的所有消息(UI 重新生成时的"剪断尾巴")。
  /// 返回被删除的条数。
  Future<int> deleteFrom(int id) async {
    // 只取需要的两列:整行 SELECT 会连 image_base64 一起搬进 CursorWindow,
    // 对图片消息"重新生成"时在 Android 会抛 Row too big(2MB 上限)。
    final target = await db.db.query(
      'messages',
      columns: ['session_id', 'seq'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (target.isEmpty) return 0;
    final sessionId = target.first['session_id'] as int;
    final seq = target.first['seq'] as int;
    _invalidate(db.db, sessionId);
    return db.db.delete('messages', where: 'session_id = ? AND seq >= ?', whereArgs: [sessionId, seq]);
  }

  /// 清空某会话的全部消息(含压缩摘要与原文,`/clear` 命令用)。seq 重新从 0 开始。
  Future<void> clearSession(int sessionId) async {
    _invalidate(db.db, sessionId);
    await db.db.delete('messages', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  /// 未被压缩折叠的附件行(attachments 去重记账用):返回按 seq 升序的
  /// `kind='attachment'` 行。调用方以"窗口内是否已出现同 ref_id"判定该来源
  /// 是否需要重复注入 —— 被压缩挤出的行(is_compacted=1)不在其中,对应
  /// 条目退出上下文后允许重新触发注入。
  Future<List<Message>> activeAttachments(int sessionId) async {
    final rows = await db.db.query(
      'messages',
      columns: ['id', 'session_id', 'role', 'content', 'seq', 'is_compacted', 'compact_of', 'kind', 'ref_id'],
      where: "session_id = ? AND kind = 'attachment' AND is_compacted = 0",
      whereArgs: [sessionId],
      orderBy: 'seq',
    );
    return rows.map(Message.fromMap).toList();
  }

  /// 追加一条 system 行(压缩摘要等),返回新行 id。
  ///
  /// seq 读-写与 [append] 同款事务模板,防止并发插入拿到相同 seq。
  Future<int> insertSystem({required int sessionId, required String content}) async {
    _invalidate(db.db, sessionId);
    return db.db.transaction((txn) async {
      final next = Sqflite.firstIntValue(
        await txn.rawQuery('SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE session_id = ?', [sessionId]),
      )!;
      return txn.insert('messages', {'session_id': sessionId, 'role': 'system', 'content': content, 'seq': next});
    });
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
    if (sample.isNotEmpty) _invalidate(db.db, sample.first['session_id'] as int);
    final batch = db.db.batch();
    for (final id in ids) {
      batch.update('messages', {'is_compacted': 1, 'compact_of': compactOf}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// 会话导入的分块落库(流式归档用):列映射与 [importMessages] 一致,
  /// seq 从 [seqStart] 起连续。每块一个事务,调用方每 8~16 条提交一次,
  /// 峰值内存只与块内消息的图片大小相关,与归档总大小无关。
  Future<List<int>> insertMessageChunk({
    required int sessionId,
    required List<Message> messages,
    required int seqStart,
  }) async {
    if (messages.isEmpty) return const [];
    _invalidate(db.db, sessionId);
    return db.db.transaction((txn) async {
      final batch = txn.batch();
      for (final (i, m) in messages.indexed) {
        batch.insert('messages', {
          'session_id': sessionId,
          'role': m.role,
          'content': m.content,
          'seq': seqStart + i,
          'is_compacted': m.isCompacted ? 1 : 0,
          'kind': m.kind.wire,
          if (m.refId != null) 'ref_id': m.refId,
          if (m.imageUrl != null) 'image_url': m.imageUrl,
          if (m.imageBase64 != null) 'image_base64': m.imageBase64,
          if (m.imagePrompt != null) 'image_prompt': m.imagePrompt,
        });
      }
      final ids = await batch.commit(noResult: false);
      return [for (final id in ids) if (id is int) id];
    });
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
    _invalidate(db.db, sessionId);
    final batch = db.db.batch();
    for (final (rowIndex, compactIndex) in links) {
      if (rowIndex < 0 || rowIndex >= rowIds.length) continue;
      if (compactIndex < 0 || compactIndex >= rowIds.length) continue;
      batch.update(
        'messages',
        {'compact_of': rowIds[compactIndex]},
        where: 'id = ?',
        whereArgs: [rowIds[rowIndex]],
      );
    }
    await batch.commit(noResult: true);
  }

  /// 会话导入:按列表顺序把消息落到全新会话 —— seq 重排为从 0 开始的连续
  /// 序列(新会话内自洽即可),图片 base64 原样落列。入参 [Message.compactOf]
  /// 是**归档数组内索引**(v4 导出语义):先批量插入拿到各行新 id,再把
  /// compact_of 换算回"摘要行新 id"(与生产写入 markCompacted 的行 id 语义
  /// 一致);越界索引按无指向处理。单事务完成。
  Future<void> importMessages({required int sessionId, required List<Message> messages}) async {
    if (messages.isEmpty) return;
    _invalidate(db.db, sessionId);
    await db.db.transaction((txn) async {
      final batch = txn.batch();
      for (final (i, m) in messages.indexed) {
        batch.insert('messages', {
          'session_id': sessionId,
          'role': m.role,
          'content': m.content,
          'seq': i,
          'is_compacted': m.isCompacted ? 1 : 0,
          'kind': m.kind.wire,
          if (m.refId != null) 'ref_id': m.refId,
          if (m.imageUrl != null) 'image_url': m.imageUrl,
          if (m.imageBase64 != null) 'image_base64': m.imageBase64,
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
  }

  /// 摘要写入 + 原文标记压缩原子完成(消除原先两写之间的失败窗口:
  /// insertSystem 成功但 markCompacted 失败会留下孤儿摘要)。
  /// 返回摘要行的 id。
  Future<int> insertSystemAndCompact({
    required int sessionId,
    required String content,
    required List<int> compactIds,
  }) async {
    _invalidate(db.db, sessionId);
    return db.db.transaction((txn) async {
      final next = Sqflite.firstIntValue(
        await txn.rawQuery('SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE session_id = ?', [sessionId]),
      )!;
      final summaryId = await txn.insert('messages', {
        'session_id': sessionId,
        'role': 'system',
        'content': content,
        'seq': next,
      });
      final batch = txn.batch();
      for (final id in compactIds) {
        batch.update('messages', {'is_compacted': 1, 'compact_of': summaryId}, where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
      return summaryId;
    });
  }
}

/// 消息列表缓存键:(Database, sessionId, includeImages) 决定取哪个库的哪种视图。
/// 用底层 sqflite `Database` 对象区分不同连接(测试通常各开一个 in-memory 库),
/// 避免跨库串味;同一应用的同一库内则跨 `MessageRepository` 实例共享。
class _MessageCacheKey {
  final Database db;
  final int sessionId;
  final bool includeImages;
  const _MessageCacheKey(this.db, this.sessionId, this.includeImages);

  @override
  bool operator ==(Object other) =>
      other is _MessageCacheKey &&
      identical(other.db, db) &&
      other.sessionId == sessionId &&
      other.includeImages == includeImages;

  @override
  int get hashCode => Object.hash(identityHashCode(db), sessionId, includeImages);
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
