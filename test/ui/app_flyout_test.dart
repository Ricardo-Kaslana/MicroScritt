// 桌面锚定弹卡(app_flyout):向上锚定定位、点卡外/Esc 关闭、全局单卡、
// 内容热更新与窗口缩放跟随。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/app_flyout.dart';

/// 最小宿主:两个锚定触发件,卡片内容带 key 便于取矩形。
class _Harness extends StatefulWidget {
  final Key firstCardKey;
  final Key secondCardKey;
  const _Harness({required this.firstCardKey, required this.secondCardKey});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final ValueNotifier<String> _label = ValueNotifier('card 1');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppFlyoutAnchor(
                  width: 220,
                  alignment: AppFlyoutAlignment.start,
                  builder: (context, handle) => ElevatedButton(
                    key: const ValueKey('trigger-1'),
                    onPressed: handle.toggle,
                    child: const Text('trigger 1'),
                  ),
                  flyoutBuilder: (context, handle) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_label.value, key: widget.firstCardKey),
                      // 热更新:改内容源后显式 rebuild() —— 只有 entry 真正
                      // 被重标脏,新文案才会上树(验证 rebuild() 语义)。
                      TextButton(
                        onPressed: () {
                          _label.value = 'card 1 v2';
                          handle.rebuild();
                        },
                        child: const Text('swap'),
                      ),
                      TextButton(
                        onPressed: () => handle.close(),
                        child: const Text('close 1'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                AppFlyoutAnchor(
                  width: 220,
                  builder: (context, handle) => ElevatedButton(
                    key: const ValueKey('trigger-2'),
                    onPressed: handle.toggle,
                    child: const Text('trigger 2'),
                  ),
                  flyoutBuilder: (context, handle) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('card 2', key: widget.secondCardKey),
                      TextButton(
                        onPressed: () => handle.close(),
                        child: const Text('close 2'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  Future<void> pumpHarness(
    WidgetTester tester, {
    required Key firstCardKey,
    required Key secondCardKey,
  }) async {
    await tester.pumpWidget(_Harness(
      firstCardKey: firstCardKey,
      secondCardKey: secondCardKey,
    ));
  }

  testWidgets('flyout opens upward above the anchor', (tester) async {
    const cardKey = ValueKey('card-1');
    await pumpHarness(tester, firstCardKey: cardKey, secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();

    final trigger = tester.getRect(find.byKey(const ValueKey('trigger-1')));
    final card = tester.getRect(find.byKey(cardKey));
    expect(card.bottom, lessThanOrEqualTo(trigger.top),
        reason: '弹卡应整体在锚点上方(底边贴锚点顶缘 + gap)');
    expect(card.left, greaterThanOrEqualTo(0));
    expect(find.text('card 1'), findsOneWidget);
  });

  testWidgets('tall flyout content is capped and scrolls inside the card', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1000, 1000)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: AppFlyoutAnchor(
                width: 260,
                builder: (context, handle) => ElevatedButton(
                  key: const ValueKey('tall-trigger'),
                  onPressed: handle.toggle,
                  child: const Text('open tall card'),
                ),
                flyoutBuilder: (context, handle) => Column(
                  key: const ValueKey('tall-card'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 40, child: Text('header')),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemExtent: 40,
                        itemCount: 40,
                        itemBuilder: (context, index) => Text('row $index'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('tall-trigger')));
    await tester.pumpAndSettle();

    final trigger = tester.getRect(find.byKey(const ValueKey('tall-trigger')));
    final card = tester.getRect(find.byKey(const ValueKey('tall-card')));
    expect(
      card.height,
      closeTo(kAppFlyoutMaxHeight, 0.5),
      reason: '大窗口下卡片应封顶在固定高度,而不是长满可用空间',
    );
    expect(card.bottom, lessThanOrEqualTo(trigger.top));

    // 封顶后的剩余条目由卡内列表滚动接管。
    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 39'), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('tall-card')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    expect(find.text('row 39'), findsOneWidget);
  });

  testWidgets('tapping outside closes the card without a barrier', (tester) async {
    const cardKey = ValueKey('card-1');
    await pumpHarness(tester, firstCardKey: cardKey, secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);

    // 点卡片外(屏幕左上角):弹卡关闭,无遮罩层残留。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsNothing);
  });

  testWidgets('re-clicking the trigger toggles instead of reopening', (tester) async {
    await pumpHarness(tester,
        firstCardKey: const ValueKey('card-1'),
        secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsNothing,
        reason: '触发件与卡片同 TapRegion 组,再次点击是 toggle');
  });

  testWidgets('escape closes the card', (tester) async {
    await pumpHarness(tester,
        firstCardKey: const ValueKey('card-1'),
        secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsNothing);
  });

  testWidgets('opening another flyout closes the previous one (single instance)', (
    tester,
  ) async {
    await pumpHarness(tester,
        firstCardKey: const ValueKey('card-1'),
        secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trigger-2')));
    await tester.pumpAndSettle();

    expect(find.text('card 1'), findsNothing, reason: '打开新卡应顶替旧卡');
    expect(find.text('card 2'), findsOneWidget);
  });

  testWidgets('content rebuilds via rebuild() without reopening', (tester) async {
    await pumpHarness(tester,
        firstCardKey: const ValueKey('card-1'),
        secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsOneWidget);

    // 卡内按钮改内容源并调用 handle.rebuild():文案热更新,弹卡不关。
    await tester.tap(find.text('swap'));
    await tester.pumpAndSettle();
    expect(find.text('card 1 v2'), findsOneWidget);
    expect(find.text('card 1'), findsNothing);
  });

  testWidgets('card follows anchor when the window resizes', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 600)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpHarness(tester,
        firstCardKey: const ValueKey('card-1'),
        secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    final before = tester.getRect(find.byKey(const ValueKey('card-1')));

    tester.view
      ..physicalSize = const Size(1000, 600)
      ..devicePixelRatio = 1.0;
    await tester.pumpAndSettle();
    final after = tester.getRect(find.byKey(const ValueKey('card-1')));

    expect(after.left, greaterThan(before.left),
        reason: '锚点随窗口加宽右移,卡片应跟随而不是停在旧坐标');
    expect(find.text('card 1'), findsOneWidget, reason: '缩放不应关闭弹卡');
  });

  testWidgets('row tap inside the card can close via handle', (tester) async {
    await pumpHarness(tester,
        firstCardKey: const ValueKey('card-1'),
        secondCardKey: const ValueKey('card-2'));

    await tester.tap(find.byKey(const ValueKey('trigger-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('close 1'));
    await tester.pumpAndSettle();
    expect(find.text('card 1'), findsNothing);
  });
}
