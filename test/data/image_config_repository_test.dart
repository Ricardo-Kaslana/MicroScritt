// 生图 provider 仓储:插件关联、动态设置、活跃互斥与脏值兜底。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_config_repository.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late ImageConfigRepository repo;

  // 逐测试关闭连接:sqflite 的共享内存库在同一进程内跨连接共享,
  // 不关闭会让上一测试的数据残留到下一测试。
  setUp(() async {
    db = await openTestDb();
    repo = ImageConfigRepository(db);
  });
  tearDown(() async {
    await db.db.close();
  });

  ImageProviderRecord rec({
    int id = 0,
    String name = 'c',
    bool active = false,
    String? baseUrl,
    String apiKey = 'k',
    String model = 'm',
    int? steps,
    double? cfg,
    int count = 1,
    String? pluginId = 'microscritt.chat-completions',
    Map<String, dynamic> pluginSettings = const {},
  }) => ImageProviderRecord(
    id: id,
    displayName: name,
    isActive: active,
    config: ImageConfig(
      kind: ImageBackendKind.plugin,
      baseUrl: baseUrl ?? '',
      apiKey: apiKey,
      model: model,
      steps: steps,
      cfg: cfg,
      count: count,
      pluginId: pluginId,
      pluginSettings: pluginSettings,
    ),
  );

  test('saveProvider round-trips every field (含插件关联与动态设置)', () async {
    final id = await repo.saveProvider(
      rec(
        name: '网关',
        baseUrl: 'https://nai.example.com',
        apiKey: 'sk-nai-secret',
        model: 'nai-diffusion-4-5-full',
        steps: 40,
        cfg: 0.35,
        count: 4,
        pluginId: 'microscritt.nai2',
        pluginSettings: const {'size': '横图'},
      ),
    );

    final loaded = await repo.byId(id);
    expect(loaded, isNotNull);
    expect(loaded!.displayName, '网关');
    expect(loaded.isActive, isTrue, reason: '首条落库自动置活跃');
    expect(loaded.config.kind, ImageBackendKind.plugin);
    expect(loaded.config.pluginId, 'microscritt.nai2');
    expect(loaded.config.baseUrl, 'https://nai.example.com');
    expect(loaded.config.apiKey, 'sk-nai-secret');
    expect(loaded.config.model, 'nai-diffusion-4-5-full');
    expect(loaded.config.steps, 40);
    expect(loaded.config.cfg, 0.35);
    expect(loaded.config.count, 4);
    expect(loaded.config.pluginSettings, {'size': '横图'});
  });

  test('多套配置的 api_key 与动态设置互不覆盖', () async {
    await repo.saveProvider(
      rec(name: '网关', apiKey: 'sk-gateway', model: 'g:k_euler'),
    );
    await repo.saveProvider(
      rec(
        name: 'nai2',
        apiKey: 'sk-nai-2',
        model: 'nai-diffusion-4-5-full',
        steps: 35,
        pluginId: 'microscritt.nai2',
        pluginSettings: const {'size': '方图'},
      ),
    );

    final all = await repo.all();
    expect(all, hasLength(2));
    expect(all[0].config.apiKey, 'sk-gateway');
    expect(all[1].config.apiKey, 'sk-nai-2');
    expect(all[0].config.pluginSettings, isEmpty);
    expect(all[1].config.pluginSettings, {'size': '方图'});
    expect(all[0].config.steps, isNull);
    expect(all[1].config.steps, 35);
  });

  test('首条自动活跃、后续新增不抢占;setActive 互斥且 loadActiveConfig 跟随', () async {
    final a = await repo.saveProvider(rec(name: 'A', apiKey: 'k-a'));
    final b = await repo.saveProvider(rec(name: 'B', apiKey: 'k-b'));

    expect((await repo.byId(a))!.isActive, isTrue);
    expect((await repo.byId(b))!.isActive, isFalse);
    expect((await repo.loadActiveConfig())!.apiKey, 'k-a');

    await repo.setActive(b);
    expect((await repo.byId(a))!.isActive, isFalse);
    expect((await repo.byId(b))!.isActive, isTrue);
    expect((await repo.loadActiveConfig())!.apiKey, 'k-b');
  });

  test('update 已有配置不新增行', () async {
    final id = await repo.saveProvider(rec(name: 'A', apiKey: 'old'));
    await repo.saveProvider(rec(id: id, name: 'A2', apiKey: 'new'));

    final all = await repo.all();
    expect(all, hasLength(1));
    expect(all.single.id, id);
    expect(all.single.displayName, 'A2');
    expect(all.single.config.apiKey, 'new');
  });

  test('删除非活跃配置不影响当前在用', () async {
    final a = await repo.saveProvider(rec(name: 'A', apiKey: 'k-a'));
    final b = await repo.saveProvider(rec(name: 'B', apiKey: 'k-b'));

    await repo.deleteProvider(b);
    expect((await repo.byId(a))!.isActive, isTrue);
    expect((await repo.loadActiveConfig())!.apiKey, 'k-a');
  });

  test('删除当前在用的配置会顺位补一条活跃(不留"有配置但无活跃")', () async {
    final a = await repo.saveProvider(rec(name: 'A', apiKey: 'k-a'));
    final b = await repo.saveProvider(rec(name: 'B', apiKey: 'k-b'));

    await repo.deleteProvider(a);
    expect((await repo.byId(b))!.isActive, isTrue);
    expect((await repo.loadActiveConfig())!.apiKey, 'k-b');
  });

  test('删光后 loadActiveConfig 为 null(生图整轮跳过)', () async {
    final a = await repo.saveProvider(rec(name: 'A'));
    await repo.deleteProvider(a);
    expect(await repo.loadActiveConfig(), isNull);
    expect(await repo.all(), isEmpty);
  });

  test('没有任何配置时 loadActiveConfig 为 null', () async {
    expect(await repo.loadActiveConfig(), isNull);
  });

  test('count is clamped to the 1-6 range on load', () async {
    final id = await repo.saveProvider(rec(count: 6));
    await db.db.rawUpdate(
      'UPDATE image_providers SET count = 99 WHERE id = ?',
      [id],
    );
    expect((await repo.byId(id))!.config.count, 6);
    await db.db.rawUpdate('UPDATE image_providers SET count = 0 WHERE id = ?', [
      id,
    ]);
    expect((await repo.byId(id))!.config.count, 1);
  });

  test('count/settings 列缺值兜底(裸 INSERT 的老行)', () async {
    await db.db.insert('image_providers', {
      'display_name': 'legacy',
      'base_url': 'https://gateway.example.com/v1',
      'api_key': 'k1',
      'model': 'm1',
    });
    final row = (await repo.all()).single;
    expect(row.config.count, 1);
    expect(row.config.pluginSettings, isEmpty);
  });

  test('settings_json 非法回落空对象(启动水合不能因脏值抛错)', () async {
    await db.db.insert('image_providers', {
      'display_name': 'dirty',
      'kind': 'plugin',
      'base_url': '',
      'api_key': '',
      'model': '',
      'plugin_id': 'x',
      'settings_json': '[not, an, object]',
      'is_active': 1,
    });
    expect((await repo.loadActiveConfig())!.pluginSettings, isEmpty);
  });

  test('all() 按 position 序返回', () async {
    await repo.saveProvider(
      ImageProviderRecord(
        id: 0,
        displayName: 'second',
        position: 5,
        config: const ImageConfig(apiKey: 'k2', model: 'm2'),
      ),
    );
    await repo.saveProvider(
      ImageProviderRecord(
        id: 0,
        displayName: 'first',
        position: 1,
        config: const ImageConfig(apiKey: 'k1', model: 'm1'),
      ),
    );
    expect((await repo.all()).map((r) => r.displayName).toList(), [
      'first',
      'second',
    ]);
  });

  test('ImageProviderRecord.defaultNameFor 返回通用插件默认名', () {
    expect(ImageProviderRecord.defaultNameFor(ImageBackendKind.plugin), '生图插件');
  });
}
