/// 显示层正则脚本模型(`regex_scripts` 表)。
///
/// 对**气泡显示文本**做查找替换,替换串里可写轻量样式标记(如 `<i>…</i>`、
/// `<c=ff8800>…</c>`)交给 `RichMessageText` 渲染成富文本。仅作用于显示层:
/// 落库与发给 LLM 的内容保持原样。脚本不作用于上下文/提示词层。
library;

/// 一条用户可编辑的显示层正则脚本。
class RegexScript {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 显示名(管理列表用)。
  final String name;

  /// 查找正则(Dart RegExp 语法)。
  final String findRegex;

  /// 替换串,支持 `$1`–`$9` 捕获组引用、`$&` 整体匹配、`$$` 字面 `$`,
  /// 以及样式标记。
  final String replace;

  /// 是否启用;停用后不参与显示层替换。
  final bool enabled;

  /// 应用顺序(小者先);同序按 id。
  final int position;

  const RegexScript({
    this.id,
    required this.name,
    required this.findRegex,
    required this.replace,
    this.enabled = true,
    this.position = 0,
  });

  RegexScript copyWith({
    int? id,
    String? name,
    String? findRegex,
    String? replace,
    bool? enabled,
    int? position,
  }) =>
      RegexScript(
        id: id ?? this.id,
        name: name ?? this.name,
        findRegex: findRegex ?? this.findRegex,
        replace: replace ?? this.replace,
        enabled: enabled ?? this.enabled,
        position: position ?? this.position,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'find_regex': findRegex,
        'replace': replace,
        'enabled': enabled ? 1 : 0,
        'position': position,
      };

  factory RegexScript.fromMap(Map<String, Object?> m) => RegexScript(
        id: m['id'] as int?,
        name: m['name'] as String,
        findRegex: m['find_regex'] as String,
        replace: m['replace'] as String,
        enabled: (m['enabled'] as int? ?? 1) != 0,
        position: m['position'] as int? ?? 0,
      );
}
