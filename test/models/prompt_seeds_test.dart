// 内置预设提示词种子测试:类型分派、默认启用、位置连续与内容红线。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/prompt_item.dart';
import 'package:microscritt/models/prompt_seeds.dart';

void main() {
  /// 约束输出形式的 rule 类条目。
  const ruleNames = {'格式生成指导'};

  test('default seeds: 2 entries, all enabled, rule/preset split', () {
    final seeds = kDefaultPromptSeeds;
    expect(seeds.length, 2);

    // rule/preset 类型分派:rule 类随规则段组装,其余随预设段组装。
    expect(
      seeds.where((s) => ruleNames.contains(s.name)).every((s) => s.kind == PromptItemKind.rule),
      isTrue,
    );
    expect(
      seeds.where((s) => !ruleNames.contains(s.name)).every((s) => s.kind == PromptItemKind.preset),
      isTrue,
    );
    // 每条都有非空显示名与正文。
    expect(seeds.every((s) => s.name.isNotEmpty), isTrue);
    expect(seeds.every((s) => s.text.trim().isNotEmpty), isTrue);
    // 名称唯一(种子按 name 幂等落库依赖此性质)。
    expect(seeds.map((s) => s.name).toSet().length, seeds.length);
    // 位置连续可排序。
    final positions = seeds.map((s) => s.position).toList()..sort();
    expect(positions, List.generate(seeds.length, (i) => i));

    // 全部默认启用。
    expect(seeds.every((s) => s.enabled), isTrue);

    // 顺序:角色扮演基调最前,格式生成指导随后。
    expect(seeds[0].name, '角色扮演基调');
    expect(seeds[1].name, '格式生成指导');
  });

  test('seeds contain no third-party or restricted content markers', () {
    // 开源化红线:内置种子不得包含第三方项目标记、破限/NSFW 指令与
    // 「12岁即为成年」一类不当条款。
    final all = kDefaultPromptSeeds.map((s) => s.text).join('\n');
    for (final banned in [
      'RP-Hub', 'Roleplay Hub', 'roleplay_hub',
      '破限', 'NSFW', 'nsfw',
      '12岁', '12 岁',
    ]) {
      expect(all.contains(banned), isFalse, reason: '种子不得包含「$banned」');
    }
    expect(
      kDefaultPromptSeeds.map((s) => s.name).join('\n').contains('NSFW'),
      isFalse,
    );
  });

  test('rule seeds wrap their directive in a lowercase tag block', () {
    for (final name in ruleNames) {
      final seed = kDefaultPromptSeeds.firstWhere((s) => s.name == name);
      expect(seed.text.startsWith('<'), isTrue, reason: '$name 应以标签块开头');
      expect(seed.text.contains('</'), isTrue, reason: '$name 应闭合标签块');
    }
  });

  test('seeds round-trip through toMap/fromMap preserving name', () {
    final seed = kDefaultPromptSeeds.firstWhere((s) => s.name == '角色扮演基调');
    final fromMap = PromptItem.fromMap(seed.toMap());
    expect(fromMap.name, '角色扮演基调');
    expect(fromMap.text, seed.text);
    expect(fromMap.enabled, isTrue);
    expect(fromMap.kind, PromptItemKind.preset);
  });
}
