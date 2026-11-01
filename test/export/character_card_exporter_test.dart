import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/export/character_card_exporter.dart';
import 'package:microscritt/import/worldbook_importer.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';

void main() {
  test('exports the card json', () {
    const card = CharacterCard(name: 'Alice', description: 'knight');
    final json = CharacterCardExporter.export(card);
    expect(json.contains('"name":"Alice"'), isTrue);
  });

  test('re-injects the column avatar when the stored json has none (V1 flat)', () {
    // data_json 落库已剥掉内嵌头像(toStorageJson);导出必须把列里的头像补回,
    // 否则换端/重导入就丢图。
    const avatar = 'aGVsbG8=';
    final card = CharacterCard.fromJson({'name': 'Alice', 'description': 'knight'}).withAvatar(avatar);
    final json = jsonDecode(CharacterCardExporter.export(card)) as Map<String, dynamic>;
    expect(json['avatar'], avatar);
    expect(json['name'], 'Alice');
  });

  test('re-injects the avatar into the data envelope for V2 cards', () {
    const avatar = 'aGVsbG8=';
    final card = CharacterCard.fromJson({'spec': 'chara_card_v2', 'spec_version': '2.0', 'data': {'name': 'Alice'}})
        .withAvatar(avatar);
    final json = jsonDecode(CharacterCardExporter.export(card)) as Map<String, dynamic>;
    expect((json['data'] as Map<String, dynamic>)['avatar'], avatar);
  });

  test('overwrites character_book with the current worldbook entries', () {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v2',
      'data': {
        'name': 'Alice',
        // raw 里的旧快照:导入后本端已改,导出应以当前条目为准。
        'character_book': {
          'entries': [
            {'keys': ['旧条目'], 'content': '旧内容'},
          ],
        },
      },
    });
    final entries = [
      const WorldbookEntry(
        characterId: 0,
        name: '王都',
        keys: ['王都', '首都'],
        caseSensitive: true,
        matchWholeWords: true,
        selective: true,
        secondaryKeys: ['白天'],
        constant: true,
        content: '王都的描述。',
        position: 2,
      ),
    ];
    final json = jsonDecode(CharacterCardExporter.export(card, worldbook: entries)) as Map<String, dynamic>;
    final book = (json['data'] as Map<String, dynamic>)['character_book'] as Map<String, dynamic>;
    final list = (book['entries'] as List).cast<Map<String, dynamic>>();
    expect(list, hasLength(1));
    expect(list.first['comment'], '王都');
    expect(list.first['keys'], ['王都', '首都']);
    expect(list.first['content'], '王都的描述。');
    expect(list.first['constant'], true);
    expect(list.first['case_sensitive'], true);
    expect(list.first['selective'], true);
    expect(list.first['secondary_keys'], ['白天']);
    expect((list.first['extensions'] as Map)['match_whole_words'], true);

    // 往返:导出的 character_book 经导入提取器还原出等价条目。
    final reparsed = CharacterCard.fromJson(jsonDecode(CharacterCardExporter.export(card, worldbook: entries))
        as Map<String, dynamic>);
    final extracted = WorldbookImporter.extract(reparsed);
    expect(extracted, hasLength(1));
    expect(extracted.first.name, '王都');
    expect(extracted.first.keys, ['王都', '首都']);
    expect(extracted.first.constant, isTrue);
    expect(extracted.first.caseSensitive, isTrue);
    expect(extracted.first.matchWholeWords, isTrue);
    expect(extracted.first.selective, isTrue);
    expect(extracted.first.secondaryKeys, ['白天']);
    expect(extracted.first.content, '王都的描述。');
  });

  test('merges captured extra ST fields; modeled fields win on conflict (EJ)', () {
    // EJ 批:导入时捕获的未建模字段(存 WorldbookEntry.extra)导出时铺回
    // character_book,建模字段覆盖 —— ST 拿回的专有字段不再凭空丢失。
    final card = CharacterCard.fromJson({'spec': 'chara_card_v2', 'data': {'name': 'Alice'}});
    const entry = WorldbookEntry(
      characterId: 0,
      name: '王都',
      keys: ['王都'],
      constant: true,
      content: '本端改过的内容',
      extra: {
        'position': 'before_char',
        'probability': 100,
        'useProbability': true,
        'selectiveLogic': 0,
        'depth': 4,
        // 冲突字段:导出必须以建模现值为准,不能让旧透传值盖回来。
        'content': '原始内容',
        'constant': false,
        'extensions': {'color': '#ff0000'},
      },
    );
    final json = jsonDecode(CharacterCardExporter.export(card, worldbook: [entry])) as Map<String, dynamic>;
    final e2 = (((json['data'] as Map<String, dynamic>)['character_book'] as Map<String, dynamic>)['entries'] as List).single
        as Map<String, dynamic>;

    // 未建模字段原样透传。
    expect(e2['position'], 'before_char');
    expect(e2['probability'], 100);
    expect(e2['useProbability'], isTrue);
    expect(e2['selectiveLogic'], 0);
    expect(e2['depth'], 4);
    // 冲突字段以建模值为准。
    expect(e2['content'], '本端改过的内容');
    expect(e2['constant'], isTrue);
    // extensions 合并:extra 的自定义键 + 建模的 match_whole_words。
    final ext = e2['extensions'] as Map<String, dynamic>;
    expect(ext['color'], '#ff0000');
    expect(ext['match_whole_words'], false);

    // 全环往返:导出的卡再导入,透传字段原样回到 extra。
    final extracted = WorldbookImporter.extract(CharacterCard.fromJson(json));
    expect(extracted.single.extra['probability'], 100);
    expect(extracted.single.extra['position'], 'before_char');
    expect((extracted.single.extra['extensions'] as Map)['color'], '#ff0000');
    expect(extracted.single.content, '本端改过的内容');
  });

  test('keeps the raw character_book when there are no local entries', () {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v2',
      'data': {
        'name': 'Alice',
        'character_book': {
          'entries': [
            {'keys': ['旧条目'], 'content': '旧内容'},
          ],
        },
      },
    });
    final json = jsonDecode(CharacterCardExporter.export(card, worldbook: const [])) as Map<String, dynamic>;
    final book = (json['data'] as Map<String, dynamic>)['character_book'] as Map<String, dynamic>;
    expect(((book['entries'] as List).first as Map)['keys'], ['旧条目']);
  });
}