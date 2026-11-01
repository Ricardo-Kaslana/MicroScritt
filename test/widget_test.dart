// 应用冒烟测试:空库冷启动进入角色列表并显示空态。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/app.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/state/providers.dart';
import 'support/test_database.dart';

void main() {
  testWidgets('app boots to character screen', (tester) async {
    late final AppDatabase db;
    // openTestDb() 走 sqflite_ffi 的真实 isolate I/O,在假时钟测试区内不会
    // 推进;runAsync 提供一段真实异步窗口。
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db)], child: const MicroScrittApp()),
    );
    // 等 charactersProvider 的真实 isolate I/O 完成,再收敛动画。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('角色'), findsOneWidget);
    // 空库显示空态引导
    expect(find.text('暂无角色'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });
}
