// showAppSheet:底部弹层的返回值、宽度覆盖与默认滚动控制。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/app_sheet.dart';

void main() {
  testWidgets('showAppSheet 返回弹层内选择的值', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showAppSheet<String>(
                  context,
                  builder: (sheetContext) => TextButton(
                    onPressed: () => Navigator.pop(sheetContext, '选中的值'),
                    child: const Text('pick'),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('pick'), findsOneWidget);

    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();
    expect(picked, '选中的值');
    expect(find.text('pick'), findsNothing);
  });

  testWidgets('showAppSheet 宽窗按 maxWidth 覆盖弹层宽度', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAppSheet<void>(
                context,
                isScrollControlled: false,
                maxWidth: 500,
                builder: (_) => const SizedBox(
                  key: ValueKey('sheet_body'),
                  width: 2000,
                  height: 100,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('sheet_body'))).width, 500);
  });
}
