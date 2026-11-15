// 共享语法层:命令边界、技能最长匹配、宏、signature 记忆化与快路径。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/text_syntax.dart';

List<InlineToken> _scan(
  String text, {
  Set<String> skills = const {},
  bool startsAtBoundary = true,
}) => CompiledSyntax.compile(
  skillNames: skills,
).scanInline(text, startsAtBoundary: startsAtBoundary);

void main() {
  test('compile memoizes by skill signature', () {
    final a = CompiledSyntax.compile(skillNames: {'剑术', '烹饪'});
    final b = CompiledSyntax.compile(skillNames: {'烹饪', '剑术'});
    final c = CompiledSyntax.compile(skillNames: {'剑术'});
    expect(identical(a, b), isTrue);
    expect(identical(a, c), isFalse);
  });

  test('commands respect start/whitespace boundaries and case', () {
    final start = _scan('/rerun 画面更暗');
    expect(start.single.kind, InlineKind.command);
    expect(start.single.start, 0);
    expect(start.single.end, 6); // 只含命令名,不含 args

    final middle = _scan('先别动 /RERUN');
    expect(middle.single.kind, InlineKind.command);
    expect(middle.single.start, 4);
    expect(middle.single.end, 10);

    expect(_scan('/testify'), isEmpty);
    expect(_scan('a/test'), isEmpty);
    expect(_scan('/rerun', startsAtBoundary: false), isEmpty);
  });

  test('command args are not part of the token', () {
    final tokens = _scan('/rerun 画面更暗');
    expect(tokens.single.end, '/rerun'.length);
  });

  test('skill alternation prefers the longest name', () {
    final tokens = _scan('@剑术', skills: {'剑', '剑术'});
    expect(tokens.single.kind, InlineKind.skill);
    expect(tokens.single.start, 0);
    expect(tokens.single.end, '@剑术'.length);
  });

  test('macros are tokenized only as placeholders', () {
    final tokens = _scan('{{user}}和{{char}}');
    expect(tokens.map((t) => t.kind), [InlineKind.macro, InlineKind.macro]);
    expect(tokens[0].start, 0);
    expect(tokens[1].start, '{{user}}和'.length);
  });

  test('overlaps resolve to command, then skill, then macro', () {
    final tokens = _scan('@剑术 /test', skills: {'剑术'});
    expect(tokens.map((t) => t.kind), [InlineKind.skill, InlineKind.command]);
  });

  test('mayContainSpecial is a cheap gate, not a match guarantee', () {
    final syntax = CompiledSyntax.compile();
    expect(syntax.mayContainSpecial('普通文本'), isFalse);
    expect(syntax.mayContainSpecial('含 / 斜杠'), isTrue);
    expect(syntax.mayContainSpecial('含 @'), isTrue);
    expect(syntax.mayContainSpecial('{{user}}'), isTrue);
  });
}
