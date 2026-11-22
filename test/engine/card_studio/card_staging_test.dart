// 制卡暂存测试:字段覆盖、条目 id/extra/position 稳定、删除与恢复语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/card_studio/card_staging.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';

void main() {
  CharacterCard baseCard() => const CharacterCard(
        name: '旧名字',
        description: '旧描述',
        personality: '旧性格',
        creator: 'author',
        characterVersion: '1.2',
        fav: true,
        depthPrompt: '旧深度',
        raw: {
          'spec': 'chara_card_v2',
          'data': {'name': '旧名字'},
        },
      );

  WorldbookEntry entry(int id, String name, {int position = 0, String content = 'c'}) =>
      WorldbookEntry(
        id: id,
        characterId: 7,
        name: name,
        keys: ['k$id'],
        content: content,
        position: position,
        extra: {'probability': 100},
      );

  test('field overrides: last wins, untouched fields and metadata preserved', () {
    final staging = CardStaging(baseCard: baseCard(), characterId: 7);
    staging.setFields({'name': '中间名', 'description': '新描述'});
    staging.setFields({'name': '新名字'});

    final card = staging.workingCard;
    expect(card.name, '新名字');
    expect(card.description, '新描述');
    expect(card.personality, '旧性格');
    expect(card.creator, 'author');
    expect(card.characterVersion, '1.2');
    expect(card.fav, isTrue);
    expect(card.depthPrompt, '旧深度');
    expect(card.raw, {'spec': 'chara_card_v2', 'data': {'name': '旧名字'}});
    expect(staging.overriddenFieldCount, 2);
  });

  test('new card builds from empty baseline; generated avatar is included', () {
    final staging = CardStaging(characterId: 0);
    staging.setFields({
      'name': '新卡',
      'alternateGreetings': ['g1', 'g2'],
      'tags': ['tag'],
    });
    expect(staging.workingCard.name, '新卡');
    expect(staging.workingCard.alternateGreetings, ['g1', 'g2']);
    expect(staging.workingCard.avatarHash, isNull);

    staging.avatarPrompt = 'portrait';
    staging.avatarHash = 'asset-hash';
    expect(staging.workingCard.avatarHash, 'asset-hash');
  });

  test('add/remove entries: temp negative id, appended position, delete cap ledger', () {
    final base = [entry(1, 'A', position: 0), entry(2, 'B', position: 1)];
    final staging = CardStaging(baseEntries: base, characterId: 7);

    final addedId = staging.addEntry(WorldbookEntry(
      characterId: 7,
      name: 'C',
      keys: const ['c'],
      content: 'new',
    ));
    expect(addedId, lessThan(0));
    expect(staging.isStagedNew(addedId), isTrue);
    expect(staging.workingEntries.last.id, addedId);
    expect(staging.workingEntries.last.position, 2);

    expect(staging.removeEntry(addedId), isTrue);
    expect(staging.workingEntries.any((e) => e.id == addedId), isFalse);
    // 本地新增条目被删不计入删除帽。
    expect(staging.everRemoved, isEmpty);

    expect(staging.removeEntry(1), isTrue);
    expect(staging.removedBaseIds, {1});
    expect(staging.everRemoved, {1});
    expect(staging.workingEntries.map((e) => e.id), [2]);

    // re-remove 不命中(已不在工作副本),累计帽不重复计。
    expect(staging.removeEntry(1), isFalse);
    expect(staging.everRemoved, {1});
  });

  test('upsert restores a removed base entry and keeps it in the ledger', () {
    final base = [entry(1, 'A', position: 0), entry(2, 'B', position: 1)];
    final staging = CardStaging(baseEntries: base, characterId: 7);
    staging.removeEntry(1);
    expect(staging.removedBaseIds, {1});

    staging.upsertEntry(entry(1, 'A2', position: 0, content: 'updated'));
    expect(staging.removedBaseIds, isEmpty);
    expect(staging.everRemoved, {1});
    expect(staging.workingEntryById(1)!.name, 'A2');
    expect(staging.workingEntryById(1)!.extra, {'probability': 100});
    expect(staging.workingEntries.map((e) => e.id), [1, 2]);
  });

  test('seeded negative ids stay unique across rounds', () {
    final staging = CardStaging(
      baseEntries: [
        entry(-1, '首轮新增', position: 0),
        entry(-3, '更早新增', position: 1),
      ],
      characterId: 7,
    );
    expect(staging.stagedNewCount, 2);

    final next = staging.addEntry(
      WorldbookEntry(characterId: 7, name: '本轮新增', content: 'new'),
    );
    expect(next, -4);
    expect(
      staging.workingEntries.where((e) => e.id! < 0).map((e) => e.id),
      [-1, -3, -4],
    );
    expect(staging.stagedNewCount, 3);

    // 种子里的新增条目删除仍不计入 base 删除帽。
    expect(staging.removeEntry(-1), isTrue);
    expect(staging.everRemoved, isEmpty);
    expect(staging.stagedNewCount, 2);
  });

  test('name lookup is trimmed and case-insensitive; empty name matches nothing', () {
    final staging = CardStaging(
      baseEntries: [entry(1, 'Alice'), entry(2, 'alice'), entry(3, 'Bob')],
      characterId: 7,
    );
    expect(staging.workingEntriesByName(' ALICE ').map((e) => e.id), [1, 2]);
    expect(staging.workingEntriesByName('  '), isEmpty);
    expect(staging.baseEntryById(3)!.name, 'Bob');
  });

  test('text totals cover card fields and entry contents', () {
    final staging = CardStaging(baseCard: baseCard(), characterId: 7);
    staging.setFields({'description': '12345', 'tags': ['ab']});
    final cardLen = staging.cardTextLength;
    expect(cardLen, greaterThanOrEqualTo(5 + 2 + '旧名字'.length + '旧性格'.length + '旧深度'.length));

    staging.addEntry(WorldbookEntry(characterId: 7, name: 'X', content: '123'));
    expect(staging.worldbookTextLength, 3);
  });
}
