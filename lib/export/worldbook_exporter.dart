import 'dart:convert';

import '../models/worldbook_entry.dart';

/// 世界书条目序列化。两种输出形态共用一个实现,避免「导入认识、导出不写」的
/// 字段漂移(历史上 extra 透传字段就吃过这个亏):
///
/// - **独立世界书文件**(ST World Info 形态):[export] / [exportJson] / [toStEntry]。
///   `entries` 为以序号为键的对象,条目字段用 ST 原生名(`key` / `keysecondary` /
///   `disable` / `order` / `caseSensitive` / `matchWholeWords`),可被 SillyTavern
///   的「导入世界书」直接读入,也能被本端 [WorldbookImporter] 无损读回。
/// - **角色卡 `character_book` 条目**(ST V2 条目形态):[toCardEntry] / [cardBookJson],
///   字段名 `keys` / `secondary_keys` / `enabled` / `insertion_order` —— 由
///   `CharacterCardExporter` 与会话导出复用。
///
/// 两种形态都先铺 [WorldbookEntry.extra](导入时捕获的未建模字段),建模字段再覆盖
/// —— 用户改过的字段以库中现值为准,未建模的原样透传,第三方消费端不丢字段。
class WorldbookExporter {
  /// 导出为独立世界书文件的 JSON 字符串(ST World Info 形态)。
  static String export(List<WorldbookEntry> entries) => jsonEncode(exportJson(entries));

  static Map<String, dynamic> exportJson(List<WorldbookEntry> entries) => {
    'entries': {for (final (i, e) in entries.indexed) '$i': toStEntry(e, i)},
  };

  /// 独立世界书条目(ST World Info 形态)。
  ///
  /// 注意 `position` 一词在两边含义不同:ST 的 `position` 是「插入位置枚举」
  /// (before_char/after_char…),本端的 `position` 是列表排序序号。排序序号写
  /// ST 的 `order`;ST 原生的 `position` 由 extra 透传,这里不覆写。
  static Map<String, dynamic> toStEntry(WorldbookEntry e, int index) => {
    ...e.extra,
    // uid 是 ST 条目自身标识,导出按数组序号重写(导入端不读,仅入 extra)。
    'uid': index,
    'key': e.keys,
    if (e.secondaryKeys.isNotEmpty) 'keysecondary': e.secondaryKeys,
    'comment': e.name,
    'content': e.content,
    'constant': e.constant,
    'selective': e.selective,
    'disable': !e.enabled,
    'order': e.position != 0 ? e.position : index,
    'caseSensitive': e.caseSensitive,
    'useRegex': e.useRegex,
    'matchWholeWords': e.matchWholeWords,
    // 本端扩展:后台锚定选择(ST 不认识,但原样保留整条对象,不丢)。
    'background': e.background,
    'extensions': {..._extraExtensions(e), 'match_whole_words': e.matchWholeWords},
  };

  /// 角色卡 `character_book` 条目形态(与 [WorldbookImporter] 的读取字段一一对应)。
  static Map<String, dynamic> toCardEntry(WorldbookEntry e, int index) => {
    ...e.extra,
    'comment': e.name,
    'keys': e.keys,
    'content': e.content,
    'enabled': e.enabled,
    'constant': e.constant,
    'insertion_order': e.position != 0 ? e.position : index,
    'case_sensitive': e.caseSensitive,
    'selective': e.selective,
    if (e.secondaryKeys.isNotEmpty) 'secondary_keys': e.secondaryKeys,
    if (e.useRegex) 'use_regex': true,
    // 本端扩展:后台锚定选择随卡往返(否则卡导出→导入一次就退回按常驻推断)。
    'background': e.background,
    // ST 把整词匹配放条目 extensions;另带 camelCase 拼写兜底(RP-Hub 形态)。
    'extensions': {
      ..._extraExtensions(e),
      'match_whole_words': e.matchWholeWords,
      if (e.matchWholeWords) 'matchWholeWords': true,
    },
  };

  static Map<String, dynamic> cardBookJson(List<WorldbookEntry> entries) => {
    'entries': [for (final (i, e) in entries.indexed) toCardEntry(e, i)],
  };

  static Map<String, dynamic> _extraExtensions(WorldbookEntry e) {
    final ext = e.extra['extensions'];
    return ext is Map<String, dynamic> ? Map<String, dynamic>.of(ext) : const {};
  }
}
