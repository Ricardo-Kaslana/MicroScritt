import '../models/worldbook_entry.dart';
import 'database.dart';

class WorldbookRepository {
  final AppDatabase db;
  WorldbookRepository(this.db);

  // 历史遗留列:kind 曾区分「规则/技能」两类条目(v37 起永久退役,世界书
  // 不再有类型之分)。列在库里保留(NOT NULL 无默认,增量迁移不删列),
  // 写入恒为 'rule' 占位,代码侧不再读取。
  static const String _legacyKindColumnValue = 'rule';

  /// 整组写入某角色的世界书条目。
  ///
  /// **保持条目 id 稳定**(2026-09-28 批):带 id 的条目走 UPDATE、无 id 的走
  /// INSERT、不在新列表里的 DELETE —— 取代旧的「全删再全插」。
  ///
  /// 为什么必须稳定:附件去重账本以 `wb:<worldbook_entries.id>` 记账
  /// ([AttachmentRef.worldbook])。id 一变,同一会话里既有的附件行就再也匹配
  /// 不上,条目会被当成"没注入过"重新注入 —— 而旧附件行仍留在活跃窗口里,
  /// 于是同一条目在上下文里并存多份,面板上的附件数远超条目数。旧实现每次
  /// 保存(哪怕只切换一个启用开关)都会让全表 id 前移。
  Future<void> replaceForCharacter(int characterId, List<WorldbookEntry> entries) async {
    await db.db.transaction((txn) async {
      final existingRows = await txn.query(
        'worldbook_entries',
        columns: ['id'],
        where: 'character_id = ?',
        whereArgs: [characterId],
      );
      final existingIds = {for (final r in existingRows) r['id'] as int};
      final keepIds = <int>{
        for (final e in entries)
          if (e.id != null) e.id!,
      };
      final batch = txn.batch();
      for (final id in existingIds.difference(keepIds)) {
        batch.delete('worldbook_entries', where: 'id = ?', whereArgs: [id]);
      }
      for (final e in entries) {
        final values = <String, Object?>{
          'character_id': characterId,
          'kind': _legacyKindColumnValue,
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
          'enabled': e.enabled ? 1 : 0,
          'background': e.background ? 1 : 0,
          'extra': e.extraWire,
        };
        final id = e.id;
        // id 存在且确实属于本角色 → 原地更新;否则插入新行(无 id,或 id 指向
        // 别的角色 —— 跨角色复制条目时走这条路,不能误改他人行)。
        if (id != null && existingIds.contains(id)) {
          batch.update('worldbook_entries', values, where: 'id = ?', whereArgs: [id]);
        } else {
          batch.insert('worldbook_entries', values);
        }
      }
      await batch.commit(noResult: true);
    });
  }

  /// 单次 substr 读取的字符数。TEXT 以 UTF-8 存放,最坏 4 字节/字符 ——
  /// 256K 字符 ≤ 1MB,配合同行其它小字段仍远低于 Android CursorWindow 的
  /// 2MB 上限。
  static const int _textChunkChars = 256 * 1024;

  /// 某角色的全部条目。content/extra 可能异常巨大(20MB 级卡把整本设定塞进
  /// 单条),整列 SELECT 会让超窗行抛 "Row too big":聊天组装、状态面板与导出
  /// 会一起失效。这里先只取小值 + 长度,超阈值行再按 id 分块拼接。
  Future<List<WorldbookEntry>> byCharacter(int characterId) async {
    final rows = await db.db.rawQuery(
      'SELECT id, character_id, name, key, use_regex, case_sensitive,'
      ' match_whole_words, selective, secondary_key, constant, position,'
      ' enabled, background,'
      ' CASE WHEN length(content) > $_textChunkChars THEN NULL ELSE content END AS content,'
      ' length(content) AS content_len,'
      ' CASE WHEN length(extra) > $_textChunkChars THEN NULL ELSE extra END AS extra,'
      ' length(extra) AS extra_len'
      ' FROM worldbook_entries WHERE character_id = ? ORDER BY position, id',
      [characterId],
    );
    final entries = <WorldbookEntry>[];
    for (final row in rows) {
      var content = row['content'] as String?;
      if (content == null && (row['content_len'] as int? ?? 0) > 0) {
        content = await _readTextColumn(row['id'] as int, 'content');
      }
      var extra = row['extra'] as String?;
      if (extra == null && (row['extra_len'] as int? ?? 0) > 0) {
        extra = await _readTextColumn(row['id'] as int, 'extra');
      }
      entries.add(
        WorldbookEntry.fromMap({
          ...row,
          // 行在分段读取期间被删除时 content 可能落空:按空条目返回,
          // 不让一次并发删除炸掉整本世界书的加载。
          'content': content ?? '',
          'extra': extra,
        }),
      );
    }
    return entries;
  }

  /// 分块读回 worldbook_entries 的单列文本(列名只允许内部常量)。
  Future<String?> _readTextColumn(int id, String column) async {
    final lenRows = await db.db.rawQuery(
      'SELECT length($column) AS len FROM worldbook_entries WHERE id = ? LIMIT 1',
      [id],
    );
    if (lenRows.isEmpty) return null;
    final len = lenRows.first['len'] as int?;
    if (len == null) return null;
    final buffer = StringBuffer();
    for (var start = 1; start <= len; start += _textChunkChars) {
      final chunk = await db.db.rawQuery(
        'SELECT substr($column, ?, ?) AS piece FROM worldbook_entries WHERE id = ? LIMIT 1',
        [start, _textChunkChars, id],
      );
      if (chunk.isEmpty) return null;
      buffer.write(chunk.first['piece'] as String? ?? '');
    }
    return buffer.toString();
  }
}
