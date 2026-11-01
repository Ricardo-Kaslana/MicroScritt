import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(
      home: Scaffold(body: ModelSelectorBar(usage: ContextLink(estimateTokens: 20000))),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
  }

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
    // 芯片旁出现"推理 高"的提示。
    expect(find.text('推理 高'), findsOneWidget);

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
