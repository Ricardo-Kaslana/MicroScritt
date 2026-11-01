import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/app.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/character_screen.dart';
import '../support/test_database.dart';

void main() {
  testWidgets('app applies dark theme when settings say dark', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings(themeMode: AppThemeMode.dark)),
        ],
        child: const MicroScrittApp(),
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(CharacterScreen));
    expect(Theme.of(context).brightness, Brightness.dark);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('app applies light theme when settings say light', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings(themeMode: AppThemeMode.light)),
        ],
        child: const MicroScrittApp(),
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(CharacterScreen));
    expect(Theme.of(context).brightness, Brightness.light);
    await tester.runAsync(() => db.db.close());
  });
}
