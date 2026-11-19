/// agent 单步传输:一次带 tools 的 LlmRequest → 收集本步全部事件。
/// 取消竞速复刻 BackgroundEngine._attempt:cancelSignal 触发即解除等待 +
/// 关掉底层 HTTP 订阅,不等模型吐首块;ErrorEvent 保留 kind(步级重试的
/// 决策输入,legacy 单发路径丢弃它)。
library;

import 'dart:async';
import '../../backend/llm_backend.dart';
import '../../backend/upstream_error.dart';
import '../../models/llm_tool.dart';
import '../../models/token_usage.dart';
import 'agent_events.dart';

/// 单步(单尝试)的结果。
sealed class AgentStepOutcome {
  const AgentStepOutcome();

  /// 本尝试已收到的用量(失败尝试也可能烧了 token,逐步入账要求带出)。
  TokenUsage get usage;
}

/// 流正常收尾:本步全部工具调用(流末一次性)、thinking 回放块、正文与用量。
class AgentStepSuccess extends AgentStepOutcome {
  final List<ToolCall> calls;
  final List<Map<String, dynamic>> replayBlocks;
  final String text;
  @override
  final TokenUsage usage;
  const AgentStepSuccess({
    this.calls = const [],
    this.replayBlocks = const [],
    this.text = '',
    this.usage = const TokenUsage(),
  });
}

/// 流报错/取消:kind 供 runner 判定可重试性(null = 传输异常,按瞬态处理)。
class AgentStepFailure extends AgentStepOutcome {
  final AgentFailureReason reason;
  final String? detail;
  final UpstreamErrorKind? kind;
  @override
  final TokenUsage usage;
  const AgentStepFailure(this.reason, {this.detail, this.kind, this.usage = const TokenUsage()});
}

/// 发起一步请求并竞速收集。shouldCancel 轮询 + cancelSignal 唤醒双通道,
/// 与主写/legacy 后台同款语义:取消即断链,服务端立刻停止生成。
Future<AgentStepOutcome> runAgentStep(
  LlmBackend backend,
  LlmRequest request, {
  bool Function()? shouldCancel,
  Future<void>? cancelSignal,
  void Function(String delta)? onTextDelta,
}) {
  final completer = Completer<AgentStepOutcome>();
  StreamSubscription<LlmEvent>? sub;
  var cancelled = false;
  final buffer = StringBuffer();
  var toolCalls = const <ToolCall>[];
  var blocks = const <Map<String, dynamic>>[];
  var usage = const TokenUsage();

  void finish(AgentStepOutcome outcome) {
    if (!completer.isCompleted) completer.complete(outcome);
  }

  void onCancel() {
    if (cancelled || completer.isCompleted) return;
    cancelled = true;
    finish(AgentStepFailure(AgentFailureReason.cancelled, usage: usage));
    // 不 await:流可能卡在 client.send(),await 会把取消拖到连接建立之后。
    unawaited(sub?.cancel());
  }

  sub = backend.generate(request).listen(
    (event) {
      if (cancelled) return;
      switch (event) {
        case TextDelta(:final text):
          buffer.write(text);
          // 流式正文只作 UI 即时反馈;步结果仍以 buffer 为准(重试会重置 buffer)。
          onTextDelta?.call(text);
        case ToolCallsEvent(:final calls, :final replayBlocks):
          toolCalls = calls;
          blocks = replayBlocks;
        case UsageEvent(usage: final snapshot):
          // 每请求一次的终值快照,直接取用(不做增量求和)。
          usage = snapshot;
        case DoneEvent():
          break;
        case ErrorEvent(:final message, :final kind):
          finish(AgentStepFailure(
            AgentFailureReason.backendError,
            detail: message,
            kind: kind,
            usage: usage,
          ));
      }
    },
    onError: (Object e) {
      finish(AgentStepFailure(
        AgentFailureReason.backendError,
        detail: '$e',
        usage: usage,
      ));
    },
    onDone: () {
      if (cancelled) return;
      // 自然收尾后再查一次:取消可能与末块同时到达。
      if (shouldCancel?.call() ?? false) {
        onCancel();
        return;
      }
      finish(AgentStepSuccess(
        calls: toolCalls,
        replayBlocks: blocks,
        text: buffer.toString(),
        usage: usage,
      ));
    },
    cancelOnError: true,
  );
  if (shouldCancel?.call() ?? false) {
    onCancel();
  } else if (cancelSignal != null) {
    cancelSignal.whenComplete(() {
      if (shouldCancel?.call() ?? false) onCancel();
    });
  }
  return completer.future;
}