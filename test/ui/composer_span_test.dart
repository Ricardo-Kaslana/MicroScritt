// 输入框行内 Span:命令/技能/宏、标签真实样式、引号、chip、原文不变与
// 普通段 style==null 契约。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/composer_span_builder.dart';
import 'package:microscritt/ui/text_syntax.dart';

final _scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3355AA));
final _palette = SyntaxPalette.of(_scheme, SyntaxSurface.composer);

TextSpan? _build(
  String text, {
  Set<String> skills = const {},
  bool dialogue = true,
}) {
  return buildComposerSpans(
    text: text,
    baseStyle: null,
    syntax: CompiledSyntax.compile(skillNames: skills),
    palette: _palette,
    highlightDialogue: dialogue,
  );
}

List<TextSpan> _children(TextSpan? span) =>
    span?.children?.whereType<TextSpan>().toList() ?? const [];

String _joined(TextSpan? span) =>
    _children(span).map((s) => s.text ?? '').join();

TextSpan _text(TextSpan? span, String text) =>
    _children(span).firstWhere((s) => s.text == text);

void main() {
  test('plain text returns null so the field uses its default spans', () {
    expect(_build('普通文本'), isNull);
  });

  test('slash text without a known command still returns null', () {
    expect(_build('a/test'), isNull);
    expect(_build('/testify'), isNull);
  });

  test('@skill tokens color only the token; neighbors keep null style', () {
    final span = _build('试试@剑术看看', skills: {'剑术'});
    expect(_text(span, '@剑术').style?.color, _scheme.primary);
    expect(_text(span, '试试').style, isNull);
    expect(_text(span, '看看').style, isNull);
    expect(_joined(span), '试试@剑术看看');
  });

  test('commands color only the command name and keep args unstyled', () {
    final span = _build('/rerun 画面更暗');
    final command = _text(span, '/rerun');
    expect(command.style?.color, _scheme.tertiary);
    expect(command.style?.fontWeight, FontWeight.w600);
    expect(_text(span, ' 画面更暗').style, isNull);
    expect(_joined(span), '/rerun 画面更暗');
  });

  test('macros render as italic placeholders', () {
    final span = _build('{{user}}来了');
    final macro = _text(span, '{{user}}');
    expect(macro.style?.color, _palette.macro);
    expect(macro.style?.fontStyle, FontStyle.italic);
  });

  test('style tags apply real styles and dim the markers', () {
    final span = _build('a<b>粗</b>c');
    expect(_text(span, '粗').style?.fontWeight, FontWeight.bold);
    expect(_text(span, '<b>').style?.color, _palette.markup);
    expect(_text(span, '</b>').style?.color, _palette.markup);
    expect(_text(span, 'a').style, isNull);
    expect(_text(span, 'c').style, isNull);
    expect(_joined(span), 'a<b>粗</b>c');
  });

  test('nested tags compose, and color/mark map to real effects', () {
    final nested = _build('<b><i>x</i></b>');
    expect(_text(nested, 'x').style?.fontWeight, FontWeight.bold);
    expect(_text(nested, 'x').style?.fontStyle, FontStyle.italic);

    final colored = _build('<c=ff0000>红</c>');
    expect(_text(colored, '红').style?.color, const Color(0xFFFF0000));

    final marked = _build('<mark>高亮</mark>');
    expect(_text(marked, '高亮').style?.backgroundColor, _palette.markBackground);
  });

  test('unclosed tags still style the tail and never lose text', () {
    final span = _build('<b>粗');
    expect(_text(span, '粗').style?.fontWeight, FontWeight.bold);
    expect(_joined(span), '<b>粗');
  });

  test('mismatched close markers are dimmed but do not change the stack', () {
    final span = _build('a</b>b');
    expect(_text(span, 'a').style, isNull);
    expect(_text(span, 'b').style, isNull);
    expect(_text(span, '</b>').style?.color, _palette.markup);
    expect(_joined(span), 'a</b>b');
  });

  test(
    'quotes italicize and accent, and commands inside quotes stay plain',
    () {
      final span = _build('“/test 台词”');
      for (final child in _children(span)) {
        expect(child.style?.fontStyle, FontStyle.italic);
        expect(child.style?.color, isNot(_scheme.tertiary));
      }
      expect(_joined(span), '“/test 台词”');
    },
  );

  test('dialogue highlighting can be turned off while tags still apply', () {
    final plain = _build('“台词”', dialogue: false);
    expect(_children(plain).every((s) => s.style == null), isTrue);

    final tagged = _build('“<b>粗</b>”', dialogue: false);
    expect(_text(tagged, '粗').style?.fontWeight, FontWeight.bold);
  });

  test('chip markers are dimmed and content gets a background', () {
    final span = _build('<chip>时间</chip>');
    expect(_text(span, '<chip>').style?.color, _palette.markup);
    expect(_text(span, '</chip>').style?.color, _palette.markup);
    expect(_text(span, '时间').style?.backgroundColor, _palette.chipBackground);
    expect(_joined(span), '<chip>时间</chip>');
  });

  test('unclosed chip keeps its background through the tail', () {
    final span = _build('<chip>时间');
    expect(_text(span, '时间').style?.backgroundColor, _palette.chipBackground);
    expect(_joined(span), '<chip>时间');
  });

  test('a command after a non-whitespace character is not highlighted', () {
    final span = _build('x/test');
    expect(span, isNull);
  });
}
