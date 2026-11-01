// 生图插件目录:导入/替换/停用、被引用禁删与内置插件随启动刷新。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_config_repository.dart';
import 'package:microscritt/data/image_plugin_repository.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/models/image_plugin.dart';

import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late ImagePluginRepository repository;

  setUp(() async {
    db = await openTestDb();
    repository = ImagePluginRepository(db);
  });

  tearDown(() => db.db.close());

  const plugin = ImagePlugin(
    id: 'example.image',
    name: 'Example',
    version: '1.0.0',
    code: 'function step(ctx) { return {action: "error", message: "x"}; }',
    fields: [
      ImagePluginField(
        key: 'baseUrl',
        label: 'URL',
        type: ImagePluginFieldType.url,
      ),
    ],
    permissions: ImagePluginPermissions(endpointSetting: 'baseUrl'),
  );

  test(
    'save, replace, toggle and delete round-trip the plugin catalog',
    () async {
      await repository.save(plugin);
      await repository.save(plugin.copyWith(enabled: false));
      var all = await repository.all();
      expect(all.single.enabled, isFalse);
      expect(all.single.permissions.endpointSetting, 'baseUrl');

      await repository.setEnabled(plugin.id, true);
      all = await repository.all();
      expect(all.single.enabled, isTrue);

      await repository.delete(plugin.id);
      expect(await repository.all(), isEmpty);
    },
  );

  test('a plugin referenced by an image provider cannot be deleted', () async {
    await repository.save(plugin);
    await ImageConfigRepository(db).saveProvider(
      ImageProviderRecord(
        id: 0,
        displayName: 'Plugin provider',
        config: ImageConfig(
          kind: ImageBackendKind.plugin,
          apiKey: '',
          model: '',
          pluginId: plugin.id,
          pluginSettings: {
            'baseUrl': 'http://127.0.0.1:8080',
            'token': 'secret',
          },
        ),
      ),
    );

    await expectLater(repository.delete(plugin.id), throwsStateError);
    final active = await ImageConfigRepository(db).loadActiveConfig();
    expect(active!.pluginId, plugin.id);
    expect(active.pluginSettings['token'], 'secret');
  });

  test(
    'corrupt storage rows are skipped and corrupt provider settings fall back safely',
    () async {
      await db.db.insert('image_plugins', {
        'id': 'broken',
        'name': 'Broken',
        'version': '1',
        'manifest_json': '{bad',
        'js_code': 'x',
        'enabled': 1,
      });
      await repository.save(plugin);
      expect((await repository.all()).single.id, plugin.id);

      await db.db.insert('image_providers', {
        'display_name': 'Dirty',
        'kind': 'plugin',
        'base_url': '',
        'api_key': '',
        'model': '',
        'plugin_id': plugin.id,
        'settings_json': '[1,2]',
        'is_active': 1,
      });
      expect(
        (await ImageConfigRepository(db).loadActiveConfig())!.pluginSettings,
        isEmpty,
      );
    },
  );

  test('upsertBuiltins 首次插入、二次刷新 JS 且保留启用状态', () async {
    await repository.upsertBuiltins();
    var all = await repository.all();
    expect(all.map((p) => p.id).toSet(), {
      'microscritt.chat-completions',
      'microscritt.nai2',
    });
    expect(all.every((p) => p.enabled), isTrue);

    // 用户停用其一,并篡改另一条的 JS(模拟旧版本残留的有 bug 代码)。
    await repository.setEnabled('microscritt.nai2', false);
    await db.db.update(
      'image_plugins',
      {'js_code': 'STALE'},
      where: 'id = ?',
      whereArgs: ['microscritt.chat-completions'],
    );

    await repository.upsertBuiltins();
    all = await repository.all();
    final chat = all.firstWhere((p) => p.id == 'microscritt.chat-completions');
    final nai2 = all.firstWhere((p) => p.id == 'microscritt.nai2');
    expect(chat.code, isNot('STALE'), reason: '内置协议修复随启动传播');
    expect(chat.code, contains('extractContent'));
    expect(nai2.enabled, isFalse, reason: '保留用户的停用选择');
  });
}
