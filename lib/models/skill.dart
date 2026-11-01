/// 全局技能模型(`skills` 表):名称 + 描述 + 内容。
///
/// 技能是**全局共享**的提示词资产,不归属会话、也不由后台引擎自动激活 ——
/// 用户在设置页自由创建/编辑,并手动控制启用;启用中的技能在所有会话的
/// 上下文组装里全局生效,经 @提及以附件行注入。从角色卡世界书导入的技能
/// 没有描述([description] 为空串)。
library;

/// 一条全局技能。
class Skill {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 技能名;@提及时使用的标识,同一库内应唯一。
  final String name;

  /// 一句话说明技能的用途/何时使用;允许为空(世界书导入的技能没有描述)。
  final String description;

  /// 技能正文;仅在 @提及触发时进入上下文。
  final String content;

  /// 启用开关:关闭后不进任何上下文。
  final bool enabled;

  const Skill({
    this.id,
    required this.name,
    this.description = '',
    required this.content,
    this.enabled = true,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'description': description,
    'content': content,
    'enabled': enabled ? 1 : 0,
  };

  factory Skill.fromMap(Map<String, Object?> m) => Skill(
    id: m['id'] as int?,
    name: m['name'] as String,
    description: m['description'] as String? ?? '',
    content: m['content'] as String,
    enabled: (m['enabled'] as int? ?? 1) != 0,
  );
}
