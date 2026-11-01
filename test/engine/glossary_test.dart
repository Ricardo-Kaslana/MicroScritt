import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/glossary.dart';
import 'package:microscritt/models/worldbook_entry.dart';

WorldbookEntry _entry({
  required String keysJson,
  String content = '释义',
  bool enabled = true,
  bool useRegex = false,
  bool wholeWord = false,
  String name = '',
}) =>
    WorldbookEntry(
      characterId: 1,
      name: name,
      keys: (keysJson.split(',').map((s) => s.trim()).toList()),
      useRegex: useRegex,
      matchWholeWords: wholeWord,
      content: content,
      enabled: enabled,
    );

void main() {
  test('collects enabled entries; skips disabled/regex/empty', () {
    // v37 起世界书不再有类型之分:全部启用条目都参与词典。
    final g = compileGlossary([
      _entry(keysJson: '魔力'),
      _entry(keysJson: '禁用词', enabled: false),
      _entry(keysJson: r'\d+', useRegex: true),
      _entry(keysJson: '空释义', content: '  '),
      _entry(keysJson: ' , '),
    ]);
    expect(g.terms.map((t) => t.term).toList(), ['魔力']);
    expect(g.terms.single.title, '魔力'); // 无名条目回退触发词
  });

  test('entry name becomes card title; same term first entry wins', () {
    final g = compileGlossary([
      _entry(keysJson: '魔力,法力', name: '魔法体系'),
      _entry(keysJson: '魔力', name: '后来者'),
    ]);
    expect(g.terms.length, 2); // 魔力 + 法力
    expect(g.termFor('魔力')!.title, '魔法体系');
    expect(g.termFor('法力')!.title, '魔法体系');
  });

  test('longest term first in pattern (prefix swallowed by longer word)', () {
    final g = compileGlossary([
      _entry(keysJson: '星'),
      _entry(keysJson: '星之海'),
    ]);
    expect(g.terms.first.term, '星之海');
    final m = g.pattern!.firstMatch('来到了星之海深处');
    expect(m?.group(0), '星之海');
  });

  test('case-insensitive matching', () {
    final g = compileGlossary([_entry(keysJson: 'Ether')]);
    expect(g.termFor('ETHER')!.term, 'Ether');
    expect(g.pattern!.firstMatch('a lump of ether here')?.group(0), 'ether');
  });

  test('whole-word only for pure ASCII terms', () {
    final g = compileGlossary([_entry(keysJson: 'star', wholeWord: true)]);
    // 整词:Start 里的 star 不命中。
    expect(g.pattern!.hasMatch('Starting over'), isFalse);
    expect(g.pattern!.firstMatch('a star rises')?.group(0), 'star');

    // CJK 词条即使标了整词也走子串(无词边界)。
    final cjk = compileGlossary([_entry(keysJson: '星海', wholeWord: true)]);
    expect(cjk.pattern!.firstMatch('星海之王')?.group(0), '星海');
  });

  test('empty entries compile to empty glossary', () {
    final g = compileGlossary([]);
    expect(g.isEmpty, isTrue);
    expect(g.pattern, isNull);
  });

  test('memoizes by input list identity, recompiles on new instance', () {
    final a = [_entry(keysJson: '魔力')];
    final first = compileGlossary(a);
    expect(identical(compileGlossary(a), first), isTrue);
    final second = compileGlossary([_entry(keysJson: '魔力')]);
    expect(identical(second, first), isFalse);
    expect(second.terms.first.term, first.terms.first.term);
  });
}
