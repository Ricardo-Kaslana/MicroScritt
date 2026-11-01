// 文本配置文件 microscritt-config.json 的快照写出、外部编辑应用与 fail-safe 容错。
// 文件是启动时权威,应用按节提交;坏文件只打日志,库与文件都保持原样。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_config_file.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/data/user_repository.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/models/user.dart';
import '../support/test_database.dart';

void main() {
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

  test('writes a readable snapshot, and applying it unchanged is a no-op', () async {
    await UserRepository(db).save(const UserProfile(name: 'Alice'));
    final modelId = await seedProvider();
    await AppSettingsRepository(db).save(
      (await AppSettingsRepository(db).load()).copyWith(backgroundModelId: modelId),
    );

    await file.writeSnapshot(db);
    final text = File(file.path).readAsStringSync();
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['version'], 1);
    expect((decoded['user'] as Map)['name'], 'Alice');
    final provider = (decoded['llm'] as Map)['providers'][0] as Map;
    expect(provider['providerId'], 'openai');
    expect(provider['apiKey'], 'sk-test');
    // 端点兼容选项以 compat 对象随 provider 一并落文件。
    expect(provider['compat'], isA<Map>());
    expect((provider['models'] as List).single['modelId'], 'gpt-test');

    final result = await file.applyIfPresent(db);
    expect(result, isNotNull);
    expect(result!.changed, isFalse);
    // 相同快照不重建模型行,后台模型引用保持稳定。
    expect((await LlmProviderRepository(db).all()).single.models.single.id, modelId);
    expect((await AppSettingsRepository(db).load()).backgroundModelId, modelId);
  });

  test('applies external edits to user name / provider fields and keeps the avatar', () async {
    await UserRepository(db).save(const UserProfile(name: 'Alice', avatarBase64: 'aGVsbG8='));
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
    expect(user.avatarBase64, 'aGVsbG8=');
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
}
