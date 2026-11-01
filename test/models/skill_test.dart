// 技能模型测试:map 往返与历史行缺 description/enabled 列的兜底。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/skill.dart';

void main() {
  test('toMap/fromMap round-trips all fields', () {
    const s = Skill(
      id: 3,
      name: 'combat',
      description: 'writing fight scenes',
      content: 'Use vivid blows',
      enabled: true,
    );
    final r = Skill.fromMap(s.toMap());
    expect(r.id, 3);
    expect(r.name, 'combat');
    expect(r.description, 'writing fight scenes');
    expect(r.content, 'Use vivid blows');
    expect(r.enabled, isTrue);
  });

  test('enabled defaults to true', () {
    const s = Skill(name: 'n', content: 'c');
    expect(s.enabled, isTrue);
  });

  test('description defaults to empty (worldbook-imported skills have none)', () {
    const s = Skill(name: 'imported', content: 'c');
    expect(s.description, isEmpty);
  });

  test('fromMap tolerates legacy rows without description/enabled columns', () {
    final r = Skill.fromMap({'id': 1, 'name': 'n', 'content': 'c'});
    expect(r.description, isEmpty);
    expect(r.enabled, isTrue);
  });
}
