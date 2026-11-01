// 冷启动品牌动画:播放完原位揭示首屏(移除 overlay 不重建 child)、点击
// 跳过且不穿透,以及关闭动画/Reduce Motion 时直接显示首屏。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/startup_splash.dart';

Widget _app({Widget? home}) => MaterialApp(
  builder: (context, child) =>
      StartupSplash(child: child ?? const SizedBox.shrink()),
  home: home ?? const Scaffold(body: Center(child: Text('home'))),
);

class _Probe extends StatefulWidget {
  const _Probe({super.key});

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  testWidgets('plays the launch animation, then reveals the child in place', (
    tester,
  ) async {
    final probeKey = GlobalKey<_ProbeState>();
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: Center(child: _Probe(key: probeKey)),
        ),
      ),
    );

    expect(find.byKey(StartupSplash.overlayKey), findsOneWidget);
    expect(find.byKey(probeKey), findsOneWidget);
    final stateBefore = tester.state<_ProbeState>(find.byKey(probeKey));

    // 退场段(1700–2000ms)开始后 overlay 仍应在场。
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.byKey(StartupSplash.overlayKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(StartupSplash.overlayKey), findsNothing);
    expect(find.byKey(probeKey), findsOneWidget);
    // overlay 移除不能重建首屏。
    expect(tester.state<_ProbeState>(find.byKey(probeKey)), same(stateBefore));
  });

  testWidgets('tapping during playback skips it and does not reach the child', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => taps++,
              child: const Text('target'),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(StartupSplash.overlayKey), findsOneWidget);

    // 点击落在 child 的按钮位置,但应先被 overlay 拦截并视为跳过。
    await tester.tap(find.text('target'), warnIfMissed: false);
    await tester.pump();
    expect(find.byKey(StartupSplash.overlayKey), findsNothing);
    expect(taps, 0);

    await tester.tap(find.text('target'));
    expect(taps, 1);
  });

  testWidgets('skips playback when the platform disables animations', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.byKey(StartupSplash.overlayKey), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('skips playback when reduce motion is enabled (iOS)', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.byKey(StartupSplash.overlayKey), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
