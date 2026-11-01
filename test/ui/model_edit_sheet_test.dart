import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/ui/model_edit_sheet.dart';

/// ModelEditSheet 经 showModalBottomSheet 承载并 pop 出 [LlmModelEntry]。
/// FormTextField 的 label 不在 TextField 内部,靠 `ValueKey('field_$label')`
/// 定位温度字段(form_field.dart 里的既有惯例)。
void main() {
  const tempKey = ValueKey('field_Temperature(留空 = 0.7 默认)');

  LlmModelEntry? popped;

  Future<void> openSheet(WidgetTester tester, {LlmModelEntry? existing}) async {
    popped = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                popped = await showModalBottomSheet<LlmModelEntry>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ModelEditSheet(existing: existing),
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
  }

  // 必填字段(modelId/displayName/contextCapacity)已在 base 里齐备,
  // 让 temperature 是唯一变量,避开其他字段的必填校验分支干扰本测目的。
  const base = LlmModelEntry(
    id: 1,
    providerId: 1,
    modelId: 'gpt-4o',
    displayName: 'GPT-4o',
    contextCapacity: 128000,
    maxOutput: 4096,
  );

  testWidgets('既有 temperature 回填并去尾零(0.70 → 0.7)', (tester) async {
    await openSheet(tester, existing: base.copyWith(temperature: () => 0.7));
    final field = tester.widget<TextField>(find.byKey(tempKey));
    expect(field.controller!.text, '0.7');
  });

  testWidgets('清空 temperature → pop 出 null(主写走默认 0.7)', (tester) async {
    await openSheet(tester, existing: base.copyWith(temperature: () => 0.8));
    await tester.enterText(find.byKey(tempKey), '');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(popped, isNotNull);
    expect(popped!.temperature, isNull);
  });

  testWidgets('填入合法 0.2 → pop 出该值', (tester) async {
    await openSheet(tester, existing: base);
    await tester.enterText(find.byKey(tempKey), '0.2');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(popped!.temperature, 0.2);
  });

  testWidgets('超上限 temperature(3.0)阻断保存并弹 SnackBar', (tester) async {
    await openSheet(tester, existing: base);
    await tester.enterText(find.byKey(tempKey), '3.0');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.textContaining('Temperature 需为 0.0 – 2.0 之间的数字'), findsOneWidget);
    expect(popped, isNull);
  });

  testWidgets('非数字 temperature("abc")阻断保存并弹 SnackBar', (tester) async {
    await openSheet(tester, existing: base);
    await tester.enterText(find.byKey(tempKey), 'abc');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.textContaining('Temperature 需为 0.0 – 2.0 之间的数字'), findsOneWidget);
    expect(popped, isNull);
  });
}
