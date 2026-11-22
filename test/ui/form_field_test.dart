// 表单字段的复制按钮:多行默认显示、单行需显式 copyable、空内容禁用,
// 以及剪贴板写入后的图标回弹(平台通道打桩)。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/form_field.dart';
import 'package:microscritt/ui/theme/app_theme.dart';

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

  testWidgets('appInputDecoration 默认沿用主题,描边档可调圆角与内边距', (tester) async {
    InputDecoration? themed;
    InputDecoration? outlined;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              themed = appInputDecoration(context, hintText: '主题档');
              outlined = appInputDecoration(
                context,
                hintText: '描边档',
                borderAlpha: 0.5,
                radius: 10,
                contentPadding: const EdgeInsets.all(8),
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(themed!.border, isNull);
    expect(themed!.enabledBorder, isNull);
    expect(themed!.filled, isNull);

    expect(outlined!.filled, isTrue);
    expect(outlined!.contentPadding, const EdgeInsets.all(8));
    final border = outlined!.enabledBorder! as OutlineInputBorder;
    expect(border.borderRadius, BorderRadius.circular(10));
  });

  testWidgets('下拉字段的长 helper 自动换行,不再单行省略', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const helper = '仅影响后台请求,与主对话的推理等级互相独立;默认关闭。';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormDropdownField<String>(
            value: 'off',
            label: '推理强度',
            helperText: helper,
            items: const ['off'],
            labelOf: (value) => value,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final helperText = tester.widget<Text>(find.text(helper));
    expect(helperText.maxLines, 3);
    // 320 宽下该说明至少占两行,证明实际发生了换行而非单行省略。
    expect(tester.getSize(find.text(helper)).height, greaterThan(20));
  });
}
