import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/hook_repository.dart';
import 'package:microscritt/models/hook.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/hooks_screen.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: HooksScreen()),
  );

  testWidgets('empty state shows guidance', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      // 默认 USER 替换脚本是全新安装种入的,v15 起 hooks 表非空;
      // 本测试验证空清单行为,故先清空。
      await db.db.delete('hooks');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('暂无 Hook'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('lists existing hooks with trigger labels and toggles', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await db.db.delete('hooks'); // 排除全新安装种入的默认 USER 替换 hook
      await HookRepository(
        db,
      ).insert(const Hook(name: '净化回复', triggerPoint: HookTriggerPoint.afterStream, jsCode: '__ctx.text = "x"'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('净化回复'), findsOneWidget);
    // 列表项只显示名称,不再展示触发点标签。
    expect(find.text('流式后(改写回复)'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.byType(Switch));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    late final List<Hook> all;
    await tester.runAsync(() async {
      all = await HookRepository(db).all();
    });
    expect(all.single.enabled, isFalse);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('deletes a hook via the visible row delete button', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await db.db.delete('hooks'); // 排除全新安装种入的默认 USER 替换 hook
      await HookRepository(
        db,
      ).insert(const Hook(name: '净化回复', triggerPoint: HookTriggerPoint.afterStream, jsCode: '__ctx.text = "x"'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 点行内可见的删除按钮 → 弹确认框。
    final delFinder = find.descendant(
      of: find.ancestor(of: find.text('净化回复'), matching: find.byType(ListTile)),
      matching: find.byIcon(Icons.delete_outline),
    );
    expect(delFinder, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(delFinder);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.text('删除 Hook?'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if ((await db.db.query('hooks')).isEmpty) break;
      }
      await tester.pumpAndSettle();
    });

    late final List<Hook> all;
    await tester.runAsync(() async {
      all = await HookRepository(db).all();
    });
    expect(all, isEmpty);
    expect(find.text('暂无 Hook'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('creates a hook via the editor', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    await tester.tap(find.widgetWithText(FloatingActionButton, '新建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byKey(const ValueKey('field_名字 *')), '新钩子');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      final container = ProviderScope.containerOf(tester.element(find.byType(HooksScreen, skipOffstage: false)));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(hooksProvider);
        if (st.value?.any((h) => h.name == '新钩子') ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    expect(find.text('新钩子'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });
}
