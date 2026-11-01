/// 角色卡与世界书的持久化。
///
/// data_json 一律经 `CharacterCard.toStorageJson()` 落库(剥掉内嵌头像),
/// 大列读取一律分块,避免 Android CursorWindow 的单行 2MB 上限。
library;

import 'dart:convert';
import '../models/character_card.dart';
import '../models/worldbook_entry.dart';
import 'database.dart';

/// 列表投影:角色卡 + 头像/背景是否存在的布尔标记。
///
/// [card] 可能被 SQL 兜底裁成只剩名字(超窗行);详情须按 [id] 重新
/// [CharacterRepository.get]。
class CharacterRecord {
  final int id;
  final CharacterCard card;

  /// 列表投影是否带独立头像/背景(真值需按 id 惰性读取,见
  /// [CharacterRepository.avatarBase64For])。列表查询不把整列 BLOB 拉进
  /// Android CursorWindow —— 大卡头像(1.5MB PNG ≈ 2MB base64)会撑爆 2MB
  /// 窗口,`SELECT *` 直接抛 "Row too big",列表永远转圈;桌面 FFI 无此上限,
  /// 所以只有移动端出问题。
  final bool hasAvatar;
  final bool hasBackground;
  const CharacterRecord({
    required this.id,
    required this.card,
    this.hasAvatar = false,
    this.hasBackground = false,
  });
}

/// 角色卡仓储:CRUD、级联删除与列表投影。
class CharacterRepository {
  final AppDatabase db;
  CharacterRepository(this.db);

  /// 单次 substr 读取的字符数。Android CursorWindow 上限约 2MB,而 SQLite 的
  /// TEXT 以 UTF-8 存放:最坏 4 字节/字符,256K 字符 ≤ 1MB,给同一行的其它
  /// 列留足余量。超大卡(如内嵌巨型世界书/20MB 级 JSON)的 data_json 必须
  /// 按块读回,否则整行超窗时 `get` 只能放弃、导出按钮点了没反应。
  static const int _textChunkChars = 256 * 1024;

  /// base64 头像/背景是纯 ASCII(1 字节/字符)。缩图上限是 1.4MB base64,
  /// 取同值作阈值:正常头像一次查询取回,历史超大列才分块。
  static const int _base64ChunkChars = 1400 * 1024;

  /// 列表投影里 data_json 的字节上限。超过就 NULL 化由 [all] 按 id 补读:
  /// 用字节而非字符判断,CJK/emoji 卡片不会再"字数看着不多"却撑爆窗口。
  static const int _listJsonByteLimit = 1024 * 1024;

  /// 新建角色卡,返回自增 id。
  ///
  /// data_json 用 `toStorageJson()`:内嵌头像只落 `avatar_base64` 列,否则大卡
  /// 单行超过 Android CursorWindow,列表/详情会整屏失效。
  Future<int> insert(CharacterCard c) async {
    return db.db.insert('characters', {
      'name': c.name,
      'avatar_base64': c.avatarBase64,
      'background_base64': c.backgroundBase64,
      'data_json': jsonEncode(c.toStorageJson()),
    });
  }

  /// 角色卡片与其世界书在同一个事务内落库:replace 语义(先清后插)。
  /// 消除了"角色已插入但世界书写入失败 → 角色缺世界书"的崩溃窗口。
  Future<int> insertWithWorldbook(CharacterCard c, List<WorldbookEntry> entries) async {
    return db.db.transaction((txn) async {
      final id = await txn.insert('characters', {
        'name': c.name,
        'avatar_base64': c.avatarBase64,
        'background_base64': c.backgroundBase64,
        // 见 [insert]:data_json 不落内嵌头像,避免大卡单行撑爆 CursorWindow。
        'data_json': jsonEncode(c.toStorageJson()),
      });
      final batch = txn.batch();
      batch.delete('worldbook_entries', where: 'character_id = ?', whereArgs: [id]);
      for (final e in entries) {
        batch.insert('worldbook_entries', {
          'character_id': id,
          // kind 列为历史遗留(已退役,见 WorldbookRepository 注释),恒写占位。
          'kind': 'rule',
          'name': e.name,
          'key': e.keysWire,
          'use_regex': e.useRegex ? 1 : 0,
          'case_sensitive': e.caseSensitive ? 1 : 0,
          'match_whole_words': e.matchWholeWords ? 1 : 0,
          'selective': e.selective ? 1 : 0,
          'secondary_key': e.secondaryKeysWire,
          'constant': e.constant ? 1 : 0,
          'content': e.content,
          'position': e.position,
          'extra': e.extraWire,
          'enabled': e.enabled ? 1 : 0,
          'background': e.background ? 1 : 0,
        });
      }
      await batch.commit(noResult: true);
      return id;
    });
  }

