import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/display_regex.dart';
import 'package:microscritt/models/regex_script.dart';

void main() {
  group('compileDisplayScripts', () {
    test('drops disabled and invalid-pattern scripts', () {
      final compiled = compileDisplayScripts(const [
        RegexScript(name: 'ok', findRegex: 'a', replace: 'b'),
        RegexScript(name: 'off', findRegex: 'c', replace: 'd', enabled: false),
        RegexScript(name: 'bad', findRegex: '([unclosed', replace: 'e'),
      ]);
      expect(compiled.map((c) => c.source.name).toList(), ['ok']);
    });

    test('orders by position then id', () {
      final compiled = compileDisplayScripts(const [
        RegexScript(id: 3, name: 'third-by-id', findRegex: 'a', replace: 'a', position: 1),
        RegexScript(id: 1, name: 'first', findRegex: 'b', replace: 'b', position: 0),
        RegexScript(id: 2, name: 'second-by-id', findRegex: 'c', replace: 'c', position: 1),
      ]);
      expect(compiled.map((c) => c.source.name).toList(), ['first', 'second-by-id', 'third-by-id']);
    });

    test('memoizes by input list identity, recompiles on new instance', () {
      final a = [const RegexScript(name: 'x', findRegex: 'a', replace: 'b')];
      final first = compileDisplayScripts(a);
      // 同一实例:直接复用(流式每帧重取 Provider 值的场景)。
      expect(identical(compileDisplayScripts(a), first), isTrue);
      // 内容相同的新实例:重编(结果等价但不是同一对象)。
      final fresh = [const RegexScript(name: 'x', findRegex: 'a', replace: 'b')];
      final second = compileDisplayScripts(fresh);
      expect(identical(second, first), isFalse);
      expect(second.map((c) => c.source.name).toList(), first.map((c) => c.source.name).toList());
    });
  });

  group('applyDisplayScripts', () {
    List<CompiledRegexScript> compile(List<RegexScript> scripts) => compileDisplayScripts(scripts);

    test(r'expands $1 capture groups', () {
      final out = applyDisplayScripts(
        '她*低下头*微笑',
        compile([const RegexScript(name: 'star', findRegex: r'\*(.+?)\*', replace: '<i>*\$1*</i>')]),
      );
      expect(out, '她<i>*低下头*</i>微笑');
    });

    test(r'expands $& whole match and $$ literal dollar', () {
      final out = applyDisplayScripts(
        'abc',
        compile([const RegexScript(name: 'whole', findRegex: 'b', replace: '[\$&][\$\$]')]),
      );
      expect(out, 'a[b][\$]c');
    });

    test('out-of-range group expands to empty string', () {
      final out = applyDisplayScripts(
        'ab',
        compile([const RegexScript(name: 'x', findRegex: '(a)b', replace: '<\$2>')]),
      );
      expect(out, '<>');
    });

    test('chains multiple scripts in order', () {
      final out = applyDisplayScripts('abc', compile(const [
        RegexScript(name: '1', findRegex: 'a', replace: 'X'),
        RegexScript(name: '2', findRegex: 'Xb', replace: 'Y'),
      ]));
      expect(out, 'Yc');
    });

    test('no scripts returns text unchanged', () {
      expect(applyDisplayScripts('same', const []), 'same');
    });
  });

  group('validateRegexPattern', () {
    test('valid pattern passes, invalid reports error', () {
      expect(validateRegexPattern(r'\d+'), isNull);
      expect(validateRegexPattern('([bad'), isNotNull);
      // 空串在 Dart RegExp 里合法(匹配空串),不算无效。
      expect(validateRegexPattern(''), isNull);
    });
  });
}
