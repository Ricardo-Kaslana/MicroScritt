// 生图配置编辑页的通用表单(生图插件是唯一后端):插件预选与保存、
// 画面风格回填、插件动态字段,以及空插件目录拒绝保存。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_config_repository.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/models/image_plugin.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/image_provider_edit_screen.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  const chatPlugin = ImagePlugin(
    id: 'microscritt.chat-completions',
    name: '对话式生图网关(OpenAI 兼容)',
    version: '1.0.0',
    code: 'function step(){}',
    usesStandardParams: true,
    supportsTest: true,
    supportsListModels: true,
    permissions: ImagePluginPermissions(endpointSetting: 'baseUrl'),
  );
  const openaiPlugin = ImagePlugin(
    id: 'microscritt.openai-images',
    name: 'OpenAI Images 兼容',
    version: '1.0.0',
    code: 'function step(){}',
    fields: [
      ImagePluginField(
        key: 'size',
        label: '尺寸',
        type: ImagePluginFieldType.select,
        defaultValue: '1024x1024',
        options: [ImagePluginOption(value: '1024x1024', label: '1024 × 1024')],
      ),
    ],
    permissions: ImagePluginPermissions(endpointSetting: 'baseUrl'),
  );

  Widget harness({
    ImageProviderRecord? existing,
    List<ImagePlugin> plugins = const [],
  }) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      imagePluginsProvider.overrideWith((ref) => plugins),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ImageProviderEditScreen(existing: existing),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  Future<void> openEditor(
    WidgetTester tester, {
    ImageProviderRecord? existing,
    List<ImagePlugin> plugins = const [],
  }) async {
    // 放大视口,让长表单的保存按钮无需滚动即可命中(避免 hit-test 落空)。
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(existing: existing, plugins: plugins));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }

  Finder field(String label) => find.byKey(ValueKey('field_$label'));
  String fieldText(WidgetTester tester, String label) =>
      tester.widget<TextField>(field(label)).controller?.text ?? '';

  Future<void> tapSave(WidgetTester tester) async {
    await tester.runAsync(() async {
      final button = find.widgetWithText(FilledButton, '保存生图配置');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('新建:预选首个插件,标准参数区与刷新/测试按钮齐备,默认名取插件名', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openEditor(tester, plugins: const [chatPlugin]);

    expect(fieldText(tester, '配置名称'), '对话式生图网关(OpenAI 兼容)');
    expect(
      find.byKey(const ValueKey('image_plugin_microscritt.chat-completions')),
      findsOneWidget,
    );
    expect(find.text('刷新模型列表'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('画面风格'), findsOneWidget);
    // 尺寸/步数与模型、每次生图数量同级平铺,不存在「高级参数」折叠组。
    expect(find.text('高级参数'), findsNothing);
    expect(field('尺寸'), findsOneWidget);
    expect(field('步数 (steps)'), findsOneWidget);
    for (final label in [
      '提示词引导值 (scale)',
      '缩放引导值 (cfg)',
      '采样器 (sampler)',
      '画师串 (artist)',
      '噪声调度 (noise_schedule)',
      '负面提示词(留空用内置默认)',
    ]) {
      expect(field(label), findsNothing, reason: '$label 应只在自定义风格里维护');
    }

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('保存:kind=plugin、pluginId 与核心字段落库,首条自动活跃', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openEditor(tester, plugins: const [chatPlugin]);

    await tester.enterText(field('配置名称'), '我的网关');
    await tester.enterText(
      field('服务地址 (base URL)'),
      'https://gateway.example.com/v1',
    );
    await tester.enterText(field('API Key / Token'), 'sk-saved');
    await tester.enterText(field('步数 (steps)'), '35');
    await tapSave(tester);

    late ImageConfig? active;
    await tester.runAsync(() async {
      active = await ImageConfigRepository(db).loadActiveConfig();
    });
    expect(active!.kind, ImageBackendKind.plugin);
    expect(active!.pluginId, 'microscritt.chat-completions');
    expect(active!.baseUrl, 'https://gateway.example.com/v1');
    expect(active!.apiKey, 'sk-saved');
    expect(active!.size, '竖图');
    expect(active!.steps, 35);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('画面风格回填六参数并随保存落库', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openEditor(tester, plugins: const [chatPlugin]);

    await tester.enterText(field('配置名称'), '风格配置');
    await tester.enterText(
      field('服务地址 (base URL)'),
      'https://gateway.example.com/v1',
    );
    await tester.enterText(field('API Key / Token'), 'sk-style');

    await tester.tap(find.byKey(const ValueKey('image_style_自定义')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动漫插画').last);
    await tester.pump();
    await tapSave(tester);

    late ImageConfig? active;
    await tester.runAsync(() async {
      active = await ImageConfigRepository(db).loadActiveConfig();
    });
    expect(active!.artist, contains('anime illustration'));
    expect(active!.sampler, 'k_dpmpp_2m_sde');
    expect(active!.noiseSchedule, 'karras');
    expect(active!.scale, 6);
    expect(active!.cfg, 0);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('插件动态字段落 pluginSettings;无标准参数区', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openEditor(tester, plugins: const [openaiPlugin]);

    expect(find.text('画面风格'), findsNothing);
    expect(find.text('刷新模型列表'), findsNothing);
    expect(find.byKey(const ValueKey('plugin_field_size')), findsOneWidget);

    await tester.enterText(
      field('服务地址 (base URL)'),
      'https://img.example.com/v1',
    );
    await tester.enterText(field('API Key / Token'), 'sk-x');
    await tapSave(tester);

    late ImageConfig? active;
    await tester.runAsync(() async {
      active = await ImageConfigRepository(db).loadActiveConfig();
    });
    expect(active!.pluginId, 'microscritt.openai-images');
    expect(active!.pluginSettings, {'size': '1024x1024'});

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('空插件目录:显示管理入口且保存被拒', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openEditor(tester, plugins: const []);

    expect(find.text('管理生图插件'), findsOneWidget);
    await tester.enterText(field('配置名称'), '无名配置');
    await tapSave(tester);
    expect(find.text('请先选择已导入的生图插件'), findsOneWidget);
    late List<ImageProviderRecord> all;
    await tester.runAsync(() async {
      all = await ImageConfigRepository(db).all();
    });
    expect(all, isEmpty);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('编辑已有插件配置:保留 pluginId 与动态设置,保存是更新', (tester) async {
    late int id;
    await tester.runAsync(() async {
      db = await openTestDb();
      id = await ImageConfigRepository(db).saveProvider(
        ImageProviderRecord(
          id: 0,
          displayName: '旧名',
          config: ImageConfig(
            apiKey: 'sk-old',
            model: 'm',
            baseUrl: 'https://img.example.com/v1',
            pluginId: openaiPlugin.id,
            pluginSettings: const {'size': '1024x1024'},
          ),
        ),
      );
    });
    final existing = await tester.runAsync(
      () => ImageConfigRepository(db).byId(id),
    );
    await openEditor(tester, existing: existing, plugins: const [openaiPlugin]);

    expect(fieldText(tester, '配置名称'), '旧名');
    await tester.enterText(field('配置名称'), '新名');
    await tapSave(tester);

    late List<ImageProviderRecord> all;
    await tester.runAsync(() async {
      all = await ImageConfigRepository(db).all();
    });
    expect(all, hasLength(1));
    expect(all.single.id, id);
    expect(all.single.config.pluginId, openaiPlugin.id);
    expect(all.single.config.pluginSettings, {'size': '1024x1024'});

    await tester.runAsync(() => db.db.close());
  });
}
