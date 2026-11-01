// 角色卡世界书提取测试:字段归一化、排序口径与未建模字段的 extra 捕获。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/import/worldbook_importer.dart';
import 'package:microscritt/models/character_card.dart';

void main() {
  test('extracts entries from a V2 flat card', () {
    final card = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': [
          {'keys': ['sword', 'blade'], 'content': 'The sword glows', 'constant': false},
          {'keys': <String>[], 'content': 'Always-on lore', 'constant': true},
        ],
      },
    });
    final entries = WorldbookImporter.extract(card);
    expect(entries.length, 2);
    expect(entries[0].keys, ['sword', 'blade']);
    expect(entries[0].content, 'The sword glows');
    expect(entries[1].constant, isTrue);
    // 后台锚定选择随导入初始化:以常驻条目为准(与本端 v52 迁移同款回填)。
    expect(entries[0].background, isFalse);
    expect(entries[1].background, isTrue);
    // v37 起世界书不再有类型之分:导入条目一律按普通条目处理。
  });

  test('extracts entries from a V3 wrapped card', () {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v3',
      'data': {
        'name': 'A',
        'character_book': {
          'entries': [
            {'keys': ['king'], 'content': 'The king rules', 'use_regex': true},
          ],
        },
      },
    });
    final entries = WorldbookImporter.extract(card);
    expect(entries.length, 1);
    expect(entries[0].useRegex, isTrue);
  });

  test('returns empty when no character_book present', () {
    expect(WorldbookImporter.extract(const CharacterCard(name: 'A')), isEmpty);
  });

  test('maps ST comment to the display name (trimmed; empty stays blank)', () {
    final card = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': [
          {'keys': ['sword'], 'content': 'x', 'comment': '  圣剑传说  '},
          {'keys': ['king'], 'content': 'y', 'comment': '  '},
          {'keys': ['queen'], 'content': 'z'},
        ],
      },
    });
    final entries = WorldbookImporter.extract(card);
    expect(entries[0].name, '圣剑传说');
    expect(entries[1].name, isEmpty);
    expect(entries[2].name, isEmpty);
  });

  test('keeps secondary_keys separate with selective semantics (ST)', () {
    final card = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': [
          {
            'keys': ['primary'],
            'secondary_keys': ['secondary'],
            'content': 'x',
            'selective': true,
            'case_sensitive': true,
            'useRegex': true,
            'extensions': {'match_whole_words': true},
          },
        ],
      },
    });
    final entries = WorldbookImporter.extract(card);
    expect(entries.single.keys, ['primary']);
    expect(entries.single.secondaryKeys, ['secondary']);
    expect(entries.single.selective, isTrue);
    expect(entries.single.caseSensitive, isTrue);
    expect(entries.single.matchWholeWords, isTrue);
    expect(entries.single.useRegex, isTrue);
    expect(entries.single.enabled, isTrue);
  });

  test('normalizes key shapes: single strings, key field, commas, non-string values', () {
    final card = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': [
          {'keys': '图书馆,国都', 'content': 'comma string keys'},
          {'key': '孤立的key', 'content': 'singular key field'},
          {'keys': ['alpha,beta', 'beta', 123, true, 'gamma，delta'], 'content': 'mixed array'},
        ],
      },
    });
    final entries = WorldbookImporter.extract(card);
    expect(entries[0].keys, ['图书馆', '国都']);
    expect(entries[1].keys, ['孤立的key']);
    // 逗号切分 + 去重 + 数字/布尔转字符串。
    expect(entries[2].keys, ['alpha', 'beta', '123', 'true', 'gamma', 'delta']);
  });

  test('preserves disabled state and keyless entries; drops empty content only (EF)', () {
    // 提取语义是按原样保真导入,不再过滤"不可注入条目":
    // 停用条目照原 enabled 状态落库(引擎本就不注入停用条目,行为等价),
    // 内容不再在"导出→导入"或重导入一次后凭空丢失;无关键词且非常驻的
    // 占位条目同样保留(引擎永不触发,纯惰性数据)。只有空内容仍被丢弃。
    final card = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': [
          {'keys': ['a'], 'content': 'ok'},
          {'keys': ['b'], 'content': 'off', 'enabled': false},
          {'keys': ['c'], 'content': 'legacy off', 'disabled': true},
          {'keys': ['d'], 'content': '   '},
          {'keys': <String>[], 'content': 'no keys, not constant'},
        ],
      },
    });
    final entries = WorldbookImporter.extract(card);
    expect(entries.map((e) => e.content).toList(),
        ['ok', 'off', 'legacy off', 'no keys, not constant']);
    expect(entries[0].enabled, isTrue);
    expect(entries[1].enabled, isFalse); // ST enabled=false → 停用落库
    expect(entries[2].enabled, isFalse); // 旧式 disabled=true → 停用落库
    expect(entries[3].enabled, isTrue); // 无触发条件但启用态照记
  });

  test('captures unmodeled ST fields into extra; modeled/sort fields are stripped (EJ)', () {
    final card = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': [
          {
            'comment': '王都', 'keys': ['王都'], 'content': 'desc',
            'enabled': true, 'constant': false, 'case_sensitive': false,
            'selective': true, 'secondary_keys': ['白天'],
            'insertion_order': 5,
            // 未建模的 ST 专有字段:原样进 extra。
            'position': 'before_char', 'probability': 80, 'useProbability': true,
            'selectiveLogic': 1, 'role': 0, 'depth': 4, 'sticky': 3,
            'extensions': {'color': '#fff', 'match_whole_words': true},
          },
        ],
      },
    });
    final e = WorldbookImporter.extract(card).single;
    expect(e.extra['probability'], 80);
    expect(e.extra['position'], 'before_char');
    expect(e.extra['selectiveLogic'], 1);
    expect(e.extra['sticky'], 3);
    expect(e.extra['role'], 0);
    // 建模字段与排序字段不进 extra(导出时由建模状态/position 序号重写)。
    expect(e.extra.containsKey('insertion_order'), isFalse);
    expect(e.extra.containsKey('comment'), isFalse);
    expect(e.extra.containsKey('selective'), isFalse);
    expect(e.extra.containsKey('secondary_keys'), isFalse);
    // extensions 只留未建模的自定义键。
    expect(e.extra['extensions'], {'color': '#fff'});
  });

  test('accepts entries as object map and character_book as array (RP-Hub tolerance)', () {
    final asObject = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': {
          'k1': {'keys': ['a'], 'content': 'from object'},
        },
      },
    });
    expect(WorldbookImporter.extract(asObject).map((e) => e.content).toList(), ['from object']);

    final asArray = CharacterCard.fromJson({
      'name': 'A',
      'character_book': [
        {'keys': ['b'], 'content': 'book is array'},
      ],
    });
    expect(WorldbookImporter.extract(asArray).map((e) => e.content).toList(), ['book is array']);
  });

  test('sorts entries: ST insertion_order, RP-Hub order, stable within equal keys', () {
    final st = CharacterCard.fromJson({
      'name': 'A',
      'character_book': {
        'entries': [
          {'keys': ['x'], 'content': 'third', 'insertion_order': 2},
          {'keys': ['y'], 'content': 'first', 'insertion_order': 0},
          {'keys': ['z'], 'content': 'second', 'insertion_order': 1},
        ],
      },
    });
    expect(
      WorldbookImporter.extract(st).map((e) => e.content).toList(),
      ['first', 'second', 'third'],
    );
    // position 承接排序后的序号。
    expect(WorldbookImporter.extract(st).map((e) => e.position).toList(), [0, 1, 2]);

    final rp = CharacterCard.fromJson({
      'data': {
        'name': 'A',
        'extensions': {'rp_hub_watermark': 'rp-hub'},
        'character_book': {
          'entries': [
            {'keys': ['x'], 'content': 'low', 'order': 9},
            {'keys': ['y'], 'content': 'high', 'order': 1},
            {'keys': ['z'], 'content': 'mid', 'order': 5},
          ],
        },
      },
    });
    expect(
      WorldbookImporter.extract(rp).map((e) => e.content).toList(),
      ['high', 'mid', 'low'],
    );
  });

  test('does not read a leftover data envelope when top-level name exists (V1 upgrade)', () {
    final card = CharacterCard.fromJson({
      'name': '旧版',
      'character_book': {
        'entries': [{'keys': ['top'], 'content': 'from flat top'}],
      },
      'data': {
        'name': '嵌套版',
        'character_book': {
          'entries': [{'keys': ['inner'], 'content': 'from envelope'}],
        },
      },
    });
    expect(WorldbookImporter.extract(card).map((e) => e.content).toList(), ['from flat top']);
  });
}