import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/models/endpoint_compat.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late LlmProviderRepository repo;

  setUp(() async {
    db = await openTestDb();
    repo = LlmProviderRepository(db);
  });

  tearDown(() async {
    await db.db.close();
  });

  LlmModelEntry model(int id, String mid, {bool active = false}) => LlmModelEntry(
    id: id,
    providerId: 0,
    modelId: mid,
    displayName: 'M $mid',
    contextCapacity: 128000,
    maxOutput: 4096,
    isActive: active,
  );

  test('saves and reloads a provider with its model catalog', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'my-proxy',
        displayName: '我的代理',
        baseUrl: 'https://proxy.example.com/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'sk-xyz',
        isActive: true,
        models: [model(0, 'gpt-a', active: true), model(0, 'gpt-b')],
      ),
    );

    final all = await repo.all();
    expect(all, hasLength(1));
    final p = all.single;
    expect(p.providerId, 'my-proxy');
    expect(p.displayName, '我的代理');
    expect(p.protocol, LlmProtocol.openaiCompat);
    expect(p.models, hasLength(2));
    expect(p.activeModel!.modelId, 'gpt-a');
  });

  test('multiple providers are ordered and active state is tracked', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'openai',
        displayName: 'OpenAI 兼容',
        baseUrl: 'https://api.openai.com/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k1',
        isActive: false,
        models: [model(0, 'gpt-4o', active: true)],
      ),
    );
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'anthropic',
        displayName: 'Anthropic',
        baseUrl: 'https://api.anthropic.com',
        protocol: LlmProtocol.anthropic,
        apiKey: 'k2',
        isActive: true,
        models: [model(0, 'claude-3-5-sonnet', active: true)],
      ),
    );

    final all = await repo.all();
    expect(all, hasLength(2));
    final active = all.where((p) => p.isActive).single;
    expect(active.providerId, 'anthropic');

    // setActive 把另一家切为当前。
    final openai = all.firstWhere((p) => p.providerId == 'openai');
    await repo.setActive(providerId: openai.id, modelId: openai.activeModel!.id);
    final reloaded = await repo.all();
    expect(reloaded.firstWhere((p) => p.providerId == 'openai').isActive, isTrue);
    expect(reloaded.firstWhere((p) => p.providerId == 'anthropic').isActive, isFalse);
  });

  test('loadBackendConfig maps active provider + active model to BackendConfig', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'anthropic',
        displayName: 'Anthropic',
        baseUrl: 'https://api.anthropic.com',
        protocol: LlmProtocol.anthropic,
        apiKey: 'sk-an',
        isActive: true,
        models: [model(0, 'claude-3-5-sonnet', active: true)],
      ),
    );

    final config = await repo.loadBackendConfig();
    expect(config, isNotNull);
    expect(config!.provider, BackendProvider.anthropic);
    expect(config.baseUrl, 'https://api.anthropic.com');
    expect(config.model, 'claude-3-5-sonnet');
    expect(config.maxTokens, 4096);
  });

  test('loadBackendConfig returns null when no active provider/model', () async {
    expect(await repo.loadBackendConfig(), isNull);

    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'openai',
        displayName: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        isActive: false, // 非当前
        models: [model(0, 'gpt-4o', active: true)],
      ),
    );
    expect(await repo.loadBackendConfig(), isNull);
  });

  test('compat options round-trip and reach the runtime BackendConfig', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'a',
        displayName: 'A',
        baseUrl: 'http://a',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        isActive: true,
        compat: const EndpointCompat(replyViaTool: true),
        models: [model(0, 'm', active: true)],
      ),
    );

    final reloaded = (await repo.all()).single;
    expect(reloaded.compat.replyViaTool, isTrue);
    expect((await repo.loadBackendConfig())!.compat.replyViaTool, isTrue);

    // 关掉后写回:全关落空串(与列默认值一致)。
    await repo.saveProvider(reloaded.copyWith(compat: EndpointCompat.standard));
    expect((await repo.all()).single.compat.isStandard, isTrue);
  });

  test('corrupt compat_flags wire falls back to standard instead of crashing load', () async {
    // 启动即水合 provider 行,坏值抛错会炸掉整个 App —— 与 extra_headers
    // 同一条 fail-safe 家规。
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'a',
        displayName: 'A',
        baseUrl: 'http://a',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        models: [model(0, 'm1')],
      ),
    );
    final id = (await repo.all()).single.id;
    await db.db.update('llm_providers', {'compat_flags': '{not json'}, where: 'id = ?', whereArgs: [id]);

    final loaded = (await repo.all()).single;
    expect(loaded.compat.isStandard, isTrue);
  });

  test('compat flags wire codec tolerates garbage', () {
    expect(EndpointCompat.fromWire(null).isStandard, isTrue);
    expect(EndpointCompat.fromWire('').isStandard, isTrue);
    expect(EndpointCompat.fromWire('{broken').isStandard, isTrue);
    expect(EndpointCompat.fromWire('[]').isStandard, isTrue);
    // 旧版本写入的 requiredTools 键按未知字段忽略。
    expect(EndpointCompat.fromWire('{"requiredTools":true}').isStandard, isTrue);
    expect(EndpointCompat.fromWire('{"requiredTools":false}').isStandard, isTrue);
    expect(EndpointCompat.standard.toWire(), '');
    expect(const EndpointCompat(replyViaTool: true).toWire(), '{"replyViaTool":true}');
    expect(const EndpointCompat(noncePrefix: true).toWire(), '{"noncePrefix":true}');
    expect(
      EndpointCompat.fromWire('{"requiredTools":true,"replyViaTool":true,"noncePrefix":true}'),
      const EndpointCompat(replyViaTool: true, noncePrefix: true),
    );
  });

  test('deleting a provider removes it and its models', () async {
    var id = 0;
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'a',
        displayName: 'A',
        baseUrl: 'http://a',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        models: [model(0, 'm1')],
      ),
    );
    // 取回真实 id。
    final p = (await repo.all()).single;
    id = p.id;
    await repo.deleteProvider(id);
    expect(await repo.all(), isEmpty);
    final rows = await db.db.query('llm_models', where: 'provider_id = ?', whereArgs: [id]);
    expect(rows, isEmpty);
  });

  test('loadConfigForModel resolves a specific model to a BackendConfig', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'anthropic',
        displayName: 'Anthropic',
        baseUrl: 'https://api.anthropic.com',
        protocol: LlmProtocol.anthropic,
        apiKey: 'sk-an',
        // 两个模型:主写选中 claude,后台指定 haiku。
        models: [model(0, 'claude-3-5-sonnet', active: true), model(0, 'claude-3-haiku')],
      ),
    );
    final p = (await repo.all()).single;
    final backgroundModel = p.models.firstWhere((m) => m.modelId == 'claude-3-haiku');

    final config = await repo.loadConfigForModel(backgroundModel.id);
    expect(config, isNotNull);
    expect(config!.provider, BackendProvider.anthropic);
    expect(config.baseUrl, 'https://api.anthropic.com');
    expect(config.model, 'claude-3-haiku');
    expect(config.apiKey, 'sk-an');
  });

  test('loadConfigForModel returns null for an unknown model id', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'openai',
        displayName: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        models: [model(0, 'gpt-4o')],
      ),
    );
    expect(await repo.loadConfigForModel(999999), isNull);
  });

  test('per-model temperature round-trips through BackendConfig (EZ v56)', () async {
    // 每模型 temperature:显式设置 → BackendConfig 拿到该值;留空 → 主写默认 0.7。
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'openai',
        displayName: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        isActive: true,
        models: [
          LlmModelEntry(
            id: 0, providerId: 0, modelId: 'creative', displayName: 'Creative',
            contextCapacity: 128000, maxOutput: 4096, temperature: 1.2, isActive: true,
          ),
          LlmModelEntry(
            id: 0, providerId: 0, modelId: 'defaulted', displayName: 'Defaulted',
            contextCapacity: 128000, maxOutput: 4096, // temperature 未设
          ),
        ],
      ),
    );
    final p = (await repo.all()).single;
    expect(p.models.firstWhere((m) => m.modelId == 'creative').temperature, 1.2);
    expect(p.models.firstWhere((m) => m.modelId == 'defaulted').temperature, isNull);

    // 主写走 loadBackendConfig(取 active provider + active model) → 用当次选中模型的 temperature。
    final main = await repo.loadBackendConfig();
    expect(main!.temperature, 1.2);
    // 后台经 loadConfigForModel 解析到"未设"模型 → BackendConfig 兜底 0.7。
    final defModel = p.models.firstWhere((m) => m.modelId == 'defaulted');
    final def = await repo.loadConfigForModel(defModel.id);
    expect(def!.temperature, 0.7);
    // 显式设过温度的模型走 loadConfigForModel 时透传原值(与主写口径一致)。
    final creModel = p.models.firstWhere((m) => m.modelId == 'creative');
    final cre = await repo.loadConfigForModel(creModel.id);
    expect(cre!.temperature, 1.2);
  });

  test('editing an existing provider persists changes (id preserved)', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'x',
        displayName: 'X',
        baseUrl: 'http://x/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k1',
        models: [model(0, 'm1', active: true)],
      ),
    );
    final saved = (await repo.all()).single;

    await repo.saveProvider(
      LlmProviderConfig(
        id: saved.id,
        providerId: 'x',
        displayName: 'X2',
        baseUrl: 'http://x2/v1',
        protocol: LlmProtocol.anthropic,
        apiKey: 'k2',
        isActive: true,
        models: [model(0, 'm2', active: true)],
      ),
    );

    final after = (await repo.all()).single;
    expect(after.id, saved.id); // 保持同一行
    expect(after.displayName, 'X2');
    expect(after.protocol, LlmProtocol.anthropic);
    expect(after.models.single.modelId, 'm2');
  });

  test('extra headers round-trip (normalized to lowercase) and flow into BackendConfig', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'my-gateway',
        displayName: 'My Gateway',
        baseUrl: 'https://gateway.example.com/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'sk-x',
        isActive: true,
        models: [model(0, 'm', active: true)],
        extraHeaders: const {
          'Origin': 'https://client.example.com',
          'Referer': 'https://client.example.com/',
          'User-Agent': 'PostmanRuntime/1.1.0',
        },
      ),
    );

    final p = (await repo.all()).single;
    // dart:io 发送不区分大小写,存库即统一小写键。
    expect(p.extraHeaders.keys.every((k) => k == k.toLowerCase()), isTrue);
    expect(p.extraHeaders['origin'], 'https://client.example.com');
    expect(p.extraHeaders['user-agent'], 'PostmanRuntime/1.1.0');

    final config = await repo.loadBackendConfig();
    expect(config, isNotNull);
    expect(config!.extraHeaders, p.extraHeaders);
  });

  test('provider without extra headers loads with an empty map', () async {
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'x',
        displayName: 'X',
        baseUrl: 'http://x',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        models: [model(0, 'm1')],
      ),
    );
    final p = (await repo.all()).single;
    expect(p.extraHeaders, isEmpty);

    final config = await repo.loadConfigForModel(p.models.single.id);
    expect(config, isNotNull);
    expect(config!.extraHeaders, isEmpty);
  });

  test('saving a provider preserves model row ids (background_model_id stays valid)', () async {
    // 回归:saveProvider 曾整批删模型重插,所有模型拿到新自增 id,按
    // llm_models.id 引用的 app_settings.background_model_id 随即悬空,
    // 后台 agent 静默回退主写模型。upsert 后未变/改名行的 id 必须稳定。
    await repo.saveProvider(
      LlmProviderConfig(
        id: 0,
        providerId: 'p',
        displayName: 'P',
        baseUrl: 'http://x',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'k',
        models: [model(0, 'm1'), model(0, 'm2')],
      ),
    );
    final saved = (await repo.all()).single;
    final m1 = saved.models[0];

    // 再保存:改 m1 的展示名、删掉 m2、新增 m3 —— m1 的 id 不得漂移。
    await repo.saveProvider(
      saved.copyWith(
        displayName: 'P 改名', // provider 级改动同样不能牵连模型 id
        models: [
          m1.copyWith(displayName: 'M1 改名'),
          model(0, 'm3'),
        ],
      ),
    );
    final after = (await repo.all()).single;
    expect(after.displayName, 'P 改名');
    expect(after.models.map((m) => m.modelId), ['m1', 'm3']);
    expect(after.models.first.id, m1.id, reason: '未变行的 id 必须稳定(外键引用)');
    expect(after.models.first.displayName, 'M1 改名');
    // 被引用的模型 id 仍能解析出完整配置(后台 agent 选型不悬空)。
    expect(await repo.loadConfigForModel(m1.id), isNotNull);
    // 消失的 m2 行确实删除,不留孤儿。
    expect(after.models.where((m) => m.modelId == 'm2'), isEmpty);
  });

  test('extra header wire codec tolerates garbage and normalizes keys', () {
    // 老行默认空串 / 手改坏的 JSON:一律回退空 map,不挡 provider 加载。
    expect(LlmProviderConfig.extraHeadersFromWire(null), isEmpty);
    expect(LlmProviderConfig.extraHeadersFromWire(''), isEmpty);
    expect(LlmProviderConfig.extraHeadersFromWire('{broken'), isEmpty);
    expect(LlmProviderConfig.extraHeadersFromWire('[]'), isEmpty);
    // 非字符串值跳过、键归一化小写。
    expect(LlmProviderConfig.extraHeadersFromWire('{"Origin":"https://x","skip":123}'), {
      'origin': 'https://x',
    });

    expect(LlmProviderConfig.extraHeadersWire({}), '');
    expect(LlmProviderConfig.extraHeadersWire({'X-A': ' v '}), '{"x-a":"v"}');
  });
}
