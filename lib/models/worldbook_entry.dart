/// 世界书条目模型(`worldbook_entries` 表)与 ST 字段兼容序列化。
///
/// 条目按关键词/常驻规则触发,进入主写上下文的附件段;未建模的 ST 专有
/// 字段保存在 [WorldbookEntry.extra] 中原样透传,导出时重建。
library;

import 'dart:convert';

/// 一条世界书条目(不可变)。
class WorldbookEntry {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 所属角色 id。
  final int characterId;

  /// 显示名(ST `comment` 映射;空时 UI 回退首关键词)。不参与触发。
  final String name;

  /// 主关键词列表;空列表且非常驻的条目永不触发。
  final List<String> keys;

  /// 关键词是否按正则解释(Dart RegExp 语法)。
  final bool useRegex;

  /// 匹配是否区分大小写(ST 条目顶层 `case_sensitive`;默认不敏感)。
  final bool caseSensitive;

  /// 整词匹配(ST 条目 `extensions.match_whole_words`);仅纯 ASCII 词键生效,CJK 回退子串。
  final bool matchWholeWords;

  /// 选择性触发(ST `selective`):true 时主键与次键各至少命中一个才触发。
  final bool selective;

  /// 次关键词(ST `secondary_keys`),仅 [selective] 为 true 时参与判定。
  final List<String> secondaryKeys;

  /// 是否常驻:true 时无需关键词命中,每轮都进入上下文。
  final bool constant;

  /// 条目正文;触发后以 `<system-reminder>` 附件行注入。
  final String content;

  /// 组装/列表排序位(升序)。
  final int position;

  /// 是否启用;停用后不参与触发。
  final bool enabled;

  /// 是否进入后台agent 上下文锚定段(状态面板后台 agent 区「后台世界书条目」
  /// 选择,对应库列 `background`)。
  ///
  /// 快状态轮的 `<worldbook_background>` 锚定段以此为准,不再按 [constant]
  /// 判断;v52 迁移用 constant 回填,保持升级前行为。初始化路径(记忆/生图
  /// 指导生成)仍按常驻条目取数。
  final bool background;

  /// 原始条目里**未建模字段**的透传保真(对应库列 `extra`)。
  ///
  /// ST 专有的 position/probability/useProbability/selectiveLogic/role/depth/
  /// 递归标志/group/automation_id,以及 `extensions` 里我们不认识的自定义键,
  /// 都原样存这里;导出重建 `character_book` 时先铺 extra、建模字段覆盖 ——
  /// 第三方消费端拿回的字段不再凭空丢失。本端 UI 新建的条目为空。
  final Map<String, dynamic> extra;

  const WorldbookEntry({
    this.id,
    required this.characterId,
    this.name = '',
    this.keys = const [],
    this.useRegex = false,
    this.caseSensitive = false,
    this.matchWholeWords = false,
    this.selective = false,
    this.secondaryKeys = const [],
    this.constant = false,
    required this.content,
    this.position = 0,
    this.enabled = true,
    this.background = false,
    this.extra = const {},
  });

  /// 主关键词列的落库 JSON 文本。
  String get keysWire => jsonEncode(keys);

  /// 次关键词列的落库 JSON 文本。
  String get secondaryKeysWire => jsonEncode(secondaryKeys);

  /// extra 列 wire:空对象存 ''(列 NOT NULL DEFAULT '' 的口径)。
  String get extraWire => extra.isEmpty ? '' : jsonEncode(extra);

  /// 生成替换部分字段的新条目;列表与 map 字段按引用共享(调用方不就地修改)。
  WorldbookEntry copyWith({
    int? id,
    int? characterId,
    String? name,
    List<String>? keys,
    bool? useRegex,
    bool? caseSensitive,
    bool? matchWholeWords,
    bool? selective,
    List<String>? secondaryKeys,
    bool? constant,
    String? content,
    int? position,
    bool? enabled,
    bool? background,
    Map<String, dynamic>? extra,
  }) => WorldbookEntry(
    id: id ?? this.id,
    characterId: characterId ?? this.characterId,
    name: name ?? this.name,
    keys: keys ?? this.keys,
    useRegex: useRegex ?? this.useRegex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    matchWholeWords: matchWholeWords ?? this.matchWholeWords,
    selective: selective ?? this.selective,
    secondaryKeys: secondaryKeys ?? this.secondaryKeys,
    constant: constant ?? this.constant,
    content: content ?? this.content,
    position: position ?? this.position,
    enabled: enabled ?? this.enabled,
    background: background ?? this.background,
    extra: extra ?? this.extra,
  );

  /// 列表显示名:优先 [name],空则回退首关键词(无关键词条目显示常驻占位)。
  String get displayLabel => name.isNotEmpty
      ? name
      : keys.isEmpty
          ? '(常驻/无关键词)'
          : keys.join(', ');

  Map<String, Object?> toMap() => {
        'id': id,
        'character_id': characterId,
        'name': name,
        'key': keysWire,
        'use_regex': useRegex ? 1 : 0,
        'case_sensitive': caseSensitive ? 1 : 0,
        'match_whole_words': matchWholeWords ? 1 : 0,
        'selective': selective ? 1 : 0,
        'secondary_key': secondaryKeysWire,
        'constant': constant ? 1 : 0,
        'content': content,
        'position': position,
        'enabled': enabled ? 1 : 0,
        'background': background ? 1 : 0,
        'extra': extraWire,
      };

  factory WorldbookEntry.fromMap(Map<String, Object?> m) => WorldbookEntry(
        id: m['id'] as int?,
        characterId: m['character_id'] as int,
        name: m['name'] as String? ?? '',
        // key/secondary_key 列坏 JSON(手改库/异常导入)时回退空列表:同一行
        // 其余字段仍可用,不让一行坏数据炸掉整个角色的世界书加载(与
        // llm_provider「损坏的配置不挡加载」的容错哲学一致)。
        keys: _decodeKeyList(m['key']),
        useRegex: (m['use_regex'] as int? ?? 0) != 0,
        caseSensitive: (m['case_sensitive'] as int? ?? 0) != 0,
        matchWholeWords: (m['match_whole_words'] as int? ?? 0) != 0,
        selective: (m['selective'] as int? ?? 0) != 0,
        secondaryKeys: _decodeKeyList(m['secondary_key']),
        constant: (m['constant'] as int? ?? 0) != 0,
        content: m['content'] as String,
        position: m['position'] as int? ?? 0,
        enabled: (m['enabled'] as int? ?? 1) != 0,
        background: (m['background'] as int? ?? 0) != 0,
        extra: _decodeExtra(m['extra']),
      );

  /// extra 列解码;null/空串/坏 JSON/非对象一律回退空(透传保真是附加信息,
  /// 容错口径与 key 列一致 —— 一行坏数据不挡整个角色的世界书加载)。
  static Map<String, dynamic> _decodeExtra(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const {};
      return decoded;
    } on FormatException {
      return const {};
    }
  }

  /// key/secondary_key 列的 JSON 数组解码;null/非字符串/坏 JSON/非数组一律
  /// 回退空列表(空键列表 = 永不触发的条目,内容仍可在管理页查看修复)。
  static List<String> _decodeKeyList(Object? raw) {
    if (raw is! String) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map((e) => e.toString()).toList();
    } on FormatException {
      return const [];
    }
  }
}
