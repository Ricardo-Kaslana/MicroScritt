/// 单轮附件注入预算与来源优先级。
///
/// 发送管线每轮可能产生多类附件候选(@技能、系统通知、世界书触发):
/// 技能是用户主动调用、通知是系统事件,二者豁免预算全量注入;世界书键
/// 命中是自动行为、频率不可控,受全局设置的附件限额约束,超出时按候选
/// 顺序丢弃尾部(即 `ContextAssembler.matchTriggered` 的返回顺序:启用
/// 条目的库序)。
library;

/// 附件来源类型,按优先级降序声明:技能(用户主动)> 通知(系统事件)>
/// 世界书触发(自动)。前两者豁免单轮预算。
enum AttachmentOrigin {
  skill,
  notice,
  worldbook;

  /// 是否豁免单轮注入预算(不占全局附件限额名额)。
  bool get budgetExempt => this != AttachmentOrigin.worldbook;
}

/// 一条待落库的附件候选:来源类型 + ref 标识 + 线上内容。
class AttachmentCandidate {
  /// 来源类型,决定是否占用单轮预算名额。
  final AttachmentOrigin origin;

  /// 附件行的去重标识(如 `skill:3` / `wb:12` / `notice:compact:<时刻>`),
  /// 落库到 `messages.ref_id`,与组装侧的去重账本共用同一口径。
  final String refId;

  /// 线上文本(`<system-reminder>` 包裹后的完整内容),落库时原样写入。
  final String content;

  const AttachmentCandidate({
    required this.origin,
    required this.refId,
    required this.content,
  });
}

/// 在单轮预算内选择实际注入的候选:豁免项([AttachmentOrigin.budgetExempt])
/// 全收并保持原序,预算项取前 [maxAutoAttachments] 条。
/// `maxAutoAttachments <= 0` 表示关闭自动附件(预算项一条都不注入)。
/// 返回值保持"豁免项在前、预算项在后"的落库顺序。
List<AttachmentCandidate> selectWithinBudget(
  List<AttachmentCandidate> candidates,
  int maxAutoAttachments,
) {
  final exempt = candidates.where((c) => c.origin.budgetExempt).toList();
  final budgeted = candidates.where((c) => !c.origin.budgetExempt).toList();
  final taken = maxAutoAttachments <= 0
      ? const <AttachmentCandidate>[]
      : budgeted.take(maxAutoAttachments).toList();
  return [...exempt, ...taken];
}
