// 输入框控制器:行内样式接入、IME 组合回退与技能集合变化后的刷新。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/text_syntax.dart';
import 'package:microscritt/ui/widgets/chat_composer.dart';

void main() {
  Future<(BuildContext, ComposerSyntaxController)> pumpController(
    WidgetTester tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(key: key, builder: (_) => const SizedBox()),
      ),
    );
    final controller = ComposerSyntaxController();
    addTearDown(controller.dispose);
    return (key.currentContext!, controller);
  }

  List<TextSpan> children(TextSpan span) =>
      span.children?.whereType<TextSpan>().toList() ?? const [];

  testWidgets('controller renders commands and style tags inline', (
    tester,
  ) async {
    final (context, controller) = await pumpController(tester);
    controller.text = '/rerun 画面更暗 <b>粗</b>';

    final span = controller.buildTextSpan(
      context: context,
      style: null,
      withComposing: false,
    );
    final enabled = children(span);
    final command = enabled.firstWhere((s) => s.text == '/rerun');
    expect(command.style?.color, Theme.of(context).colorScheme.tertiary);
    expect(command.style?.fontWeight, FontWeight.w600);
    expect(
      enabled.firstWhere((s) => s.text == '粗').style?.fontWeight,
      FontWeight.bold,
    );
    expect(enabled.firstWhere((s) => s.text == '<b>').style?.color, isNotNull);
  });

  testWidgets('skill tokens appear after updateSyntax without touching text', (
    tester,
  ) async {
    final (context, controller) = await pumpController(tester);
    controller.text = '@剑术';
    controller.selection = const TextSelection.collapsed(offset: 3);

    final before = controller.buildTextSpan(
      context: context,
      style: null,
      withComposing: false,
    );
    expect(children(before).where((s) => s.style?.color != null), isEmpty);

    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.updateSyntax(
      CompiledSyntax.compile(skillNames: {'剑术'}),
      highlightDialogue: true,
    );
    await tester.pump();
    expect(notifications, 1);

    final after = controller.buildTextSpan(
      context: context,
      style: null,
      withComposing: false,
    );
    final skill = children(after).firstWhere((s) => s.text == '@剑术');
    expect(skill.style?.color, Theme.of(context).colorScheme.primary);

    // 相同签名不重复通知;文本与选区始终原样。
    controller.updateSyntax(
      CompiledSyntax.compile(skillNames: {'剑术'}),
      highlightDialogue: true,
    );
    await tester.pump();
    expect(notifications, 1);
    expect(controller.text, '@剑术');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
  });

  testWidgets('IME composing falls back to the base span tree', (tester) async {
    final (context, controller) = await pumpController(tester);
    controller.updateSyntax(CompiledSyntax.compile(), highlightDialogue: true);
    controller.value = const TextEditingValue(
      text: '/test',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 0, end: 5),
    );

    final span = controller.buildTextSpan(
      context: context,
      style: null,
      withComposing: true,
    );
    // 组合期间不做语法染色,保住 IME 下划线;原文与选区不变。
    expect(
      children(
        span,
      ).where((s) => s.style?.color == Theme.of(context).colorScheme.tertiary),
      isEmpty,
    );
    expect(controller.text, '/test');
    expect(controller.selection, const TextSelection.collapsed(offset: 5));
  });
}
