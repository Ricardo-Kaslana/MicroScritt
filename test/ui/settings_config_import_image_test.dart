// 完整配置导入 UI:确认弹层列出插件,单事务恢复生图配置并回写配置文件。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_config_file.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_config_repository.dart';
import 'package:microscritt/data/image_plugin_repository.dart';
import 'package:microscritt/data/image_style_repository.dart';
import 'package:microscritt/data/user_repository.dart';
import 'package:microscritt/models/image_plugin.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/settings/settings_actions.dart';

import '../support/fake_file_picker.dart';
import '../support/test_database.dart';

class _ImportHarness extends ConsumerWidget {
  const _ImportHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => importSettingsConfig(context, ref),
          child: const Text('导入'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('imports image config from a complete v2 file', (tester) async {
    late AppDatabase db;
    late Directory tmp;
    late File config;
    final plugin = const ImagePlugin(
      id: 'test.image-plugin',
      name: '测试生图插件',
      version: '1.0.0',
      code: 'function step(ctx) { return { done: true, images: [] }; }',
    );
    await tester.runAsync(() async {
      db = await openTestDb();
      tmp = await Directory.systemTemp.createTemp('config_import_image');
      final source = jsonEncode({
        'version': 2,
        'user': {'name': 'Alice'},
        'image': {
          'plugins': [
            {
              'id': plugin.id,
              'builtin': false,
              'enabled': true,
              'package': jsonDecode(plugin.toPackageJson()),
            },
          ],
          'providers': [
            {
              'displayName': '测试配置',
              'isActive': true,
              'position': 0,
              'config': {
                'kind': 'plugin',
                'baseUrl': 'https://image.example.com',
                'apiKey': 'secret',
                'model': 'image-model',
                'count': 1,
                'pluginId': plugin.id,
                'pluginSettings': <String, dynamic>{},
              },
            },
          ],
          'styles': [
            {'name': '自定义风格', 'sampler': 'k_euler'},
          ],
        },
      });
      config = File('${tmp.path}/microscritt-config.json')
        ..writeAsStringSync(source);
    });
    FakeFilePicker.install(pickedPath: config.path);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appConfigFileProvider.overrideWithValue(AppConfigFile(config.path)),
        ],
        child: const MaterialApp(home: _ImportHarness()),
      ),
    );
    await tester.tap(find.text('导入'));
    await tester.runAsync(() async {
      for (
        var i = 0;
        i < 100 && find.text('导入完整配置?').evaluate().isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(find.text('导入完整配置?'), findsOneWidget);
    expect(find.textContaining('测试生图插件'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.runAsync(() async {
      for (
        var i = 0;
        i < 100 && find.textContaining('已导入配置').evaluate().isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    final plugins = await tester.runAsync(
      () => ImagePluginRepository(db).all(),
    );
    final providers = await tester.runAsync(
      () => ImageConfigRepository(db).all(),
    );
    final styles = await tester.runAsync(() => ImageStyleRepository(db).all());
    final name = await tester.runAsync(() => UserRepository(db).name());
    expect(plugins!.single.id, plugin.id);
    expect(providers!.single.displayName, '测试配置');
    expect(providers.single.config.apiKey, 'secret');
    expect(styles!.single.name, '自定义风格');
    expect(name, 'Alice');

    final written = await tester.runAsync(
      () async => jsonDecode(await config.readAsString())
          as Map<String, dynamic>,
    );
    expect(written!['version'], 2);
    expect((written['image'] as Map)['providers'], hasLength(1));

    await tester.runAsync(() async {
      await db.db.close();
      tmp.deleteSync(recursive: true);
    });
  });
}