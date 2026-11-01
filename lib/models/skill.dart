/// 全局技能(Anthropic Skills 风格):`name` + `description` + 实际内容。
///
/// 技能是**全局共享**的提示词资产,不再归属会话、也不再由后台引擎自动激活 ——
/// 用户在设置页自由创建/编辑,并手动控制启用;启用中的技能在所有会话的上下文
/// 组装里全局生效(拼进 system 稳定段)。从角色卡世界书导入的技能没有描述
/// ([description] 为空串)。
class Skill {
  final int? id;
  final String name;

  /// 一句话说明技能的用途/何时使用(Anthropic skills 的 description 字段)。
  /// 允许为空:世界书导入产生的技能没有描述。
  final String description;
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
