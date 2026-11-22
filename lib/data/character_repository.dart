/// 角色卡与世界书的持久化。
///
/// data_json 一律经 `CharacterCard.toStorageJson()` 落库;头像/背景只保存
/// 文件资产 hash,业务行与引用计数同事务更新。超大 data_json 仍分块读取,
/// 避免 Android CursorWindow 的单行 2MB 上限。
library;

import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../models/character_card.dart';
import '../models/worldbook_entry.dart';
import 'database.dart';
import 'message_repository.dart';
import 'worldbook_repository.dart';

/// 列表投影:角色卡(含头像/背景 hash)与对应存在标记。
class CharacterRecord {
  final int id;
  final CharacterCard card;
  final bool hasAvatar;
  final bool hasBackground;
  const CharacterRecord({
    required this.id,
    required this.card,
    this.hasAvatar = false,
    this.hasBackground = false,
  });
}

/// 角色卡仓储:CRUD、图片引用计数、级联删除与列表投影。
class CharacterRepository {
  final AppDatabase db;
  CharacterRepository(this.db);

  /// 超大 data_json 单次 substr 读取的字符数,给 CursorWindow 留足余量。
  static const int _textChunkChars = 256 * 1024;

  /// 列表投影里 data_json 的字节上限;超过后由 all 按 id 分块补读。
  static const int _listJsonByteLimit = 1024 * 1024;

