// 世界书页 widget 测试:条目列表与启停、批量启停、删除、新建条目与菜单入口。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/worldbook_screen.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  late AppDatabase db;
  late int charId;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(
      home: WorldbookScreen(characterId: charId, characterName: 'Alice'),
    ),
  );

  testWidgets('lists entries by name (fallback keys) and toggles enabled', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(
          characterId: 0,
          name: '被咒之剑',
          keys: ['圣剑', 'excalibur'],
          // 表单外字段 + extra 透传:启停后必须原样保留。
          caseSensitive: true,
          matchWholeWords: true,
          selective: true,
          secondaryKeys: ['白天'],
          content: '一段隐藏的内容',
          extra: {'probability': 60},
        ),
        WorldbookEntry(characterId: 0, keys: ['无名'], content: 'na'),
      ]);
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 有条目名时只显示名称;关键词/类型/内容摘要均不展示。
    expect(find.text('被咒之剑'), findsOneWidget);
    expect(find.textContaining('圣剑'), findsNothing);
    expect(find.textContaining('规则'), findsNothing);
    expect(find.textContaining('一段隐藏的内容'), findsNothing);
    // 名称为空时回退首关键词。
    expect(find.text('无名'), findsOneWidget);

    await tester.runAsync(() async {
      // 只点「被咒之剑」那行的开关(列表里有两条)。
      final switchFinder = find.descendant(
        of: find.ancestor(of: find.text('被咒之剑'), matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.tap(switchFinder);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    late final List<WorldbookEntry> entries;
    await tester.runAsync(() async {
      entries = await WorldbookRepository(db).byCharacter(charId);
    });
    final toggled = entries.singleWhere((e) => e.name == '被咒之剑');
    expect(toggled.enabled, isFalse);
    expect(entries.singleWhere((e) => e.name.isEmpty).enabled, isTrue);
    // 启停只翻 enabled:表单外的匹配语义字段与 extra 透传字段不再被重建抹掉
    //(旧实现逐字段重建,启停一次即丢)。
    expect(toggled.caseSensitive, isTrue);
    expect(toggled.matchWholeWords, isTrue);
    expect(toggled.selective, isTrue);
    expect(toggled.secondaryKeys, ['白天']);
    expect(toggled.extra, {'probability': 60});
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('deletes an entry via the visible row delete button', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(
          characterId: 0,
          name: '被咒之剑',
          keys: ['圣剑', 'excalibur'],
          content: '一段隐藏的内容',
        ),
        WorldbookEntry(characterId: 0, keys: ['无名'], content: 'na'),
      ]);
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 点「被咒之剑」行内可见的删除按钮 → 弹确认框。
    final delFinder = find.descendant(
      of: find.ancestor(of: find.text('被咒之剑'), matching: find.byType(ListTile)),
      matching: find.byIcon(Icons.delete_outline),
    );
    expect(delFinder, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(delFinder);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.text('删除条目?'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final rows = await WorldbookRepository(db).byCharacter(charId);
        if (rows.length == 1) break;
      }
      await tester.pumpAndSettle();
    });

    late final List<WorldbookEntry> entries;
    await tester.runAsync(() async {
      entries = await WorldbookRepository(db).byCharacter(charId);
    });
    // 只删掉目标条目,其余保留。
    expect(entries.single.name, isEmpty);
    expect(entries.single.keys, ['无名']);
    expect(find.text('被咒之剑'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('appbar menu enables/disables all entries at once', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(
          characterId: 0,
          name: '被咒之剑',
          keys: ['圣剑'],
          content: 'a',
          enabled: false,
          // 批量启停只动 enabled:其余匹配语义/extra 字段必须原样保留。
          caseSensitive: true,
          selective: true,
          secondaryKeys: ['白天'],
          extra: {'probability': 60},
        ),
        WorldbookEntry(characterId: 0, name: '盾', keys: ['盾'], content: 'b'),
      ]);
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.text('全部启用'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('全部启用'));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final rows = await WorldbookRepository(db).byCharacter(charId);
        if (rows.every((e) => e.enabled)) break;
      }
      await tester.pumpAndSettle();
    });

    late List<WorldbookEntry> entries;
    await tester.runAsync(() async {
      entries = await WorldbookRepository(db).byCharacter(charId);
    });
    expect(entries.every((e) => e.enabled), isTrue);
    final sword = entries.singleWhere((e) => e.name == '被咒之剑');
    expect(sword.caseSensitive, isTrue);
    expect(sword.selective, isTrue);
    expect(sword.secondaryKeys, ['白天']);
    expect(sword.extra, {'probability': 60});

    // 全部停用。
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部停用'));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final rows = await WorldbookRepository(db).byCharacter(charId);
        if (rows.every((e) => !e.enabled)) break;
      }
      await tester.pumpAndSettle();
    });
    await tester.runAsync(() async {
      entries = await WorldbookRepository(db).byCharacter(charId);
    });
    expect(entries.every((e) => !e.enabled), isTrue);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('creates an entry via the editor', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('暂无世界书条目'), findsOneWidget);

    await tester.tap(find.widgetWithText(FloatingActionButton, '新建条目'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byKey(const ValueKey('field_名称')), '古龙传说');
    await tester.enterText(find.byKey(const ValueKey('field_关键词(逗号分隔)')), '龙, dragon');
    await tester.enterText(find.byKey(const ValueKey('field_内容 *')), '山谷里睡着一条古龙');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      final container = ProviderScope.containerOf(tester.element(find.byType(WorldbookScreen, skipOffstage: false)));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(worldbookProvider(charId));
        if (st.value?.any((e) => e.content.contains('古龙')) ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    // 列表只显示名称,不显示关键词/内容。
    expect(find.text('古龙传说'), findsOneWidget);
    expect(find.text('龙, dragon'), findsNothing);
    late final List<WorldbookEntry> entries;
    await tester.runAsync(() async {
      entries = await WorldbookRepository(db).byCharacter(charId);
    });
    expect(entries.single.name, '古龙传说');
    expect(entries.single.keys, ['龙', 'dragon']);
    expect(entries.single.content, '山谷里睡着一条古龙');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('appbar menu offers import and export of entries', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, keys: ['圣剑'], content: 'a'),
      ]);
    });
    await tester.pumpWidget(harness());
    // 按条件等首次加载收敛,不用固定延时(并发跑全量套件时不够)。
    await waitUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await waitUntil(tester, () => find.text('导入条目').evaluate().isNotEmpty);
    // 导入项恒在;导出/批量项只在有条目时出现。
    expect(find.text('导入条目'), findsOneWidget);
    expect(find.text('导出条目(JSON)'), findsOneWidget);
    expect(find.text('全部启用'), findsOneWidget);
    expect(find.text('全部停用'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('empty state offers an import action and the menu hides export', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });
    await tester.pumpWidget(harness());
    await waitUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);

    expect(find.text('暂无世界书条目'), findsOneWidget);
    // 空书时唯一的入口是导入:空态按钮与菜单项都在。
    expect(find.text('导入条目'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await waitUntil(tester, () => find.text('导入条目').evaluate().length == 2);
    expect(find.text('导出条目(JSON)'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });
}
