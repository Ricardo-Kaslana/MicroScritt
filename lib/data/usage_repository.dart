/// Token 用量明细仓库:逐请求 append-only 写入与统计面板所需的聚合查询。
///
/// 会话行上的用量列是"最近一轮快照",无法支撑全量/按日/按模型统计;本仓库把
/// 每次业务生成的用量单独落一行,天然避开整行覆盖写的并发窗口,也让按时间与
/// 模型维度聚合成为纯 SQL 查询。
library;

import '../models/token_usage.dart';
import '../models/usage_stats.dart';
import 'database.dart';

/// `usage_records` 表的读写入口。
class UsageRepository {
  final AppDatabase db;

  UsageRepository(this.db);

  /// 写入一条逐请求用量记录,返回行 id。
  ///
  /// [reported] 为 false 表示上游未上报 usage:仍计入请求次数,但不贡献 token。
  /// 记录是附加信息,调用方自行忽略写入失败。
  Future<int> record({
    int? sessionId,
    required UsageKind kind,
    required String providerId,
    required String providerName,
    required String model,
    required String modelName,
    required TokenUsage usage,
    required bool reported,
    DateTime? createdAt,
  }) {
    return db.db.insert('usage_records', {
      'session_id': sessionId,
      'kind': kind.name,
      'provider_id': providerId,
      'provider_name': providerName,
      'model': model,
      'model_name': modelName,
      'input_tokens': usage.inputTokens,
      'output_tokens': usage.outputTokens,
      'cached_input_tokens': usage.cachedInputTokens,
      'reported': reported ? 1 : 0,
      'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
    });
  }

  /// 全量累计总览(累计 Token、请求次数、缓存命中与未上报次数)。
  Future<UsageSummary> summary() async {
    final rows = await db.db.rawQuery('''
      SELECT
        COALESCE(SUM(input_tokens), 0) AS input_tokens,
        COALESCE(SUM(output_tokens), 0) AS output_tokens,
        COALESCE(SUM(cached_input_tokens), 0) AS cached_input_tokens,
        COUNT(*) AS requests,
        COALESCE(SUM(CASE WHEN reported = 0 THEN 1 ELSE 0 END), 0) AS unreported
      FROM usage_records
    ''');
    if (rows.isEmpty) return const UsageSummary();
    final row = rows.first;
    return UsageSummary(
      inputTokens: _int(row['input_tokens']),
      outputTokens: _int(row['output_tokens']),
      cachedInputTokens: _int(row['cached_input_tokens']),
      requests: _int(row['requests']),
      unreportedRequests: _int(row['unreported']),
    );
  }

  /// 全部历史按自然日聚合(本地时区,升序);无记录的日期不补行。
  Future<List<UsageDailyTotal>> dailyTotals() async {
    final rows = await db.db.rawQuery('''
      SELECT
        date(created_at / 1000, 'unixepoch', 'localtime') AS day,
        COALESCE(SUM(input_tokens), 0) AS input_tokens,
        COALESCE(SUM(output_tokens), 0) AS output_tokens,
        COALESCE(SUM(cached_input_tokens), 0) AS cached_input_tokens,
        COUNT(*) AS requests
      FROM usage_records
      GROUP BY day
      ORDER BY day ASC
    ''');
    return [
      for (final row in rows)
        if (_parseDay(row['day']) case final day?)
          UsageDailyTotal(
            day: day,
            inputTokens: _int(row['input_tokens']),
            outputTokens: _int(row['output_tokens']),
            cachedInputTokens: _int(row['cached_input_tokens']),
            requests: _int(row['requests']),
          ),
    ];
  }

  /// 按模型聚合。[days] 为 null 表示全量;否则取含今天在内的最近 N 个自然日。
  ///
  /// 同一模型标识可能因展示名变化出现多组,这里按 [ModelUsageTotal.model]
  /// 二次合并,展示名与 provider 名取首组非空值。
  Future<List<ModelUsageTotal>> modelTotals({int? days}) async {
    final where = days == null ? '' : 'WHERE created_at >= ?';
    final args = <Object?>[];
    if (days != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final cutoff = today.subtract(Duration(days: days - 1));
      args.add(cutoff.millisecondsSinceEpoch);
    }
    final rows = await db.db.rawQuery('''
      SELECT
        model,
        model_name,
        provider_name,
        COALESCE(SUM(input_tokens), 0) AS input_tokens,
        COALESCE(SUM(output_tokens), 0) AS output_tokens,
        COALESCE(SUM(cached_input_tokens), 0) AS cached_input_tokens,
        COUNT(*) AS requests
      FROM usage_records
      $where
      GROUP BY model, model_name, provider_name
      ORDER BY SUM(input_tokens + output_tokens) DESC, model ASC
    ''', args);

    final merged = <String, ModelUsageTotal>{};
    for (final row in rows) {
      final model = (row['model'] as String?) ?? '';
      final name = (row['model_name'] as String?) ?? '';
      final provider = (row['provider_name'] as String?) ?? '';
      final input = _int(row['input_tokens']);
      final output = _int(row['output_tokens']);
      final cached = _int(row['cached_input_tokens']);
      final requests = _int(row['requests']);
      final existing = merged[model];
      if (existing == null) {
        merged[model] = ModelUsageTotal(
          model: model,
          modelName: name,
          providerName: provider,
          inputTokens: input,
          outputTokens: output,
          cachedInputTokens: cached,
          requests: requests,
        );
      } else {
        merged[model] = ModelUsageTotal(
          model: model,
          modelName: existing.modelName.isNotEmpty ? existing.modelName : name,
          providerName: existing.providerName.isNotEmpty
              ? existing.providerName
              : provider,
          inputTokens: existing.inputTokens + input,
          outputTokens: existing.outputTokens + output,
          cachedInputTokens: existing.cachedInputTokens + cached,
          requests: existing.requests + requests,
        );
      }
    }
    final result = merged.values.toList()
      ..sort((a, b) {
        final byTokens = b.totalTokens.compareTo(a.totalTokens);
        return byTokens != 0 ? byTokens : a.model.compareTo(b.model);
      });
    return result;
  }

  /// 一次加载统计页所需的全部聚合(总览 + 全量每日 + 7/30 天/全量模型)。
  Future<UsageStatsBundle> loadBundle() async {
    final summary = await this.summary();
    final daily = await dailyTotals();
    final models7d = await modelTotals(days: 7);
    final models30d = await modelTotals(days: 30);
    final modelsAll = await modelTotals();
    return UsageStatsBundle(
      summary: summary,
      daily: daily,
      models7d: models7d,
      models30d: models30d,
      modelsAll: modelsAll,
    );
  }
}

int _int(Object? value) => switch (value) {
  int v => v,
  num v => v.toInt(),
  String v => int.tryParse(v) ?? 0,
  _ => 0,
};

DateTime? _parseDay(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}