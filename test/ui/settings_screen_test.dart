// 设置页 widget 测试:外观与「对话与后台」开关、LLM provider 列表与编辑入口、
// 生图配置区的空态、列表与当前使用切换。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_config_repository.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/settings_screen.dart';
import 'package:microscritt/ui/user_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  late AppDatabase db;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: SettingsScreen()),
  );

  /// 让 FutureProvider 读取真实 DB 后刷新一帧。
  Future<void> settleProviders(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }

  /// 逐段向下滚动直到目标文本进入视口(scrollUntilVisible 对惰性列表里
  /// 尚未构建的目标会抛 Bad state,这里自己循环 drag)。
  Future<void> scrollToListSection(
    WidgetTester tester,
    Finder scrollable,
    String text,
  ) async {
    final target = find.text(text);
    for (var i = 0; i < 30 && target.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(scrollable, const Offset(0, -250));
      await tester.pump();
    }
    await tester.pump();
    expect(target, findsOneWidget);
  }

  testWidgets('shows all sections and the add-provider button', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('外观'), findsOneWidget);
    // 「对话与后台」区块把 LLM 区挤出了首屏,逐段下滚再断言。
    expect(find.text('对话与后台'), findsOneWidget);
    final scrollable = find.byType(Scrollable).first;
    await scrollToListSection(tester, scrollable, 'LLM 后端');
    await scrollToListSection(tester, scrollable, '生图');
    expect(find.text('生图'), findsOneWidget);
    await scrollToListSection(tester, scrollable, '内容与扩展');
    expect(find.text('内容与扩展'), findsOneWidget);
    expect(find.text('全局提示词'), findsOneWidget);
    expect(find.text('Hooks'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('关于'),
      200,
      scrollable: scrollable,
    );
    expect(find.text('关于'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('chat background switch toggles and persists', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.pump();

    // 外观区里的聊天背景开关,默认关闭。
    final toggle = find.widgetWithText(SwitchListTile, '聊天背景');
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    // 打开开关 → 落库。
    await tester.tap(toggle);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    // 真实 DB 读必须在 runAsync 窗口内,否则在 fake-async 区会永不完成(挂死)。
    late bool persisted;
    await tester.runAsync(() async {
      persisted = (await AppSettingsRepository(
        db,
      ).load()).chatBackgroundEnabled;
    });
    expect(persisted, isTrue);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('context auto compact switch toggles and persists', (
    tester,
  ) async {
    // 自动压缩从"按条数阈值下拉"改为"占用率三挡 + 总开关":开关默认开启,
    // 关闭后落库(挡位是固定策略,不在 UI 暴露);副标题只留短文案,
    // 详细三挡说明经「查看说明」弹层展示。
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.pump();

    final scrollable = find.byType(Scrollable).first;
    await scrollToListSection(tester, scrollable, '上下文自动压缩');

    final toggle = find.widgetWithText(SwitchListTile, '上下文自动压缩');
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    // 副标题为短文案;点标题旁「查看说明」info 按钮(InfoButton)弹出三挡详情。
    expect(find.text('按窗口占用率三挡自动压缩'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byTooltip('查看说明'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('上下文自动压缩 · 三挡说明'), findsOneWidget);
    expect(find.textContaining('目标挡 20%'), findsOneWidget);
    expect(find.textContaining('软挡 60%'), findsOneWidget);
    expect(find.textContaining('硬挡 80%'), findsOneWidget);
    // 点「知道了」关闭弹层,不改变开关状态。
    await tester.tap(find.text('知道了'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.tap(toggle);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    late bool persisted;
    await tester.runAsync(() async {
      persisted = (await AppSettingsRepository(db).load()).autoCompactEnabled;
    });
    expect(persisted, isFalse);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('background blur slider adjusts and persists', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.pump();

    // 开关默认关闭 → 滑块存在、禁用、值 18。
    expect(find.byType(Slider), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 18.0);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);

    // 打开聊天背景 → 滑块启用。
    await tester.tap(find.widgetWithText(SwitchListTile, '聊天背景'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNotNull);

    // 拖动滑块 → onChangeEnd 落库。
    await tester.drag(find.byType(Slider), const Offset(150, 0));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    late double persisted;
    await tester.runAsync(() async {
      persisted = (await AppSettingsRepository(db).load()).chatBackgroundBlur;
    });
    expect(persisted, isNot(18.0));

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('user management entry navigates to the user screen', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('用户'), findsOneWidget); // 分区标题
    expect(find.text('用户管理'), findsOneWidget);

    await tester.tap(find.text('用户管理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 进入用户管理屏:可设置用户名与头像。
    expect(find.byType(UserScreen), findsOneWidget);
    expect(find.text('选择头像'), findsOneWidget);
    expect(find.widgetWithText(TextField, '用户名'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets(
    'LLM section shows provider tiles with models and current model',
    (tester) async {
      await tester.runAsync(() async {
        db = await openTestDb();
        await LlmProviderRepository(db).saveProvider(
          LlmProviderConfig(
            id: 0,
            providerId: 'anthropic',
            displayName: 'Anthropic',
            baseUrl: 'https://api.anthropic.com',
            protocol: LlmProtocol.anthropic,
            apiKey: 'sk-an',
            isActive: true,
            models: [
              LlmModelEntry(
                id: 0,
                providerId: 0,
                modelId: 'claude-3-5-sonnet',
                displayName: 'Claude Sonnet',
                contextCapacity: 200000,
                maxOutput: 8192,
                isActive: true,
              ),
              LlmModelEntry(
                id: 0,
                providerId: 0,
                modelId: 'claude-3-opus',
                displayName: 'Claude Opus',
                contextCapacity: 200000,
                maxOutput: 4096,
              ),
            ],
          ),
        );
      });
      await tester.pumpWidget(harness());
      await settleProviders(tester);
      // 「对话与后台」新区块把 LLM 区挤到首屏之下,先滚到位。
      await tester.scrollUntilVisible(
        find.text('Anthropic'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      expect(find.text('Anthropic'), findsWidgets);
      // 卡片只显示 provider 名称:协议/地址/模型个数等详情进了编辑页。
      expect(find.textContaining('https://api.anthropic.com'), findsNothing);
      expect(find.textContaining('模型 2 个'), findsNothing);
      expect(find.textContaining('Anthropic'), findsWidgets);
      // 设置页不再展示具体模型/当前模型(选择移到了聊天输入框的模型选择器)。
      expect(find.text('Claude Sonnet'), findsNothing);
      expect(find.text('Claude Opus'), findsNothing);

      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets('LLM section shows the seeded default deepseek provider tile', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // openTestDb 起步即清空 provider(测试从干净状态起步);这里用带种子的
      // 新库验证产品默认:全新安装直接就有 deepseek 官网 + deepseek-flash。
      db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
    });
    await tester.pumpWidget(harness());
    await settleProviders(tester);
    await tester.scrollUntilVisible(
      find.text('DeepSeek 官网'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    expect(find.text('DeepSeek 官网'), findsOneWidget);
    // 卡片只显示 provider 名称:地址/模型个数等详情进了编辑页。
    expect(find.textContaining('https://api.deepseek.com'), findsNothing);
    // 不再出现空态提示。
    expect(find.textContaining('还没有配置任何 LLM provider'), findsNothing);
    // 底单/选择器路径由模型选择条测试覆盖;设置页只确认默认 provider 落库并展示。

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('adding a provider navigates to the provider editor', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await settleProviders(tester);
    await tester.scrollUntilVisible(
      find.text('LLM 后端'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    // 空态提示。
    expect(find.textContaining('还没有配置任何 LLM provider'), findsOneWidget);

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('添加 Provider'),
      200,
      scrollable: scrollable,
    );
    // scrollUntilVisible 可能在按钮刚进入缓存区时停下(center 仍在屏外),先滚到视口
    // 中央并 pump 一帧,确保 tap 命中。
    await Scrollable.ensureVisible(
      tester.element(find.text('添加 Provider')),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.text('添加 Provider'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 进入新建 Provider 编辑器。
    expect(find.text('新建 Provider'), findsOneWidget);
    expect(find.text('Provider ID'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets(
    'provider edit screen persists provider + models (suffix shorthand)',
    (tester) async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await tester.pumpWidget(harness());
      await settleProviders(tester);

      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('添加 Provider'),
        200,
        scrollable: scrollable,
      );
      // scrollUntilVisible 可能在按钮刚进入缓存区时停下(center 仍在屏外),先滚到视口
      // 中央并 pump 一帧,确保 tap 命中。
      await Scrollable.ensureVisible(
        tester.element(find.text('添加 Provider')),
        alignment: 0.5,
      );
      await tester.pump();
      await tester.tap(find.text('添加 Provider'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 填 provider 字段。
      await tester.enterText(find.byKey(const ValueKey('field_显示名称')), '我的代理');
      await tester.enterText(
        find.byKey(const ValueKey('field_Provider ID')),
        'my-proxy',
      );
      await tester.enterText(
        find.byKey(const ValueKey('field_API 地址')),
        'https://proxy.example.com/v1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('field_API Key')),
        'sk-custom',
      );

      // 添加一个模型:上下文容量与最大输出支持 1m / 256k 简写。
      final editorScroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('添加模型'),
        200,
        scrollable: editorScroll,
      );
      // 编辑页加入「自定义请求头」区后页面变长,scrollUntilVisible 可能在按钮
      // 刚露边时停下(center 仍在视口外),tap 静默脱靶、弹层打不开。滚到视口
      // 中央再点,与上方「添加 Provider」同款处理。
      await Scrollable.ensureVisible(
        tester.element(find.text('添加模型')),
        alignment: 0.5,
      );
      await tester.pump();
      await tester.tap(find.text('添加模型'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('field_模型 ID(发送给 API 的标识)')),
        'proxy-model',
      );
      await tester.enterText(find.byKey(const ValueKey('field_展示名称')), '代理模型');
      await tester.enterText(
        find.byKey(const ValueKey('field_上下文容量 (tokens)')),
        '1m',
      );
      await tester.enterText(
        find.byKey(const ValueKey('field_最大输出 tokens(留空用后端默认)')),
        '256k',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      // 设置页不再有"设为当前 provider"开关:直接保存即可。
      expect(find.text('设为当前使用的 LLM provider'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('保存'),
        200,
        scrollable: editorScroll,
      );
      await tester.tap(find.text('保存'));

      // 落库轮询。
      late List<LlmProviderConfig> saved;
      await tester.runAsync(() async {
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          saved = await LlmProviderRepository(db).all();
          if (saved.isNotEmpty) break;
        }
      });
      await tester.pump();

      expect(saved, hasLength(1));
      final p = saved.single;
      expect(p.providerId, 'my-proxy');
      expect(p.isActive, isFalse); // 是否在用由模型选择器决定,不在编辑页设置
      expect(p.protocol, LlmProtocol.openaiCompat);
      expect(p.models.single.modelId, 'proxy-model');
      expect(p.models.single.contextCapacity, 1000000); // 1m 解析为 1000000
      expect(p.models.single.maxOutput, 256000); // 256k 解析为 256000

      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets('provider API key field has an eye toggle to show/hide the key', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await settleProviders(tester);

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('添加 Provider'),
      200,
      scrollable: scrollable,
    );
    // scrollUntilVisible 可能在按钮刚进入缓存区时停下(center 仍在屏外),先滚到视口
    // 中央并 pump 一帧,确保 tap 命中。
    await Scrollable.ensureVisible(
      tester.element(find.text('添加 Provider')),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.text('添加 Provider'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 与生图区同款小眼睛:默认隐藏,点"显示"切明文,再点"隐藏"收回。
    // v47 新增的「官方 OpenAI 参数风格」开关把 API Key 行推低了,先滚进视口
    // 再点小眼睛(tap 对屏外中心点是静默落空)。
    final field = find.byKey(const ValueKey('field_API Key'));
    await tester.enterText(field, 'sk-secret');
    await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.tap(find.byTooltip('显示'));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isFalse);
    expect(find.text('sk-secret'), findsWidgets); // 明文可见
    await tester.tap(find.byTooltip('隐藏'));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isTrue);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('生图区:空态提示 + 添加按钮进入编辑页', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await settleProviders(tester);

    // 生图区在首屏之下:惰性列表此刻还没构建它,provider 也就没开始读取。
    // 先滚到位触发构建,再等加载完成 —— 滚到那一刻就断言必然扑空。
    final scrollable = find.byType(Scrollable).first;
    await scrollToListSection(tester, scrollable, '添加生图配置');
    await waitUntil(
      tester,
      () => find.textContaining('还没有配置生图服务').evaluate().isNotEmpty,
    );

    expect(find.textContaining('还没有配置生图服务'), findsOneWidget);

    await Scrollable.ensureVisible(
      tester.element(find.text('添加生图配置')),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.text('添加生图配置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 进入新建生图配置编辑器:参数细节(密钥/模型/尺寸/步数)全在那里。
    expect(find.text('新建生图配置'), findsOneWidget);
    expect(find.byKey(const ValueKey('field_配置名称')), findsOneWidget);
    expect(find.byKey(const ValueKey('field_API Key / Token')), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('生图区:列表显示多套配置与「当前使用」标记,不泄漏密钥', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      final repo = ImageConfigRepository(db);
      await repo.saveProvider(
        const ImageProviderRecord(
          id: 0,
          displayName: '我的生图网关',
          config: ImageConfig(apiKey: 'sk-secret-a', model: 'm-a'),
        ),
      );
      await repo.saveProvider(
        const ImageProviderRecord(
          id: 0,
          displayName: 'Nai2API',
          config: ImageConfig(
            kind: ImageBackendKind.plugin,
            baseUrl: 'https://nai.example.com',
            apiKey: 'STA1N-secret-b',
            model: 'nai-diffusion-4-5-full',
            pluginId: 'microscritt.nai2',
          ),
        ),
      );
    });
    await tester.pumpWidget(harness());
    await settleProviders(tester);

    final scrollable = find.byType(Scrollable).first;
    await scrollToListSection(tester, scrollable, '添加生图配置');
    await waitUntil(tester, () => find.text('Nai2API').evaluate().isNotEmpty);

    expect(find.text('我的生图网关'), findsOneWidget);
    expect(find.text('Nai2API'), findsOneWidget);
    // 首条落库自动活跃 → 只有它带「当前使用」,另一条给「设为当前使用」按钮。
    expect(find.textContaining('当前使用'), findsOneWidget);
    expect(find.byTooltip('设为当前使用'), findsOneWidget);
    // 密钥不进列表(只在编辑页),避免在设置页明文暴露凭据。
    expect(find.textContaining('sk-secret-a'), findsNothing);
    expect(find.textContaining('STA1N-secret-b'), findsNothing);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('生图区:点「设为当前使用」切换活跃配置并落库', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      final repo = ImageConfigRepository(db);
      await repo.saveProvider(
        const ImageProviderRecord(
          id: 0,
          displayName: 'A',
          config: ImageConfig(apiKey: 'k-a', model: 'm-a'),
        ),
      );
      await repo.saveProvider(
        const ImageProviderRecord(
          id: 0,
          displayName: 'B',
          config: ImageConfig(apiKey: 'k-b', model: 'm-b'),
        ),
      );
    });
    await tester.pumpWidget(harness());
    await settleProviders(tester);

    final scrollable = find.byType(Scrollable).first;
    await scrollToListSection(tester, scrollable, '添加生图配置');
    await waitUntil(
      tester,
      () => find.byTooltip('设为当前使用').evaluate().isNotEmpty,
    );

    expect(find.byTooltip('设为当前使用'), findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(find.byTooltip('设为当前使用')),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('设为当前使用'));
    await tester.pumpAndSettle();

    late ImageConfig? active;
    await tester.runAsync(() async {
      active = await ImageConfigRepository(db).loadActiveConfig();
    });
    expect(active, isNotNull);
    expect(active!.apiKey, 'k-b', reason: 'A 首条自动活跃;B 是第二条,被切为当前使用');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('single-turn attachment budget dropdown persists (DG)', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness());
    await tester.pump();

    // 默认 5 条:「对话与后台」组里的下拉显示「最多 5 条」。
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('单轮附件上限'),
      200,
      scrollable: scrollable,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('单轮附件上限')),
      alignment: 0.5,
    );
    await tester.pump();
    final tile = find.widgetWithText(ListTile, '单轮附件上限');
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('最多 5 条')),
      findsOneWidget,
    );

    // 展开下拉选「关闭」→ 落库为 0。
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(DropdownButton<int>)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('关闭').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    int? savedMax;
    await tester.runAsync(() async {
      final row = (await db.db.query('app_settings', where: 'id = 1')).single;
      savedMax = row['max_auto_attachments'] as int?;
    });
    expect(savedMax, 0);
    expect(
      find.descendant(of: tile, matching: find.text('关闭')),
      findsOneWidget,
    );

    await tester.runAsync(() => db.db.close());
  });
}
