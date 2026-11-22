// 基线数据库(v75):全新建库的表结构与种子;旧版本库的归档重建。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/usage_repository.dart';
import 'package:microscritt/models/data_root.dart';
import 'package:microscritt/models/prompt_seeds.dart';

/// v72 及以前的 `usage_records` 形态(与 v73 基线一致)。
const String _usageRecordsDdl = '''
  CREATE TABLE usage_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER,
    kind TEXT NOT NULL DEFAULT 'main',
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    model_name TEXT NOT NULL DEFAULT '',
    input_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cached_input_tokens INTEGER NOT NULL DEFAULT 0,
    reported INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
  )
''';

Map<String, Object?> _usageRow({
  String model = 'deepseek-flash',
  String kind = 'main',
  int input = 100,
  int output = 20,
  int cached = 0,
  int reported = 1,
  required DateTime createdAt,
}) => {
  'session_id': 1,
  'kind': kind,
  'provider_id': 'deepseek',
  'provider_name': 'DeepSeek 官网',
  'model': model,
  'model_name': model,
  'input_tokens': input,
  'output_tokens': output,
  'cached_input_tokens': cached,
  'reported': reported,
  'created_at': createdAt.millisecondsSinceEpoch,
};

void main() {
  sqfliteFfiInit();

  test('fresh install: baseline tables only, no legacy tables/columns', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );

    final tables = (await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%'",
    )).map((r) => r['name'] as String).toSet();

    for (final expected in [
      'characters',
      'sessions',
      'messages',
      'image_assets',
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
      'usage_records',
    ]) {
      expect(tables, contains(expected), reason: '基线表 $expected 应存在');
    }
    expect(tables, hasLength(22), reason: 'v75 基线共 22 张业务表');
    expect(AppDatabase.schemaVersion, 75);
    expect(
      (await db.db.rawQuery('PRAGMA user_version')).single.values.single,
      75,
    );
    final settingColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('app_settings')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      settingColumns,
      contains('compress_images'),
      reason: 'v73 起新图片入库压缩开关可配置',
    );
    expect(
      settingColumns,
      containsAll([
        'background_variable_injection',
        'background_next_suggestions',
      ]),
      reason: 'v74 起 Agentic 增强开关可配置',
    );
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
      containsAll(['image_hash', 'image_url', 'image_prompt']),
      reason: 'v72 起消息只保存图片哈希,URL 与生图描述保留',
    );
    expect(messageColumns, isNot(contains('image_base64')));

    final characterColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('characters')",
    )).map((r) => r['name'] as String).toSet();
    expect(characterColumns, containsAll(['avatar_hash', 'background_hash']));
    expect(characterColumns, isNot(contains('avatar_base64')));
    expect(characterColumns, isNot(contains('background_base64')));

    final userColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('user_profile')",
    )).map((r) => r['name'] as String).toSet();
    expect(userColumns, contains('avatar_hash'));
    expect(userColumns, isNot(contains('avatar_base64')));

    final assetColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('image_assets')",
    )).map((r) => r['name'] as String).toSet();
    expect(assetColumns, {
      'hash',
      'byte_size',
      'mime',
      'width',
      'height',
      'ref_count',
      'created_at',
    });
    final assetIndexes = (await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND tbl_name='image_assets'",
    )).map((r) => r['name'] as String).toSet();
    expect(assetIndexes, contains('idx_image_assets_reclaim'));

    final filterIndexes = (await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'",
    )).map((r) => r['name'] as String).toSet();
    expect(
      filterIndexes,
      containsAll([
        'idx_sessions_character_id',
        'idx_worldbook_entries_character_id',
        'idx_llm_models_provider_id',
        'idx_image_providers_plugin_id',
      ]),
      reason: 'v75 起高频筛选列有索引',
    );

    final sessionColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('sessions')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      sessionColumns,
      contains('pinned_at'),
      reason: 'v67 起会话可置顶(pinned_at 空值表示未置顶)',
    );

    final variableColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('variables')",
    )).map((r) => r['name'] as String).toSet();
    expect(variableColumns, contains('agent_access'), reason: 'v66 起变量带三档后台权限');

    final appSettingsColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('app_settings')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      appSettingsColumns,
      contains('background_deletion_confirm'),
      reason: 'v66 起支持删除前确认严格模式',
    );
    expect(
      appSettingsColumns,
      contains('auto_compact_threshold'),
      reason: 'v68 起自动压缩触发线可配置',
    );
    expect(
      appSettingsColumns,
      contains('background_mode'),
      reason: 'v71 起后台运行模式可配置(legacy/agentic/hybrid)',
    );

    final providerColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('llm_providers')",
    )).map((r) => r['name'] as String).toSet();
    expect(providerColumns, isNot(contains('gateway_flags')), reason: '旧列名已废弃');
    expect(providerColumns, contains('modern_params'));
    expect(
      providerColumns,
      isNot(contains('compat_flags')),
      reason: 'v70 起移除历史遗留端点兼容选项列',
    );

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

    final usageColumns = (await db.db.rawQuery(
      "SELECT name FROM pragma_table_info('usage_records')",
    )).map((r) => r['name'] as String).toSet();
    expect(
      usageColumns,
      containsAll([
        'session_id',
        'kind',
        'provider_id',
        'provider_name',
        'model',
        'model_name',
        'input_tokens',
        'output_tokens',
        'cached_input_tokens',
        'reported',
        'created_at',
      ]),
      reason: 'v69 起逐请求用量明细支撑全量统计',
    );
    final usageIndexes = (await db.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='usage_records'",
    )).map((r) => r['name'] as String).toSet();
    expect(
      usageIndexes,
      containsAll(['idx_usage_records_created', 'idx_usage_records_model']),
      reason: '按时间与模型聚合都需要索引',
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

      // 内置生图协议插件种子:对话式网关 + Nai2API + NovelAI 官方 API。
      final imagePlugins = await db.db.query('image_plugins', orderBy: 'id');
      expect(imagePlugins.map((r) => r['id'] as String).toSet(), {
        'microscritt.chat-completions',
        'microscritt.nai2',
        'microscritt.novelai',
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
        files.where(
          (f) =>
              f.startsWith('microscritt-legacy-v60-') &&
              !f.endsWith('.usage-salvaged'),
        ),
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
        files.where(
          (f) =>
              f.startsWith('microscritt-legacy-v60-') &&
              !f.endsWith('.usage-salvaged'),
        ),
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

  test('legacy usage_records are salvaged into the rebuilt baseline', () async {
    final dir = await Directory.systemTemp.createTemp('microscritt_test_');
    addTearDown(() => dir.delete(recursive: true));
    final legacyPath = p.join(dir.path, 'microscritt.db');

    // v72 旧库:带逐请求用量明细。
    final legacy = await databaseFactoryFfi.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
        version: 72,
        onCreate: (db, version) async {
          await db.execute(_usageRecordsDdl);
          await db.insert(
            'usage_records',
            _usageRow(
              input: 120,
              output: 30,
              cached: 20,
              createdAt: DateTime(2026, 5, 1, 10),
            ),
          );
          await db.insert(
            'usage_records',
            _usageRow(
              kind: 'background',
              model: 'deepseek-pro',
              input: 40,
              output: 10,
              createdAt: DateTime(2026, 5, 2, 10),
            ),
          );
        },
      ),
    );
    await legacy.close();

    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: legacyPath,
    );

    // 统计页口径(聚合)与逐行数据都应保留。
    final summary = await UsageRepository(db).summary();
    expect(summary.requests, 2, reason: '升级重建后历史用量不归零');
    expect(summary.totalTokens, 200);
    expect(summary.cachedInputTokens, 20);
    final rows = await db.db.query('usage_records', orderBy: 'id');
    expect(rows, hasLength(2));
    expect(rows.first['kind'], 'main');
    expect(rows.last['model'], 'deepseek-pro');

    final markers = dir
        .listSync()
        .map((e) => p.basename(e.path))
        .where((name) => name.endsWith('.usage-salvaged'));
    expect(markers, hasLength(1), reason: '归档只回灌一次');

    await db.db.close();

    // 二次启动不会重复回灌。
    final reopened = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: legacyPath,
    );
    expect(await reopened.db.query('usage_records'), hasLength(2));
    await reopened.db.close();
  });

  test('archives left by earlier upgrades are recovered once', () async {
    final dir = await Directory.systemTemp.createTemp('microscritt_test_');
    addTearDown(() => dir.delete(recursive: true));
    final mainPath = p.join(dir.path, 'microscritt.db');

    // 模拟本特性上线前遗留的 v71 归档:主库已是当前基线,归档未标记。
    final archivePath = p.join(
      dir.path,
      'microscritt-legacy-v71-2026-01-01T00-00-00-000.db',
    );
    final archive = await databaseFactoryFfi.openDatabase(
      archivePath,
      options: OpenDatabaseOptions(
        version: 71,
        onCreate: (db, version) async {
          await db.execute(_usageRecordsDdl);
          await db.insert(
            'usage_records',
            _usageRow(createdAt: DateTime(2026, 1, 1, 9)),
          );
        },
      ),
    );
    await archive.close();

    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: mainPath,
    );
    expect(
      await db.db.query('usage_records'),
      hasLength(1),
      reason: '启动时应补救此前升级丢失的历史统计',
    );
    expect(File('$archivePath.usage-salvaged').existsSync(), isTrue);
    await db.db.close();

    final reopened = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: mainPath,
    );
    expect(await reopened.db.query('usage_records'), hasLength(1));
    await reopened.db.close();
  });

  test('unreadable archives never block startup', () async {
    final dir = await Directory.systemTemp.createTemp('microscritt_test_');
    addTearDown(() => dir.delete(recursive: true));
    final mainPath = p.join(dir.path, 'microscritt.db');
    final archivePath = p.join(
      dir.path,
      'microscritt-legacy-v72-2026-01-01T00-00-00-000.db',
    );
    await File(archivePath).writeAsString('not a sqlite database');

    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: mainPath,
    );
    expect(await db.db.query('usage_records'), isEmpty);
    expect(
      File('$archivePath.usage-salvaged').existsSync(),
      isFalse,
      reason: '失败不写标记,下次启动重试',
    );

    await db.db.close();
  });
}
