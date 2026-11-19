/// 用量统计页的自绘图表:每日热力图、趋势折线图、模型环形图。
///
/// 不引入图表库:三张图只画网格/折线/扇区,固定调色板与主题色足够,零新依赖
/// 也避免 pubspec/lock 受镜像地址影响。图表只消费 [UsageDailyTotal] /
/// [ModelUsageTotal],不读写数据库。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/llm_units.dart';
import '../../models/usage_stats.dart';

/// 图表共用的固定调色板(亮暗主题下都保持可辨识)。
const List<Color> usageChartPalette = [
  Color(0xFF0A7CFF),
  Color(0xFF34C759),
  Color(0xFFFF9F0A),
  Color(0xFFFF375F),
  Color(0xFFAF52DE),
  Color(0xFF5AC8FA),
  Color(0xFF8E8E93),
];

/// 把按日聚合补零到"含今天在内的最近 [days] 个自然日",升序。
///
/// 数据库只返回有记录的日期;趋势图需要连续横轴,缺失日补 0。
List<UsageDailyTotal> usageSeriesForDays(
  List<UsageDailyTotal> daily,
  int days,
) {
  if (days <= 0) return const [];
  final byDay = <DateTime, UsageDailyTotal>{
    for (final d in daily) DateUtils.dateOnly(d.day): d,
  };
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return [
    for (var offset = days - 1; offset >= 0; offset--)
      _seriesEntry(
        today.subtract(Duration(days: offset)),
        byDay[today.subtract(Duration(days: offset))],
      ),
  ];
}

UsageDailyTotal _seriesEntry(DateTime day, UsageDailyTotal? entry) =>
    UsageDailyTotal(
      day: day,
      inputTokens: entry?.inputTokens ?? 0,
      outputTokens: entry?.outputTokens ?? 0,
      cachedInputTokens: entry?.cachedInputTokens ?? 0,
      requests: entry?.requests ?? 0,
    );

/// 最近 [minWeeks]–[maxWeeks] 周的每日用量热力图(按周列、星期行,GitHub 风格)。
///
/// 未来日期留空;色阶按窗口内单日峰值分四档,无记录日显示弱化的底色。
/// 周数按可用宽度自适应:手机保持 [minWeeks] 周,桌面逐步增加(最多约一年)
/// 让热力图铺满卡片,而不是在左侧缩成一小块。
class UsageHeatmap extends StatelessWidget {
  /// 全量按日聚合(顺序无关)。
  final List<UsageDailyTotal> daily;

  /// 窄屏最少展示的周数(含本周);手机宽度下 20 周可读性最好。
  final int minWeeks;

  /// 宽屏最多展示的周数(约一年);格子仍保持可读尺寸。
  final int maxWeeks;

