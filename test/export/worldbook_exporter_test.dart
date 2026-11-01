// 世界书导出测试:ST World Info 形态、order/uid 回退与经导入器的往返。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/export/worldbook_exporter.dart';
import 'package:microscritt/import/worldbook_importer.dart';
import 'package:microscritt/models/worldbook_entry.dart';

void main() {
  test('exports ST World Info shape: entries object with native field names', () {
    const entry = WorldbookEntry(
      characterId: 0,
      name: '王都',
      keys: ['王都', '首都'],
      useRegex: true,
      caseSensitive: true,
      matchWholeWords: true,
      selective: true,
      secondaryKeys: ['白天'],
      constant: true,
      content: '王都的描述。',
      position: 3,
      enabled: false,
      background: true,
      extra: {
        'position': 'before_char',
        'probability': 80,
        'extensions': {'color': '#fff'},
      },
    );
    final json = jsonDecode(WorldbookExporter.export([entry])) as Map<String, dynamic>;
    final entries = json['entries'] as Map<String, dynamic>;
    expect(entries.keys.toList(), ['0']);
    final e = entries['0'] as Map<String, dynamic>;
    expect(e['key'], ['王都', '首都']);
    expect(e['keysecondary'], ['白天']);
    expect(e['comment'], '王都');
    expect(e['content'], '王都的描述。');
    expect(e['constant'], true);
    expect(e['selective'], true);
    // enabled=false 写成 ST 的反布尔 disable。
    expect(e['disable'], true);
    // 本端 position 是排序序号 → 写 ST 的 order;ST 的插入位置枚举由 extra 透传,不覆写。
    expect(e['order'], 3);
    expect(e['position'], 'before_char');
    expect(e['caseSensitive'], true);
    expect(e['useRegex'], true);
    expect(e['matchWholeWords'], true);
    expect(e['background'], true);
    expect(e['uid'], 0);
    expect(e['probability'], 80);
    final ext = e['extensions'] as Map<String, dynamic>;
    expect(ext['color'], '#fff');
    expect(ext['match_whole_words'], true);
  });

  test('order and uid fall back to the array index', () {
    final json =
        jsonDecode(
              WorldbookExporter.export(const [
                WorldbookEntry(characterId: 0, keys: ['a'], content: 'a'),
                WorldbookEntry(characterId: 0, keys: ['b'], content: 'b'),
              ]),
            )
            as Map<String, dynamic>;
    final entries = json['entries'] as Map<String, dynamic>;
    expect((entries['0'] as Map)['order'], 0);
    expect((entries['1'] as Map)['order'], 1);
    expect((entries['0'] as Map)['uid'], 0);
    expect((entries['1'] as Map)['uid'], 1);
  });

  test('round-trips every modeled field through the importer', () {
    const entry = WorldbookEntry(
      characterId: 0,
      name: '王都',
      keys: ['王都', '首都'],
      useRegex: true,
      caseSensitive: true,
      matchWholeWords: true,
      selective: true,
      secondaryKeys: ['白天'],
      constant: true,
      content: '王都的描述。',
      position: 2,
      enabled: false,
      background: true,
      extra: {'probability': 80, 'position': 'before_char'},
    );
    final reparsed = WorldbookImporter.fromJson(jsonDecode(WorldbookExporter.export([entry]))).single;
    expect(reparsed.name, '王都');
    expect(reparsed.keys, ['王都', '首都']);
    expect(reparsed.useRegex, isTrue);
    expect(reparsed.caseSensitive, isTrue);
    expect(reparsed.matchWholeWords, isTrue);
    expect(reparsed.selective, isTrue);
    expect(reparsed.secondaryKeys, ['白天']);
    expect(reparsed.constant, isTrue);
    expect(reparsed.content, '王都的描述。');
    expect(reparsed.enabled, isFalse);
    // background 是本端扩展:不写它就会在"导出→导入"后退回按常驻推断。
    expect(reparsed.background, isTrue);
    // 未建模字段原样回到 extra;建模过的 extensions 键不残留。
    expect(reparsed.extra['probability'], 80);
    expect(reparsed.extra['position'], 'before_char');
    expect(reparsed.extra.containsKey('extensions'), isFalse);
  });

  test('exports an empty book as an empty entries object', () {
    expect(jsonDecode(WorldbookExporter.export(const [])), {'entries': <String, dynamic>{}});
  });

  test('card-form entry keeps the character_book field names', () {
    const entry = WorldbookEntry(
      characterId: 0,
      name: '王都',
      keys: ['王都'],
      selective: true,
      secondaryKeys: ['白天'],
      constant: true,
      content: 'desc',
      position: 2,
      enabled: false,
      background: true,
    );
    final e = WorldbookExporter.toCardEntry(entry, 0);
    expect(e['keys'], ['王都']);
    expect(e['secondary_keys'], ['白天']);
    expect(e['enabled'], false);
    expect(e['insertion_order'], 2);
    expect(e['background'], true);
    expect((e['extensions'] as Map)['match_whole_words'], false);
  });
}
