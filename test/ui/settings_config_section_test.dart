import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/settings_screen.dart';
import '../support/test_database.dart';

void main() {
  testWidgets('settings exposes the text-config export/import entries', (tester) async {
    late AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        if (find.text('导出配置').evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('导出配置'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.text('配置'), findsOneWidget);
    expect(find.text('导出配置'), findsOneWidget);
    expect(find.text('导入配置'), findsOneWidget);
    expect(find.text('配置文件'), findsOneWidget);
    // 测试环境未注入 AppConfigFile:路径行显示未启用,且不可点击。
    expect(find.text('未启用'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });
}
