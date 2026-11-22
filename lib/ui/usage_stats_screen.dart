/// Token 用量统计独立页:全量总览、每日热力图、趋势折线图与模型分布。
///
/// 数据来源是 `usage_records` 的逐请求明细(append-only),因此总览是"应用使用
/// 至今"的累计值;7/30 天只影响趋势与模型分布,总览与热力图始终用全量。
/// 页面不自绘 SQL 或图表细节:聚合在 [UsageRepository],图表在 usage_charts。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/llm_units.dart';
import '../models/usage_stats.dart';
import '../state/providers.dart';
import 'common/async_section.dart';
import 'common/empty_state.dart';
import 'common/export_helper.dart';
import 'common/section_header.dart';
import 'widgets/usage_charts.dart';

/// 用量统计页;从设置页「统计」分组进入。
class UsageStatsScreen extends ConsumerStatefulWidget {
  const UsageStatsScreen({super.key});

  @override
  ConsumerState<UsageStatsScreen> createState() => _UsageStatsScreenState();
}

class _UsageStatsScreenState extends ConsumerState<UsageStatsScreen> {
  /// 趋势与模型分布的时间范围(含今天):7 或 30 天。
  int _rangeDays = 7;

  Future<void> _export(UsageStatsBundle bundle) async {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}';
    final content = const JsonEncoder.withIndent(
      '  ',
    ).convert(bundle.toJson(exportedAt: now));
    await saveJsonFile(
      context,
      fileName: 'MicroScritt-用量统计-$stamp.json',
      content: content,
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(usageStatsProvider);
    try {
      await ref.read(usageStatsProvider.future);
    } catch (_) {
      // 错误由 AsyncValue 渲染,刷新手势本身不再抛出。
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(usageStatsProvider);
    final bundle = stats.asData?.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('用量统计'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: '导出数据',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: bundle == null ? null : () => _export(bundle),
          ),
        ],
      ),
      body: AsyncSection<UsageStatsBundle>(
        value: stats,
        compact: false,
        errorTitle: '统计加载失败',
        onRetry: () => _refresh(),
        builder: (context, data) => RefreshIndicator(
          onRefresh: _refresh,
          // 桌面宽屏限制内容宽度并居中:图表有足够画幅,又不至于把折线
          // 拉成超宽横幅;手机宽度下约束自然不生效。
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: _StatsBody(
                bundle: data,
                rangeDays: _rangeDays,
                onRangeChanged: (value) => setState(() => _rangeDays = value),
                onExport: () => _export(data),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatsBody extends StatelessWidget {
  final UsageStatsBundle bundle;
  final int rangeDays;
  final ValueChanged<int> onRangeChanged;
  final VoidCallback onExport;

  const _StatsBody({
    required this.bundle,
    required this.rangeDays,
    required this.onRangeChanged,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = bundle.summary;
    final models = rangeDays == 7 ? bundle.models7d : bundle.models30d;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('总览', icon: Icons.summarize_outlined),
        _SummaryCard(summary: summary),
        if (summary.unreportedRequests > 0) ...[
          const SizedBox(height: 12),
          _UnreportedNotice(count: summary.unreportedRequests),
        ],
        if (summary.requests == 0) ...[
          const SizedBox(height: 12),
          const EmptyState(
            compact: true,
            icon: Icons.query_stats,
            title: '暂无用量记录',
            message: '完成一次对话后,这里会累计 Token、请求次数与缓存命中率。',
          ),
        ],
        const SizedBox(height: 16),
        const SectionHeader('每日用量热力图', icon: Icons.grid_on_outlined),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '每日用量 · 颜色越深当日用量越大',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              UsageHeatmap(daily: bundle.daily),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: SectionHeader('趋势与模型分布', icon: Icons.show_chart),
            ),
            _RangeSwitch(days: rangeDays, onChanged: onRangeChanged),
          ],
        ),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '每日 Token 趋势 · 最近 $rangeDays 天',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              UsageLineChart(data: usageSeriesForDays(bundle.daily, rangeDays)),
              const SizedBox(height: 20),
              Text(
                '模型用量 · 最近 $rangeDays 天',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              UsageModelPieChart(models: models),
            ],
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: summary.requests == 0 ? null : onExport,
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('导出统计数据 (JSON)'),
        ),
        const SizedBox(height: 8),
        Text(
          '导出包含累计总览、全部每日聚合与模型聚合;逐请求明细保留在本地数据库。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final UsageSummary summary;

  const _SummaryCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final metrics = [
      _MetricRow(
        icon: Icons.data_usage,
        label: '累计 Token',
        value: formatTokenCountZh(summary.totalTokens),
        detail:
            '输入 ${formatTokenCountZh(summary.inputTokens)} · '
            '输出 ${formatTokenCountZh(summary.outputTokens)}',
        valueColor: scheme.primary,
      ),
      _MetricRow(
        icon: Icons.bolt_outlined,
        label: '累计请求',
        value: '${summary.requests}',
        detail: summary.unreportedRequests > 0
            ? '其中 ${summary.unreportedRequests} 次未上报用量'
            : '全部请求均已上报用量',
      ),
      _MetricRow(
        icon: Icons.percent,
        label: '缓存命中率',
        value: summary.inputTokens <= 0
            ? '—'
            : '${(summary.cacheHitRate * 100).toStringAsFixed(1)}%',
        detail: summary.inputTokens <= 0
            ? '暂无输入用量'
            : '命中 ${formatTokenCountZh(summary.cachedInputTokens)} / '
                  '输入 ${formatTokenCountZh(summary.inputTokens)}',
        valueColor: summary.cachedInputTokens > 0 ? scheme.primary : null,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // 桌面宽屏三项指标并排,避免总览卡占据过多纵向空间;手机保持逐行。
        final wide = constraints.maxWidth >= 640;
        return SurfaceCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: metrics[0]),
                    _MetricDivider(color: scheme.outlineVariant),
                    Expanded(child: metrics[1]),
                    _MetricDivider(color: scheme.outlineVariant),
                    Expanded(child: metrics[2]),
                  ],
                )
              : Column(
                  children: [
                    metrics[0],
                    const SizedBox(height: 14),
                    metrics[1],
                    const SizedBox(height: 14),
                    metrics[2],
                  ],
                ),
        );
      },
    );
  }
}

class _MetricDivider extends StatelessWidget {
  final Color color;

  const _MetricDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: VerticalDivider(
        width: 28,
        thickness: 0.5,
        color: color.withValues(alpha: 0.45),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String detail;
  final Color? valueColor;

  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 16, color: scheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                detail,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UnreportedNotice extends StatelessWidget {
  final int count;

  const _UnreportedNotice({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '有 $count 次请求未返回用量:它们计入请求次数,但不计入 Token 与'
              '缓存命中率。若用量始终为 0,请在该 Provider 开启「官方 OpenAI '
              '参数风格」,让流式响应返回 usage。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RangeSwitch extends StatelessWidget {
  final int days;
  final ValueChanged<int> onChanged;

  const _RangeSwitch({required this.days, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 7, label: Text('7 天')),
        ButtonSegment(value: 30, label: Text('30 天')),
      ],
      selected: {days},
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