  static String? _hash(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// characters 行的统一投影:图片列只写 hash,data_json 不落内嵌图片。
  static Map<String, Object?> _characterValues(CharacterCard c) => {
    'name': c.name,
    'avatar_hash': _hash(c.avatarHash),
    'background_hash': _hash(c.backgroundHash),
    'data_json': jsonEncode(c.toStorageJson()),
  };

  Future<void> _acquire(DatabaseExecutor txn, String? hash) async {
    if (hash != null) await db.images.acquire(txn, hash);
  }

  Future<void> _release(DatabaseExecutor txn, String? hash) async {
    if (hash != null) await db.images.release(txn, hash);
  }

  Future<int> _insertInTxn(DatabaseExecutor txn, CharacterCard c) async {
    await _acquire(txn, _hash(c.avatarHash));
    await _acquire(txn, _hash(c.backgroundHash));
    return txn.insert('characters', _characterValues(c));
  }

  /// 新建角色卡,图片引用与角色行在同一事务提交。
  Future<int> insert(CharacterCard c) =>
      db.db.transaction((txn) => _insertInTxn(txn, c));

  /// 角色卡片与其世界书在同一个事务内落库:replace 语义(先清后插)。
  Future<int> insertWithWorldbook(
    CharacterCard c,
    List<WorldbookEntry> entries,
  ) async {
    return db.db.transaction((txn) async {
      final id = await _insertInTxn(txn, c);
      final batch = txn.batch();
      batch.delete(
        'worldbook_entries',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      for (final e in entries) {
        batch.insert('worldbook_entries', {
          'character_id': id,
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

  Future<({String? avatar, String? background})?> _storedImages(
    DatabaseExecutor txn,
    int id,
  ) async {
    final rows = await txn.query(
      'characters',
      columns: ['avatar_hash', 'background_hash'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      avatar: _hash(rows.first['avatar_hash']),
      background: _hash(rows.first['background_hash']),
    );
  }

  /// 覆盖式更新:acquire 新图 → 更新业务行 → release 旧图。
  /// 相同 hash 先加后减,净计数不变;角色不存在时不 acquire 新引用。
  Future<void> _updateInTxn(
    DatabaseExecutor txn,
    int id,
    CharacterCard c,
  ) async {
    final old = await _storedImages(txn, id);
    // 角色不存在时不能静默成功:否则 updateWithWorldbook 会给不存在的角色
    // 写世界书孤儿行,UI 也误以为保存成功。抛错让事务整体回滚。
    if (old == null) throw StateError('角色卡不存在或已被删除');
    await _acquire(txn, _hash(c.avatarHash));
    await _acquire(txn, _hash(c.backgroundHash));
    await txn.update(
      'characters',
      _characterValues(c),
      where: 'id = ?',
      whereArgs: [id],
    );
    await _release(txn, old.avatar);
    await _release(txn, old.background);
  }

  Future<void> update(int id, CharacterCard c) async {
    await db.db.transaction((txn) => _updateInTxn(txn, id, c));
  }

  /// 单事务更新角色卡、世界书与图片引用;世界书按 id 稳定增删改。
  Future<void> updateWithWorldbook(
    int id,
    CharacterCard c,
    List<WorldbookEntry> entries,
  ) async {
    await db.db.transaction((txn) async {
      await _updateInTxn(txn, id, c);
      await WorldbookRepository.replaceForCharacterInTxn(txn, id, entries);
    });
  }

  /// 手动级联删除角色的全部依赖,并释放角色图与其所有会话消息图引用。
  /// SQLite 事务内只调整计数,不物理删除文件。
  Future<void> deleteWithCascade(int id) async {
    final sessionIds = await db.db.transaction<List<int>>((txn) async {
      final characterImages = await _storedImages(txn, id);
      final messageImages = await txn.rawQuery(
        'SELECT image_hash FROM messages '
        'WHERE session_id IN (SELECT id FROM sessions WHERE character_id = ?) '
        'AND image_hash IS NOT NULL',
        [id],
      );
      for (final row in messageImages) {
        await _release(txn, _hash(row['image_hash']));
      }

      final sessionIds = (await txn.query(
        'sessions',
        columns: ['id'],
        where: 'character_id = ?',
        whereArgs: [id],
      )).map((r) => r['id'] as int).toList();
      for (final sid in sessionIds) {
        await txn.delete('messages', where: 'session_id = ?', whereArgs: [sid]);
        await txn.delete(
          'variables',
          where: 'session_id = ?',
          whereArgs: [sid],
        );
        await txn.delete(
          'variable_trash',
          where: 'session_id = ?',
          whereArgs: [sid],
        );
        await txn.delete(
          'variable_deletion_proposals',
          where: 'session_id = ?',
          whereArgs: [sid],
        );
        await txn.delete('memories', where: 'session_id = ?', whereArgs: [sid]);
        await txn.delete(
          'image_guides',
          where: 'session_id = ?',
          whereArgs: [sid],
        );
      }
      await txn.delete('sessions', where: 'character_id = ?', whereArgs: [id]);
      await txn.delete(
        'worldbook_entries',
        where: 'character_id = ?',
        whereArgs: [id],
      );
      await txn.delete('characters', where: 'id = ?', whereArgs: [id]);
      await _release(txn, characterImages?.avatar);
      await _release(txn, characterImages?.background);
      return sessionIds;
    });
    for (final sid in sessionIds) {
      MessageRepository.invalidateSession(db.db, sid);
    }
  }

  /// 单卡详情。损坏 data_json 返回 null;图片列只读 64 字符 hash。
  Future<CharacterCard?> get(int id) async {
    final String? dataJson;
    try {
      dataJson = await _readTextColumn(
        id,
        'data_json',
        chunkChars: _textChunkChars,
      );
    } catch (_) {
      return null;
    }
    if (dataJson == null) return null;
    final CharacterCard card;
    try {
      card = CharacterCard.fromStorageJson(
        jsonDecode(dataJson) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
    try {
      final images = await _storedImages(db.db, id);
      if (images == null) return null;
      return card
          .replacingBackground(images.background)
          .replacingAvatar(images.avatar);
    } catch (_) {
      // 图片列读取失败时返回 null 而不是"无头像/背景"的降级卡:后者被 UI
      // 保存会把原头像/背景清空并释放引用。
      return null;
    }
  }

  /// 分块读取 characters.data_json;列名固定,绝不接收用户输入。
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

  /// 列表行始终带图片 hash;超大 data_json 仅展示路径按需分块水合。
  Future<List<CharacterRecord>> all({bool hydrateOversized = false}) async {
    final rows = await db.db.rawQuery(
      'SELECT id, name, avatar_hash, background_hash,'
      " CASE WHEN length(CAST(data_json AS BLOB)) > $_listJsonByteLimit THEN '' ELSE data_json END AS data_json,"
      ' (length(CAST(data_json AS BLOB)) > $_listJsonByteLimit) AS json_oversized,'
      ' (avatar_hash IS NOT NULL AND length(avatar_hash) > 0) AS has_avatar,'
      ' (background_hash IS NOT NULL AND length(background_hash) > 0) AS has_background'
      ' FROM characters ORDER BY id',
    );
    final records = <CharacterRecord>[];
    for (final r in rows) {
      var card = _listCard(r);
      final oversized = r['json_oversized'] == 1 || r['json_oversized'] == true;
      if (oversized && hydrateOversized) {
        card = await _readOversizedCard(r['id'] as int) ?? card;
        card = _withHashes(card, r);
      }
      records.add(
        CharacterRecord(
          id: r['id'] as int,
          card: card,
          hasAvatar: r['has_avatar'] == 1 || r['has_avatar'] == true,
          hasBackground:
              r['has_background'] == 1 || r['has_background'] == true,
        ),
      );
    }
    return records;
  }

  Future<CharacterCard?> _readOversizedCard(int id) async {
    try {
      final rawJson = await _readTextColumn(
        id,
        'data_json',
        chunkChars: _textChunkChars,
      );
      if (rawJson == null || rawJson.isEmpty) return null;
      return CharacterCard.fromStorageJson(
        jsonDecode(rawJson) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  CharacterCard _withHashes(CharacterCard card, Map<String, Object?> r) => card
      .replacingBackground(_hash(r['background_hash']))
      .replacingAvatar(_hash(r['avatar_hash']));

  CharacterCard _listCard(Map<String, Object?> r) {
    final rawJson = r['data_json'] as String? ?? '';
    CharacterCard card;
    if (rawJson.isEmpty) {
      card = CharacterCard(name: r['name'] as String? ?? '');
    } else {
      try {
        card = CharacterCard.fromStorageJson(
          jsonDecode(rawJson) as Map<String, dynamic>,
        );
      } catch (_) {
        card = CharacterCard(name: r['name'] as String? ?? '');
      }
    }
    return _withHashes(card, r);
  }

  /// 按 id 读取头像资产 hash;取不到/为空返回 null。
  Future<String?> avatarHashFor(int id) async {
    final images = await _storedImages(db.db, id);
    return images?.avatar;
  }

  /// 按 id 读取背景资产 hash;取不到/为空返回 null。
  Future<String?> backgroundHashFor(int id) async {
    final images = await _storedImages(db.db, id);
    return images?.background;
  }
}
