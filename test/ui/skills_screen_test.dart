import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/skills_screen.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: SkillsScreen()),
  );

  testWidgets('empty state shows guidance', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('暂无技能'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('lists skills, toggles enablement and shows description fallback', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await SkillRepository(db).insert(const Skill(name: '战斗描写', description: '生动的打斗', content: 'c1'));
      await SkillRepository(db).insert(const Skill(name: '导入技能', content: 'c2', enabled: false));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('战斗描写'), findsOneWidget);
    expect(find.text('生动的打斗'), findsOneWidget);
    // 无描述的世界书导入技能显示占位。
    expect(find.text('(无描述)'), findsOneWidget);

    // 关掉「战斗描写」的开关。
    await tester.runAsync(() async {
      final switchFinder = find.descendant(
        of: find.ancestor(of: find.text('战斗描写'), matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.tap(switchFinder);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    late final List<Skill> all;
    await tester.runAsync(() async {
      all = await SkillRepository(db).all();
    });
    expect(all.firstWhere((s) => s.name == '战斗描写').enabled, isFalse);
    expect(all.firstWhere((s) => s.name == '导入技能').enabled, isFalse);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('deletes a skill via the visible row delete button', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await SkillRepository(db).insert(const Skill(name: '战斗描写', content: 'c1'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 点行内可见的删除按钮 → 弹确认框。
    final delFinder = find.descendant(
      of: find.ancestor(of: find.text('战斗描写'), matching: find.byType(ListTile)),
      matching: find.byIcon(Icons.delete_outline),
    );
    expect(delFinder, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(delFinder);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.text('删除技能?'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if ((await db.db.query('skills')).isEmpty) break;
      }
      await tester.pumpAndSettle();
    });

    late final List<Skill> all;
    await tester.runAsync(() async {
      all = await SkillRepository(db).all();
    });
    expect(all, isEmpty);
    expect(find.text('暂无技能'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('creates a skill via the editor with name + content required', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    await tester.tap(find.widgetWithText(FloatingActionButton, '新建技能'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byKey(const ValueKey('field_名称 *')), '烹饪指南');
    await tester.enterText(find.byKey(const ValueKey('field_描述')), '做饭时参考');
    await tester.enterText(find.byKey(const ValueKey('field_内容 *')), '所有菜肴都要写得香气扑鼻');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      final container = ProviderScope.containerOf(tester.element(find.byType(SkillsScreen, skipOffstage: false)));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(skillsProvider);
        if (st.value?.any((s) => s.name == '烹饪指南') ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    expect(find.text('烹饪指南'), findsOneWidget);
    expect(find.text('做饭时参考'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('imports worldbook entries as description-less global skills', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: '导入源角色X'));
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, name: '王都', keys: ['王都'], constant: true, content: '王都的描述。'),
        WorldbookEntry(characterId: 0, keys: ['圣剑'], content: '圣剑的传说。'),
      ]);
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 打开导入入口 → 选择角色。(DB 查询需 runAsync 窗口驱动)
    await tester.tap(find.byTooltip('从世界书导入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    // 角色选择页不暴露内部 id。
    expect(find.textContaining('id '), findsNothing);
    await tester.tap(find.text('导入源角色X'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump();

    // 勾选两个世界书条目(点行内复选框;点行本体是查看内容)。
    Future<void> check(String label) async {
      final cb = find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        matching: find.byType(Checkbox),
      );
      await tester.tap(cb);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    await check('王都');
    await check('圣剑');

    await tester.runAsync(() async {
      await tester.pumpAndSettle();
      final fab = find.widgetWithText(FloatingActionButton, '导入选中 (2)');
      await tester.ensureVisible(fab);
      await tester.tap(fab, warnIfMissed: false);
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final rows = await db.db.query('skills', where: "name IN ('王都', '圣剑')");
        if (rows.length == 2) break;
      }
      await tester.pumpAndSettle();
    });

    late final List<Skill> imported;
    await tester.runAsync(() async {
      imported = await SkillRepository(db).all();
    });
    expect(imported.map((s) => s.name).toSet(), {'王都', '圣剑'});
    // 世界书导入的技能没有描述,且默认启用(全局生效)。
    expect(imported.every((s) => s.description.isEmpty), isTrue);
    expect(imported.every((s) => s.enabled), isTrue);
    expect(imported.firstWhere((s) => s.name == '王都').content, '王都的描述。');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('entry picker supports select-all and clear-all', (tester) async {
    Future<void> seed() async {
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: '全选源角色Y'));
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, name: '王都', keys: ['王都'], constant: true, content: '王都的描述。'),
        WorldbookEntry(characterId: 0, keys: ['圣剑'], content: '圣剑的传说。'),
      ]);
    }

    await tester.runAsync(() async {
      db = await openTestDb();
      await seed();
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    await tester.tap(find.byTooltip('从世界书导入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.tap(find.text('全选源角色Y'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump();

    // 初始一个都没选。
    expect(find.widgetWithText(FloatingActionButton, '导入选中 (0)'), findsOneWidget);

    // 全选 → FAB 计数变 2,按钮文案变为「取消全选」。
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FloatingActionButton, '导入选中 (2)'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);

    // 取消全选 → 清空回 0。
    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FloatingActionButton, '导入选中 (0)'), findsOneWidget);
    expect(find.text('取消全选'), findsNothing);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('tapping an entry opens a viewer with its full content', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: '查看源角色Z'));
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, name: '王都', keys: ['王都'], constant: true, content: '王都的描述。'),
        WorldbookEntry(characterId: 0, keys: ['圣剑'], content: '圣剑的传说。'),
      ]);
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    await tester.tap(find.byTooltip('从世界书导入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.tap(find.text('查看源角色Z'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump();

    // 点条目行 → 底部弹层显示完整内容(条目列表本身不再截断展示内容)。
    await tester.tap(find.text('王都'));
    await tester.pumpAndSettle();

    expect(find.text('王都的描述。'), findsOneWidget);
    // 常驻条目标注触发方式。
    expect(find.text('常驻 · 无需关键词'), findsOneWidget);
    // 未点开的条目全文不出现在弹层里。
    expect(find.text('圣剑的传说。'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });
}
