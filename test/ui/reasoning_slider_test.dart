// 推理等级滑块:七档短标签刻度、拖动松手回调、点刻度直接选档与大字号布局。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/ui/widgets/reasoning_slider.dart';

void main() {
  testWidgets('drag and tick labels select reasoning levels', (tester) async {
    ReasoningLevel? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: ReasoningSlider(
                value: ReasoningLevel.off,
                onSelected: (level) => selected = level,
              ),
            ),
          ),
        ),
      ),
    );

    // 七档刻度齐全,窄宽度使用短标签。
    for (final level in ReasoningLevel.values) {
      expect(find.text(level.shortLabel), findsOneWidget);
    }

    // 拖到最右端:松手才回调 Max。
    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(selected, ReasoningLevel.max);

    // 点刻度文字可直接选档;点当前档不重复回调。
    selected = null;
    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();
    expect(selected, ReasoningLevel.low);
    selected = null;
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });

  testWidgets('seven tick labels fit a 320-wide card at 2x text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: ReasoningSlider(
                  value: ReasoningLevel.medium,
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    for (final level in ReasoningLevel.values) {
      expect(find.text(level.shortLabel), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
