/// 一次请求的 token 用量快照与协议字段解析。
///
/// 用量只用于展示与上下文占用估算,不参与计费;所有字段缺省为 0,
/// 未知/缺失字段不得导致请求失败。
library;

/// 一次请求的 token 用量终值快照。
class TokenUsage {
  /// 输入 token 数(协议原始口径)。
  final int inputTokens;

  /// 输出 token 数。
  final int outputTokens;

  /// 命中提示缓存的输入 token 数。
  final int cachedInputTokens;

  const TokenUsage({this.inputTokens = 0, this.outputTokens = 0, this.cachedInputTokens = 0});

  /// 未命中缓存的输入 token 数。
  int get uncachedInputTokens => inputTokens - cachedInputTokens;

  /// 合并**同一次请求**内的多个用量快照:各字段取最大。
  ///
  /// 流式响应里网关上报的 usage 是请求内单调递增的**累计快照**,不是增量:
  /// Anthropic 在 message_start 报 input、message_delta 报最终 output;
  /// 不少 OpenAI 兼容网关(尤其推理模型中转)在**每个 SSE 块**都附带累计
  /// usage。快照取最大即终值;若按增量求和,"每块一报"的网关会把几千个块
  /// 的累计值叠成百万/千万级虚高用量(实测两轮对话 input/out 冲到几千万)。
  TokenUsage mergeMax(TokenUsage other) => TokenUsage(
        inputTokens: inputTokens > other.inputTokens ? inputTokens : other.inputTokens,
        outputTokens: outputTokens > other.outputTokens ? outputTokens : other.outputTokens,
        cachedInputTokens:
            cachedInputTokens > other.cachedInputTokens ? cachedInputTokens : other.cachedInputTokens,
      );

  /// 解析 OpenAI 兼容响应的 `usage` 对象;缺失字段按 0 处理。
  factory TokenUsage.fromOpenAi(Map<String, dynamic> json) => TokenUsage(
        inputTokens: json['prompt_tokens'] as int? ?? 0,
        outputTokens: json['completion_tokens'] as int? ?? 0,
        cachedInputTokens: ((json['prompt_tokens_details'] as Map<String, dynamic>?)?['cached_tokens'] as int?) ?? 0,
      );

  /// 解析 Anthropic Messages 的 usage;命中只计 cache_read,不计缓存写入。
  factory TokenUsage.fromAnthropic(Map<String, dynamic> json) => TokenUsage(
        inputTokens: json['input_tokens'] as int? ?? 0,
        outputTokens: json['output_tokens'] as int? ?? 0,
        // 命中口径:只取 cache_read。新建缓存段(cache_creation)是写入不是命中,
        // 计入会让"首次建缓存"的轮次显示虚高的命中率;uncachedInputTokens
        // (= input − read) 从而等于"未命中发送 + 新建缓存段"两部分。
        cachedInputTokens: json['cache_read_input_tokens'] as int? ?? 0,
      );
}
