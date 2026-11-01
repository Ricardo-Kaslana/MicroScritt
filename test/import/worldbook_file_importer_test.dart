import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/import/worldbook_importer.dart';
import 'package:microscritt/models/worldbook_entry.dart';

void main() {
  test('imports an ST World Info file (entries object, key arrays, disable)', () {
    final entries = WorldbookImporter.fromJson({
      'entries': {
        '0': {
          'uid': 0,
          'key': ['sword', 'blade'],
          'keysecondary': ['night'],
          'comment': '圣剑',
          'content': 'The sword glows',
          'constant': false,
          'selective': true,
          'disable': true,
          'order': 2,
          'caseSensitive': true,
          'matchWholeWords': true,
        },
        '1': {'key': 'always', 'content': 'Always-on lore', 'constant': true, 'order': 1},
      },
    });
    // order 升序:常驻那条(order 1)在前。
    expect(entries.map((e) => e.content).toList(), ['Always-on lore', 'The sword glows']);
    final sword = entries.last;
    expect(sword.name, '圣剑');
    expect(sword.keys, ['sword', 'blade']);
    expect(sword.secondaryKeys, ['night']);
    expect(sword.selective, isTrue);
    expect(sword.caseSensitive, isTrue);
    expect(sword.matchWholeWords, isTrue);
    // ST 的反布尔 disable=true → 停用。
    expect(sword.enabled, isFalse);
    expect(sword.background, isFalse);
    // 第三方文件没有 background 字段 → 按常驻初始化(与 v52 迁移同款口径)。
    expect(entries.first.background, isTrue);
    // `key` 单字符串形态。
    expect(entries.first.keys, ['always']);
  });

  test('imports a bare entry array', () {
    final entries = WorldbookImporter.fromJson([
      {'keys': ['a'], 'content': 'first'},
      {'keys': ['b'], 'content': 'second'},
    ]);
    expect(entries.map((e) => e.content).toList(), ['first', 'second']);
  });

  test('imports a book whose entries are an array', () {
    final entries = WorldbookImporter.fromJson({
      'entries': [
        {'keys': ['a'], 'content': 'from array'},
      ],
    });
    expect(entries.single.content, 'from array');
  });

  test('routes a character card json through its character_book', () {
    final entries = WorldbookImporter.fromJson({
      'spec': 'chara_card_v2',
      'data': {
        'name': 'Alice',
        'character_book': {
          'entries': [
            {'keys': ['king'], 'content': 'The king rules'},
          ],
        },
      },
    });
    expect(entries.single.content, 'The king rules');
  });

  test('accepts a single entry object', () {
    final entries = WorldbookImporter.fromJson({'keys': ['solo'], 'content': 'lone entry'});
    expect(entries.single.content, 'lone entry');
  });

  test('reads bytes and tolerates a UTF-8 BOM', () {
    final bytes = Uint8List.fromList([
      0xEF, 0xBB, 0xBF,
      ...utf8.encode(jsonEncode({
        'entries': [
          {'keys': ['a'], 'content': 'bom ok'},
        ],
      })),
    ]);
    expect(WorldbookImporter.fromBytes(bytes).single.content, 'bom ok');
  });

  test('throws a FormatException on malformed json', () {
    expect(
      () => WorldbookImporter.fromBytes(Uint8List.fromList(utf8.encode('not json'))),
      throwsA(isA<FormatException>()),
    );
  });

  test('throws a FormatException when no worldbook is present', () {
    expect(() => WorldbookImporter.fromJson({'hello': 'world'}), throwsA(isA<FormatException>()));
    expect(() => WorldbookImporter.fromJson({'entries': <String, dynamic>{}}), throwsA(isA<FormatException>()));
    expect(() => WorldbookImporter.fromJson(42), throwsA(isA<FormatException>()));
  });

  group('mergeInto', () {
    const existing = [
      WorldbookEntry(characterId: 0, name: 'a', keys: ['a'], content: 'a', position: 0),
      WorldbookEntry(characterId: 0, name: 'b', keys: ['b'], content: 'b', position: 7),
    ];
    const incoming = [
      WorldbookEntry(characterId: 0, name: 'x', keys: ['x'], content: 'x', position: 0),
      WorldbookEntry(characterId: 0, name: 'y', keys: ['y'], content: 'y', position: 1),
    ];

    test('append keeps existing entries and repositions imported after the max', () {
      final merged = WorldbookImporter.mergeInto(existing, incoming, replace: false);
      expect(merged.map((e) => e.name).toList(), ['a', 'b', 'x', 'y']);
      // 现有条目的 position 原样(用户手填的值不动);导入条目顺延到最大 position 之后。
      expect(merged.map((e) => e.position).toList(), [0, 7, 8, 9]);
    });

    test('replace drops existing entries and renumbers from zero', () {
      final merged = WorldbookImporter.mergeInto(existing, incoming, replace: true);
      expect(merged.map((e) => e.name).toList(), ['x', 'y']);
      expect(merged.map((e) => e.position).toList(), [0, 1]);
    });

    test('append into an empty book starts at zero', () {
      final merged = WorldbookImporter.mergeInto(const [], incoming, replace: false);
      expect(merged.map((e) => e.position).toList(), [0, 1]);
    });

    test('empty incoming is a no-op even when replace is requested', () {
      // "用空集合覆盖"会把整本书清空,属破坏性误操作 → 按 no-op 处理。
      expect(WorldbookImporter.mergeInto(existing, const [], replace: true), same(existing));
      expect(WorldbookImporter.mergeInto(existing, const [], replace: false), same(existing));
    });
  });
}
