// 模型选择条:当前模型 chip、选择弹窗(provider/模型/推理等级)与使用率
// 圆环的悬停百分比、点击底单的容量用量与缓存命中率口径。移动端走底部
// 抽屉,桌面端(windows 钉平台)走锚定弹卡 —— 两条路径分开覆盖。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/common/app_flyout.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import 'package:microscritt/ui/theme/app_theme.dart';
import 'package:microscritt/ui/widgets/reasoning_slider.dart';
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
    // 选择条贴底摆放:桌面弹卡的锚定语义是「从底栏入口向上展开」,与
    // 聊天输入区真实位置一致;移动端底单不受摆放影响。
    child: const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ModelSelectorBar(usage: ContextLink(estimateTokens: 20000)),
        ),
      ),
    ),
  );

  /// provider/配置的真实 DB 读取需要 runAsync 窗口,固定延时后补一帧让结果上树。
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
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

  testWidgets(
    'shows the active model name and picks another model from the sheet',
    (tester) async {
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
      expect(find.byType(Slider), findsOneWidget);

      // 与推理等级/上下文用量底单一致的叉号关闭入口。
      expect(find.byTooltip('关闭'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('选择模型'), findsNothing);

      // 重新打开并选择第二个模型。
      await tester.tap(find.byKey(const ValueKey('model_selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Opus'));
      await tester.pumpAndSettle();

      // 落库(必须在 runAsync 内读 DB):当前配置应指向 Claude Opus。
      BackendConfig? config;
      await tester.runAsync(() async {
        config = await LlmProviderRepository(db).loadBackendConfig();
      });
      expect(config!.model, 'claude-3-opus');

      await tester.runAsync(() => db.db.close());
    },
  );
  testWidgets('picker sheet hugs its content when only one model exists', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await LlmProviderRepository(db).saveProvider(
        LlmProviderConfig(
          id: 0,
          providerId: 'deepseek',
          displayName: 'DeepSeek 官网',
          baseUrl: 'https://api.deepseek.com',
          protocol: LlmProtocol.openaiCompat,
          apiKey: 'sk-ds',
          isActive: true,
          models: [
            LlmModelEntry(
              id: 0,
              providerId: 0,
              modelId: 'deepseek-flash',
              displayName: 'deepseek-flash',
              contextCapacity: 1000000,
              isActive: true,
            ),
          ],
        ),
      );
    });
    await tester.pumpWidget(harness());
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('model_selector')));
    await tester.pumpAndSettle();

    // 底单底部只留 16 的内边距;旧实现固定 60% 屏高会留下大块空白。
    // 推理等级在列表下方,是正文最底部的固定内容。
    final sheet = tester.getRect(find.byType(ModelPickerSheet));
    final lastContent = tester.getRect(find.byType(ReasoningSlider));
    expect(sheet.bottom - lastContent.bottom, lessThan(32));

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('picker sheet caps its height when many models exist', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await LlmProviderRepository(db).saveProvider(
        LlmProviderConfig(
          id: 0,
          providerId: 'many',
          displayName: 'Many',
          baseUrl: 'https://example.com',
          protocol: LlmProtocol.openaiCompat,
          apiKey: 'sk-many',
          isActive: true,
          models: [
            for (var i = 0; i < 30; i++)
              LlmModelEntry(
                id: 0,
                providerId: 0,
                modelId: 'model-$i',
                displayName: 'Model $i',
                contextCapacity: 128000,
              ),
          ],
        ),
      );
    });
    await tester.pumpWidget(harness());
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('model_selector')));
    await tester.pumpAndSettle();

    // 模型多时封顶 0.6 屏高,其余行在底单内部滚动。
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final sheetHeight = tester.getSize(find.byType(ModelPickerSheet)).height;
    expect(sheetHeight, lessThanOrEqualTo(screenHeight * 0.6 + 0.5));

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('reasoning level changes persist to app_settings', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await seedProvider();
    });
    await tester.pumpWidget(harness());
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('model_selector')));
    await tester.pumpAndSettle();

    // 先默认关闭,切到最高档。
    late ReasoningLevel before;
    await tester.runAsync(() async {
      before = (await AppSettingsRepository(db).load()).reasoningLevel;
    });
    expect(before, ReasoningLevel.off);
    // 滑块拖到最右端 = 最高档;松手才落库。
    await tester.drag(find.byType(Slider), const Offset(600, 0));
    await tester.pumpAndSettle();

    late ReasoningLevel persisted;
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        persisted = (await AppSettingsRepository(db).load()).reasoningLevel;
        if (persisted == ReasoningLevel.max) break;
      }
    });
    expect(persisted, ReasoningLevel.max);
    // 落库成功后才更新 provider/重建 chip,补一帧让提示上树。
    await tester.pumpAndSettle();
    // 芯片旁出现"推理 Max"的提示。
    expect(find.text('推理 Max'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('reasoning save failure keeps the old value and reports', (
    tester,
  ) async {
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
    await tester.drag(find.byType(Slider), const Offset(600, 0));
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

  testWidgets('usage ring tooltip shows percentage and sheet shows usage', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await seedProvider();
    });
    // 真实锚点 150000/200000(75%),其中 120000 命中缓存(80%):
    // 悬停只给百分比,底单给「已用/容量(百分比)」与缓存命中率。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(
            body: ModelSelectorBar(
              usage: ContextLink(
                estimateTokens: 5000,
                actualInputTokens: 150000,
                cachedInputTokens: 120000,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.byTooltip('已用 75.0%'), findsOneWidget);
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
    expect(find.text('上下文容量'), findsOneWidget);
    expect(find.text('15万/20万（75.0%）'), findsOneWidget);
    expect(find.text('缓存命中率'), findsOneWidget);
    expect(find.text('80.0%'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    // 无真实锚点:估算值标 ≈,缓存命中率无数据。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(
            body: ModelSelectorBar(usage: ContextLink(estimateTokens: 20000)),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.byTooltip('已用 10.0%'), findsOneWidget);
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
    expect(find.text('≈2万/20万（10.0%）'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('usage ring hints when the model has no capacity', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(
            body: ModelSelectorBar(usage: ContextLink(estimateTokens: 5000)),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.byTooltip('未设置上下文容量'), findsOneWidget);
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
    expect(find.text('未设置'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  group('desktop flyout (windows)', () {
    // 平台覆盖必须在测试体内复位:binding 的 foundation 不变量校验在
    // testWidgets 回调结束时、group tearDown 之前执行。
    Future<void> withWindowsPlatform(Future<void> Function() body) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('model flyout opens above the chip and switching persists', (
      tester,
    ) async {
      await withWindowsPlatform(() async {
        await tester.runAsync(() async {
          db = await openTestDb();
          await seedProvider();
        });
        await tester.pumpWidget(harness());
        await settle(tester);

        final chipRect = tester.getRect(
          find.byKey(const ValueKey('model_selector')),
        );
        await tester.tap(find.byKey(const ValueKey('model_selector')));
        await tester.pumpAndSettle();

        // 弹卡在 chip 上方,内容与移动端底单同源;桌面无叉号(点外部/Esc 关闭)。
        final headerRect = tester.getRect(find.text('选择模型'));
        expect(
          headerRect.bottom,
          lessThanOrEqualTo(chipRect.top),
          reason: '弹卡应整体在锚点 chip 上方',
        );
        expect(find.text('Anthropic'), findsOneWidget);
        expect(find.text('Claude Opus'), findsOneWidget);
        expect(find.text('推理等级'), findsOneWidget);
        expect(find.byType(Slider), findsOneWidget);
        expect(find.byTooltip('关闭'), findsNothing);
        // 行内只展示展示名与容量信息,不再重复模型 ID。
        expect(find.textContaining('claude-3-5-sonnet'), findsNothing);
        expect(find.textContaining('上下文'), findsWidgets);

        // 推理等级整块位于模型列表下方。
        final lastModelRow = tester.getRect(find.text('Claude Opus'));
        final reasoningTitle = tester.getRect(find.text('推理等级'));
        expect(reasoningTitle.top, greaterThan(lastModelRow.bottom));

        // 正文与标题/其它弹卡行一致保留左边距,不贴着卡片左缘。
        final cardHeader = tester.getRect(
          find.ancestor(
            of: find.text('选择模型'),
            matching: find.byType(AppFlyoutHeader),
          ),
        );
        final bodyTitle = tester.getRect(find.text('推理等级'));
        expect(
          bodyTitle.left - cardHeader.left,
          greaterThanOrEqualTo(AppSpacing.lg - 0.5),
        );

        // 点卡外关闭。
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(find.text('选择模型'), findsNothing);

        // 再开、选第二个模型:关卡并落库。
        await tester.tap(find.byKey(const ValueKey('model_selector')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Claude Opus'));
        await tester.pumpAndSettle();
        expect(find.text('选择模型'), findsNothing, reason: '选中后应关闭弹卡');
        BackendConfig? config;
        await tester.runAsync(() async {
          config = await LlmProviderRepository(db).loadBackendConfig();
        });
        expect(config!.model, 'claude-3-opus');

        await tester.runAsync(() => db.db.close());
      });
    });

    testWidgets('reasoning slider in the flyout persists without closing', (
      tester,
    ) async {
      await withWindowsPlatform(() async {
        await tester.runAsync(() async {
          db = await openTestDb();
          await seedProvider();
        });
        await tester.pumpWidget(harness());
        await settle(tester);

        await tester.tap(find.byKey(const ValueKey('model_selector')));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Slider), const Offset(600, 0));
        await tester.pumpAndSettle();

        // 滑块落库不关弹卡(与移动端底单同一语义),Esc 再关。
        expect(find.text('选择模型'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('选择模型'), findsNothing);

        late ReasoningLevel persisted;
        await tester.runAsync(() async {
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            persisted = (await AppSettingsRepository(db).load()).reasoningLevel;
            if (persisted == ReasoningLevel.max) break;
          }
        });
        expect(persisted, ReasoningLevel.max);

        await tester.runAsync(() => db.db.close());
      });
    });

    testWidgets('usage ring opens the detail flyout above itself', (
      tester,
    ) async {
      await withWindowsPlatform(() async {
        await tester.runAsync(() async {
          db = await openTestDb();
          await seedProvider();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ModelSelectorBar(
                    usage: ContextLink(
                      estimateTokens: 5000,
                      actualInputTokens: 150000,
                      cachedInputTokens: 120000,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await settle(tester);

        final ringRect = tester.getRect(find.byType(ContextUsageRing));
        await tester.tap(find.byType(ContextUsageRing));
        await tester.pumpAndSettle();

        final headerRect = tester.getRect(find.text('上下文使用情况'));
        expect(
          headerRect.bottom,
          lessThanOrEqualTo(ringRect.top),
          reason: '用量弹卡应整体在圆环上方',
        );
        expect(find.text('15万/20万（75.0%）'), findsOneWidget);
        expect(find.text('缓存命中率'), findsOneWidget);
        expect(find.text('80.0%'), findsOneWidget);
        expect(find.byTooltip('关闭'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('上下文使用情况'), findsNothing);

        await tester.runAsync(() => db.db.close());
      });
    });
  });
}
