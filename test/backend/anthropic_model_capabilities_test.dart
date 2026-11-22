// Anthropic 模型代际解析:legacy/adaptive 边界、日期后缀、off 策略与 effort 映射。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/anthropic_model_capabilities.dart';
import 'package:microscritt/models/app_settings.dart';

void main() {
  AnthropicModelCapabilities capabilities(String modelId) =>
      resolveAnthropicModelCapabilities(modelId);

  test('Claude 4.5 and earlier stay on legacy budgets', () {
    for (final id in [
      'claude-sonnet-4-5',
      'claude-opus-4-5-20251101',
      'claude-sonnet-4-20250514',
      'claude-3-5-sonnet-20241022',
      'claude-3-7-sonnet-20250219',
      'unknown-model',
    ]) {
      expect(
        capabilities(id).style,
        AnthropicThinkingStyle.legacyBudget,
        reason: id,
      );
    }
  });

  test('Claude 4.6+ and 5+ use adaptive thinking', () {
    for (final id in [
      'claude-opus-4-6-v1',
      'claude-sonnet-4-6',
      'claude-opus-4-7',
      'claude-opus-4-8',
      'claude-opus-5',
      'claude-sonnet-5',
      'claude-haiku-5-5',
      'anthropic.claude-sonnet-5-5',
      'claude-fable-5.2',
      'claude-mythos-5-1',
    ]) {
      expect(
        capabilities(id).style,
        AnthropicThinkingStyle.adaptive,
        reason: id,
      );
    }
  });

  test('8-digit date suffixes do not count as minor versions', () {
    // 4.0 ≠ 4.20:日期后缀必须整体忽略。
    expect(
      capabilities('anthropic.claude-sonnet-4-20250514').style,
      AnthropicThinkingStyle.legacyBudget,
    );
    expect(
      capabilities('claude-sonnet-4-6-20250514').style,
      AnthropicThinkingStyle.adaptive,
    );
  });

  test('off mode follows model-specific thinking restrictions', () {
    expect(capabilities('claude-opus-4-6').offMode, AnthropicOffMode.disabled);
    expect(capabilities('claude-opus-4-8').offMode, AnthropicOffMode.disabled);
    expect(capabilities('claude-sonnet-5').offMode, AnthropicOffMode.disabled);
    expect(capabilities('claude-haiku-5-5').offMode, AnthropicOffMode.disabled);
    expect(
      capabilities('claude-sonnet-5-5').offMode,
      AnthropicOffMode.betweenTools,
    );
    expect(capabilities('claude-opus-5-5').offMode, AnthropicOffMode.omit);
    expect(capabilities('claude-fable-5-2').offMode, AnthropicOffMode.omit);
    expect(capabilities('claude-mythos-5-1').offMode, AnthropicOffMode.omit);
  });

  test('adaptive effort maps minimal to low and off to null', () {
    expect(adaptiveEffortOf(ReasoningLevel.off), isNull);
    expect(adaptiveEffortOf(ReasoningLevel.minimal), 'low');
    expect(adaptiveEffortOf(ReasoningLevel.low), 'low');
    expect(adaptiveEffortOf(ReasoningLevel.medium), 'medium');
    expect(adaptiveEffortOf(ReasoningLevel.high), 'high');
    expect(adaptiveEffortOf(ReasoningLevel.xhigh), 'xhigh');
    expect(adaptiveEffortOf(ReasoningLevel.max), 'max');
  });
}
