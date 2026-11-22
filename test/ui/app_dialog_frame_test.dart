// AppDialogFrame:标题/副标题/次栏/动作栏、宽高约束与关闭入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/app_dialog_frame.dart';

void main() {
  testWidgets('AppDialogFrame 渲染标题、次栏、内容与动作并可关闭', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AppDialogFrame(
                  title: '全部变量',
                  subtitle: '共 3 项',
                  secondaryBar: Text('次级栏'),
                  actions: [],
                  child: SizedBox(
                    key: ValueKey('dialog_body'),
                    height: 120,
                    child: Text('正文'),
                  ),
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
    expect(find.text('全部变量'), findsOneWidget);
    expect(find.text('共 3 项'), findsOneWidget);
    expect(find.text('次级栏'), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('全部变量'), findsNothing);
  });

  testWidgets('AppDialogFrame 动作栏与宽度约束生效', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AppDialogFrame(
                  frameKey: const ValueKey('frame'),
                  title: '头像',
                  maxWidth: 420,
                  actions: [
                    TextButton(
                      onPressed: () {
                        closed = true;
                        Navigator.pop(dialogContext);
                      },
                      child: const Text('关闭'),
                    ),
                  ],
                  child: const SizedBox(
                    width: 2000,
                    height: 120,
                    child: Text('内容'),
                  ),
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
    expect(tester.getSize(find.byKey(const ValueKey('frame'))).width, 420);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(find.byKey(const ValueKey('frame')), findsNothing);
  });
}
