import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/token_usage.dart';

void main() {
  test('parses OpenAI usage with cached tokens', () {
    final u = TokenUsage.fromOpenAi({
      'prompt_tokens': 1000,
      'completion_tokens': 50,
      'prompt_tokens_details': {'cached_tokens': 800},
    });
    expect(u.inputTokens, 1000);
    expect(u.outputTokens, 50);
    expect(u.cachedInputTokens, 800);
    expect(u.uncachedInputTokens, 200);
  });

  test('parses Anthropic usage with cache read/creation', () {
    final u = TokenUsage.fromAnthropic({
      'input_tokens': 900,
      'output_tokens': 40,
      'cache_creation_input_tokens': 100,
      'cache_read_input_tokens': 500,
    });
    expect(u.inputTokens, 900);
    // 命中口径只计 cache_read:新建缓存段(creation)是写入不是命中。
    expect(u.cachedInputTokens, 500);
    expect(u.uncachedInputTokens, 400); // 未命中发送 300 + 新建缓存段 100
  });
}
