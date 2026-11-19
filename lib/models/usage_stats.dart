/// Token 用量统计的中立类型:用量分类与面板所需的聚合结构。
///
/// 放在 models 层,让持久化层(`lib/data`)与 UI 共用同一份结构而不互相 import;
/// 只承载数值与展示标签,不感知 SQL 或界面。逐请求明细只在写入时以参数形态
/// 出现,读出统一走聚合结构,避免把大表整表载入内存。
library;

/// 一次 LLM 生成的用途分类(落库为 `usage_records.kind` 的字面值)。
enum UsageKind { main, background, compact, card }

/// 全量累计总览。
class UsageSummary {
  /// 已上报请求的输入 token 总和。
  final int inputTokens;

  /// 已上报请求的输出 token 总和。
  final int outputTokens;

  /// 已上报请求的缓存命中输入 token 总和。
  final int cachedInputTokens;

  /// 全部业务请求次数(含未上报用量的请求)。
  final int requests;

  /// 其中未上报用量的请求次数。
  final int unreportedRequests;

  const UsageSummary({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.requests = 0,
    this.unreportedRequests = 0,
  });

  /// 输入 + 输出 token 总量。
  int get totalTokens => inputTokens + outputTokens;

  /// 缓存命中率(命中输入 / 输入);没有输入时不除以零。
  double get cacheHitRate =>
      inputTokens <= 0 ? 0 : cachedInputTokens / inputTokens;

  /// 导出用结构。
  Map<String, Object?> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInputTokens': cachedInputTokens,
    'totalTokens': totalTokens,
    'requests': requests,
    'unreportedRequests': unreportedRequests,
    'cacheHitRate': double.parse(cacheHitRate.toStringAsFixed(4)),
  };
}

/// 按自然日聚合的用量(本地时区)。
class UsageDailyTotal {
  /// 当天 00:00(本地时区)。
  final DateTime day;

  /// 当天输入 token 总和。
  final int inputTokens;

  /// 当天输出 token 总和。
  final int outputTokens;

  /// 当天缓存命中输入 token 总和。
  final int cachedInputTokens;

  /// 当天请求次数(含未上报用量的请求)。
  final int requests;

  const UsageDailyTotal({
    required this.day,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.requests = 0,
  });

  /// 当天输入 + 输出 token 总量。
  int get totalTokens => inputTokens + outputTokens;

  /// 导出用结构;日期用 ISO-8601 的日期部分。
  Map<String, Object?> toJson() => {
    'day': _dateOnlyIso(day),
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInputTokens': cachedInputTokens,
    'totalTokens': totalTokens,
    'requests': requests,
  };
}

/// 按模型聚合的用量。
class ModelUsageTotal {
  /// 模型标识(发送给 API 的值)。
  final String model;

  /// 模型展示名;空串时回落到 [model]。
  final String modelName;

  /// 首个记录的 provider 展示名;未知时为空串。
  final String providerName;

  /// 输入 token 总和。
  final int inputTokens;

  /// 输出 token 总和。
  final int outputTokens;

  /// 缓存命中输入 token 总和。
  final int cachedInputTokens;

  /// 请求次数。
  final int requests;

  const ModelUsageTotal({
    required this.model,
    required this.modelName,
    this.providerName = '',
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.requests = 0,
  });

  /// 输入 + 输出 token 总量。
  int get totalTokens => inputTokens + outputTokens;

  /// 图例/饼图展示名。
  String get label => modelName.isEmpty ? model : modelName;

  /// 导出用结构。
  Map<String, Object?> toJson() => {
    'model': model,
    'modelName': modelName,
    'providerName': providerName,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cachedInputTokens': cachedInputTokens,
    'totalTokens': totalTokens,
    'requests': requests,
  };
}

/// 统计页一次加载所需的全部聚合数据。
class UsageStatsBundle {
  /// 全量累计总览。
  final UsageSummary summary;

  /// 全量按日聚合(升序);热力图与 7/30 天折线都由它切片。
  final List<UsageDailyTotal> daily;

  /// 最近 7 天按模型聚合。
  final List<ModelUsageTotal> models7d;

  /// 最近 30 天按模型聚合。
  final List<ModelUsageTotal> models30d;

  /// 全量按模型聚合(导出用)。
  final List<ModelUsageTotal> modelsAll;

  const UsageStatsBundle({
    required this.summary,
    required this.daily,
    required this.models7d,
    required this.models30d,
    required this.modelsAll,
  });

  /// 导出 JSON:总览 + 全量每日 + 7/30 天与全量模型聚合。
  ///
  /// 不导出逐请求明细 —— 面板与导出都以聚合口径呈现,避免大库导出时的
  /// 内存峰值;需要明细的场景由数据库文件本身承担。
  Map<String, Object?> toJson({required DateTime exportedAt}) => {
    'app': 'MicroScritt',
    'exportVersion': 1,
    'exportedAt': exportedAt.toIso8601String(),
    'summary': summary.toJson(),
    'daily': [for (final d in daily) d.toJson()],
    'models7d': [for (final m in models7d) m.toJson()],
    'models30d': [for (final m in models30d) m.toJson()],
    'modelsAll': [for (final m in modelsAll) m.toJson()],
  };
}

/// ISO 日期部分(`YYYY-MM-DD`),供导出与测试断言共用。
String _dateOnlyIso(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}