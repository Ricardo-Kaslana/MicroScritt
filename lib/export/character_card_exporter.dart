import 'dart:convert';

import '../models/character_card.dart';
import '../models/worldbook_entry.dart';
import 'worldbook_exporter.dart';

class CharacterCardExporter {
  /// data_json 落库时已把内嵌头像剥掉([CharacterCard.toStorageJson])、头像只存
  /// 列里;导出前经 toExportJson 把列里的头像补回 JSON,保证导出的卡在其它
  /// 酒馆端也带头像,不会丢图。
  ///
  /// [worldbook] 是该角色当前的世界书条目(独立表维护):非空时以它为准覆盖
  /// 导出 JSON 的 `character_book` —— 否则导出的卡带的还是导入时 raw 里的
  /// 旧快照,与本端编辑后的世界书不一致。为空时保留 raw 原有 character_book
  /// (可能包含导入时被过滤的停用条目,不无故丢弃)。
  static String export(CharacterCard card, {List<WorldbookEntry>? worldbook}) =>
      jsonEncode(exportJson(card, worldbook: worldbook));

  /// [export] 的 Map 形态:会话导出等需要把角色卡嵌进更大 JSON 的场合复用,
  /// 避免二次 encode/decode。
  static Map<String, dynamic> exportJson(CharacterCard card, {List<WorldbookEntry>? worldbook}) {
    var json = card.toExportJson();
    if (worldbook != null && worldbook.isNotEmpty) {
      json = _withCharacterBook(json, worldbook);
    }
    return json;
  }

  /// 在副本的 fieldData 目标处写入 `character_book`(ST V2 entries 数组形态)。
  static Map<String, dynamic> _withCharacterBook(
    Map<String, dynamic> json,
    List<WorldbookEntry> entries,
  ) {
    final copy = <String, dynamic>{...json};
    if (copy['data'] is Map<String, dynamic>) {
      final data = <String, dynamic>{...(copy['data'] as Map<String, dynamic>)};
      data['character_book'] = WorldbookExporter.cardBookJson(entries);
      copy['data'] = data;
    } else {
      copy['character_book'] = WorldbookExporter.cardBookJson(entries);
    }
    return copy;
  }
}
