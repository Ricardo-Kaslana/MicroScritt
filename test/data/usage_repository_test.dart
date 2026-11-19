// 逐请求用量仓库:总览、按日聚合、按模型范围聚合与导出 bundle。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/usage_repository.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/models/usage_stats.dart';

import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late UsageRepository repo;

  setUp(() async {
    db = await openTestDb();
    repo = UsageRepository(db);
  });

  tearDown(() async {
    await db.db.close();
  });

  Future<int> record({
    int? sessionId = 1,
    UsageKind kind = UsageKind.main,
    String providerId = 'deepseek',
    String providerName = 'DeepSeek 官网',
    String model = 'deepseek-flash',
    String modelName = 'deepseek-flash',
    TokenUsage usage = const TokenUsage(),
    bool reported = true,
    DateTime? createdAt,
  }) {
    return repo.record(
      sessionId: sessionId,
      kind: kind,
      providerId: providerId,
      providerName: providerName,
      model: model,
      modelName: modelName,
      usage: usage,
      reported: reported,
      createdAt: createdAt,
    );
  }

  test('summary aggregates tokens, requests and unreported count', () async {
    final now = DateTime.now();
    await record(
      usage: const TokenUsage(
        inputTokens: 100,
        outputTokens: 50,
        cachedInputTokens: 25,
      ),
      createdAt: now,
    );
    await record(
      kind: UsageKind.background,
      usage: const TokenUsage(),
      reported: false,
      createdAt: now,
    );

    final summary = await repo.summary();
    expect(summary.inputTokens, 100);
    expect(summary.outputTokens, 50);
    expect(summary.cachedInputTokens, 25);
    expect(summary.totalTokens, 150);
    expect(summary.requests, 2);
    expect(summary.unreportedRequests, 1);
    expect(summary.cacheHitRate, closeTo(0.25, 1e-9));
  });

  test('empty database yields zero summary and no series', () async {
    final summary = await repo.summary();
    expect(summary.requests, 0);
    expect(summary.totalTokens, 0);
    expect(summary.cacheHitRate, 0);
    expect(await repo.dailyTotals(), isEmpty);
    expect(await repo.modelTotals(), isEmpty);
    expect(await repo.modelTotals(days: 7), isEmpty);
  });

  test('daily totals group by local calendar day in ascending order', () async {
    await record(
      usage: const TokenUsage(inputTokens: 10, outputTokens: 1),
      createdAt: DateTime(2026, 1, 10, 9),
    );
    await record(
      usage: const TokenUsage(inputTokens: 20, outputTokens: 2),
      createdAt: DateTime(2026, 1, 10, 23, 30),
    );
    await record(
      usage: const TokenUsage(inputTokens: 30, outputTokens: 3),
      createdAt: DateTime(2026, 1, 11, 0, 30),
    );

    final daily = await repo.dailyTotals();
    expect(daily.map((d) => d.day), [
      DateTime(2026, 1, 10),
      DateTime(2026, 1, 11),
    ]);
    expect(daily.first.requests, 2);
    expect(daily.first.totalTokens, 33);
    expect(daily.last.requests, 1);
    expect(daily.last.totalTokens, 33);
  });

  test('model totals respect the recent-day window and merge by model', () async {
    final now = DateTime.now();
    await record(
      model: 'recent-model',
      modelName: 'Recent',
      usage: const TokenUsage(inputTokens: 100, outputTokens: 20),
      createdAt: now,
    );
    await record(
      model: 'old-model',
      modelName: 'Old',
      usage: const TokenUsage(inputTokens: 80, outputTokens: 10),
      createdAt: now.subtract(const Duration(days: 10)),
    );
    // 同一模型标识、不同展示名:聚合后应合并成一行。
    await record(
      model: 'recent-model',
      modelName: 'Recent Renamed',
      usage: const TokenUsage(inputTokens: 30, outputTokens: 5),
      createdAt: now,
    );

    final within7 = await repo.modelTotals(days: 7);
    expect(within7.map((m) => m.model), ['recent-model']);
    expect(within7.single.totalTokens, 155);
    expect(within7.single.requests, 2);
    expect(within7.single.modelName, 'Recent');

    final within30 = await repo.modelTotals(days: 30);
    expect(within30.map((m) => m.model), containsAll(['recent-model', 'old-model']));

    final all = await repo.modelTotals();
    expect(all.length, 2);
    expect(all.first.model, 'recent-model');
    expect(all.first.providerName, 'DeepSeek 官网');
  });

  test('loadBundle combines summary, full daily and 7/30-day models', () async {
    final now = DateTime.now();
    await record(
      kind: UsageKind.compact,
      usage: const TokenUsage(inputTokens: 40, outputTokens: 10),
      createdAt: now,
    );

    final bundle = await repo.loadBundle();
    expect(bundle.summary.requests, 1);
    expect(bundle.summary.totalTokens, 50);
    expect(bundle.daily.single.day, DateTime(now.year, now.month, now.day));
    expect(bundle.models7d.single.totalTokens, 50);
    expect(bundle.models30d.single.totalTokens, 50);
    expect(bundle.modelsAll.single.totalTokens, 50);

    final json = bundle.toJson(exportedAt: now);
    expect(json['exportVersion'], 1);
    expect(json['summary'], isA<Map<String, Object?>>());
    expect(json['daily'], hasLength(1));
    expect(json['models7d'], hasLength(1));
  });
}