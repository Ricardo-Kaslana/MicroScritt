/// 推理等级滑块:Off / Minimal / Low / Medium / High / XHigh / Max 七档横向拖动选择。
///
/// 拖动期间只更新本地拇指与档位标签,松手才回调 [onSelected];父级落库
/// 失败未采纳新值时,滑块自动回到原档,不保留假成功的位置。
/// 轨道自带七个停靠点,刻度用短标签避让窄卡宽度,无障碍与语义值仍用全称;
/// 刻度文字与停靠点对齐且可点选;跨档时给一次轻触感。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/app_settings.dart';
import '../common/motion.dart';

const double _kTrackHeight = 6;
const double _kThumbRadius = 9;
const double _kOverlayRadius = 18;
const double _kLabelHeight = 30;

class ReasoningSlider extends StatefulWidget {
  /// 当前生效的档位。
  final ReasoningLevel value;

  /// 松手且档位变化时回调;相同档位不回调。
  final ValueChanged<ReasoningLevel> onSelected;
  const ReasoningSlider({
    super.key,
    required this.value,
    required this.onSelected,
  });

  @override
  State<ReasoningSlider> createState() => _ReasoningSliderState();
}

class _ReasoningSliderState extends State<ReasoningSlider> {
  /// 拖动中的临时位置;null = 未拖动,拇指跟随 [ReasoningSlider.value]。
  double? _dragValue;

  static ReasoningLevel _levelOf(double value) {
    final index = value.round().clamp(0, ReasoningLevel.values.length - 1);
    return ReasoningLevel.values[index];
  }

  ReasoningLevel get _displayed =>
      _levelOf(_dragValue ?? widget.value.index.toDouble());

  void _handleChanged(double value) {
    final previous = _displayed;
    setState(() => _dragValue = value);
    // 每跨过一个档位给一次轻触感,拖动过程有明确反馈。
    if (_levelOf(value) != previous) HapticFeedback.selectionClick();
  }

  void _handleChangeEnd(double value) {
    final level = _levelOf(value);
    setState(() => _dragValue = null);
    if (level != widget.value) widget.onSelected(level);
  }

  void _select(ReasoningLevel level) {
    if (level == widget.value) return;
    HapticFeedback.selectionClick();
    widget.onSelected(level);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trackShape = _ReasoningTrackShape(
      trackColor: scheme.surfaceContainerHighest,
      activeColor: scheme.primary,
      inactiveStopColor: scheme.onSurfaceVariant.withValues(alpha: 0.35),
      activeStopColor: scheme.onPrimary.withValues(alpha: 0.9),
      divisions: ReasoningLevel.values.length - 1,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: _kTrackHeight,
            trackShape: trackShape,
            // 停靠点由轨道自绘,关掉默认刻度与拖动气泡;
            // 刻度文字已实时高亮当前档位。
            tickMarkShape: SliderTickMarkShape.noTickMark,
            showValueIndicator: ShowValueIndicator.never,
            padding: EdgeInsets.zero,
            thumbShape: _ReasoningThumbShape(
              fillColor: scheme.surface,
              borderColor: scheme.primary,
            ),
            overlayShape: const RoundSliderOverlayShape(
              overlayRadius: _kOverlayRadius,
            ),
            overlayColor: scheme.primary.withValues(alpha: 0.12),
          ),
          child: Slider(
            value: _dragValue ?? widget.value.index.toDouble(),
            min: 0,
            max: (ReasoningLevel.values.length - 1).toDouble(),
            divisions: ReasoningLevel.values.length - 1,
            label: '推理等级',
            semanticFormatterCallback: (value) => _levelOf(value).label,
            onChanged: _handleChanged,
            onChangeEnd: _handleChangeEnd,
          ),
        ),
        SizedBox(
          height: _kLabelHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final count = ReasoningLevel.values.length;
              final divisions = count - 1;
              final usable = math.max(
                0.0,
                constraints.maxWidth - _kOverlayRadius * 2,
              );
              final spacing = usable / divisions;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < count; i++)
                    Positioned(
                      left: _kOverlayRadius + usable * i / divisions,
                      top: 0,
                      // 以停靠点为中心摆放;每格限宽并等比缩字,七个刻度在
                      // 320 宽与大字号下也不会互相压住。
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, 0),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: spacing),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _tickLabel(
                              context,
                              ReasoningLevel.values[i],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tickLabel(BuildContext context, ReasoningLevel level) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = level == _displayed;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _select(level),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: AnimatedDefaultTextStyle(
          duration: motionDurationOf(
            context,
            const Duration(milliseconds: 160),
          ),
          curve: Curves.easeOut,
          style: theme.textTheme.bodySmall!.copyWith(
            color: active ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
          child: Text(level.shortLabel),
        ),
      ),
    );
  }
}

/// 七档轨道:通栏圆角底轨 + 主色已选段 + 七个停靠点(已越过的点用对比色)。
class _ReasoningTrackShape extends SliderTrackShape {
  const _ReasoningTrackShape({
    required this.trackColor,
    required this.activeColor,
    required this.inactiveStopColor,
    required this.activeStopColor,
    required this.divisions,
  });

  final Color trackColor;
  final Color activeColor;
  final Color inactiveStopColor;
  final Color activeStopColor;
  final int divisions;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    // 与 Slider 的拇指行程一致:两侧各留一个拇指/光环半径,
    // 保证拇指中心恰好落在轨道两端。
    final overlayWidth = sliderTheme.overlayShape!
        .getPreferredSize(isEnabled, isDiscrete)
        .width;
    final thumbWidth = sliderTheme.thumbShape!
        .getPreferredSize(isEnabled, isDiscrete)
        .width;
    final inset = math.max(overlayWidth, thumbWidth) / 2;
    final top = offset.dy + (parentBox.size.height - _kTrackHeight) / 2;
    return Rect.fromLTWH(
      offset.dx + inset,
      top,
      math.max(0.0, parentBox.size.width - inset * 2),
      _kTrackHeight,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.isEmpty) return;
    final canvas = context.canvas;
    final radius = Radius.circular(_kTrackHeight / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = trackColor,
    );

    final ltr = textDirection == TextDirection.ltr;
    final activeWidth =
        (ltr ? thumbCenter.dx - rect.left : rect.right - thumbCenter.dx).clamp(
          0.0,
          rect.width,
        );
    if (activeWidth > 0) {
      final activeRect = Rect.fromLTWH(
        ltr ? rect.left : rect.right - activeWidth,
        rect.top,
        activeWidth,
        rect.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(activeRect, radius),
        Paint()..color = activeColor,
      );
    }

    final stopPaint = Paint();
    for (var i = 0; i <= divisions; i++) {
      final x = rect.left + rect.width * i / divisions;
      final reached = ltr
          ? x <= thumbCenter.dx + 0.01
          : x >= thumbCenter.dx - 0.01;
      stopPaint.color = reached ? activeStopColor : inactiveStopColor;
      canvas.drawCircle(Offset(x, rect.center.dy), 2.5, stopPaint);
    }
  }
}

/// 滑块拇指:底色填充 + 主色描边,按下时轻微放大,深浅主题下都能从轨道上辨出。
class _ReasoningThumbShape extends SliderComponentShape {
  const _ReasoningThumbShape({
    required this.fillColor,
    required this.borderColor,
  });

  final Color fillColor;
  final Color borderColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_kThumbRadius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final radius = _kThumbRadius + activationAnimation.value * 1.5;
    final path = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.4), 2, false);
    canvas.drawCircle(center, radius, Paint()..color = fillColor);
    canvas.drawCircle(
      center,
      radius - 1.25,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }
}
