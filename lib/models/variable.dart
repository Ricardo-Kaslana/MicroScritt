/// 变量对后台 agent 的开放程度。
///
/// - [full]: 后台可改值、可删除（后台新建变量的默认归属）；
/// - [protected]: 后台可改值、不可删除（人工新增/导入的默认归属）；
/// - [readonly]: 后台不可改、不可删除（会话级"常量"）。
///
/// 权限只在仓库层强制执行；提示词里的 `<variable_access>` 只是让模型少做
/// 无用功，不能作为安全边界。
enum VariableAccess {
  full,
  protected,
  readonly;

  static VariableAccess fromStorage(Object? raw) =>
      VariableAccess.values.where((v) => v.name == raw).firstOrNull ??
      VariableAccess.protected;

  /// 面向 UI 的短标签。
  String get label => switch (this) {
    VariableAccess.full => '可改可删',
    VariableAccess.protected => '可改不可删',
    VariableAccess.readonly => '只读常量',
  };

  /// 面向 UI 的说明文案。
  String get description => switch (this) {
    VariableAccess.full => '后台可按剧情更新并清理该变量',
    VariableAccess.protected => '后台可更新值，但不会删除',
    VariableAccess.readonly => '后台完全不能修改，仅手动维护',
  };
}

class Variable {
  final int? id;
  final int sessionId;
  final String key;
  final String value;
  final VariableAccess agentAccess;

  const Variable({
    this.id,
    required this.sessionId,
    required this.key,
    required this.value,
    this.agentAccess = VariableAccess.protected,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'session_id': sessionId,
    'key': key,
    'value': value,
    'agent_access': agentAccess.name,
  };

  factory Variable.fromMap(Map<String, Object?> m) => Variable(
    id: m['id'] as int?,
    sessionId: m['session_id'] as int,
    key: m['key'] as String,
    value: m['value'] as String,
    agentAccess: VariableAccess.fromStorage(m['agent_access']),
  );
}

/// 回收站条目:删除时保留原值与原权限,供状态面板恢复。
class VariableTrashEntry {
  final int? id;
  final int sessionId;
  final String key;
  final String value;
  final VariableAccess agentAccess;
  final DateTime deletedAt;

  /// 'agent' = 后台自动/确认删除;'user' = 用户手动删除/清空。
  final String deletedBy;

  const VariableTrashEntry({
    this.id,
    required this.sessionId,
    required this.key,
    required this.value,
    required this.agentAccess,
    required this.deletedAt,
    required this.deletedBy,
  });

  bool get byAgent => deletedBy == 'agent';

  factory VariableTrashEntry.fromMap(Map<String, Object?> m) =>
      VariableTrashEntry(
        id: m['id'] as int?,
        sessionId: m['session_id'] as int,
        key: m['key'] as String,
        value: m['value'] as String,
        agentAccess: VariableAccess.fromStorage(m['agent_access']),
        deletedAt: DateTime.fromMillisecondsSinceEpoch(m['deleted_at'] as int),
        deletedBy: m['deleted_by'] as String? ?? 'user',
      );
}

/// 严格模式下的待确认删除建议:后台提出、尚未执行。
class VariableDeletionProposal {
  final int? id;
  final int sessionId;
  final String key;
  final String value;
  final DateTime createdAt;

  const VariableDeletionProposal({
    this.id,
    required this.sessionId,
    required this.key,
    required this.value,
    required this.createdAt,
  });

  factory VariableDeletionProposal.fromMap(Map<String, Object?> m) =>
      VariableDeletionProposal(
        id: m['id'] as int?,
        sessionId: m['session_id'] as int,
        key: m['key'] as String,
        value: m['value'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}
