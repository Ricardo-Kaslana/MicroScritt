// 生图插件管理页:导入(权限确认)、启停与删除;导入校验的 JS 求值用
// 替身 runtime,不与本机 QuickJS/Node 桥接耦合。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_plugin_repository.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/models/image_plugin.dart';
import 'package:microscritt/models/image_plugin_seeds.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/image_plugins_screen.dart';

import '../support/fake_file_picker.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

/// 导入只校验插件 JS 能求出 `step` 函数;协议语义由后端插件测试用真实
/// 引擎覆盖,这里恒返回 "ok",避免 UI 测试依赖本机 JS 桥接库。
class _FakeRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => 'ok';
}

void main() {
  late AppDatabase db;

  Widget harness({List<ImagePlugin>? plugins}) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      hookRuntimeProvider.overrideWithValue(_FakeRuntime()),
      if (plugins != null)
        imagePluginsProvider.overrideWith((ref) => plugins),
    ],
    child: const MaterialApp(home: ImagePluginsScreen()),
  );

  testWidgets(
    'imports with permission confirmation, toggles and deletes a plugin',
    (tester) async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      // 仓库自带示例插件声明 baseUrl 端点权限,导入时会弹权限确认。
      FakeFilePicker.install(pickedPath: 'examples/image_plugins/openai_images.json');
      await tester.pumpWidget(harness());
      expect(find.text('暂无生图插件'), findsOneWidget);

      await tester.tap(find.widgetWithText(FloatingActionButton, '导入 JSON'));
      // 读文件、解析 manifest 与 JS 求值都是真实异步,FAB 里的进度圈不会
      // 收敛,不能用 pumpAndSettle,按弹层出现轮询。
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

  testWidgets('built-in plugins have no delete action', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    const custom = ImagePlugin(
      id: 'custom.plugin',
      name: '自定义插件',
      version: '1.0.0',
      code: 'function step(){}',
    );
    await tester.pumpWidget(
      harness(plugins: [kDefaultImagePluginSeeds.first, custom]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('· 内置'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byTooltip('内置插件不可删除'), findsOneWidget);
    expect(find.byTooltip('删除'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });
}
