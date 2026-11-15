/// 轻量 UI 偏好模型与独立偏好文件(`ui-prefs.json`)的解析。
///
/// 与数据库 schema 解耦:偏好字段增减不改 schema,坏文件/未知值一律
/// fail-safe 回落到默认值。
library;

/// 角色列表布局:列表(信息优先)、图片卡面网格(立绘优先)或
/// 扑克牌堆(单卡聚焦,翻牌浏览)。
enum CharacterLayout {
  list,
  grid,
  deck;

  /// 未知/缺失值一律回落列表(偏好解析必须 fail-safe)。
  static CharacterLayout fromWire(Object? raw) =>
      CharacterLayout.values.where((v) => v.name == raw).firstOrNull ??
      CharacterLayout.list;

  /// AppBar 布局按钮按声明顺序循环:列表 → 图片 → 牌堆 → 列表。
  CharacterLayout get next =>
      CharacterLayout.values[(index + 1) % CharacterLayout.values.length];

  /// 文件/传输用的字面值。
  String get wire => name;
}

/// 轻量 UI 偏好的持久化形态(与数据库、LLM 配置文件分开的独立小文件)。
/// 角色列表布局、牌堆浏览进度与桌面侧栏折叠状态的快照。
class UiPrefs {
  /// 当前布局;缺省为列表。
  final CharacterLayout characterLayout;

  /// 桌面宽窗聊天页的会话侧栏是否折叠;缺省展开,非布尔值一律回落展开。
  final bool sidebarCollapsed;

  /// 牌堆布局停在正面的角色 id;缺省/非整数/角色已删除时由牌堆回落第一张。
  final int? deckFrontCharacterId;

  const UiPrefs({
    this.characterLayout = CharacterLayout.list,
    this.sidebarCollapsed = false,
    this.deckFrontCharacterId,
  });

  factory UiPrefs.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return const UiPrefs();
    return UiPrefs(
      characterLayout: CharacterLayout.fromWire(raw['characterLayout']),
      sidebarCollapsed: raw['sidebarCollapsed'] == true,
      deckFrontCharacterId: raw['deckFrontCharacterId'] is int
          ? raw['deckFrontCharacterId'] as int
          : null,
    );
  }
}
