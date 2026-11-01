import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/form_field.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> copied;

  setUp(() {
    copied = [];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpField(
    WidgetTester tester, {
    required TextEditingController controller,
    int lines = 1,
    bool? copyable,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FormTextField(
              controller: controller,
              label: '内容',
              lines: lines,
              copyable: copyable,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('多行字段默认显示复制按钮并复制当前全文', (tester) async {
    final controller = TextEditingController(text: '第一行\n第二行');
    addTearDown(controller.dispose);
    await pumpField(tester, controller: controller, lines: 6);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();

    expect(copied, ['第一行\n第二行']);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('单行字段默认隐藏,显式 copyable 才显示', (tester) async {
    final controller = TextEditingController(text: 'abc');
    addTearDown(controller.dispose);
    await pumpField(tester, controller: controller);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);

    await pumpField(tester, controller: controller, copyable: true);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('空内容时复制按钮禁用', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pumpField(tester, controller: controller, lines: 4);

    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.copy_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(copied, isEmpty);
  });
}