  /// 覆盖式更新角色卡(name/avatar/background/data_json 全部重写)。
  Future<void> update(int id, CharacterCard c) async {
    await db.db.update(
      'characters',
      {
        'name': c.name,
        'avatar_base64': c.avatarBase64,
        'background_base64': c.backgroundBase64,
        // 见 [insert]:data_json 不落内嵌头像,避免大卡单行撑爆 CursorWindow。
        'data_json': jsonEncode(c.toStorageJson()),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// sqflite 默认不启用外键级联,手动在单事务内清掉角色的一切依赖:
  /// 会话消息/会话变量/会话记忆/生图指导 → 会话 → 世界书 → 角色本身。
  /// 技能是全局目录,不随角色/会话删除。
  Future<void> deleteWithCascade(int id) async {
    await db.db.transaction((txn) async {
      final sessionIds = (await txn.query(
        'sessions',
        columns: ['id'],
        where: 'character_id = ?',
        whereArgs: [id],
      )).map((r) => r['id'] as int).toList();
      for (final sid in sessionIds) {
        await txn.delete('messages', where: 'session_id = ?', whereArgs: [sid]);
        await txn.delete('variables', where: 'session_id = ?', whereArgs: [sid]);
        await txn.delete('memories', where: 'session_id = ?', whereArgs: [sid]);
        await txn.delete('image_guides', where: 'session_id = ?', whereArgs: [sid]);
      }
      await txn.delete('sessions', where: 'character_id = ?', whereArgs: [id]);
      await txn.delete('worldbook_entries', where: 'character_id = ?', whereArgs: [id]);
      await txn.delete('characters', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 单卡详情。data_json 落库不含内嵌头像([toStorageJson]),头像按 id 惰性读列;
  /// 任何一步读不到(损坏 JSON)都优雅降级而不是整屏崩溃。
  ///
  /// 三列全部走 [_readTextColumn]:大卡(20MB 级 raw JSON / 未缩图的历史头像)
  /// 单行超过 Android CursorWindow 时,整列 SELECT 会直接抛 "Row too big",
  /// 此前 `get` 只能返回 null —— 编辑/导出按钮点了毫无反馈。现在按长度探测
  /// + substr 分块拼接,任何平台单次返回都远低于窗口上限。
  Future<CharacterCard?> get(int id) async {
    final String? dataJson;
    try {
      dataJson = await _readTextColumn(id, 'data_json', chunkChars: _textChunkChars);
    } catch (_) {
      return null;
    }
    if (dataJson == null) return null;
    final CharacterCard card;
    try {
      card = CharacterCard.fromJson(jsonDecode(dataJson) as Map<String, dynamic>);
    } catch (_) {
      return null; // data_json 损坏:放弃加载,不给格式化异常出口。
    }
    String? background;
    String? avatar;
    try {
      background = await _readTextColumn(id, 'background_base64', chunkChars: _base64ChunkChars);
    } catch (_) {
      background = null;
    }
    try {
      avatar = await _readTextColumn(id, 'avatar_base64', chunkChars: _base64ChunkChars);
    } catch (_) {
      avatar = null;
    }
    final withBackground = background == null || background.isEmpty
        ? card
        : card.withBackground(background);
    return avatar == null || avatar.isEmpty
        ? withBackground
        : withBackground.withAvatar(avatar);
  }

  /// 读取 characters 表的一个文本列:小值一次取回,超过 [chunkChars] 的用
  /// substr 分块读取再拼接。返回 null 表示行不存在或列为 NULL。
  ///
  /// [column] 只允许内部常量(data_json/avatar_base64/background_base64)——
  /// 列名拼进 SQL 是为了让 SQLite 只物化这一列;绝不接收用户输入。
  Future<String?> _readTextColumn(
    int id,
    String column, {
    required int chunkChars,
  }) async {
    final meta = await db.db.rawQuery(
      'SELECT length($column) AS len,'
      ' CASE WHEN length($column) > ? THEN NULL ELSE $column END AS value'
      ' FROM characters WHERE id = ? LIMIT 1',
      [chunkChars, id],
    );
    if (meta.isEmpty) return null;
    final row = meta.first;
    final value = row['value'];
    if (value is String) return value;
    final len = row['len'] as int?;
    if (len == null) return null;
    final buffer = StringBuffer();
    for (var start = 1; start <= len; start += chunkChars) {
      final chunk = await db.db.rawQuery(
        'SELECT substr($column, ?, ?) AS piece FROM characters WHERE id = ? LIMIT 1',
        [start, chunkChars, id],
      );
      if (chunk.isEmpty) return null;
      buffer.write(chunk.first['piece'] as String? ?? '');
    }
    return buffer.toString();
  }

  /// [hydrateOversized] 为真时,对超阈值的行按 id 单独补读完整 JSON(见
  /// [_readOversizedCard])—— 只有列表/详情展示需要描述等字段;导入查重等
  /// 只关心名字的调用方保持默认 false,不为大卡白读整列。
  Future<List<CharacterRecord>> all({bool hydrateOversized = false}) async {
    // 只投影轻量列 + 一个"是否带头像/背景"布尔:avatar_base64/background_base64
    // 可能是几 MB 的 base64,整列塞进 SELECT * 会在 Android 撑爆 2MB 的
    // CursorWindow("Row too big to fit into CursorWindow")导致列表永远转圈。
    // 头像/背景按 id 惰性读取(avatarBase64For/backgroundBase64For)。
    //
    // data_json 也不整列投影:落库已由 toStorageJson 剥掉内嵌头像,正常行天然
    // 安全;这里再留一道 SQL 级兜底 —— 单行超过字节阈值(如内嵌巨型世界书
    // 的卡)以空串替代,避免一行拖垮整个列表。按 `length(CAST(... AS BLOB))`
    // 取 UTF-8 字节数:CJK/emoji 一个字 3–4 字节,按字符数判断会低估窗口占用。
    // 超阈值行由 [hydrateOversized] 单独分块补读(见 [_readOversizedCard])。
    final rows = await db.db.rawQuery(
      'SELECT id, name,'
      " CASE WHEN length(CAST(data_json AS BLOB)) > $_listJsonByteLimit THEN '' ELSE data_json END AS data_json,"
      ' (length(CAST(data_json AS BLOB)) > $_listJsonByteLimit) AS json_oversized,'
      ' (avatar_base64 IS NOT NULL AND length(avatar_base64) > 0) AS has_avatar,'
      ' (background_base64 IS NOT NULL AND length(background_base64) > 0) AS has_background'
      ' FROM characters ORDER BY id',
    );
    final records = <CharacterRecord>[];
    for (final r in rows) {
      var card = _listCard(r);
      final oversized = r['json_oversized'] == 1 || r['json_oversized'] == true;
      if (oversized && hydrateOversized) {
        card = await _readOversizedCard(r['id'] as int) ?? card;
      }
      records.add(
        CharacterRecord(
          id: r['id'] as int,
          card: card,
          hasAvatar: r['has_avatar'] == 1 || r['has_avatar'] == true,
          hasBackground: r['has_background'] == 1 || r['has_background'] == true,
        ),
      );
    }
    return records;
  }

  /// 超大行的补读:按 id 分块读回完整 data_json(移动端也不会撞 CursorWindow),
  /// 失败只影响这一张卡,绝不拖垮列表。
  Future<CharacterCard?> _readOversizedCard(int id) async {
    try {
      final rawJson = await _readTextColumn(id, 'data_json', chunkChars: _textChunkChars);
      if (rawJson == null || rawJson.isEmpty) return null;
      return CharacterCard.fromJson(jsonDecode(rawJson) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 列表行 → 展示用卡。data_json 被 SQL 兜底裁成空串/或内容损坏时,回退成
  /// 只有名字的卡(名字是独立列,永远读得到),列表不崩、不转圈。
  CharacterCard _listCard(Map<String, Object?> r) {
    final rawJson = r['data_json'] as String? ?? '';
    if (rawJson.isEmpty) return CharacterCard(name: r['name'] as String? ?? '');
    try {
      return CharacterCard.fromJson(jsonDecode(rawJson) as Map<String, dynamic>);
    } catch (_) {
      return CharacterCard(name: r['name'] as String? ?? '');
    }
  }

  /// 按 id 惰性读取头像列(列表预览用,避免把大 BLOB 拖进列表查询)。取不到/为空
  /// 返回 null,调用方回退占位图。超大历史列走分块读取,不再整列撞窗口。
  Future<String?> avatarBase64For(int id) async {
    final v = await _readTextColumn(id, 'avatar_base64', chunkChars: _base64ChunkChars);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 按 id 惰性读取背景列(见 [avatarBase64For])。聊天页渲染背景时用。
  Future<String?> backgroundBase64For(int id) async {
    final v = await _readTextColumn(id, 'background_base64', chunkChars: _base64ChunkChars);
    return (v == null || v.isEmpty) ? null : v;
  }
}
