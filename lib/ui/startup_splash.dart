/// 冷启动品牌动画:三球依次落入图标三点、胶囊展开、应用名淡入,随后整体
/// 淡出露出首屏;全程约 2 秒、纯代码绘制,亮暗自适应。
///
/// 由 `MaterialApp.builder` 挂在 Navigator 之上:child 常驻 Stack 第 0 项,
/// 动画结束只移除 overlay;播放中点击任意处跳过(150ms 淡出,不硬切),
/// Reduce Motion 直接显示首屏。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'common/motion.dart';
import 'theme/brand.dart';

/// 冷启动品牌动画的挂载点与状态机:负责开始、跳过与结束调度;绘制在 overlay
/// 子组件内完成。
///
/// 必须挂在 `MaterialApp.builder` 上(Theme/MediaQuery 之下、Navigator 之上):
/// child 始终是 Stack 第 0 项,动画结束只移除 overlay,不重建首屏。
class StartupSplash extends StatefulWidget {
  const StartupSplash({super.key, required this.child});

  final Widget child;

  /// overlay 的稳定 key,供测试定位;移除后 Widget 树不再含此节点。
  static const Key overlayKey = ValueKey('startup-splash-overlay');

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

// 时间轴(毫秒),对应 _SplashPainter 的取值;总长 2000。
const double _totalMs = 2000;
const double _ballStaggerMs = 100;
const double _ballDurationMs = 520;
const double _impactT = 0.62;
const double _capsuleStartMs = 760;
const double _capsuleEndMs = 1340;
const double _wordStartMs = 1160;
const double _wordEndMs = 1540;
const double _exitStartMs = 1700;
const double _exitEndMs = 2000;

const List<Color> _dotColors = [
  AppBrand.dotBlue,
  AppBrand.dotGreen,
  AppBrand.dotOrange,
];

class _StartupSplashState extends State<StartupSplash>
    with TickerProviderStateMixin {
  late final AnimationController _controller;

  /// 跳过时的淡出控制器:主时间轴停住后,整层从当前画面淡到透明再移除。
  /// 点击瞬间硬切会让首屏像被「闪一下」,淡出把两段画面接起来。
  late final AnimationController _dismiss;
  bool _started = false;
  bool _finished = false;
  bool _skipping = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
      // 跳过判断自己做,避免系统设置把 2 秒动画悄悄压成 100ms 的闪烁。
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_onStatus);
    _dismiss = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      // 初值 1(完全可见);跳过后 reverse 到 0。
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (reduceMotionOf(context)) {
      _finished = true;
      return;
    }
    _controller.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _finished) return;
    setState(() => _finished = true);
  }

  /// 点击跳过:主时间轴停住,整层淡出后再移除 overlay,不重建首屏。
  /// 淡出期间 overlay 仍拦截点击、不穿透到首屏。
  void _skip() {
    if (_finished || _skipping) return;
    _skipping = true;
    _controller.stop();
    _dismiss.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _finished = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _dismiss.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(child: widget.child),
        if (!_finished)
          Positioned.fill(
            child: BlockSemantics(
              child: FadeTransition(
                opacity: _dismiss,
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: isDark
                      ? SystemUiOverlayStyle.light
                      : SystemUiOverlayStyle.dark,
                  child: _SplashOverlay(
                    key: StartupSplash.overlayKey,
                    animation: _controller,
                    onTap: _skip,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SplashOverlay extends StatelessWidget {
  const _SplashOverlay({
    super.key,
    required this.animation,
    required this.onTap,
  });

  final Animation<double> animation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '启动动画,轻点任意处跳过',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final elapsed = animation.value * _totalMs;
            final exitT = _interval(elapsed, _exitStartMs, _exitEndMs);
            final fade = 1 - Curves.easeInCubic.transform(exitT);
            return Opacity(
              opacity: fade.clamp(0.0, 1.0),
              child: Material(
                color: theme.scaffoldBackgroundColor,
                child: LayoutBuilder(
                  builder: (context, constraints) =>
                      _buildContent(context, constraints.biggest, elapsed),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, Size size, double elapsed) {
    final theme = Theme.of(context);
    final shortest = math.min(size.width, size.height);
    final markW = (shortest * 0.52).clamp(176.0, 260.0);
    final markH = markW * 240 / 704;
    final dotD = markW * 112 / 704;
    final dotGap = markW * 140 / 704;
    final center = Offset(size.width / 2, size.height * 0.45);

    final wordT = Curves.easeOutCubic.transform(
      _interval(elapsed, _wordStartMs, _wordEndMs),
    );
    final hintT = Curves.easeOut.transform(_interval(elapsed, 700, 1000));
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _SplashPainter(
            elapsed: elapsed,
            center: center,
            markW: markW,
            markH: markH,
            dotD: dotD,
            dotGap: dotGap,
            capsuleColor: theme.brightness == Brightness.dark
                ? AppBrand.capsuleDark
                : AppBrand.capsuleLight,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: center.dy + markH / 2 + 28,
          child: Opacity(
            opacity: wordT,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - wordT)),
              // 应用名跟随系统字号;大字号下以 FittedBox 收缩到可用宽度,
              // 只压回放不下的部分,不整体禁用用户的无障碍设置。
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'MicroScritt',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: SafeArea(
              minimum: const EdgeInsets.only(bottom: 24),
              child: Opacity(
                opacity: hintT,
                child: Text(
                  '轻点任意处跳过',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.36),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SplashPainter extends CustomPainter {
  _SplashPainter({
    required this.elapsed,
    required this.center,
    required this.markW,
    required this.markH,
    required this.dotD,
    required this.dotGap,
    required this.capsuleColor,
  });

  final double elapsed;
  final Offset center;
  final double markW;
  final double markH;
  final double dotD;
  final double dotGap;
  final Color capsuleColor;

  @override
  void paint(Canvas canvas, Size size) {
    final dotR = dotD / 2;
    final exitT = _interval(elapsed, _exitStartMs, _exitEndMs);
    final scale = 1 + 0.04 * Curves.easeOutCubic.transform(exitT);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);

    _paintRipples(canvas, dotR);
    _paintCapsule(canvas);
    _paintDots(canvas, dotR);

    canvas.restore();
  }

  void _paintRipples(Canvas canvas, double dotR) {
    for (var i = 0; i < 3; i++) {
      final landing = i * _ballStaggerMs + _ballDurationMs * _impactT;
      final t = _interval(elapsed, landing, landing + 360);
      if (elapsed < landing || t >= 1) continue;
      final cx = center.dx + (i - 1) * dotGap;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6 + 2.2 * (1 - t)
        ..color = _dotColors[i].withValues(alpha: 0.26 * (1 - t));
      canvas.drawCircle(Offset(cx, center.dy), dotR * (1 + 1.6 * t), paint);
    }
  }

  void _paintCapsule(Canvas canvas) {
    final t = _interval(elapsed, _capsuleStartMs, _capsuleEndMs);
    if (t <= 0) return;
    // easeOutBack 的过冲让胶囊像灵岛一样「弹」开,再混入三次缓出让收尾更稳。
    final eased =
        0.65 * Curves.easeOutBack.transform(t) +
        0.35 * Curves.easeOutCubic.transform(t);
    final w = _lerp(dotD * 1.55, markW, eased);
    final h = _lerp(dotD * 1.55, markH, eased);
    final rect = Rect.fromCenter(center: center, width: w, height: h);
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.min(w, h) / 2),
    );
    canvas.drawRRect(rrect, Paint()..color = capsuleColor);
  }

  void _paintDots(Canvas canvas, double dotR) {
    for (var i = 0; i < 3; i++) {
      final pose = _ballPose(i);
      if (pose.opacity <= 0) continue;
      final cx = center.dx + (i - 1) * dotGap;
      final cy = center.dy + pose.dy;
      final rx = dotR * (1 + 0.55 * pose.squash);
      final ry = dotR * (1 - 0.70 * pose.squash);
      // 挤压时底边保持不动,球体像被地面「接住」。
      final ovalCenter = Offset(cx, cy + dotR - ry);
      canvas.drawOval(
        Rect.fromCenter(center: ovalCenter, width: rx * 2, height: ry * 2),
        Paint()..color = _dotColors[i].withValues(alpha: pose.opacity),
      );
    }
  }

  _BallPose _ballPose(int i) {
    final start = i * _ballStaggerMs;
    if (elapsed < start) return const _BallPose(dy: 0, opacity: 0, squash: 0);
    final rawT = (elapsed - start) / _ballDurationMs;
    final t = rawT.clamp(0.0, 1.0);
    final drop = _dropProgress(t);
    return _BallPose(
      dy: -dotD * 4.5 * (1 - drop),
      opacity: (t / 0.18).clamp(0.0, 1.0),
      // 挤压按真实经过时间衰减,球停下后余量继续回弹到 0。
      squash: _squashAt(rawT),
    );
  }

  /// 0 = 起点(落点上方),1 = 落定;接触后两次衰减回弹。
  static double _dropProgress(double t) {
    if (t < _impactT) {
      return Curves.easeInQuad.transform(t / _impactT);
    }
    if (t < 0.80) {
      final u = (t - _impactT) / (0.80 - _impactT);
      return 1 - math.sin(u * math.pi) * 0.55;
    }
    if (t < 0.94) {
      final u = (t - 0.80) / (0.94 - 0.80);
      return 1 - math.sin(u * math.pi) * 0.18;
    }
    return 1;
  }

  static double _squashAt(double t) {
    var squash = 0.0;
    const impacts = [0.62, 0.80, 0.94];
    const amplitudes = [0.22, 0.13, 0.07];
    for (var i = 0; i < impacts.length; i++) {
      final dt = t - impacts[i];
      if (dt >= 0) squash += amplitudes[i] * math.exp(-14 * dt);
    }
    return squash.clamp(0.0, 0.3);
  }

  @override
  bool shouldRepaint(covariant _SplashPainter oldDelegate) {
    return oldDelegate.elapsed != elapsed ||
        oldDelegate.center != center ||
        oldDelegate.markW != markW ||
        oldDelegate.markH != markH ||
        oldDelegate.dotD != dotD ||
        oldDelegate.dotGap != dotGap ||
        oldDelegate.capsuleColor != capsuleColor;
  }
}

class _BallPose {
  const _BallPose({
    required this.dy,
    required this.opacity,
    required this.squash,
  });

  final double dy;
  final double opacity;
  final double squash;
}

double _interval(double t, double begin, double end) {
  if (end <= begin) return t >= begin ? 1 : 0;
  return ((t - begin) / (end - begin)).clamp(0.0, 1.0);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
