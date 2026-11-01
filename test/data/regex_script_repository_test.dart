import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/regex_script_repository.dart';
import 'package:microscritt/models/regex_script.dart';
import '../support/test_database.dart';

void main() {
  test('insert assigns sequential positions, all returns position order', () async {
    final db = await openTestDb();
    final repo = RegexScriptRepository(db);
    await repo.insert(const RegexScript(name: 'first', findRegex: 'a', replace: 'b'));
    await repo.insert(const RegexScript(name: 'second', findRegex: 'c', replace: 'd'));

    final all = await repo.all();
    expect(all.map((s) => s.name).toList(), ['first', 'second']);
    expect(all.map((s) => s.position).toList(), [0, 1]);
  });

  test('all honors explicit position ordering', () async {
    final db = await openTestDb();
    final repo = RegexScriptRepository(db);
    final id1 = await repo.insert(const RegexScript(name: 'a', findRegex: 'a', replace: 'a'));
    final id2 = await repo.insert(const RegexScript(name: 'b', findRegex: 'b', replace: 'b'));
    // 手动把 b 挪到最前(库里可能还有前面测试留下的行,只断言相对顺序)。
    await repo.update(RegexScript(id: id2, name: 'b', findRegex: 'b', replace: 'b', position: -1));
    await repo.update(RegexScript(id: id1, name: 'a', findRegex: 'a', replace: 'a', position: 5));

    final names = (await repo.all()).map((s) => s.name).toList();
    expect(names.first, 'b');
    expect(names.indexOf('b') < names.indexOf('a'), isTrue);
  });

  test('update and delete roundtrip', () async {
    final db = await openTestDb();
    final repo = RegexScriptRepository(db);
    final id = await repo.insert(const RegexScript(name: 'a', findRegex: 'x', replace: 'y'));
    await repo.update(RegexScript(id: id, name: 'a2', findRegex: 'p', replace: 'q', enabled: false, position: 3));

    var all = await repo.all();
    final s = all.singleWhere((x) => x.id == id);
    expect(s.name, 'a2');
    expect(s.findRegex, 'p');
    expect(s.replace, 'q');
    expect(s.enabled, isFalse);
    expect(s.position, 3);

    await repo.delete(id);
    expect((await repo.all()).where((x) => x.id == id), isEmpty);
  });
}
