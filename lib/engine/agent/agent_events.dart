/// agent 内核的进度事件与失败词汇:供状态面板文案与逐步用量入账消费。
/// 内核不认识具体业务,事件只携带步序号、工具名与用量。
library;

import '../../models/token_usage.dart';

/// 一个**逻辑步**结束(成功执行/非法/失败/取消)时发出;步内重试的用量
/// 求和并入本事件。消费方按步写一条用量明细(kind=background),
/// 失败/取消步 reported=false 仍计次。
class AgentStepEvent {
  /// 1 起的逻辑步序号。
  final int step;

  /// 本步实际执行的工具名(按执行顺序);非法/纯 prose 步为空。
  final List<String> toolNames;

  /// 本步用量(含重试尝试的求和),计费/统计口径。
  final TokenUsage usage;

  /// 本步**最后一次尝试**的用量(单次请求口径)。上下文占用展示应看一次
  /// 请求的输入,不能把重试求和当上下文;无重试时与 [usage] 相等。
  final TokenUsage requestUsage;

  /// 上游是否上报了可用用量:成功步且用量非零才为 true。
  final bool reported;

  /// 本步是否产出了合法工具动作(语义拒绝也算合法执行)。
  final bool success;

  /// 本步成功时的助手正文(与转录里的 assistant content 同值)。流式 UI
  /// 在步结束时以它落定正式文本,避免重试尝试的残文进入历史;失败步为空。
  final String text;

  const AgentStepEvent({
    required this.step,
    required this.toolNames,
    required this.usage,
    required this.requestUsage,
    required this.reported,
    required this.success,
    this.text = '',
  });
}

/// agent 一轮失败的细分原因(与 BackgroundFailureReason 同构,编排器据此
/// 映射回既有三值):取消 / 后端错误(含快失败与重试耗尽)/ 正确性护栏。
enum AgentFailureReason {
  /// 用户中断(shouldCancel 命中):暂存全丢弃,不落库。
  cancelled,

  /// 后端流报错/抛异常:不可重试类别快失败,或瞬态重试耗尽。
  backendError,

  /// 连续非法步达上限(未知工具/坏参数/纯 prose):轮失败。
  guardrail,
}