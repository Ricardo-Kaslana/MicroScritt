import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/text_edit_sheet.dart';

void main() {
  testWidgets('小视口 + 键盘弹起时编辑底单不溢出', (tester) async {
    // 复现 BZ 批后的溢出:可用高度不足(小窗 + viewInsets 垫高)时,
    // 固定 editorHeight 曾把 Column 撑出 138px。
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 244.0);
    addTearDown(tester.view.reset);

    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              if (!opened) {
                opened = true;
                // 视口偏小 + 底部 inset 模拟软键盘,压缩 sheet 可用高度。
                Future.microtask(
                  () => showTextEditSheet(
                    context,
                    title: '编辑',
                    initialText: 'x' * 2000,
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('保存'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('记忆等长文编辑可传入更高的编辑区', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              if (!opened) {
                opened = true;
                Future.microtask(
                  () => showTextEditSheet(
                    context,
                    title: '编辑记忆',
                    initialText: 'x' * 2000,
                    editorHeightFactor: 0.7,
                    maxEditorHeight: 620,
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(TextField)).height, greaterThan(500));
  });

  testWidgets('复制按钮复制当前编辑内容', (tester) async {
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              if (!opened) {
                opened = true;
                Future.microtask(
                  () => showTextEditSheet(
                    context,
                    title: '编辑记忆',
                    initialText: '初始内容',
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '修改后的内容');
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();

    expect(copied, ['修改后的内容']);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });
}
