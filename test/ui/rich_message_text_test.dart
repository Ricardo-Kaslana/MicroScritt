// 富文本显示管线:{{user}}/{{char}} 宏、样式标记与引号台词、显示层正则、
// 名词词典、<chip> 胶囊,以及各环节串联后的端到端输出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/display_regex.dart';
import 'package:microscritt/engine/glossary.dart';
import 'package:microscritt/models/regex_script.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/ui/widgets/rich_message_text.dart';

void main() {
  group('expandDisplayMacros', () {
    test('替换 {{user}} 与 {{char}}', () {
      expect(
        expandDisplayMacros(
          '{{user}} 对 {{char}} 说',
          userName: '小明',
          charName: '艾莉',
        ),
        '小明 对 艾莉 说',
      );
    });

    test('名字为空时保留占位符', () {
      expect(expandDisplayMacros('{{user}}/{{char}}'), '{{user}}/{{char}}');
      expect(
        expandDisplayMacros('{{user}}', userName: '', charName: '艾莉'),
        '{{user}}',
      );
    });

    test('无占位符文本原样返回', () {
      expect(expandDisplayMacros('普通文本', userName: '小明'), '普通文本');
    });
  });

  group('RichMessageText 对话高亮', () {
    Widget wrap(Widget child) =>
        MaterialApp(home: Scaffold(body: child));

    testWidgets('引号内台词渲染为斜体强调', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '她笑了笑,“你好。”然后离开。',
        style: TextStyle(color: Colors.black),
      )));

      final rich = tester.widget<Text>(find.byType(Text).first);
      // 拆成三段:叙述 / 台词(斜体) / 尾部叙述。
      final children = _childTexts(rich);
      expect(children, ['她笑了笑,', '“你好。”', '然后离开。']);
      final dialogue = _childSpans(rich)[1];
      expect(dialogue.style?.fontStyle, FontStyle.italic);
      expect(dialogue.style?.color, isNot(Colors.black));
    });

    testWidgets('对话高亮开关关闭时引号按普通正文渲染', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '她笑了笑,“你好。”然后离开。',
        style: TextStyle(color: Colors.black),
        highlightDialogue: false,
      )));

      final rich = tester.widget<Text>(find.byType(Text).first);
      // 文本拆分不变(引号保留),但台词段不再斜体/上色。
      final children = _childTexts(rich);
      expect(children, ['她笑了笑,', '“你好。”', '然后离开。']);
      final dialogue = _childSpans(rich)[1];
      expect(dialogue.style?.fontStyle, isNot(FontStyle.italic));
      expect(dialogue.style?.color, Colors.black);
    });

    testWidgets('多种引号与无引号文本', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '「早上好」 和 "hello" 与普通句子',
        style: TextStyle(color: Colors.black),
      )));
      final rich = tester.widget<Text>(find.byType(Text).first);
      final children = _childTexts(rich);
      expect(children, ['「早上好」', ' 和 ', '"hello"', ' 与普通句子']);
    });

    testWidgets('未闭合引号不高亮(流式中途)', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '她说:“等等',
        style: TextStyle(color: Colors.black),
      )));
      final rich = tester.widget<Text>(find.byType(Text).first);
      final children = _childSpans(rich);
      // 未闭合 → 整段保持普通样式。
      expect(children.length, 1);
      expect(children[0].style?.fontStyle, isNull);
    });
  });

  group('RichMessageText 样式标记', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('斜体开合与普通文本分段', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: 'a<i>b</i>c',
        style: TextStyle(color: Colors.black),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children.map((s) => s.text).toList(), ['a', 'b', 'c']);
      expect(children[1].style?.fontStyle, FontStyle.italic);
      expect(children[2].style?.fontStyle, isNull);
    });

    testWidgets('颜色标记解析 # 与无 # 两种写法', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '<c=ff0000>红</c><c=#00ff00>绿</c>',
        style: TextStyle(color: Colors.black),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children.map((s) => s.text).toList(), ['红', '绿']);
      expect(children[0].style?.color, const Color(0xffff0000));
      expect(children[1].style?.color, const Color(0xff00ff00));
    });

    testWidgets('嵌套标记:i 套在 c 内,闭合后各自还原', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '<c=0000ff>a<i>b</i>c</c>d',
        style: TextStyle(color: Colors.black),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children.map((s) => s.text).toList(), ['a', 'b', 'c', 'd']);
      expect(children[0].style?.color, const Color(0xff0000ff));
      expect(children[1].style?.color, const Color(0xff0000ff));
      expect(children[1].style?.fontStyle, FontStyle.italic);
      expect(children[2].style?.fontStyle, isNull);
      expect(children[2].style?.color, const Color(0xff0000ff));
      expect(children[3].style?.color, Colors.black);
    });

    testWidgets('未闭合标记容忍(流式中途)与孤立闭合忽略', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '<i>abc',
        style: TextStyle(color: Colors.black),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children.single.text, 'abc');
      expect(children.single.style?.fontStyle, FontStyle.italic);

      await tester.pumpWidget(wrap(const RichMessageText(
        text: 'a</i>b</b>',
        style: TextStyle(color: Colors.black),
      )));
      // 孤立闭合标记被吞掉,不进文本也不影响样式。
      expect(_childTexts(_firstText(tester)), ['a', 'b']);
      expect(_childSpans(_firstText(tester)).every((s) => s.style?.fontStyle == null), isTrue);
    });

    testWidgets('下划线与高亮底色', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '<u>x</u><mark>y</mark>',
        style: TextStyle(color: Colors.black),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children[0].style?.decoration, TextDecoration.underline);
      expect(children[1].style?.backgroundColor, isNotNull);
    });

    testWidgets('引号台词在 c 标记内尊重其颜色', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '<c=ff0000>“台词”</c>',
        style: TextStyle(color: Colors.black),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children.single.text, '“台词”');
      expect(children.single.style?.fontStyle, FontStyle.italic);
      expect(children.single.style?.color, const Color(0xffff0000));
    });
  });

  group('RichMessageText 完整管线', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('宏替换 + 正则脚本 + 标记解析端到端', (tester) async {
      await tester.pumpWidget(wrap(RichMessageText(
        text: '{{user}} *走近* {{char}}',
        style: const TextStyle(color: Colors.black),
        userName: '小明',
        charName: '艾莉',
        scripts: compileDisplayScripts(const [
          RegexScript(name: 'star', findRegex: r'\*(.+?)\*', replace: '<i>\$1</i>'),
        ]),
      )));
      expect(_childTexts(_firstText(tester)), ['小明 ', '走近', ' 艾莉']);
      final star = _childSpans(_firstText(tester))[1];
      expect(star.style?.fontStyle, FontStyle.italic);
    });

    testWidgets('正则脚本标记语法错误时原样显示标记文本', (tester) async {
      // 替换串输出的标记不完整(没有闭合):开标记后的文本全部带样式,
      // 标记本身绝不泄漏为可见文本。
      await tester.pumpWidget(wrap(RichMessageText(
        text: 'x',
        style: const TextStyle(color: Colors.black),
        scripts: compileDisplayScripts(const [
          RegexScript(name: 'wrap', findRegex: 'x', replace: '<b>x'),
        ]),
      )));
      expect(_childTexts(_firstText(tester)), ['x']);
      expect(_childSpans(_firstText(tester)).single.style?.fontWeight, FontWeight.bold);
    });

    testWidgets('空正文返回零尺寸占位', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '',
        style: TextStyle(color: Colors.black),
      )));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('RichMessageText 名词词典', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    CompiledGlossary glossary() => compileGlossary([
          WorldbookEntry(
            characterId: 1,
            name: '魔法体系',
            keys: const ['魔力'],
            content: '驱动这个世界运转的根本力量。',
          ),
        ]);

    testWidgets('词条命中渲染为点状下划线 span,其余文本不受影响', (tester) async {
      await tester.pumpWidget(wrap(RichMessageText(
        text: '她体内的魔力涌动。',
        style: const TextStyle(color: Colors.black),
        glossary: glossary(),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children.map((s) => s.text).toList(), ['她体内的', '魔力', '涌动。']);
      expect(children[1].style?.decoration, TextDecoration.underline);
      expect(children[1].style?.decorationStyle, TextDecorationStyle.dotted);
      expect(children[0].style?.decoration, isNull);
    });

    testWidgets('点击词条触发回调(释义卡入口)', (tester) async {
      GlossaryTerm? tapped;
      await tester.pumpWidget(wrap(RichMessageText(
        text: '魔力',
        style: const TextStyle(color: Colors.black),
        glossary: glossary(),
        onTermTap: (t) => tapped = t,
      )));
      await tester.tap(find.text('魔力'));
      await tester.pump();
      expect(tapped, isNotNull);
      expect(tapped!.title, '魔法体系');
      expect(tapped!.content, '驱动这个世界运转的根本力量。');
    });

    testWidgets('台词内的词条同样高亮', (tester) async {
      await tester.pumpWidget(wrap(RichMessageText(
        text: '“这是魔力吗?”',
        style: const TextStyle(color: Colors.black),
        glossary: glossary(),
      )));
      final children = _childSpans(_firstText(tester));
      expect(children.map((s) => s.text).toList(), ['“这是', '魔力', '吗?”']);
      // 台词段整体斜体,词条在其上叠加下划线。
      expect(children.every((s) => s.style?.fontStyle == FontStyle.italic), isTrue);
      expect(children[1].style?.decoration, TextDecoration.underline);
    });

    testWidgets('无词典时不高亮', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '魔力涌动',
        style: TextStyle(color: Colors.black),
      )));
      expect(_childSpans(_firstText(tester)).single.style?.decoration, isNull);
    });
  });

  group('RichMessageText 胶囊标记 <chip>', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('chip 独占一行居中,正文块照常富文本', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '<chip>2024年·秋·晴 17:42</chip>她说:“好久不见。”',
        style: TextStyle(color: Colors.black),
      )));
      // 有 chip → RichMessageText 直接子级是块布局 Column。
      expect(
        find.descendant(of: find.byType(RichMessageText), matching: find.byType(Column)),
        findsOneWidget,
      );
      // 胶囊文本与正文文本都在,标记本身不可见。
      expect(find.text('2024年·秋·晴 17:42'), findsOneWidget);
      expect(find.text('她说:“好久不见。”'), findsOneWidget);
      expect(find.textContaining('<chip>'), findsNothing);
    });

    testWidgets('正则脚本输出 chip 标记端到端([时间] → 居中胶囊)', (tester) async {
      await tester.pumpWidget(wrap(RichMessageText(
        text: '[2024年·秋]\n她推门而入。',
        style: const TextStyle(color: Colors.black),
        scripts: compileDisplayScripts(const [
          RegexScript(name: 'ts', findRegex: r'\[([^\[\]]+)\]', replace: '<chip>\$1</chip>'),
        ]),
      )));
      expect(find.text('2024年·秋'), findsOneWidget);
      expect(find.textContaining('她推门而入。'), findsOneWidget);
      // 标记与方括号本身都不再以可见文本出现。
      expect(find.textContaining('<chip>'), findsNothing);
      expect(find.textContaining('[2024'), findsNothing);
    });

    testWidgets('流式中途未闭合的 chip 也即时按胶囊渲染', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '<chip>2024年·秋',
        style: TextStyle(color: Colors.black),
      )));
      expect(find.text('2024年·秋'), findsOneWidget);
      expect(find.textContaining('<chip>'), findsNothing);
    });

    testWidgets('无 chip 时维持单 Text 路径(不引入块布局)', (tester) async {
      await tester.pumpWidget(wrap(const RichMessageText(
        text: '普通正文',
        style: TextStyle(color: Colors.black),
      )));
      expect(
        find.descendant(of: find.byType(RichMessageText), matching: find.byType(Column)),
        findsNothing,
      );
      expect(find.text('普通正文'), findsOneWidget);
    });
  });
}

/// 取 RichMessageText 渲染出的 Text 的子 span(全部为 TextSpan)。
List<TextSpan> _childSpans(Text rich) =>
    ((rich.textSpan as TextSpan).children ?? const <InlineSpan>[])
        .cast<TextSpan>()
        .toList();

List<String?> _childTexts(Text rich) =>
    _childSpans(rich).map((s) => s.text).toList();

Text _firstText(WidgetTester tester) => tester.widget<Text>(find.byType(Text).first);
