/// agent 内核循环:多步工具调用直至 finish / 取消 / 护栏 / 重试耗尽。
/// 无步数帽、无墙钟帽(设计决策③):软提醒促 finish,护栏只防坏循环,
/// 「合法但无尽」由用户取消停。转录是内存态 ChatMessage 列表,永不落库
/// (主写单写不变量);内核只 import models/ 与 backend/,读库经 profile
/// 注入的只读回调。
library;

import '../../backend/llm_backend.dart';
import '../../backend/upstream_error.dart';
import '../../models/app_settings.dart';
import '../../models/chat_message.dart';
import '../../models/llm_tool.dart';
import '../../models/token_usage.dart';
import 'agent_action.dart';
import 'agent_events.dart';
import 'agent_tool.dart';
import 'agent_transport.dart';

/// 一轮 agent 运行的完整规格:提示词分段、工具面与取消通道。
class AgentSpec {
  final LlmBackend backend;
  final String model;
  final String systemPrompt;

  /// 稳定/可变 system 分段(cacheStableSystem 时生效):稳定前缀跨步缓存,
  /// 转录增长只追加在 messages 尾部。
  final String? stableSystemPart;
  final String? variableSystemPart;
  final bool cacheStableSystem;

  /// 转录首条 user 消息(上下文 + 行动指令)。
  final String initialUserMessage;
  final AgentToolRegistry registry;

  /// 采样温度:由 profile 从模型配置透传,内核不设默认或夹取。
  final double temperature;

  /// 模型配置的「最大输出 tokens」;与主写一致,未配置时的行为由协议后端
  /// 决定(OpenAI 兼容不发送,Anthropic 要求必填)。每次步内尝试都带同一个值。
  final int? maxTokens;
  final ReasoningLevel reasoningLevel;
  final bool Function()? shouldCancel;
  final Future<void>? cancelSignal;

  /// 软提醒构建器(profile 注入,携带暂存摘要):第 8 步起每 8 步调用,
  /// reminderCount 从 1 起逐级升级。null = 不提醒。
  final String Function(int step, int reminderCount)? softReminder;
  final void Function(AgentStepEvent)? onStep;

  /// 流式正文回调(可选):本步每次 TextDelta 即时透传。后台 profile 不传,
  /// 零行为变化;流式 UI 据此渲染「正在输入」,步结束时以
  /// [AgentStepEvent.text] 落定。
  final void Function(String delta)? onTextDelta;

  const AgentSpec({
    required this.backend,
    required this.model,
    required this.systemPrompt,
    required this.initialUserMessage,
    required this.registry,
    required this.temperature,
    this.stableSystemPart,
    this.variableSystemPart,
    this.cacheStableSystem = false,
    this.maxTokens,
    this.reasoningLevel = ReasoningLevel.off,
    this.shouldCancel,
    this.cancelSignal,
    this.softReminder,
    this.onStep,
    this.onTextDelta,
  });
}

/// 一轮 agent 运行的结果:与 BackgroundRunResult 同构。
sealed class AgentRunResult {
  const AgentRunResult();
}

/// finish 收尾:finishArgs + 逐步用量 + 总用量(暂存提交归 profile/编排器)。
class AgentRunSuccess extends AgentRunResult {
  final Map<String, Object?> finishArgs;
  final List<TokenUsage> stepUsages;
  final TokenUsage totalUsage;
  const AgentRunSuccess({
    required this.finishArgs,
    required this.stepUsages,
    required this.totalUsage,
  });
}

/// 失败:原因 + 诊断(≤120 字符单行);已烧用量仍带出供入账。
class AgentRunFailure extends AgentRunResult {
  final AgentFailureReason reason;
  final String? detail;
  final List<TokenUsage> stepUsages;
  final TokenUsage totalUsage;
  const AgentRunFailure(
    this.reason, {
    this.detail,
    required this.stepUsages,
    required this.totalUsage,
  });
}

/// 通用 agent 循环。终止仅四途:finish / 取消 / 护栏 / 步内重试耗尽。
class AgentRunner {
  /// 单工具结果字符帽(上下文尺寸护栏,非循环预算)。
  static const int maxToolResultChars = 4000;

  /// 步内最大尝试次数:首试 + 2 次重试,仅 transient/rateLimit。
  static const int maxStepAttempts = 3;

  /// 连续非法步上限:未知工具/坏参数/纯 prose。
  static const int invalidStreakLimit = 3;

  /// 软提醒节奏:第 8 步起每 8 步。
  static const int reminderInterval = 8;

