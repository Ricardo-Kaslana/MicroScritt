/// 角色列表布局:列表(信息优先)或图片卡面网格(立绘优先)。
enum CharacterLayout {
  list,
  grid;

  /// 未知/缺失值一律回落列表(偏好解析必须 fail-safe)。
  static CharacterLayout fromWire(Object? raw) =>
      CharacterLayout.values.where((v) => v.name == raw).firstOrNull ??
      CharacterLayout.list;

  CharacterLayout get toggled => this == CharacterLayout.list
      ? CharacterLayout.grid
      : CharacterLayout.list;

  /// 文件/传输用的字面值。
  String get wire => name;
}

/// 轻量 UI 偏好的持久化形态(与数据库、LLM 配置文件分开的独立小文件)。
class UiPrefs {
  final CharacterLayout characterLayout;

  const UiPrefs({this.characterLayout = CharacterLayout.list});

  factory UiPrefs.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return const UiPrefs();
    return UiPrefs(
      characterLayout: CharacterLayout.fromWire(raw['characterLayout']),
    );
  }
}
