enum PromptItemKind { preset, rule }

class PromptItem {
  final int? id;
  final PromptItemKind kind;
  final String name;
  final String text;
  final bool enabled;
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

  /// 历史库可能存有 `kind='memory'` 的旧行(此类型已于本批次退役),读取时
  /// 回退到 `rule`(与该旧类型在上下文中的位置「system 可变段 → messages
  /// 旁路」最接近,内容仍会随 rule 段拼进系统提示,不至于直接消失)。
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
