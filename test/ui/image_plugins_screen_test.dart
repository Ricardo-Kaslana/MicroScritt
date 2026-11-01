import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_plugin_repository.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/image_plugins_screen.dart';

import '../support/fake_file_picker.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

class _FakeRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => 'ok';
}

void main() {
  late AppDatabase db;

  Widget harness() => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      hookRuntimeProvider.overrideWithValue(_FakeRuntime()),
    ],
    child: const MaterialApp(home: ImagePluginsScreen()),
  );

  testWidgets(
    'imports with permission confirmation, toggles and deletes a plugin',
    (tester) async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      FakeFilePicker.install(pickedPath: 'examples/image_plugins/openai_images.json');
      await tester.pumpWidget(harness());
      expect(find.text('暂无生图插件'), findsOneWidget);

      await tester.tap(find.widgetWithText(FloatingActionButton, '导入 JSON'));
      await tester.runAsync(() async {
        for (
          var i = 0;
          i < 100 && find.text('导入生图插件？').evaluate().isEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      await tester.pump();
      expect(find.text('导入生图插件？'), findsOneWidget);
      expect(find.textContaining('用户在「baseUrl」'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '导入'));
      await waitUntil(
        tester,
        () => find.textContaining('已导入插件').evaluate().isNotEmpty,
      );

      var plugins = await tester.runAsync(
        () => ImagePluginRepository(db).all(),
      );
      expect(plugins!.single.id, 'microscritt.openai-images');
      expect(find.text('OpenAI Images 兼容'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      plugins = await tester.runAsync(() => ImagePluginRepository(db).all());
      expect(plugins!.single.enabled, isFalse);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await waitUntil(tester, () => find.text('暂无生图插件').evaluate().isNotEmpty);
      plugins = await tester.runAsync(() => ImagePluginRepository(db).all());
      expect(plugins, isEmpty);

      await tester.runAsync(() => db.db.close());
    },
  );
}
