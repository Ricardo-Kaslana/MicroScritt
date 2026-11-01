import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/token_usage.dart';
import 'upstream_error.dart';

class LlmRequest {
  final String model;
  final String systemPrompt;
  final List<ChatMessage> messages;
  final double temperature;
  final int? maxTokens;

  /// 推理等级。openai 后端映射为 `reasoning_effort`(off 时不发送),
  /// anthropic 后端映射为 thinking budget(off 时不启用)。默认关闭保持既有行为。
  final ReasoningLevel reasoningLevel;

  /// 请求 provider 对"稳定前缀"(system + 历史)做提示缓存。
  ///
  /// 仅 Anthropic 后端使用:`cache_control: {type: "ephemeral"}` 放在
  /// messages 末条的 content block 内(块级字段;message 顶层的会被静默忽略),
  /// 把静态 system/history 前缀整体纳入缓存,配合组装器"可变内容只追加在
  /// 数组尾部"(附件/通知)的布局,轮次间命中缓存的稳定区。其它后端忽略此标记。
  final bool cacheContext;

  /// 是否在末条消息上额外打缓存断点(把 system + 全部历史整体缓存)。
  /// 主写默认 true;后台只缓存稳定的 system 段时置 false —— 它只有一条固定
  /// user 指令,末条断点会把每轮变化的转录/变量尾部也按写入价算进缓存,
  /// 而这些内容下一轮不会再读到。
  final bool cacheMessageBreakpoint;

  /// 缓存优化:system 提示词的稳定前缀部分,用于 Anthropic 多断点缓存。
  /// 非 null 时 Anthropic 后端将 system 字段拆为两个 content block,
  /// 在稳定块末尾放置 cache_control 断点,使可变尾部变化不影响稳定前缀的缓存命中。
  /// null 时回退到纯字符串 system 格式(hook 改写了 system prompt 时使用)。
  final String? stableSystemPart;

  /// 缓存优化:system 提示词的可变尾部部分。
  final String? variableSystemPart;

  const LlmRequest({
    required this.model,
    required this.systemPrompt,
    required this.messages,
    this.temperature = 0.7,
    this.maxTokens,
    this.reasoningLevel = ReasoningLevel.off,
    this.cacheContext = false,
    this.cacheMessageBreakpoint = true,
    this.stableSystemPart,
    this.variableSystemPart,
  });
}

sealed class LlmEvent {
  const LlmEvent();
}

class TextDelta extends LlmEvent {
  final String text;
  const TextDelta(this.text);
}

/// 一次请求的 token 用量:**最终快照**,每次请求至多发出一次(流结束时)。
/// 网关在流中多次上报的累计 usage 由后端合并(取各字段最大)后只透出终值 ——
/// 消费方(主写/后台/压缩)按"每请求一次"累加,不得把流内多个快照再求和。
class UsageEvent extends LlmEvent {
  final TokenUsage usage;
  const UsageEvent(this.usage);
}

class DoneEvent extends LlmEvent {
  const DoneEvent();
}

class ErrorEvent extends LlmEvent {
  final String message;

  /// 上游故障的稳定分类(2026-09-28 批):由后端按状态码/错误类型/正文特征
  /// 归类;null 表示无从归类(如传输层异常,消费方可视作 transient 处理)。
  /// 重试策略、测试连接与错误横幅读这个字段,不猜报错文本。
  final UpstreamErrorKind? kind;

  /// HTTP 状态码(非 200 响应时);流中途错误负载为 null。
  final int? statusCode;

  const ErrorEvent(this.message, {this.kind, this.statusCode});
}

abstract class LlmBackend {
  String get id;
  Stream<LlmEvent> generate(LlmRequest request);
}
