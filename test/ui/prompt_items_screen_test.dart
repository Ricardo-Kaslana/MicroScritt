// 提示词项管理页:种子列表、新建(规则项排在预设之后)、启用开关与删除。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/prompt_item_repository.dart';
import 'package:microscritt/models/prompt_item.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/prompt_items_screen.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: PromptItemsScreen()),
  );

  testWidgets('default presets are seeded and listed', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    // openTestDb 只清 provider/正则/生图插件种子,提示词种子保留:全新库
    // 自带 2 条(角色扮演基调 / 格式生成指导,均启用),空态不出现。
    expect(find.text('暂无提示词项'), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    final all = await tester.runAsync(() => PromptItemRepository(db).all());
    expect(all!.length, 2);
    // 「格式生成指导」为「规则」类,其余为「预设」类。
    final ruleNames = {'格式生成指导'};
    expect(all.where((i) => ruleNames.contains(i.name)).every((i) => i.kind == PromptItemKind.rule), isTrue);
    expect(all.where((i) => !ruleNames.contains(i.name)).every((i) => i.kind == PromptItemKind.preset), isTrue);
    expect(all.where((i) => i.enabled).length, 2);
    expect(all.map((i) => i.name).toSet(), contains('角色扮演基调'));
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('creates an item via the editor and lists it', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    await tester.tap(find.widgetWithText(FloatingActionButton, '新建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byKey(const ValueKey('field_内容 *')), '永远用中文回复');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      final container = ProviderScope.containerOf(tester.element(find.byType(PromptItemsScreen, skipOffstage: false)));
      // 轮询 provider 直到新项落地(invalidate 重载完成时机不稳定)
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(promptItemsProvider);
        if (st.value?.any((p) => p.text.contains('永远用中文回复')) ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    // 新项默认「规则」类,按 kind 排序落在默认预设之后,需滚动到再断言。
    final created = find.textContaining('永远用中文回复');
    final scrollable = find.byType(Scrollable).last;
    for (var i = 0; i < 30 && created.evaluate().isEmpty; i++) {
      await tester.drag(scrollable, const Offset(0, -300));
      await tester.pump();
    }
    expect(created, findsWidgets);
    // 新项带「规则」徽标;默认库里另有一条规则项,断言锚定到新项所在行。
    final newRow = find.ancestor(of: created, matching: find.byType(ListTile));
    expect(find.descendant(of: newRow, matching: find.text('规则')), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('toggle switch persists the enabled flag', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await PromptItemRepository(db).insert(const PromptItem(kind: PromptItemKind.rule, text: '可开关的项'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 规则项按 kind 排序落在默认预设之后,先滚动到可见。
    final togglable = find.textContaining('可开关的项');
    final scrollable = find.byType(Scrollable).last;
    for (var i = 0; i < 30 && togglable.evaluate().isEmpty; i++) {
      await tester.drag(scrollable, const Offset(0, -300));
      await tester.pump();
    }
    await tester.runAsync(() async {
      // 开关可能落在视图底部被 FAB 遮住;先 ensureVisible 滚进可视区再点。
      final switchFinder = find.descendant(
        of: find.ancestor(of: find.textContaining('可开关的项'), matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(switchFinder);
      await tester.pump();
      await tester.tap(switchFinder);
      final container = ProviderScope.containerOf(tester.element(find.byType(PromptItemsScreen, skipOffstage: false)));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(promptItemsProvider);
        if (st.value?.any((p) => !p.enabled) ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    late final List<PromptItem> all;
    await tester.runAsync(() async {
      all = await PromptItemRepository(db).all();
    });
    final toggled = all.singleWhere((i) => i.text.contains('可开关的项'));
    expect(toggled.enabled, isFalse);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('deletes an item via the visible row delete button', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await PromptItemRepository(db).insert(const PromptItem(kind: PromptItemKind.rule, text: '可删除的项'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 规则项按 kind 排序落在默认预设之后,先滚动到可见。
    final target = find.textContaining('可删除的项');
    final scrollable = find.byType(Scrollable).last;
    for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
      await tester.drag(scrollable, const Offset(0, -300));
      await tester.pump();
    }
    final delFinder = find.descendant(
      of: find.ancestor(of: find.textContaining('可删除的项'), matching: find.byType(ListTile)),
      matching: find.byIcon(Icons.delete_outline),
    );
    expect(delFinder, findsOneWidget);

    // 点删除按钮 → 弹确认框。
    await tester.runAsync(() async {
      await tester.ensureVisible(delFinder);
      await tester.pump();
      await tester.tap(delFinder);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.text('删除提示词项?'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      final container = ProviderScope.containerOf(tester.element(find.byType(PromptItemsScreen, skipOffstage: false)));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(promptItemsProvider);
        if (st.value?.every((p) => !p.text.contains('可删除的项')) ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    late final List<PromptItem> all;
    await tester.runAsync(() async {
      all = await PromptItemRepository(db).all();
    });
    expect(all.any((i) => i.text.contains('可删除的项')), isFalse);
    // 其余内置预设不受影响。
    expect(all.map((i) => i.name), contains('角色扮演基调'));
    await tester.runAsync(() => db.db.close());
  });
}
