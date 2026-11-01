import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/app.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/state/providers.dart';
import 'support/test_database.dart';

void main() {
  testWidgets('app boots to character screen', (tester) async {
    late final AppDatabase db;
    // openTestDb() uses sqflite_ffi (real isolate I/O), which cannot progress
    // inside the fake-async test zone; runAsync provides a real-async window.
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(overrides: [databaseProvider.overrideWithValue(db)], child: const MicroScrittApp()),
    );
    // Let the charactersProvider future (real isolate I/O) resolve, then settle.
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
