/// 一次请求的 token 用量快照与协议字段解析。
///
/// 用量只用于展示与上下文占用估算,不参与计费;所有字段缺省为 0,
/// 未知/缺失字段不得导致请求失败。
library;

/// 一次请求的 token 用量终值快照。
class TokenUsage {
  /// 输入 token 总数(含缓存命中与缓存写入;各协议已归一成同一口径)。
  final int inputTokens;

  /// 输出 token 数。
  final int outputTokens;

  /// 命中提示缓存的输入 token 数。
  final int cachedInputTokens;

  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
  });

  /// 未命中缓存的输入 token 数。
  int get uncachedInputTokens => inputTokens - cachedInputTokens;

  /// 是否上报了任何非零用量(统计里 `reported` 标志的口径)。
  bool get hasAny =>
      inputTokens > 0 || outputTokens > 0 || cachedInputTokens > 0;

  /// 两段用量求和:用于跨尝试/跨请求累加。
  /// 同一次请求内多个累计快照的合并用 [mergeMax],两者不可互换。
  TokenUsage operator +(TokenUsage other) => TokenUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
  );

  /// 合并**同一次请求**内的多个用量快照:各字段取最大。
  ///
  /// 流式响应里网关上报的 usage 是请求内单调递增的**累计快照**,不是增量:
  /// Anthropic 在 message_start 报 input、message_delta 报最终 output;
  /// 不少 OpenAI 兼容网关(尤其推理模型中转)在**每个 SSE 块**都附带累计
  /// usage。快照取最大即终值;若按增量求和,"每块一报"的网关会把几千个块
  /// 的累计值叠成百万/千万级虚高用量(实测两轮对话 input/out 冲到几千万)。
  TokenUsage mergeMax(TokenUsage other) => TokenUsage(
    inputTokens: inputTokens > other.inputTokens
        ? inputTokens
        : other.inputTokens,
    outputTokens: outputTokens > other.outputTokens
        ? outputTokens
        : other.outputTokens,
    cachedInputTokens: cachedInputTokens > other.cachedInputTokens
        ? cachedInputTokens
        : other.cachedInputTokens,
  );

  /// 解析 OpenAI 兼容响应的 `usage` 对象;缺失字段按 0 处理。
  factory TokenUsage.fromOpenAi(Map<String, dynamic> json) => TokenUsage(
    inputTokens: json['prompt_tokens'] as int? ?? 0,
    outputTokens: json['completion_tokens'] as int? ?? 0,
    cachedInputTokens:
        ((json['prompt_tokens_details']
                as Map<String, dynamic>?)?['cached_tokens']
            as int?) ??
        0,
  );

  /// 解析 Anthropic Messages 的 usage。
  ///
  /// Anthropic 官方的 `input_tokens` **不含**缓存读写:缓存命中段记在
  /// `cache_read_input_tokens`、新建缓存段记在 `cache_creation_input_tokens`,
  /// 总输入必须是三者之和。只取 `input_tokens` 会让缓存命中的轮次显示成
  /// 极小的输入,命中率(cached / input)甚至超过 100%。
  factory TokenUsage.fromAnthropic(Map<String, dynamic> json) {
    final input = json['input_tokens'] as int? ?? 0;
    final cacheCreation = json['cache_creation_input_tokens'] as int? ?? 0;
    final cacheRead = json['cache_read_input_tokens'] as int? ?? 0;
    return TokenUsage(
      inputTokens: input + cacheCreation + cacheRead,
      outputTokens: json['output_tokens'] as int? ?? 0,
      // 命中口径仍只取 cache_read:新建缓存段是写入不是命中,计入会让
      // "首次建缓存"的轮次显示虚高的命中率。uncachedInputTokens
      // (= input − read) 从而等于"未命中发送 + 新建缓存段"两部分。
      cachedInputTokens: cacheRead,
    );
  }
}