  const UsageHeatmap({
    super.key,
    required this.daily,
    this.minWeeks = 20,
    this.maxWeeks = 53,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontSize: 9,
    );
    final byDay = <DateTime, UsageDailyTotal>{
      for (final d in daily) DateUtils.dateOnly(d.day): d,
    };
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startOfThisWeek = today.subtract(Duration(days: today.weekday - 1));
    var maxValue = 0;
    for (final d in daily) {
      maxValue = math.max(maxValue, d.totalTokens);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 3.0;
        const weekdayWidth = 18.0;
        // 按可用宽度决定周数:桌面多显示让热力图铺满,手机保持最小周数,
        // 格子不缩成噪点;格子上限 26 避免宽屏下变成巨型色块。
        final fitWeeks =
            ((constraints.maxWidth - weekdayWidth) / (16 + gap)).floor();
        final weeks = fitWeeks.clamp(minWeeks, maxWeeks).toInt();
        // 每列占 cell + gap(格子右侧留白),总宽必须恰好等于可用宽度,
        // 否则最后一列的 margin 会顶出 3px 溢出。
        final cell =
            ((constraints.maxWidth - weekdayWidth - weeks * gap) / weeks)
                .clamp(4.0, 26.0);
        final firstWeek = startOfThisWeek.subtract(
          Duration(days: (weeks - 1) * 7),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 14,
              child: Stack(
                children: [
                  for (var w = 0; w < weeks; w++)
                    if (_monthStartLabel(
                          firstWeek.add(Duration(days: w * 7)),
                          w == 0
                              ? null
                              : firstWeek.add(Duration(days: (w - 1) * 7)),
                        )
                        case final label?)
                      Positioned(
                        left: weekdayWidth + w * (cell + gap),
                        top: 0,
                        child: Text(label, style: labelStyle),
                      ),
                ],
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    for (var weekday = 0; weekday < 7; weekday++)
                      SizedBox(
                        width: weekdayWidth,
                        height: cell + gap,
                        child: weekday.isEven
                            ? Center(
                                child: Text(
                                  _weekdayLabel(weekday),
                                  style: labelStyle,
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
                for (var w = 0; w < weeks; w++)
                  Column(
                    children: [
                      for (var weekday = 0; weekday < 7; weekday++)
                        _dayCell(
                          date: firstWeek.add(
                            Duration(days: w * 7 + weekday),
                          ),
                          today: today,
                          entry: byDay[firstWeek.add(
                            Duration(days: w * 7 + weekday),
                          )],
                          maxValue: maxValue,
                          cell: cell,
                          gap: gap,
                          scheme: scheme,
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('少', style: labelStyle),
                const SizedBox(width: 4),
                for (var level = 0; level < 4; level++)
                  Container(
                    width: 9,
                    height: 9,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color: _heatColor(
                        scheme,
                        maxValue <= 0
                            ? 0
                            : (maxValue * level / 4).ceil().clamp(1, maxValue),
                        maxValue,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                const SizedBox(width: 4),
                Text('多', style: labelStyle),
              ],
            ),
          ],
        );
      },
    );
  }
}

Widget _dayCell({
  required DateTime date,
  required DateTime today,
  required UsageDailyTotal? entry,
  required int maxValue,
  required double cell,
  required double gap,
  required ColorScheme scheme,
}) {
  final future = date.isAfter(today);
  final total = entry?.totalTokens ?? 0;
  final color = future
      ? Colors.transparent
      : _heatColor(scheme, total, maxValue);
  final container = Container(
    width: cell,
    height: cell,
    margin: EdgeInsets.only(right: gap, bottom: gap),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );
  if (future) return container;
  final label = '${date.month}/${date.day}';
  return Tooltip(
    message: total <= 0
        ? '$label · 无记录'
        : '$label · ${formatTokenCountZh(total)} tok',
    waitDuration: const Duration(milliseconds: 300),
    child: container,
  );
}

Color _heatColor(ColorScheme scheme, int value, int maxValue) {
  if (value <= 0 || maxValue <= 0) {
    return scheme.surfaceContainerHighest.withValues(alpha: 0.55);
  }
  final ratio = value / maxValue;
  final alpha = ratio <= 0.25
      ? 0.28
      : ratio <= 0.5
      ? 0.48
      : ratio <= 0.75
      ? 0.72
      : 1.0;
  return scheme.primary.withValues(alpha: alpha);
}

String? _monthStartLabel(DateTime weekStart, DateTime? previousWeekStart) {
  if (previousWeekStart != null &&
      previousWeekStart.month == weekStart.month) {
    return null;
  }
  return '${weekStart.month}月';
}

String _weekdayLabel(int weekday) =>
    const ['一', '', '三', '', '五', '', '日'][weekday];

/// 每日 token 趋势折线图:总量单线 + 渐变填充,Y 轴为 K/M 简写。
class UsageLineChart extends StatelessWidget {
  /// 连续日期序列(建议经 [usageSeriesForDays] 补零)。
  final List<UsageDailyTotal> data;

  const UsageLineChart({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 桌面宽屏给趋势图更多纵向空间,手机维持紧凑高度。
        final height = (constraints.maxWidth * 0.28)
            .clamp(180.0, 320.0)
            .toDouble();
        return SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _LineChartPainter(
              data: data,
              lineColor: scheme.primary,
              fillColor: scheme.primary.withValues(alpha: 0.22),
              gridColor: scheme.outlineVariant.withValues(alpha: 0.45),
              labelColor: scheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<UsageDailyTotal> data;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;
  final Color labelColor;

  _LineChartPainter({
    required this.data,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const left = 42.0, right = 6.0, top = 10.0, bottom = 22.0;
    final rect = Rect.fromLTWH(
      left,
      top,
      math.max(0, size.width - left - right),
      math.max(0, size.height - top - bottom),
    );
    if (rect.width <= 0 || rect.height <= 0) return;

    var maxValue = 0;
    for (final d in data) {
      maxValue = math.max(maxValue, d.totalTokens);
    }
    final maxY = maxValue <= 0 ? 1 : maxValue;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = rect.bottom - rect.height * i / 2;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), gridPaint);
      _paintLabel(
        canvas,
        i == 0 ? '0' : formatTokenCount((maxY * i / 2).round()),
        Offset(rect.left - 4, y),
        labelColor,
        alignRight: true,
        centerY: true,
      );
    }

    if (data.isEmpty) return;
    Offset pointAt(int i) {
      final x = data.length <= 1
          ? rect.left + rect.width / 2
          : rect.left + rect.width * i / (data.length - 1);
      final y = rect.bottom - rect.height * (data[i].totalTokens / maxY);
      return Offset(x, y);
    }

    final line = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < data.length; i++) {
      final p = pointAt(i);
      line.lineTo(p.dx, p.dy);
    }
    final fill = Path.from(line)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [fillColor, fillColor.withValues(alpha: 0)],
        ).createShader(rect),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    if (data.length <= 31) {
      final dotPaint = Paint()..color = lineColor;
      for (var i = 0; i < data.length; i++) {
        canvas.drawCircle(pointAt(i), 2.2, dotPaint);
      }
    }

    // X 轴只标首/中/末三处,避免 30 天时日期互相叠压。
    final indices = <int>{0, data.length ~/ 2, data.length - 1}.toList()..sort();
    for (final i in indices) {
      final p = pointAt(i);
      _paintLabel(
        canvas,
        '${data[i].day.month}/${data[i].day.day}',
        Offset(p.dx, rect.bottom + 4),
        labelColor,
        centerX: true,
      );
    }
  }

  void _paintLabel(
    Canvas canvas,
    String text,
    Offset anchor,
    Color color, {
    bool alignRight = false,
    bool centerX = false,
    bool centerY = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 9, color: color),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    var dx = anchor.dx;
    var dy = anchor.dy;
    if (alignRight) dx -= painter.width;
    if (centerX) dx -= painter.width / 2;
    if (centerY) dy -= painter.height / 2;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) =>
      !identical(data, oldDelegate.data) ||
      lineColor != oldDelegate.lineColor ||
      fillColor != oldDelegate.fillColor ||
      gridColor != oldDelegate.gridColor ||
      labelColor != oldDelegate.labelColor;
}

/// 模型用量环形图 + 图例:取 token 前 5 的模型,其余合并为「其他」。
class UsageModelPieChart extends StatelessWidget {
  /// 某时间范围内按模型聚合的结果(顺序无关)。
  final List<ModelUsageTotal> models;

  const UsageModelPieChart({super.key, required this.models});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final total = models.fold<int>(0, (sum, m) => sum + m.totalTokens);
    if (total <= 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.pie_chart_outline,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              '该范围内暂无模型用量',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final slices = _buildSlices(models);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 桌面宽屏环形图与图例左右并排,环形随卡片放大;手机保持上下布局。
        final wide = constraints.maxWidth >= 600;
        final ringSize = wide
            ? (constraints.maxWidth * 0.28).clamp(200.0, 300.0).toDouble()
            : (constraints.maxWidth * 0.55).clamp(168.0, 260.0).toDouble();
        final ring = _DonutRing(
          total: total,
          slices: slices,
          size: ringSize,
          trackColor: scheme.surfaceContainerHighest,
        );
        final legend = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final slice in slices)
              _LegendRow(slice: slice, total: total),
          ],
        );
        if (wide) {
          return Row(
            children: [
              ring,
              const SizedBox(width: 28),
              Expanded(child: legend),
            ],
          );
        }
        return Column(
          children: [
            ring,
            const SizedBox(height: 12),
            legend,
          ],
        );
      },
    );
  }
}

