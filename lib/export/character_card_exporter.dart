/// 角色卡导出:输出 ST 兼容 JSON,并按当前世界书重建 `character_book`。
///
/// 文件资产只在调用方显式传入 avatarBase64 时还原为外部协议头像;
/// 世界书以独立表为准覆盖导入时 raw 里的旧快照。
library;

import 'dart:convert';

import '../models/character_card.dart';
import '../models/worldbook_entry.dart';
import 'worldbook_exporter.dart';

/// 角色卡 JSON 导出入口;会话导出等需要嵌套时用 [exportJson]。
class CharacterCardExporter {
  /// [avatarBase64] 由导出边界从文件资产按需读取,模型自身不持有 base64。
  /// [worldbook] 非 null 时以库中条目整体覆盖 raw 旧快照 —— 空列表表示用户
  /// 删光了世界书,必须写回空 `entries` 才能让删除生效;null 时才保留 raw。
  static String export(
    CharacterCard card, {
    List<WorldbookEntry>? worldbook,
    String? avatarBase64,
  }) =>
      jsonEncode(exportJson(
        card,
        worldbook: worldbook,
        avatarBase64: avatarBase64,
      ));

  /// [export] 的 Map 形态,供角色卡文件或其他外部导出边界复用。
  static Map<String, dynamic> exportJson(
    CharacterCard card, {
    List<WorldbookEntry>? worldbook,
    String? avatarBase64,
  }) {
    var json = card.toExportJson(avatarBase64: avatarBase64);
    if (worldbook != null) {
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
