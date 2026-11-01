/// 会话变量与后台权限模型(`variables` / `variable_trash` /
/// `variable_deletion_proposals`)。
///
/// 变量只供后台引擎维护,不进入主写上下文;删除必须显式请求并受
/// `agent_access` 约束,权限在仓库事务内强制执行。
library;

/// 变量对后台 agent 的开放程度。
///
/// - [full]: 后台可改值、可删除(后台新建变量的默认归属);
/// - [protected]: 后台可改值、不可删除(人工新增/导入的默认归属);
/// - [readonly]: 后台不可改、不可删除(会话级常量)。
///
/// 权限只在仓库层强制执行;提示词里的 `<variable_access>` 只是让模型少做
/// 无用功,不能作为安全边界。
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

/// 一条会话变量。
class Variable {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 所属会话 id。
  final int sessionId;

  /// 变量键(同一会话内唯一)。
  final String key;

  /// 变量值(纯文本)。
  final String value;

  /// 后台可写权限;默认 [VariableAccess.protected]。
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
  /// 回收站行 id;null 表示尚未落库。
  final int? id;

  /// 所属会话 id。
  final int sessionId;

  /// 变量键。
  final String key;

  /// 删除前的值。
  final String value;

  /// 删除前的权限;恢复时保留。
  final VariableAccess agentAccess;

  /// 删除时间。
  final DateTime deletedAt;

  /// 删除来源:`agent` = 后台自动/确认删除;`user` = 用户手动删除/清空。
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

  /// 是否为后台发起/确认的删除。
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
  /// 建议行 id;null 表示尚未落库。
  final int? id;

  /// 所属会话 id。
  final int sessionId;

  /// 待删除的变量键。
  final String key;

  /// 提出建议时的变量值,供用户确认时核对。
  final String value;

  /// 建议创建时间。
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
