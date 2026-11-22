// 用量统计页:总览、热力图、趋势/模型范围切换与空态渲染。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/usage_repository.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/models/usage_stats.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/theme/app_theme.dart';
import 'package:microscritt/ui/usage_stats_screen.dart';
import 'package:microscritt/ui/widgets/usage_charts.dart';

import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  late AppDatabase db;

  // 真实 DB I/O 必须在 runAsync 窗口内完成(fake-async 区会永不完成)。
  setUp(() async {
    db = await openTestDb();
  });

  tearDown(() async {
    await db.db.close();
  });

  testWidgets('renders summary, heatmap, range switch and model legend', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final repo = UsageRepository(db);
      final now = DateTime.now();
      await repo.record(
        sessionId: 1,
        kind: UsageKind.main,
        providerId: 'deepseek',
        providerName: 'DeepSeek 官网',
        model: 'deepseek-flash',
        modelName: 'deepseek-flash',
        usage: const TokenUsage(
          inputTokens: 1200,
          outputTokens: 300,
          cachedInputTokens: 600,
        ),
        reported: true,
        createdAt: now,
      );
      await repo.record(
        sessionId: 1,
        kind: UsageKind.background,
        providerId: 'deepseek',
        providerName: 'DeepSeek 官网',
        model: 'deepseek-flash',
        modelName: 'deepseek-flash',
        usage: const TokenUsage(inputTokens: 400, outputTokens: 100),
        reported: true,
        createdAt: now,
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const UsageStatsScreen(),
        ),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('累计 Token').evaluate().isNotEmpty,
      reason: '统计聚合未加载完成',
    );

    expect(find.text('用量统计'), findsOneWidget);
    expect(find.text('累计 Token'), findsOneWidget);
    expect(find.text('累计请求'), findsOneWidget);
    expect(find.text('缓存命中率'), findsOneWidget);
    expect(find.text('2000'), findsWidgets);
    expect(find.text('输入 1600 · 输出 400'), findsOneWidget);
    expect(find.text('37.5%'), findsOneWidget);
    expect(find.text('每日用量热力图'), findsOneWidget);
    // ListView 懒加载:模型图例在首屏之下,滚动到可见后再断言。
    await tester.scrollUntilVisible(
      find.text('deepseek-flash'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('deepseek-flash'), findsOneWidget);

    // 切换到 30 天:标题与饼图数据源一起更新,不应抛错。
    await tester.tap(find.text('30 天'));
    await tester.pumpAndSettle();
    expect(find.text('每日 Token 趋势 · 最近 30 天'), findsOneWidget);
    expect(find.text('模型用量 · 最近 30 天'), findsOneWidget);
  });

  testWidgets('desktop width enlarges the trend chart without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.runAsync(() async {
      final repo = UsageRepository(db);
      await repo.record(
        sessionId: 1,
        kind: UsageKind.main,
        providerId: 'deepseek',
        providerName: 'DeepSeek 官网',
        model: 'deepseek-flash',
        modelName: 'deepseek-flash',
        usage: const TokenUsage(
          inputTokens: 3200,
          outputTokens: 800,
          cachedInputTokens: 1600,
        ),
        reported: true,
        createdAt: DateTime.now(),
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const UsageStatsScreen(),
        ),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('累计 Token').evaluate().isNotEmpty,
      reason: '统计聚合未加载完成',
    );
    await tester.scrollUntilVisible(
      find.byType(UsageLineChart),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    // 桌面宽屏下趋势图高度随卡片放大(手机为 180)。
    expect(
      tester.getSize(find.byType(UsageLineChart)).height,
      greaterThan(250),
    );
    expect(tester.takeException(), isNull, reason: '宽屏布局不应溢出');
  });

  testWidgets('empty database shows the no-record hint', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const UsageStatsScreen(),
        ),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('累计 Token').evaluate().isNotEmpty,
      reason: '统计聚合未加载完成',
    );

    expect(find.text('暂无用量记录'), findsOneWidget);
    expect(find.text('完成一次对话后,这里会累计 Token、请求次数与缓存命中率。'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('该范围内暂无模型用量'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('该范围内暂无模型用量'), findsOneWidget);
  });
}
