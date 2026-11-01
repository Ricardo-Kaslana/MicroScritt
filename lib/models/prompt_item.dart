/// 提示词条目模型(`prompt_items` 表)与旧类型兼容解析。
///
/// 预设与规则共用一张表,由 [PromptItemKind] 区分组装位置;条目只在
/// 主写 system 中生效,不进入后台请求。
library;

/// 提示词条目类型:预设段或规则段。
enum PromptItemKind {
  /// 角色扮演预设,拼进 system 的预设段。
  preset,

  /// 输出格式/行为规则,拼进 system 的规则段。
  rule,
}

/// 一条用户可编辑的提示词(启用/排序由用户维护)。
class PromptItem {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 条目类型,决定在 system 中的组装位置。
  final PromptItemKind kind;

  /// 显示名;可为空。
  final String name;

  /// 提示词正文,支持 `{{user}}` / `{{char}}` 占位符。
  final String text;

  /// 是否参与组装。
  final bool enabled;

  /// 同类型内的组装顺序(升序)。
  final int position;

  const PromptItem({
    this.id,
    required this.kind,
    this.name = '',
    required this.text,
    this.enabled = true,
    this.position = 0,
  });

  String get kindWire => kind.name;

  /// 历史库可能存有 `kind='memory'` 的旧行(该类型已退役),读取时回退到
  /// [PromptItemKind.rule](与该旧类型在上下文中的位置最接近,内容仍会随
  /// rule 段拼进系统提示,不至于直接消失)。
  static PromptItemKind kindFrom(String s) {
    for (final k in PromptItemKind.values) {
      if (k.name == s) return k;
    }
    return PromptItemKind.rule;
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'kind': kindWire,
    'name': name,
    'text': text,
    'enabled': enabled ? 1 : 0,
    'position': position,
  };

  factory PromptItem.fromMap(Map<String, Object?> m) => PromptItem(
    id: m['id'] as int?,
    kind: kindFrom(m['kind'] as String),
    name: m['name'] as String? ?? '',
    text: m['text'] as String,
    enabled: (m['enabled'] as int? ?? 1) != 0,
    position: m['position'] as int? ?? 0,
  );
}
