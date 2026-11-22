// 通用列表编辑底单:逐元素保存,元素内的换行/逗号不参与拆分。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/list_edit_sheet.dart';

void main() {
  testWidgets('per-element editing keeps newlines and commas intact', (
    tester,
  ) async {
    List<String>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showListEditSheet(
                  context,
                  title: '编辑「标签」',
                  initialValues: const ['a,b'],
                  hintText: '输入一个标签…',
                  multiline: false,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('编辑「标签」'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'x,y');
    await tester.tap(find.text('添加一条'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'c,d');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result, ['x,y', 'c,d']);
  });
}
