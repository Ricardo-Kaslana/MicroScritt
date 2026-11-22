// token 用量解析测试:OpenAI/Anthropic 缓存口径与未命中输入计算。
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
    // 官方 input_tokens 不含缓存读写:总输入 = 发送 + 新建 + 命中 = 1500。
    expect(u.inputTokens, 1500);
    // 命中口径只计 cache_read:新建缓存段(creation)是写入不是命中。
    expect(u.cachedInputTokens, 500);
    expect(u.uncachedInputTokens, 1000); // 未命中发送 900 + 新建缓存段 100
  });

  test('mergeMax keeps total-input semantics stable across snapshots', () {
    // message_start 报完整输入,message_delta 只报 output:合并后输入不变。
    final start = TokenUsage.fromAnthropic({
      'input_tokens': 900,
      'output_tokens': 1,
      'cache_creation_input_tokens': 100,
      'cache_read_input_tokens': 500,
    });
    final delta = TokenUsage.fromAnthropic({'output_tokens': 40});
    final merged = start.mergeMax(delta);
    expect(merged.inputTokens, 1500);
    expect(merged.cachedInputTokens, 500);
    expect(merged.outputTokens, 40);
    expect(merged.uncachedInputTokens, 1000);
  });
}
