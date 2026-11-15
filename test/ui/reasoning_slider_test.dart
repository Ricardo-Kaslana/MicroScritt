// 推理等级滑块:四档刻度、拖动松手回调与点刻度直接选档。
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

    // 四档刻度齐全。
    for (final level in ReasoningLevel.values) {
      expect(find.text(level.label), findsOneWidget);
    }

    // 拖到最右端:松手才回调"高"。
    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(selected, ReasoningLevel.high);

    // 点刻度文字可直接选档;点当前档不重复回调。
    selected = null;
    await tester.tap(find.text('低'));
    await tester.pumpAndSettle();
    expect(selected, ReasoningLevel.low);
    selected = null;
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });
}