  /// 失败诊断摘要最长字符数(状态面板文案用)。
  static const int maxDetailChars = 120;

  static final _whitespace = RegExp(r'\s+');

  /// 纯 prose 步的回喂指令(模型面向,英文与提示词同语言)。
  static const _proseOnlyFeedback =
      'You must act via tool calls, not prose. Call one of the registered tools, '
      'or call finish to end the run.';

  static Future<AgentRunResult> run(AgentSpec spec) async {
    final transcript = <ChatMessage>[
      ChatMessage(ChatRole.user, spec.initialUserMessage),
    ];
    final tools = <LlmTool>[...spec.registry.definitions, kFinishTool];
    final stepUsages = <TokenUsage>[];
    var invalidStreak = 0;
    var step = 0;

    TokenUsage total() => _sum(stepUsages);
    AgentRunFailure fail(AgentFailureReason reason, String? detail) =>
        AgentRunFailure(reason, detail: detail, stepUsages: stepUsages, totalUsage: total());
    void emit(
      List<String> names,
      TokenUsage usage, {
      required bool success,
      String text = '',
      TokenUsage? requestUsage,
    }) {
      final reported = success &&
          (usage.inputTokens > 0 || usage.outputTokens > 0 || usage.cachedInputTokens > 0);
      spec.onStep?.call(AgentStepEvent(
        step: step,
        toolNames: names,
        usage: usage,
        requestUsage: requestUsage ?? usage,
        reported: reported,
        success: success,
        text: text,
      ));
    }

    while (true) {
      if (spec.shouldCancel?.call() ?? false) return fail(AgentFailureReason.cancelled, null);
      step++;

      // 步内尝试:只重试瞬态/限流;输出上限与主写一致,只带模型配置的
      // 「最大输出 tokens」(未配置时由协议后端处理)。
      var stepUsage = const TokenUsage();
      var requestUsage = const TokenUsage();
      AgentStepOutcome outcome;
      var attempt = 0;
      while (true) {
        attempt++;
        final request = LlmRequest(
          model: spec.model,
          systemPrompt: spec.systemPrompt,
          messages: List.of(transcript),
          tools: tools,
          temperature: spec.temperature,
          maxTokens: spec.maxTokens,
          reasoningLevel: spec.reasoningLevel,
          cacheContext: spec.cacheStableSystem,
          // 多步转录每步重发且只追加:末块断点让增长前缀跨步命中缓存
          // (legacy 单发只有一条固定 user 指令,打末块断点白付写入溢价,
          // 故 false;agent 相反)。DeepSeek 自动缓存忽略此字段。
          cacheMessageBreakpoint: true,
          stableSystemPart: spec.cacheStableSystem ? spec.stableSystemPart : null,
          variableSystemPart: spec.cacheStableSystem ? spec.variableSystemPart : null,
        );
        outcome = await runAgentStep(
          spec.backend,
          request,
          shouldCancel: spec.shouldCancel,
          cancelSignal: spec.cancelSignal,
          onTextDelta: spec.onTextDelta,
        );
        requestUsage = outcome.usage;
        stepUsage = _add(stepUsage, outcome.usage);
        if (outcome is AgentStepSuccess) break;
        final failure = outcome as AgentStepFailure;
        if (failure.reason == AgentFailureReason.cancelled) {
          stepUsages.add(stepUsage);
          emit(const [], stepUsage, success: false, requestUsage: requestUsage);
          return fail(AgentFailureReason.cancelled, null);
        }
        final kind = failure.kind;
        final retryable = kind == null ||
            kind == UpstreamErrorKind.transient ||
            kind == UpstreamErrorKind.rateLimit;
        if (retryable &&
            attempt < maxStepAttempts &&
            !(spec.shouldCancel?.call() ?? false)) {
          continue;
        }
        stepUsages.add(stepUsage);
        emit(const [], stepUsage, success: false, requestUsage: requestUsage);
        final hint = kind == null ? '' : ' | ${kind.hint}';
        return fail(
          AgentFailureReason.backendError,
          _oneLine('${failure.detail ?? '后端调用失败'}$hint'),
        );
      }
      final success = outcome;

      final calls = success.calls;
      if (calls.isEmpty) {
        // 纯 prose / 空响应:非法步。错误经 user 消息回喂(无 tool_call_id
        // 可挂);空正文不追加 assistant 消息(Anthropic 空块数组会 400)。
        invalidStreak++;
        if (success.text.isNotEmpty) {
          transcript.add(ChatMessage(ChatRole.assistant, success.text));
        }
        transcript.add(ChatMessage(ChatRole.user, _proseOnlyFeedback));
        stepUsages.add(stepUsage);
        emit(const [], stepUsage, success: false, requestUsage: requestUsage);
        if (invalidStreak >= invalidStreakLimit) {
          return fail(AgentFailureReason.guardrail, '端点疑似不支持工具调用,请改用旧模式');
        }
        continue;
      }

      transcript.add(ChatMessage(
        ChatRole.assistant,
        success.text,
        toolCalls: calls,
        opaqueBlocks: success.replayBlocks.isEmpty ? null : success.replayBlocks,
      ));
      final executed = <String>[];
      Map<String, Object?>? finishArgs;
      for (final call in calls) {
        if (call.name == kFinishToolName) {
          // finish 混写:其前的调用已照常执行(保 last-action-wins),
          // 其后的调用忽略 —— 转录随 finish 终结,提交点确定。
          finishArgs = decodeToolArguments(call.arguments) ?? const {};
          break;
        }
        final tool = spec.registry.lookup(call.name);
        final args = decodeToolArguments(call.arguments);
        if (tool == null || args == null) {
          final why = tool == null
              ? 'unknown tool "${call.name}"'
              : 'arguments must be a valid JSON object';
          transcript.add(ChatMessage(
            ChatRole.tool,
            'Error: $why. Use one of the registered tools with a JSON object argument.',
            toolCallId: call.id,
          ));
          continue;
        }
        String result;
        try {
          result = await tool.execute(args);
        } on AgentToolFailure catch (e) {
          transcript.add(ChatMessage(ChatRole.tool, 'Error: ${e.message}', toolCallId: call.id));
          continue;
        } catch (e) {
          // 执行器意外异常:回喂纠错,不报废整轮(与语义拒绝同待遇)。
          transcript.add(ChatMessage(
            ChatRole.tool,
            'Error: tool execution failed: $e',
            toolCallId: call.id,
          ));
          continue;
        }
        executed.add(call.name);
        transcript.add(ChatMessage(
          ChatRole.tool,
          _truncateResult(result),
          toolCallId: call.id,
        ));
        if (spec.shouldCancel?.call() ?? false) {
          stepUsages.add(stepUsage);
          emit(executed, stepUsage, success: false, requestUsage: requestUsage);
          return fail(AgentFailureReason.cancelled, null);
        }
      }

      if (finishArgs != null) {
        stepUsages.add(stepUsage);
        emit(executed, stepUsage, success: true, text: success.text, requestUsage: requestUsage);
        return AgentRunSuccess(
          finishArgs: finishArgs,
          stepUsages: stepUsages,
          totalUsage: total(),
        );
      }
      if (executed.isEmpty) {
        // 全部调用非法(未知工具/坏参数):错误已作 tool_result 回喂。
        invalidStreak++;
        stepUsages.add(stepUsage);
        emit(const [], stepUsage, success: false, requestUsage: requestUsage);
        if (invalidStreak >= invalidStreakLimit) {
          return fail(AgentFailureReason.guardrail, '连续 3 步非法工具调用,已终止');
        }
        continue;
      }
      invalidStreak = 0;
      if (step % reminderInterval == 0 && spec.softReminder != null) {
        // 提醒作为 user 消息追加在 tool results 之后:Anthropic 序列化自动
        // 并入同一 user 消息(text 块与 tool_result 共存,守角色交替);
        // OpenAI 是合法的 tool 后 user 消息。
        transcript.add(ChatMessage(
          ChatRole.user,
          spec.softReminder!(step, step ~/ reminderInterval),
        ));
      }
      stepUsages.add(stepUsage);
      emit(executed, stepUsage, success: true, text: success.text, requestUsage: requestUsage);
    }
  }

  static String _truncateResult(String result) =>
      result.length <= maxToolResultChars
          ? result
          : '${result.substring(0, maxToolResultChars)}\n…(truncated)';

  static String _oneLine(String text) {
    final t = text.replaceAll(_whitespace, ' ').trim();
    return t.length <= maxDetailChars ? t : t.substring(0, maxDetailChars);
  }

  static TokenUsage _add(TokenUsage a, TokenUsage b) => TokenUsage(
    inputTokens: a.inputTokens + b.inputTokens,
    outputTokens: a.outputTokens + b.outputTokens,
    cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens,
  );

  static TokenUsage _sum(List<TokenUsage> usages) =>
      usages.fold(const TokenUsage(), _add);
}