class _DonutRing extends StatelessWidget {
  final int total;
  final List<_UsageSlice> slices;
  final double size;
  final Color trackColor;

  const _DonutRing({
    required this.total,
    required this.slices,
    required this.size,
    required this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _DonutPainter(slices: slices, trackColor: trackColor),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatTokenCountZh(total),
                style: (size >= 220
                        ? textTheme.headlineSmall
                        : textTheme.titleMedium)
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                '总 Token',
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UsageSlice {
  final String label;
  final int value;
  final Color color;

  const _UsageSlice({
    required this.label,
    required this.value,
    required this.color,
  });
}

List<_UsageSlice> _buildSlices(List<ModelUsageTotal> models) {
  final sorted = [...models]
    ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
  const maxSlices = 5;
  final slices = <_UsageSlice>[
    for (var i = 0; i < sorted.length && i < maxSlices; i++)
      _UsageSlice(
        label: sorted[i].label,
        value: sorted[i].totalTokens,
        color: usageChartPalette[i % usageChartPalette.length],
      ),
  ];
  if (sorted.length > maxSlices) {
    final rest = sorted
        .skip(maxSlices)
        .fold<int>(0, (sum, m) => sum + m.totalTokens);
    if (rest > 0) {
      slices.add(
        _UsageSlice(
          label: '其他',
          value: rest,
          color: usageChartPalette[maxSlices % usageChartPalette.length],
        ),
      );
    }
  }
  return slices;
}

class _LegendRow extends StatelessWidget {
  final _UsageSlice slice;
  final int total;

  const _LegendRow({required this.slice, required this.total});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final percent = total <= 0 ? 0.0 : slice.value / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: slice.color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              slice.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(percent * 100).toStringAsFixed(1)}%',
            style: textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 62,
            child: Text(
              formatTokenCountZh(slice.value),
              textAlign: TextAlign.right,
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<_UsageSlice> slices;
  final Color trackColor;

  _DonutPainter({required this.slices, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<int>(0, (sum, s) => sum + s.value);
    final stroke = size.shortestSide * 0.14;
    final radius = math.max(0.0, (size.shortestSide - stroke) / 2 - 2);
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radius,
    );
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = trackColor.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    if (total <= 0 || radius <= 0) return;
    var start = -math.pi / 2;
    const gap = 0.025;
    for (final slice in slices) {
      final sweep = math.pi * 2 * slice.value / total;
      final drawSweep = math.max(0.0, sweep - gap);
      if (drawSweep > 0) {
        canvas.drawArc(
          rect,
          start + gap / 2,
          drawSweep,
          false,
          Paint()
            ..color = slice.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke,
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      !identical(slices, oldDelegate.slices) ||
      trackColor != oldDelegate.trackColor;
}