// 模型选择条:当前模型 chip、选择弹窗(provider/模型/推理等级)与使用率
// 圆环的真实锚点/字符估算口径。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import '../support/test_database.dart';

/// 设置写库恒失败,用于验证推理档位的"先落库、后改内存"顺序。
class _FailingSettingsRepository extends AppSettingsRepository {
  _FailingSettingsRepository(super.db);

  @override
  Future<void> save(AppSettings settings) async {
    throw StateError('settings write failed');
  }
}

void main() {
  late AppDatabase db;

  Widget harness({AppSettingsRepository? settingsRepository}) => ProviderScope(
    // 每个用例强制新建容器:同类型根 widget 会被复用,Riverpod 状态与
    // override 会跨用例泄漏。
    key: UniqueKey(),
    overrides: [
      databaseProvider.overrideWithValue(db),
      if (settingsRepository != null)
        appSettingsRepositoryProvider.overrideWithValue(settingsRepository),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ModelSelectorBar(usage: ContextLink(estimateTokens: 20000))),
    ),
  );

  /// provider/配置的真实 DB 读取需要 runAsync 窗口,固定延时后补一帧让结果上树。
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
  }

  /// 种入启用中的 provider:首个模型为激活项,第二个只有模型行(可选切换)。
  Future<void> seedProvider() async {
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
            displayName: 'DeepSeek V4 Flash Default',
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
  }

  testWidgets('shows the active model name and picks another model from the sheet', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await seedProvider();
    });
    await tester.pumpWidget(harness());
    await settle(tester);

    // 当前模型名显示在模型选择条上。
    expect(find.byKey(const ValueKey('model_selector')), findsOneWidget);
    expect(find.text('DeepSeek V4 Flash Default'), findsOneWidget);

    // 点击打开选择器:列出 provider 与两个模型 + 推理等级。
    await tester.tap(find.byKey(const ValueKey('model_selector')));
    await tester.pumpAndSettle();
    expect(find.text('选择模型'), findsOneWidget);
    expect(find.text('Anthropic'), findsWidgets);
    expect(find.text('Claude Opus'), findsOneWidget);
    expect(find.text('推理等级'), findsOneWidget);

    // 选择第二个模型。
    await tester.tap(find.text('Claude Opus'));
    await tester.pumpAndSettle();

    // 落库(必须在 runAsync 内读 DB):当前配置应指向 Claude Opus。
    BackendConfig? config;
    await tester.runAsync(() async {
      config = await LlmProviderRepository(db).loadBackendConfig();
    });
    expect(config!.model, 'claude-3-opus');

    await tester.runAsync(() => db.db.close());
  });
  testWidgets('reasoning level changes persist to app_settings', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await seedProvider();
    });
    await tester.pumpWidget(harness());
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('model_selector')));
    await tester.pumpAndSettle();

    // 先默认关闭,切到"高"。
    late ReasoningLevel before;
    await tester.runAsync(() async {
      before = (await AppSettingsRepository(db).load()).reasoningLevel;
    });
    expect(before, ReasoningLevel.off);
    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();

    late ReasoningLevel persisted;
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        persisted = (await AppSettingsRepository(db).load()).reasoningLevel;
        if (persisted == ReasoningLevel.high) break;
      }
    });
    expect(persisted, ReasoningLevel.high);
    // 落库成功后才更新 provider/重建 chip,补一帧让提示上树。
    await tester.pumpAndSettle();
    // 芯片旁出现"推理 高"的提示。
    expect(find.text('推理 高'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('reasoning save failure keeps the old value and reports', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await seedProvider();
    });
    await tester.pumpWidget(
      harness(settingsRepository: _FailingSettingsRepository(db)),
    );
    await settle(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ModelSelectorBar)),
    );
    await tester.tap(find.byKey(const ValueKey('model_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('保存推理等级失败,请重试').evaluate().isNotEmpty) break;
    }

    // 写库失败:内存里的设置不切换,并给出可见提示。
    expect(
      container.read(appSettingsProvider).reasoningLevel,
      ReasoningLevel.off,
    );
    expect(find.text('保存推理等级失败,请重试'), findsOneWidget);
    late ReasoningLevel persisted;
    await tester.runAsync(() async {
      persisted = (await AppSettingsRepository(db).load()).reasoningLevel;
    });
    expect(persisted, ReasoningLevel.off);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('usage ring prefers the real last-request input when anchored', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await seedProvider();
    });
    // 真实锚点 150000(75%):弹窗只展示"上轮实际输入"口径,不再并列字符估算。
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(
        home: Scaffold(
          body: ModelSelectorBar(
            usage: ContextLink(estimateTokens: 5000, actualInputTokens: 150000),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
    expect(find.textContaining('上轮实际输入:150K token(150000)'), findsOneWidget);
    // 有真实值就不显示估算:两种口径同屏只会让人来回对照。
    expect(find.textContaining('字符估算'), findsNothing);
    expect(find.textContaining('已用 75.0%'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    // 无锚点:退回估算口径并明确标注。
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(
        home: Scaffold(
          body: ModelSelectorBar(usage: ContextLink(estimateTokens: 20000)),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
    expect(find.textContaining('按字符估算'), findsOneWidget);
    expect(find.textContaining('已用 10.0%'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });
}
