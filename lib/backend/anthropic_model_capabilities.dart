/// Anthropic 模型代际对应的 thinking 参数能力。
///
/// 只按模型 ID 做保守识别:自适应思考从 Claude 4.6 起可用,Claude 5+ 默认
/// 开启;未知或自定义别名回落旧式 `enabled + budget_tokens`,保持既有网关
/// 行为。模型能力只能靠命名推断,无法从响应中动态探测。
library;

import '../models/app_settings.dart';

/// thinking 参数的代际风格。
enum AnthropicThinkingStyle {
  /// Claude 4.5 及更早:固定 `budget_tokens` 预算。
  legacyBudget,

  /// Claude 4.6+:`type: adaptive` + 顶层 `output_config.effort`。
  adaptive,
}

/// 自适应模型在推理等级为 off 时的关闭方式。
enum AnthropicOffMode {
  /// 无法关闭思考:省略 thinking 且省略 temperature,避免 400。
  omit,

  /// 支持 `thinking: {type: "disabled"}`。
  disabled,

  /// Sonnet 5.5 专用:回复前不思考、工具间仍可思考。
  betweenTools,
}

/// 一个 Anthropic 模型 ID 对应的 thinking 能力。
class AnthropicModelCapabilities {
  final AnthropicThinkingStyle style;
  final AnthropicOffMode offMode;

  const AnthropicModelCapabilities({
    required this.style,
    required this.offMode,
  });

  bool get isAdaptive => style == AnthropicThinkingStyle.adaptive;
}

/// 只识别 family-first 的 Claude ID(如 `claude-opus-4-6-v1`、
/// `anthropic.claude-sonnet-4-20250514`);3.x 的 `claude-3-5-sonnet`
/// 与未知别名一律回落 legacy。
final RegExp _claudeModelPattern = RegExp(
  r'claude-(opus|sonnet|haiku|fable|mythos)-(\d+)(?:[-.](\d{1,2})(?!\d))?',
  caseSensitive: false,
);

/// 按模型 ID 推断代际;无法识别时返回 legacy,不猜测新协议。
AnthropicModelCapabilities resolveAnthropicModelCapabilities(String modelId) {
  final match = _claudeModelPattern.firstMatch(modelId.toLowerCase());
  if (match == null) {
    return const AnthropicModelCapabilities(
      style: AnthropicThinkingStyle.legacyBudget,
      offMode: AnthropicOffMode.omit,
    );
  }
  final family = match.group(1)!.toLowerCase();
  final major = int.tryParse(match.group(2)!) ?? 0;
  // `(?!\d)` 让 8 位日期后缀不参与 minor:`claude-sonnet-4-20250514` 是 4.0。
  final minor = int.tryParse(match.group(3) ?? '') ?? 0;
  final adaptive = major >= 5 || (major == 4 && minor >= 6);
  if (!adaptive) {
    return const AnthropicModelCapabilities(
      style: AnthropicThinkingStyle.legacyBudget,
      offMode: AnthropicOffMode.omit,
    );
  }
  return AnthropicModelCapabilities(
    style: AnthropicThinkingStyle.adaptive,
    offMode: _offModeFor(family, major, minor),
  );
}

AnthropicOffMode _offModeFor(String family, int major, int minor) {
  if (major < 5) return AnthropicOffMode.disabled;
  // 这些 5.x 型号拒绝 disabled;Sonnet 5.5 用 between_tools 作为最低档。
  if (family == 'sonnet' && minor >= 5) return AnthropicOffMode.betweenTools;
  if (family == 'opus' && minor >= 5) return AnthropicOffMode.omit;
  if (family == 'fable' || family == 'mythos') return AnthropicOffMode.omit;
  return AnthropicOffMode.disabled;
}

/// 推理档位 → `output_config.effort`;off 无对应值。
///
/// Anthropic 没有 `minimal` 档,最低的显式 effort 是 `low`,因此 minimal
/// 与 low 发同一个值。非 off 档按用户选择原样发送,不支持由上游报错。
String? adaptiveEffortOf(ReasoningLevel level) => switch (level) {
  ReasoningLevel.off => null,
  ReasoningLevel.minimal || ReasoningLevel.low => 'low',
  ReasoningLevel.medium => 'medium',
  ReasoningLevel.high => 'high',
  ReasoningLevel.xhigh => 'xhigh',
  ReasoningLevel.max => 'max',
};
