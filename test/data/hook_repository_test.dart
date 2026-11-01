// Hook 仓储:触发点过滤、增删改往返与默认 main/jump 种子。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/hook_repository.dart';
import 'package:microscritt/models/hook.dart';
import '../support/test_database.dart';

void main() {
  test('fresh database seeds the default main/jump input hooks', () async {
    final db = await openTestDb();
    final seeded = await HookRepository(db).byTriggerPoint(HookTriggerPoint.beforeContextAssembly);
    expect(
      seeded.map((h) => h.name),
      containsAll(['主导模式(main)', '时间快进(jump)']),
    );
    // 种子默认启用,发送链路(_runHooks)立即可用。
    expect(seeded.where((h) => h.name.startsWith('主导模式')).single.enabled, isTrue);
  });

  test('byTriggerPoint returns only hooks for that point', () async {
    final db = await openTestDb();
    final repo = HookRepository(db);
    await db.db.insert('hooks', {'name': 'a', 'trigger_point': 'beforeGenerate', 'js_code': '1'});
    await db.db.insert('hooks', {'name': 'b', 'trigger_point': 'afterStream', 'js_code': '2'});

    final before = await repo.byTriggerPoint(HookTriggerPoint.beforeGenerate);
    expect(before.map((h) => h.name).toList(), ['a']);
    expect(before.single.jsCode, '1');
  });

  test('insert and all roundtrip hooks', () async {
    final db = await openTestDb();
    final repo = HookRepository(db);
    final id = await repo.insert(const Hook(
      name: 'rewrite',
      triggerPoint: HookTriggerPoint.afterStream,
      jsCode: '__ctx.text = "x"',
    ));
    final all = await repo.all();
    final hook = all.singleWhere((h) => h.id == id);
    expect(hook.name, 'rewrite');
    expect(hook.triggerPoint, HookTriggerPoint.afterStream);
    expect(hook.enabled, isTrue);
  });

  test('update modifies hook fields', () async {
    final db = await openTestDb();
    final repo = HookRepository(db);
    final id = await repo.insert(const Hook(
      name: 'a',
      triggerPoint: HookTriggerPoint.beforePersist,
      jsCode: '1',
    ));
    await repo.update(Hook(id: id, name: 'b', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '2', enabled: false));

    final hook = (await repo.all()).singleWhere((h) => h.id == id);
    expect(hook.name, 'b');
    expect(hook.triggerPoint, HookTriggerPoint.beforeGenerate);
    expect(hook.jsCode, '2');
    expect(hook.enabled, isFalse);
  });

  test('delete removes the hook', () async {
    final db = await openTestDb();
    final repo = HookRepository(db);
    final id = await repo.insert(const Hook(name: 'gone', triggerPoint: HookTriggerPoint.afterStream, jsCode: ''));
    await repo.delete(id);
    expect((await repo.all()).where((h) => h.id == id), isEmpty);
  });
}
