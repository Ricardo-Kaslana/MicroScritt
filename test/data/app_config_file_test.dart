// 文本配置文件 microscritt-config.json 的快照写出、外部编辑应用与 fail-safe 容错。
// 文件是启动时权威;v2 起含生图插件 / provider / 自定义风格,整份配置在单事务中应用。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_config_file.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_config_repository.dart';
import 'package:microscritt/data/image_plugin_repository.dart';
import 'package:microscritt/data/image_style_repository.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/data/user_repository.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/models/image_plugin.dart';
import 'package:microscritt/models/image_style_preset.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/models/user.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';

/// 带完整动态设置表单的自定义插件,供设置校验用例复用。
const ImagePlugin customPlugin = ImagePlugin(
  id: 'example.custom',
  name: 'Custom',
  version: '1.0.0',
  code: 'function step(ctx) { return {action: "error", message: "x"}; }',
  fields: [
    ImagePluginField(
      key: 'token',
      label: 'Token',
      type: ImagePluginFieldType.password,
      required: true,
    ),
    ImagePluginField(
      key: 'endpoint',
      label: 'Endpoint',
      type: ImagePluginFieldType.url,
    ),
    ImagePluginField(
      key: 'n',
      label: 'N',
      type: ImagePluginFieldType.integer,
    ),
    ImagePluginField(
      key: 'mode',
      label: 'Mode',
      type: ImagePluginFieldType.select,
      options: [
        ImagePluginOption(value: 'a', label: 'A'),
        ImagePluginOption(value: 'b', label: 'B'),
      ],
    ),
    ImagePluginField(
      key: 'flag',
      label: 'Flag',
      type: ImagePluginFieldType.boolean,
    ),
    ImagePluginField(
      key: 'ratio',
      label: 'Ratio',
      type: ImagePluginFieldType.number,
    ),
  ],
);

const Map<String, dynamic> validPluginSettings = {
  'token': 'plugin-secret',
  'endpoint': 'https://custom.example.com/v1',
  'n': 3,
  'mode': 'a',
  'flag': true,
  'ratio': 1.5,
};

Map<String, dynamic> customPluginEntry({bool enabled = true}) => {
  'id': customPlugin.id,
  'builtin': false,
  'enabled': enabled,
  'package': jsonDecode(customPlugin.toPackageJson()),
};

Map<String, dynamic> builtinEntry(String id, {bool? enabled}) => {
  'id': id,
  'builtin': true,
  if (enabled != null) 'enabled': enabled,
};

Map<String, dynamic> providerEntry({
  String displayName = '自定义生图',
  String? pluginId,
  bool isActive = true,
  int? position,
  Map<String, dynamic> config = const {},
}) => {
  'displayName': displayName,
  'isActive': isActive,
  if (position != null) 'position': position,
  'config': {
    'baseUrl': 'https://custom.example.com',
    'apiKey': 'sk-image-secret',
    'model': 'model-x',
    'pluginId': pluginId ?? customPlugin.id,
    'count': 1,
    'pluginSettings': validPluginSettings,
    ...config,
  },
};

