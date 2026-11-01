import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/regex_script_repository.dart';
import 'package:microscritt/models/regex_script.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/regex_scripts_screen.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: RegexScriptsScreen()),
  );

  testWidgets('lists seeded scripts and toggles the built-in highlight switch', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      // 清掉全新安装种入的默认脚本,只留可控的两条。
      await db.db.delete('regex_scripts');
      final repo = RegexScriptRepository(db);
      await repo.insert(const RegexScript(name: '斜体动作', findRegex: r'\*([\s\S]+?)\*', replace: '<i>\$1</i>'));
      await repo.insert(const RegexScript(name: '加粗动作', findRegex: r'\*\*([\s\S]+?)\*\*', replace: '<b>\$1</b>'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text('斜体动作'), findsOneWidget);
    expect(find.text('加粗动作'), findsOneWidget);
    // 内置对话高亮总开关独立于脚本列表。
    expect(find.text('内置对话高亮'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('deletes a script via the visible row delete button', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await db.db.delete('regex_scripts');
      final repo = RegexScriptRepository(db);
      await repo.insert(const RegexScript(name: '斜体动作', findRegex: r'\*([\s\S]+?)\*', replace: '<i>\$1</i>'));
      await repo.insert(const RegexScript(name: '加粗动作', findRegex: r'\*\*([\s\S]+?)\*\*', replace: '<b>\$1</b>'));
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    // 点「加粗动作」行内可见的删除按钮 → 弹确认框。
    final delFinder = find.descendant(
      of: find.ancestor(of: find.text('加粗动作'), matching: find.byType(ListTile)),
      matching: find.byIcon(Icons.delete_outline),
    );
    expect(delFinder, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(delFinder);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.text('删除脚本?'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      final container = ProviderScope.containerOf(tester.element(find.byType(RegexScriptsScreen, skipOffstage: false)));
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(regexScriptsProvider);
        if (st.value?.any((s) => s.name == '加粗动作') == false) break;
      }
      await tester.pumpAndSettle();
    });

    late final List<RegexScript> all;
    await tester.runAsync(() async {
      all = await RegexScriptRepository(db).all();
    });
    expect(all.map((s) => s.name), ['斜体动作']);
    expect(find.text('加粗动作'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });
}
