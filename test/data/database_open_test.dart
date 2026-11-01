import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/models/data_root.dart';
import 'package:microscritt/models/prompt_seeds.dart';

/// 基线数据库(v66):全新建库的表结构与种子;旧版本库的归档重建。
void main() {
  sqfliteFfiInit();

  test('fresh install: baseline tables only, no legacy tables/columns', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );

    final tables = (await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name'] as String).toSet();

    for (final expected in [
      'characters',
      'sessions',
      'messages',
      'image_plugins',
      'image_providers',
      'prompt_items',
      'llm_providers',
      'llm_models',
      'worldbook_entries',
      'skills',
      'variables',
      'variable_trash',
      'variable_deletion_proposals',
      'memories',
      'image_guides',
      'hooks',
      'app_settings',
      'user_profile',
      'regex_scripts',
      'image_styles',
    ]) {
      expect(tables, contains(expected), reason: '基线表 $expected 应存在');
    }
    // 2.0 清理掉的死表与死列。
    expect(
      tables,
      isNot(contains('image_configs')),
      reason: '死表 image_configs 不再建',
    );
    expect(
      tables,
      isNot(contains('backend_configs')),
      reason: '死表 backend_configs 不再建',
    );

    final messageColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('messages')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      messageColumns,
      contains('image_prompt'),
      reason: 'v65 起保存生图原始描述,供图片重新生成',
    );

    final variableColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('variables')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      variableColumns,
      contains('agent_access'),
      reason: 'v66 起变量带三档后台权限',
    );

    final appSettingsColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('app_settings')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      appSettingsColumns,
      contains('background_deletion_confirm'),
      reason: 'v66 起支持删除前确认严格模式',
    );

    final providerColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('llm_providers')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      providerColumns,
      isNot(contains('gateway_flags')),
      reason: '旧列名已废弃,兼容选项落 compat_flags',
    );
    expect(providerColumns, contains('modern_params'));
    expect(providerColumns, contains('compat_flags'), reason: '端点兼容选项列在基线中');

    final imageProviderColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('image_providers')",
    )).map((r) => r['name'] as String).toSet();
    expect(imageProviderColumns, containsAll(['plugin_id', 'settings_json']));

    final imageKindRows = await db.db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type='table' AND name='image_providers'",
    );
    expect(
      (imageKindRows.single['sql'] as String),
      contains("DEFAULT 'chat_completions'"),
      reason: '生图 kind 列默认值为中性协议名',
    );

    expect(db.db.path, isNotNull);
    await db.db.close();
  });

  test(
    'fresh install: seeds default presets, hooks, provider and regex scripts',
    () async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );

      // 预设种子:与 kDefaultPromptSeeds 一致,全部启用项默认开。
      final prompts = await db.db.query('prompt_items');
      expect(prompts.length, kDefaultPromptSeeds.length);
      final promptNames = prompts.map((r) => r['name'] as String).toSet();
      expect(promptNames, containsAll(['角色扮演基调', '格式生成指导']));
      final formatGuide = prompts.singleWhere((r) => r['name'] == '格式生成指导');
      expect(formatGuide['kind'], 'rule', reason: '格式生成指导随规则段组装');

      // Hook 种子:仅 main/jump。
      final hooks = await db.db.query('hooks');
      expect(hooks.map((r) => r['name'] as String).toSet(), {
        '主导模式(main)',
        '时间快进(jump)',
      });

      // LLM provider 种子:deepseek,密钥留空。
      final providers = await db.db.query('llm_providers');
      expect(providers.single['provider_id'], 'deepseek');
      expect(providers.single['base_url'], 'https://api.deepseek.com');
      expect(providers.single['api_key'], '');

      // 正则脚本种子:加粗动作/斜体动作/时间戳胶囊。
      final scripts = await db.db.query('regex_scripts', orderBy: 'position');
      expect(scripts.map((r) => r['name'] as String).toList(), [
        '加粗动作',
        '斜体动作',
        '时间戳胶囊',
      ]);

      // 内置生图协议插件种子:对话式网关 + Nai2API(v64 起取代旧 Dart 后端)。
      final imagePlugins = await db.db.query('image_plugins', orderBy: 'id');
      expect(imagePlugins.map((r) => r['id'] as String).toSet(), {
        'microscritt.chat-completions',
        'microscritt.nai2',
      });
      expect(imagePlugins.every((r) => (r['enabled'] as int) == 1), isTrue);

      // 不再种入任何中转站 provider。
      expect(
        providers
            .map((r) => r['base_url'] as String)
            .where((u) => u.contains('sta1n')),
        isEmpty,
        reason: '开源版不捆绑第三方端点',
      );

      await db.db.close();
    },
  );

  test(
    'legacy database (v60) is archived and replaced by a fresh baseline',
    () async {
      final dir = await Directory.systemTemp.createTemp('microscritt_test_');
      addTearDown(() => dir.delete(recursive: true));
      final legacyPath = p.join(dir.path, 'microscritt.db');

      // 手工造一个 v60 形态的旧库(带 2.0 已移除的 gateway_flags 列)。
      final legacy = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 60,
          onCreate: (db, version) async {
            await db.execute('CREATE TABLE llm_providers (gateway_flags TEXT)');
            await db.execute(
              "INSERT INTO llm_providers VALUES ('replyInTool')",
            );
          },
        ),
      );
      await legacy.close();

      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: legacyPath,
      );

      // 归档文件出现在同目录,主路径上是全新基线库。
      final files = dir.listSync().map((e) => p.basename(e.path)).toList();
      expect(
        files.where((f) => f.startsWith('microscritt-legacy-v60-')),
        hasLength(1),
        reason: '旧库文件应被归档而非删除',
      );

      final providerColumns = (await db.db.rawQuery(
        "SELECT name FROM pragma_table_info('llm_providers')",
      )).map((r) => r['name'] as String).toSet();
      expect(
        providerColumns,
        isNot(contains('gateway_flags')),
        reason: '重建后按基线 schema 建表',
      );

      final prompts = await db.db.query('prompt_items');
      expect(prompts.length, kDefaultPromptSeeds.length, reason: '重建后种入默认预设');

      await db.db.close();
    },
  );

  test(
    'desktop default path migrates the legacy Documents database (move, not copy)',
    () async {
      final fakeHome = await Directory.systemTemp.createTemp(
        'microscritt_home_',
      );
      final fakeDocs = await Directory.systemTemp.createTemp(
        'microscritt_docs_',
      );
      addTearDown(() {
        DataRoot.overrideDir = null;
        AppDatabase.documentsDirOverride = null;
      });
      addTearDown(() async {
        // 目录删除可能因句柄未释放偶发失败,吞掉清理错误不影响断言。
        try {
          await fakeHome.delete(recursive: true);
          await fakeDocs.delete(recursive: true);
        } catch (_) {}
      });

      // 旧位置:一个 v60 旧库(搬迁后应在新目录触发归档重建)。
      final legacyPath = p.join(fakeDocs.path, 'microscritt.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 60,
          onCreate: (db, version) async {
            await db.execute('CREATE TABLE llm_providers (gateway_flags TEXT)');
          },
        ),
      );
      await legacy.close();
      // 伴生文件一并搬迁(内容无所谓,存在性参与断言)。
      await File('$legacyPath-journal').writeAsString('x');

      DataRoot.overrideDir = fakeHome.path;
      AppDatabase.documentsDirOverride = () async => fakeDocs;

      // 不传 path:走桌面默认路径(被 override 到 fakeHome)。
      final db = await AppDatabase.open(factory: databaseFactoryFfi);

      // 旧文件被移动而非复制:旧位置已无主库与伴生文件。
      expect(
        File(legacyPath).existsSync(),
        isFalse,
        reason: '搬迁用移动,避免两份数据各自演化',
      );
      expect(File('$legacyPath-journal').existsSync(), isFalse);

      // 新目录:主库重建为当前基线(v60 旧库按既有约定归档),伴生文件随迁。
      final files = fakeHome.listSync().map((e) => p.basename(e.path)).toList();
      expect(files, contains('microscritt.db'));
      expect(
        files.where((f) => f.startsWith('microscritt-legacy-v60-')),
        hasLength(1),
      );

      final prompts = await db.db.query('prompt_items');
      expect(
        prompts.length,
        kDefaultPromptSeeds.length,
        reason: '搬迁后的库按基线重建并种入',
      );

      await db.db.close();
    },
  );

  test(
    'desktop default path starts fresh when the old location is empty',
    () async {
      final fakeHome = await Directory.systemTemp.createTemp(
        'microscritt_home_',
      );
      final fakeDocs = await Directory.systemTemp.createTemp(
        'microscritt_docs_',
      );
      addTearDown(() {
        DataRoot.overrideDir = null;
        AppDatabase.documentsDirOverride = null;
      });
      addTearDown(() async {
        try {
          await fakeHome.delete(recursive: true);
          await fakeDocs.delete(recursive: true);
        } catch (_) {}
      });

      DataRoot.overrideDir = fakeHome.path;
      AppDatabase.documentsDirOverride = () async => fakeDocs;

      final db = await AppDatabase.open(factory: databaseFactoryFfi);

      // 旧位置无库:新目录直接建全新基线,不产生任何归档。
      expect(
        File(p.join(fakeHome.path, 'microscritt.db')).existsSync(),
        isTrue,
      );
      final files = fakeHome.listSync().map((e) => p.basename(e.path)).toList();
      expect(files.where((f) => f.contains('legacy')), isEmpty);

      await db.db.close();
    },
  );
}