Map<String, dynamic> v2File({
  Map<String, dynamic>? user,
  List<Map<String, dynamic>>? llmProviders,
  List<Map<String, dynamic>>? plugins,
  List<Map<String, dynamic>>? imageProviders,
  List<Map<String, dynamic>>? styles,
}) => {
  'version': 2,
  if (user != null) 'user': user,
  if (llmProviders != null) 'llm': {'providers': llmProviders},
  if (plugins != null || imageProviders != null || styles != null)
    'image': {
      if (plugins != null) 'plugins': plugins,
      if (imageProviders != null) 'providers': imageProviders,
      if (styles != null) 'styles': styles,
    },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Directory tmp;
  late AppConfigFile file;

  setUp(() async {
    db = await openTestDb();
    tmp = await Directory.systemTemp.createTemp('app_config');
    file = AppConfigFile('${tmp.path}/microscritt-config.json');
  });

  tearDown(() async {
    await db.db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<int> seedProvider({String baseUrl = 'https://api.example.com'}) async {
    final repo = LlmProviderRepository(db);
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'openai',
        displayName: 'OpenAI',
        baseUrl: baseUrl,
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'sk-test',
        isActive: true,
        models: const [
          LlmModelEntry(
            id: 0,
            providerId: 0,
            modelId: 'gpt-test',
            displayName: 'GPT Test',
            contextCapacity: 128000,
            maxOutput: 4096,
            temperature: 0.5,
            isActive: true,
          ),
        ],
        extraHeaders: const {'X-Test': '1'},
        modernParams: true,
      ),
    );
    return (await repo.all()).single.models.single.id;
  }

  test('writes a readable v2 snapshot, and applying it unchanged is a no-op', () async {
    await UserRepository(db).save(const UserProfile(name: 'Alice'));
    final modelId = await seedProvider();
    await AppSettingsRepository(db).save(
      (await AppSettingsRepository(db).load()).copyWith(backgroundModelId: modelId),
    );

    await file.writeSnapshot(db);
    final text = File(file.path).readAsStringSync();
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['version'], 2);
    expect((decoded['user'] as Map)['name'], 'Alice');
    final provider = (decoded['llm'] as Map)['providers'][0] as Map;
    expect(provider['providerId'], 'openai');
    expect(provider['apiKey'], 'sk-test');
    expect((provider['models'] as List).single['modelId'], 'gpt-test');
    expect(decoded['image'], isA<Map>());

    final result = await file.applyIfPresent(db);
    expect(result, isNotNull);
    expect(result!.changed, isFalse);
    expect(result.imageChanged, isFalse);
    // 相同快照不重建模型行,后台模型引用保持稳定。
    expect((await LlmProviderRepository(db).all()).single.models.single.id, modelId);
    expect((await AppSettingsRepository(db).load()).backgroundModelId, modelId);
    expect(File(file.dirtyPath).existsSync(), isFalse);
  });

  test('dirty marker rebuilds from DB instead of applying a stale file', () async {
    await UserRepository(db).save(const UserProfile(name: 'Alice'));
    await file.writeSnapshot(db);

    final stale =
        jsonDecode(File(file.path).readAsStringSync()) as Map<String, dynamic>;
    (stale['user'] as Map)['name'] = 'Stale';
    File(file.path).writeAsStringSync(jsonEncode(stale));
    File(file.dirtyPath).writeAsStringSync('pending');

    // 库已更新但上次回写失败:旧文件不能覆盖库,启动改为从库重建。
    expect(await file.applyIfPresent(db), isNull);
    expect(await UserRepository(db).name(), 'Alice');
    expect(File(file.dirtyPath).existsSync(), isFalse);
    final rebuilt =
        jsonDecode(File(file.path).readAsStringSync()) as Map<String, dynamic>;
    expect((rebuilt['user'] as Map)['name'], 'Alice');
  });

  test('applies external edits to user name / provider fields and keeps the avatar', () async {
    final avatar = await putTestImageHash(db);
    await UserRepository(db).save(UserProfile(name: 'Alice', avatarHash: avatar));
    await seedProvider();
    await file.writeSnapshot(db);

    final decoded = jsonDecode(File(file.path).readAsStringSync()) as Map<String, dynamic>;
    (decoded['user'] as Map)['name'] = 'Bob';
    ((decoded['llm'] as Map)['providers'] as List).first['baseUrl'] = 'https://new.example.com';
    File(file.path).writeAsStringSync(jsonEncode(decoded));

    final result = await file.applyIfPresent(db);
    expect(result!.userChanged, isTrue);
    expect(result.llmChanged, isTrue);
    final user = await UserRepository(db).load();
    expect(user.name, 'Bob');
    expect(user.avatarHash, avatar);
    expect((await LlmProviderRepository(db).all()).single.baseUrl, 'https://new.example.com');
  });

  test('re-applying a provider snapshot keeps model ids and background_model_id', () async {
    final oldModelId = await seedProvider();
    await AppSettingsRepository(db).save(
      (await AppSettingsRepository(db).load()).copyWith(backgroundModelId: oldModelId),
    );
    final decoded = jsonDecode(await AppConfigFile.snapshotText(db)) as Map<String, dynamic>;
    ((decoded['llm'] as Map)['providers'] as List).first['displayName'] = 'Renamed';
    await AppConfigFile.applyText(db, jsonEncode(decoded));

    final models = (await LlmProviderRepository(db).all()).single.models;
    expect(models.single.id, oldModelId);
    expect((await AppSettingsRepository(db).load()).backgroundModelId, oldModelId);
  });

  test('clears background_model_id when the logical model is gone', () async {
    final oldModelId = await seedProvider();
    final settingsRepo = AppSettingsRepository(db);
    await settingsRepo.save((await settingsRepo.load()).copyWith(backgroundModelId: oldModelId));

    // 换成另一个模型目录(逻辑模型不再存在)。
    final text = jsonEncode({
      'version': 1,
      'llm': {
        'providers': [
          {
            'providerId': 'openai',
            'displayName': 'OpenAI',
            'baseUrl': 'https://api.example.com',
            'protocol': 'openai',
            'apiKey': 'k',
            'models': [
              {'modelId': 'other-model', 'displayName': 'Other'},
            ],
          },
        ],
      },
    });
    await AppConfigFile.applyText(db, text);
    expect((await settingsRepo.load()).backgroundModelId, isNull);
  });

  test('user-only section leaves LLM providers untouched', () async {
    await seedProvider();
    await AppConfigFile.applyText(db, jsonEncode({
      'version': 1,
      'user': {'name': 'Carol'},
    }));
    expect((await UserRepository(db).name()), 'Carol');
    expect((await LlmProviderRepository(db).all()), hasLength(1));
  });

  test('broken config file is ignored: DB untouched, file preserved', () async {
    await UserRepository(db).save(const UserProfile(name: 'Alice'));
    File(file.path).writeAsStringSync('{ this is not json');

    // 坏文件属于 fail-safe 契约:启动路径返回 null,库不被修改,原文件保留。
    expect(await file.applyIfPresent(db), isNull);
    expect(await UserRepository(db).name(), 'Alice');
    expect(File(file.path).readAsStringSync(), '{ this is not json');
  });

  test('malformed provider entries throw a readable FormatException', () async {
    expect(
      () => AppConfigFile.applyText(db, jsonEncode({
        'version': 1,
        'llm': {
          'providers': [
            {'providerId': 'x', 'displayName': 'X'},
          ],
        },
      })),
      throwsA(isA<FormatException>()),
    );
  });

  test('normalizes multiple active providers/models to one', () async {
    final text = jsonEncode({
      'version': 1,
      'llm': {
        'providers': [
          {
            'providerId': 'a',
            'displayName': 'A',
            'baseUrl': 'https://a',
            'isActive': true,
            'models': [
              {'modelId': 'a1', 'isActive': true},
              {'modelId': 'a2', 'isActive': true},
            ],
          },
          {
            'providerId': 'b',
            'displayName': 'B',
            'baseUrl': 'https://b',
            'isActive': true,
            'models': [
              {'modelId': 'b1', 'isActive': true},
            ],
          },
        ],
      },
    });
    await AppConfigFile.applyText(db, text);
    final providers = await LlmProviderRepository(db).all();
    expect(providers.where((p) => p.isActive).length, 1);
    expect(providers.first.models.where((m) => m.isActive).length, 1);
    expect(providers.last.models.where((m) => m.isActive).length, 0);
  });

  test('v2 round-trip restores custom plugin + provider reference without id drift', () async {
    await ImagePluginRepository(db).save(customPlugin);
    final providerId = await ImageConfigRepository(db).saveProvider(
      ImageProviderRecord(
        id: 0,
        displayName: '自定义生图',
        isActive: true,
        position: 0,
        config: const ImageConfig(
          baseUrl: 'https://custom.example.com',
          apiKey: 'sk-image-secret',
          model: 'model-x',
          pluginId: 'example.custom',
          pluginSettings: validPluginSettings,
        ),
      ),
    );
    await ImageStyleRepository(db).insert(
      const ImageStylePreset(name: '我的风格', artist: 'quality', scale: 6, cfg: 0.5),
    );

    final snapshot = await AppConfigFile.snapshotText(db);
    final decoded = jsonDecode(snapshot) as Map<String, dynamic>;
    expect(decoded['version'], 2);
    final image = decoded['image'] as Map<String, dynamic>;
    final pluginJson = (image['plugins'] as List).single as Map<String, dynamic>;
    expect(pluginJson['builtin'], isFalse);
    final package = pluginJson['package'] as Map<String, dynamic>;
    expect(package['id'], 'example.custom');
    expect(package['code'], customPlugin.code);

    final providerJson = (image['providers'] as List).single as Map<String, dynamic>;
    expect(providerJson['config'], containsPair('apiKey', 'sk-image-secret'));
    expect(providerJson['config'], containsPair('pluginId', 'example.custom'));
    expect((image['styles'] as List).single, containsPair('name', '我的风格'));

    final result = await AppConfigFile.applyText(db, snapshot);
    expect(result.imageChanged, isFalse, reason: '相同快照不应重建插件/provider/风格');
    final storedProvider = (await ImageConfigRepository(db).all()).single;
    expect(storedProvider.id, providerId);
    expect(storedProvider.config.pluginSettings, validPluginSettings);
    expect((await ImagePluginRepository(db).all()).single.code, customPlugin.code);
    expect((await ImageStyleRepository(db).all()).single.name, '我的风格');
  });

  test('custom plugin + provider are restored from a v2 file', () async {
    final text = jsonEncode(v2File(
      plugins: [customPluginEntry()],
      imageProviders: [providerEntry()],
      styles: [
        {
          'name': '文件风格',
          'artist': 'best quality',
          'sampler': 'k_euler',
          'noiseSchedule': 'karras',
          'scale': 7,
          'cfg': 0.25,
          'negative': 'lowres',
        },
      ],
    ));

    final result = await AppConfigFile.applyText(db, text);
    expect(result.imageChanged, isTrue);
    expect(result.pluginCount, 1);
    expect(result.imageProviderCount, 1);
    expect(result.styleCount, 1);

    final plugin = (await ImagePluginRepository(db).all()).single;
    expect(plugin.id, 'example.custom');
    expect(plugin.code, customPlugin.code);
    expect(plugin.fields.map((field) => field.key), contains('token'));
    expect(plugin.enabled, isTrue);

    final provider = (await ImageConfigRepository(db).all()).single;
    expect(provider.displayName, '自定义生图');
    expect(provider.isActive, isTrue);
    expect(provider.position, 0);
    expect(provider.config.pluginId, 'example.custom');
    expect(provider.config.apiKey, 'sk-image-secret');
    expect(provider.config.pluginSettings['token'], 'plugin-secret');

    final style = (await ImageStyleRepository(db).all()).single;
    expect(style.name, '文件风格');
    expect(style.cfg, 0.25);
    expect(style.scale, 7);
  });

  test('builtin plugins only restore enabled; snapshot strips package/code', () async {
    await ImagePluginRepository(db).upsertBuiltins();
    final snapshot = jsonDecode(await AppConfigFile.snapshotText(db)) as Map<String, dynamic>;
    final plugins = (snapshot['image'] as Map)['plugins'] as List;
    final nai2 = plugins.cast<Map>().firstWhere((p) => p['id'] == 'microscritt.nai2');
    expect(nai2['builtin'], isTrue);
    expect(nai2.containsKey('package'), isFalse);
    expect(nai2.containsKey('code'), isFalse);
    expect(nai2['version'], isA<String>());

    // 文件里停用内置插件:库中代码保持不变,只翻转 enabled。
    await AppConfigFile.applyText(
      db,
      jsonEncode(v2File(plugins: [builtinEntry('microscritt.nai2', enabled: false)])),
    );
    final stored = (await ImagePluginRepository(db).all())
        .firstWhere((plugin) => plugin.id == 'microscritt.nai2');
    expect(stored.enabled, isFalse);
    expect(stored.code, contains('Nai2API'));
    final all = await ImagePluginRepository(db).all();
    expect(all, hasLength(3), reason: '内置永久保留,文件未列出的其它内置不被删除');
  });

  test('normalizes image provider actives and clamps count', () async {
    await ImagePluginRepository(db).upsertBuiltins();
    final text = jsonEncode(v2File(
      imageProviders: [
        providerEntry(
          displayName: 'A',
          pluginId: 'microscritt.chat-completions',
          config: {'pluginSettings': const {}, 'count': 99},
        ),
        providerEntry(
          displayName: 'B',
          pluginId: 'microscritt.chat-completions',
          config: {'pluginSettings': const {}, 'count': 0},
        ),
        providerEntry(
          displayName: 'C',
          pluginId: 'microscritt.chat-completions',
          isActive: false,
          config: {'pluginSettings': const {}, 'count': 2},
        ),
      ],
    ));
    final result = await AppConfigFile.applyText(db, text);
    expect(result.imageProviderCount, 3);

    final providers = await ImageConfigRepository(db).all();
    expect(providers.map((p) => p.displayName), ['A', 'B', 'C']);
    expect(providers.map((p) => p.isActive), [true, false, false]);
    expect(providers.map((p) => p.position), [0, 1, 2]);
    expect(providers.map((p) => p.config.count), [6, 1, 2]);
  });

  test('first provider becomes active when none is active', () async {
    await ImagePluginRepository(db).upsertBuiltins();
    await AppConfigFile.applyText(
      db,
      jsonEncode(v2File(
        imageProviders: [
          providerEntry(
            displayName: 'A',
            pluginId: 'microscritt.chat-completions',
            isActive: false,
            config: {'pluginSettings': const {}},
          ),
          providerEntry(
            displayName: 'B',
            pluginId: 'microscritt.chat-completions',
            isActive: false,
            config: {'pluginSettings': const {}},
          ),
        ],
      )),
    );
    final providers = await ImageConfigRepository(db).all();
    expect(providers.first.isActive, isTrue);
    expect(providers.last.isActive, isFalse);
    expect((await ImageConfigRepository(db).loadActiveConfig())!.pluginId,
        'microscritt.chat-completions');
  });

  test('missing plugin / bad settings / duplicate ids and names are rejected', () async {
    Future<void> expectRejected(Map<String, dynamic> payload) async {
      await expectLater(
        AppConfigFile.applyText(db, jsonEncode(payload)),
        throwsA(isA<FormatException>()),
      );
    }

    // provider 引用了不存在的插件。
    await expectRejected(v2File(
      plugins: [customPluginEntry()],
      imageProviders: [providerEntry(pluginId: 'missing.plugin')],
    ));
    // required 设置为空。
    await expectRejected(v2File(
      plugins: [customPluginEntry()],
      imageProviders: [
        providerEntry(config: {'pluginSettings': const {'endpoint': 'https://x.example.com'}}),
      ],
    ));
    // 类型不匹配。
    await expectRejected(v2File(
      plugins: [customPluginEntry()],
      imageProviders: [
        providerEntry(config: {
          'pluginSettings': const {'token': 'x', 'n': 'not-int'},
        }),
      ],
    ));
    // select 值不在 options。
    await expectRejected(v2File(
      plugins: [customPluginEntry()],
      imageProviders: [
        providerEntry(config: {
          'pluginSettings': const {'token': 'x', 'mode': 'z'},
        }),
      ],
    ));
    // url 非 HTTP(S)。
    await expectRejected(v2File(
      plugins: [customPluginEntry()],
      imageProviders: [
        providerEntry(config: {
          'pluginSettings': const {'token': 'x', 'endpoint': 'ftp://x.example.com'},
        }),
      ],
    ));
    // 内置 id 带 package。
    await expectRejected(v2File(plugins: [
      {
        'id': 'microscritt.nai2',
        'builtin': true,
        'package': jsonDecode(customPlugin.toPackageJson()),
      },
    ]));
    // 插件 id 重复。
    await expectRejected(v2File(plugins: [customPluginEntry(), customPluginEntry()]));
    // 风格名重复。
    await expectRejected(v2File(styles: [
      {'name': '重复风格'},
      {'name': '重复风格'},
    ]));
    // 没有可应用配置。
    await expectRejected({'version': 2});
  });

  test('styles with builtin preset names are skipped, not overwritten', () async {
    final result = await AppConfigFile.applyText(
      db,
      jsonEncode(v2File(styles: [
        {'name': '动漫插画', 'artist': 'should-not-apply'},
        {'name': '真正自定义', 'artist': 'mine'},
      ])),
    );
    expect(result.skippedStyles, 1);
    expect(result.styleCount, 1);
    expect(result.warnings, isNotEmpty);
    final styles = await ImageStyleRepository(db).all();
    expect(styles.single.name, '真正自定义');
    expect(styles.any((style) => style.name == '动漫插画'), isFalse);
  });

  test('version is strictly validated', () async {
    await expectLater(
      AppConfigFile.applyText(db, jsonEncode({'user': {'name': 'X'}})),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      AppConfigFile.applyText(db, jsonEncode({'version': '2', 'user': {'name': 'X'}})),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      AppConfigFile.applyText(db, jsonEncode({'version': 3, 'user': {'name': 'X'}})),
      throwsA(isA<FormatException>()),
    );
  });

  test('a DB failure mid-transaction rolls back user / llm / image', () async {
    await UserRepository(db).save(const UserProfile(name: 'Alice'));
    await seedProvider();
    // 用 trigger 在写风格时强制失败,验证此前已写入的 user / llm 也回滚。
    await db.db.execute('''
      CREATE TRIGGER fail_style BEFORE INSERT ON image_styles
      BEGIN
        SELECT RAISE(ABORT, 'boom');
      END;
    ''');

    final text = jsonEncode({
      'version': 2,
      'user': {'name': 'Bob'},
      'llm': {
        'providers': [
          {
            'providerId': 'openai',
            'displayName': 'Renamed',
            'baseUrl': 'https://api.example.com',
            'protocol': 'openai',
            'apiKey': 'sk-test',
            'models': [
              {'modelId': 'gpt-test', 'displayName': 'GPT Test'},
            ],
          },
        ],
      },
      'image': {
        'styles': [
          {'name': 'trigger-target'},
        ],
      },
    });

    await expectLater(AppConfigFile.applyText(db, text), throwsA(anything));
    expect(await UserRepository(db).name(), 'Alice');
    expect((await LlmProviderRepository(db).all()).single.displayName, 'OpenAI');
    expect(await ImageStyleRepository(db).all(), isEmpty);
  });

  test('snapshot exposes image keys, secrets and plugin code', () async {
    await UserRepository(db).save(const UserProfile(name: 'Alice'));
    await seedProvider();
    await ImagePluginRepository(db).save(customPlugin);
    await ImageConfigRepository(db).saveProvider(
      ImageProviderRecord(
        id: 0,
        displayName: '自定义生图',
        isActive: true,
        config: const ImageConfig(
          baseUrl: 'https://custom.example.com',
          apiKey: 'sk-image-secret',
          model: 'model-x',
          size: '竖图',
          scale: 6,
          cfg: 0.5,
          negative: 'bad',
          sampler: 'k_euler',
          artist: 'quality',
          noiseSchedule: 'karras',
          steps: 28,
          count: 2,
          pluginId: 'example.custom',
          pluginSettings: validPluginSettings,
        ),
      ),
    );

    final text = await AppConfigFile.snapshotText(db);
    expect(text, contains('"version": 2'));
    expect(text, contains('sk-test'), reason: 'LLM 密钥在文本中可见(既定取舍)');
    expect(text, contains('sk-image-secret'));
    expect(text, contains('plugin-secret'));
    expect(text, contains('function step'), reason: '自定义插件 code 可见');

    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final config =
        (((decoded['image'] as Map)['providers'] as List).single as Map)['config'] as Map;
    for (final key in [
      'kind',
      'baseUrl',
      'apiKey',
      'model',
      'size',
      'scale',
      'cfg',
      'negative',
      'sampler',
      'artist',
      'noiseSchedule',
      'steps',
      'count',
      'pluginId',
      'pluginSettings',
    ]) {
      expect(config.containsKey(key), isTrue, reason: '缺少字段 $key');
    }
    expect(config['kind'], 'plugin');
    expect(config['count'], 2);
    expect(config['pluginSettings'], containsPair('mode', 'a'));
  });
}