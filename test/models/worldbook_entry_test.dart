import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/worldbook_entry.dart';

void main() {
  test('toMap/fromMap round-trips all fields', () {
    const entry = WorldbookEntry(
      id: 7,
      characterId: 3,
      name: '圣剑传说',
      keys: ['sword', 'blade'],
      useRegex: true,
      caseSensitive: true,
      matchWholeWords: true,
      selective: true,
      secondaryKeys: ['cursed'],
      constant: false,
      content: 'The sword glows.',
      position: 2,
      enabled: false,
    );
    final restored = WorldbookEntry.fromMap(entry.toMap());
    expect(restored.id, 7);
    expect(restored.characterId, 3);
    expect(restored.name, '圣剑传说');
    expect(restored.keys, ['sword', 'blade']);
    expect(restored.useRegex, isTrue);
    expect(restored.caseSensitive, isTrue);
    expect(restored.matchWholeWords, isTrue);
    expect(restored.selective, isTrue);
    expect(restored.secondaryKeys, ['cursed']);
    expect(restored.constant, isFalse);
    expect(restored.content, 'The sword glows.');
    expect(restored.position, 2);
    expect(restored.enabled, isFalse);
  });

  test('defaults: empty name/keys, not regex, not constant, enabled', () {
    const entry = WorldbookEntry(characterId: 1, content: 'x');
    expect(entry.name, isEmpty);
    expect(entry.keys, isEmpty);
    expect(entry.useRegex, isFalse);
    expect(entry.constant, isFalse);
    expect(entry.enabled, isTrue);
  });

  test('displayLabel: name wins, then first keys, then constant placeholder', () {
    expect(
      const WorldbookEntry(characterId: 1, name: '命名', keys: ['k'], content: 'c').displayLabel,
      '命名',
    );
    expect(
      const WorldbookEntry(characterId: 1, keys: ['a', 'b'], content: 'c').displayLabel,
      'a, b',
    );
    expect(
      const WorldbookEntry(characterId: 1, content: 'c').displayLabel,
      '(常驻/无关键词)',
    );
  });

  test('fromMap tolerates legacy rows that still carry a kind column (v37 de-kind)', () {
    final m = <String, Object?>{
      'id': 9,
      'character_id': 2,
      // 历史遗留列:kind 曾为 rule/skill,v37 起模型不再读取。
      'kind': 'skill',
      'name': '',
      'key': jsonEncode(['k']),
      'content': 'legacy',
    };
    final e = WorldbookEntry.fromMap(m);
    expect(e.keys, ['k']);
    expect(e.content, 'legacy');
    expect(e.enabled, isTrue);
  });
}
