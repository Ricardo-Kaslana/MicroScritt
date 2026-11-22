// @提及解析与候选技能筛选:光标定位、空白截断、前缀大小写与启用过滤。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/state/skill_suggestions.dart';

void main() {
  test('skillMentionAt locates the open @ mention before the caret', () {
    expect(skillMentionAt('', 0), isNull);
    expect(skillMentionAt('你好', 2), isNull);
    expect(
      skillMentionAt('@', 1),
      const SkillMentionQuery(start: 0, query: ''),
    );
    expect(
      skillMentionAt('你好 @剑', 5),
      const SkillMentionQuery(start: 3, query: '剑'),
    );
    // 取最近一个 @;更早的提及不再参与。
    expect(
      skillMentionAt('@甲 和 @乙', 7),
      const SkillMentionQuery(start: 5, query: '乙'),
    );
  });

  test('skillMentionAt stops at whitespace and ignores @ after the caret', () {
    expect(skillMentionAt('@剑 术', 4), isNull);
    expect(skillMentionAt('abc @', 3), isNull);
    expect(
      skillMentionAt('@剑术', 2),
      const SkillMentionQuery(start: 0, query: '剑'),
    );
  });

  test('skillMentionAt clamps out-of-range cursors', () {
    expect(
      skillMentionAt('@剑', 99),
      const SkillMentionQuery(start: 0, query: '剑'),
    );
    expect(skillMentionAt('@剑', -1), isNull);
  });

  test(
    'suggestedSkills filters disabled, unnamed and non-matching entries',
    () {
      const skills = [
        Skill(name: '剑术', content: 'x'),
        Skill(name: '剑舞', content: 'x'),
        Skill(name: '禁用技能', enabled: false, content: 'x'),
        Skill(name: '   ', content: 'x'),
        Skill(name: 'Magic', content: 'x'),
      ];

      expect(suggestedSkills(skills, '').map((s) => s.name), [
        '剑术',
        '剑舞',
        'Magic',
      ]);
      expect(suggestedSkills(skills, '剑').map((s) => s.name), ['剑术', '剑舞']);
      expect(suggestedSkills(skills, 'm').map((s) => s.name), ['Magic']);
      expect(suggestedSkills(skills, '不存在'), isEmpty);
    },
  );
}
