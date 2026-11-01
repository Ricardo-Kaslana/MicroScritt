// 技能目录仓储:增删改、启停过滤与按名幂等导入。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/models/skill.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late SkillRepository skills;

  setUp(() async {
    db = await openTestDb();
    skills = SkillRepository(db);
  });

  // inMemoryDatabasePath 是共享缓存内存库:不关连接,行会跨测试泄漏。
  tearDown(() => db.db.close());

  test('all returns inserted skills ordered by id', () async {
    await skills.insert(const Skill(name: 'combat', description: 'fighting', content: 'vivid blows'));
    await skills.insert(const Skill(name: 'cooking', description: 'meals', content: 'rich flavor'));
    final all = await skills.all();
    expect(all.map((s) => s.name).toList(), ['combat', 'cooking']);
    expect(all.first.enabled, isTrue);
  });

  test('allEnabled filters on the enabled switch', () async {
    await skills.insert(const Skill(name: 'on', content: 'c', enabled: true));
    await skills.insert(const Skill(name: 'off', content: 'c', enabled: false));
    expect((await skills.all()).length, 2);
    expect((await skills.allEnabled()).map((s) => s.name), ['on']);
  });

  test('update rewrites all fields; setEnabled toggles only the flag', () async {
    final id = await skills.insert(const Skill(name: 'a', description: 'd', content: 'c'));
    await skills.update(Skill(id: id, name: 'b', description: '', content: 'c2', enabled: false));
    final updated = (await skills.all()).single;
    expect(updated.name, 'b');
    expect(updated.description, isEmpty);
    expect(updated.content, 'c2');
    expect(updated.enabled, isFalse);

    await skills.setEnabled(id, true);
    expect((await skills.all()).single.enabled, isTrue);
    expect((await skills.all()).single.name, 'b');
  });

  test('delete removes the skill', () async {
    final id = await skills.insert(const Skill(name: 'gone', content: 'c'));
    await skills.delete(id);
    expect(await skills.all(), isEmpty);
  });

  test('importAll is idempotent per name and reports skipped duplicates', () async {
    final first = await skills.importAll([
      const Skill(name: 'combat', content: 'c1'),
      const Skill(name: 'cooking', content: 'c2'),
    ]);
    expect(first, (2, 0));

    // 同名跳过(内容不同也不覆盖);新名字照常导入。
    final second = await skills.importAll([
      const Skill(name: 'combat', content: 'different'),
      const Skill(name: 'magic', content: 'c3'),
    ]);
    expect(second, (1, 1));

    final all = await skills.all();
    expect(all.map((s) => s.name), ['combat', 'cooking', 'magic']);
    // 同名去重:combat 内容保持首次导入的版本。
    expect(all.firstWhere((s) => s.name == 'combat').content, 'c1');
  });

  test('importAll can import disabled (legacy session-archive path)', () async {
    final (imported, _) = await skills.importAll([const Skill(name: 'old', content: 'c')], enabled: false);
    expect(imported, 1);
    expect((await skills.allEnabled()), isEmpty);
    expect((await skills.all()).single.enabled, isFalse);
  });
}
