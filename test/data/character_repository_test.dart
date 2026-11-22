// 角色卡仓储:hash 图片引用、CursorWindow 大卡读写、列表投影与级联删除。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/export/character_card_exporter.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() async {
    db = await openTestDb();
  });

  tearDown(() => db.db.close());

  test('roundtrips character card through JSON blob', () async {
    final repo = CharacterRepository(db);
    final id = await repo.insert(const CharacterCard(name: 'Alice', description: 'knight'));
    final loaded = await repo.get(id);
    expect(loaded?.name, 'Alice');
    expect(loaded?.description, 'knight');
    expect(loaded?.avatarHash, isNull);
    expect(loaded?.importedAvatarBase64, isNull);
    expect((await repo.all()).length, 1);
  });

  testWidgets('updateWithWorldbook keeps entry ids and swaps avatar references', (tester) async {
    await tester.runAsync(() async {
      final oldAvatar = await putTestImageHash(db, width: 8, height: 9);
      final newAvatar = await putTestImageHash(db, width: 9, height: 8);
      final repo = CharacterRepository(db);
      final worldbook = WorldbookRepository(db);
      final id = await repo.insertWithWorldbook(
        CharacterCard(name: 'Old', description: 'old', avatarHash: oldAvatar),
        const [
          WorldbookEntry(
            characterId: 0,
            name: 'Keep',
            keys: ['k'],
            content: 'old',
            position: 0,
            extra: {'probability': 100},
          ),
          WorldbookEntry(
            characterId: 0,
            name: 'Drop',
            keys: ['d'],
            content: 'gone',
            position: 1,
          ),
        ],
      );
      expect(await testImageRefCount(db, oldAvatar), 1);
      final before = await worldbook.byCharacter(id);
      final keep = before[0];
      final drop = before[1];

      await repo.updateWithWorldbook(
        id,
        CharacterCard(name: 'New', description: 'new', avatarHash: newAvatar),
        [
          keep.copyWith(content: 'updated'),
          WorldbookEntry(
            characterId: id,
            name: 'Added',
            keys: ['a'],
            content: 'new entry',
            position: 2,
          ),
        ],
      );

      final card = await repo.get(id);
      expect(card?.name, 'New');
      expect(card?.description, 'new');
      expect(card?.avatarHash, newAvatar);
      expect(await testImageRefCount(db, oldAvatar), 0);
      expect(await testImageRefCount(db, newAvatar), 1);

      // 同 hash 更新先 acquire 后 release,净计数不变。
      await repo.update(id, card!);
      expect(await testImageRefCount(db, newAvatar), 1);
      final after = await worldbook.byCharacter(id);
      expect(after.map((e) => e.name), ['Keep', 'Added']);
      expect(after.first.id, keep.id);
      expect(after.first.content, 'updated');
      expect(after.first.extra, {'probability': 100});
      expect(after.any((e) => e.id == drop.id), isFalse);
    });
  });

  testWidgets('background roundtrip uses hashes and releases replaced image', (tester) async {
    await tester.runAsync(() async {
      final first = await putTestImageHash(db, width: 10, height: 6);
      final second = await putTestImageHash(db, width: 11, height: 6);
      final repo = CharacterRepository(db);
      final id = await repo.insert(CharacterCard(name: 'Alice', backgroundHash: first));
      expect((await repo.get(id))?.backgroundHash, first);
      expect(await repo.backgroundHashFor(id), first);
      expect((await repo.all()).single.card.backgroundHash, first);

      await repo.update(id, CharacterCard(name: 'Alice', backgroundHash: second));
      expect((await repo.get(id))?.backgroundHash, second);
      expect(await testImageRefCount(db, first), 0);
      expect(await testImageRefCount(db, second), 1);
      final noBg = await repo.insert(const CharacterCard(name: 'Bob'));
      expect((await repo.get(noBg))?.backgroundHash, isNull);
    });
  });

  test('huge imported avatar is stripped from data_json and not hydrated', () async {
    final repo = CharacterRepository(db);
    final bigAvatar = 'A' * 2500000;
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {'name': 'Big', 'description': 'huge', 'avatar': bigAvatar},
    });
    final id = await repo.insert(card);

    final row = (await db.db.rawQuery(
      'SELECT length(data_json) AS l, avatar_hash FROM characters WHERE id = ?',
      [id],
    )).first;
    expect(row['l'] as int, lessThan(2000000));
    expect(row['avatar_hash'], isNull);
    final loaded = await repo.get(id);
    expect(loaded?.name, 'Big');
    expect(loaded?.description, 'huge');
    expect(loaded?.avatarHash, isNull);
    expect(loaded?.importedAvatarBase64, isNull);
    expect(jsonEncode(loaded?.raw), isNot(contains(bigAvatar)));

    final list = await repo.all();
    expect(list.single.card.name, 'Big');
    expect(list.single.hasAvatar, isFalse);
    await repo.update(id, card);
    final afterUpdate = (await db.db.rawQuery(
      'SELECT length(data_json) AS l FROM characters WHERE id = ?',
      [id],
    )).first;
    expect(afterUpdate['l'] as int, lessThan(2000000));
  });

  test('get chunks an oversized data_json instead of giving up', () async {
    final repo = CharacterRepository(db);
    final longDescription = '大' * 400000;
    final id = await repo.insert(
      CharacterCard(name: 'Monster', description: longDescription),
    );
    final loaded = await repo.get(id);
    expect(loaded, isNotNull);
    expect(loaded!.name, 'Monster');
    expect(loaded.description, longDescription);
  });

  testWidgets('avatar hash getters read only references, never image bytes', (tester) async {
    await tester.runAsync(() async {
      final avatar = await putTestImageHash(db);
      final background = await putTestImageHash(db, width: 12, height: 7);
      final repo = CharacterRepository(db);
      final id = await repo.insert(
        CharacterCard(name: 'Huge', avatarHash: avatar, backgroundHash: background),
      );
      expect(await repo.avatarHashFor(id), avatar);
      expect(await repo.backgroundHashFor(id), background);
      final loaded = await repo.get(id);
      expect(loaded?.avatarHash, avatar);
      expect(loaded?.backgroundHash, background);
      expect(loaded?.importedAvatarBase64, isNull);
    });
  });

  test('export path reads an oversized card + worldbook back in full', () async {
    final repo = CharacterRepository(db);
    final longDescription = '描' * 400000;
    final longLore = '设' * 300000;
    final id = await repo.insertWithWorldbook(
      CharacterCard(name: 'Big', description: longDescription),
      [WorldbookEntry(characterId: 0, keys: ['lore'], content: longLore)],
    );

    final card = await repo.get(id);
    final worldbook = await WorldbookRepository(db).byCharacter(id);
    expect(card, isNotNull);
    final exported = jsonDecode(
      CharacterCardExporter.export(card!, worldbook: worldbook),
    ) as Map<String, dynamic>;
    expect(exported['description'], longDescription);
    final book = exported['character_book'] as Map<String, dynamic>;
    final entries = book['entries'] as List<dynamic>;
    expect((entries.single as Map<String, dynamic>)['content'], longLore);
  });

  test('get returns null for an unparseable oversized data_json', () async {
    final id = await db.db.insert('characters', {
      'name': 'Monster',
      'data_json': 'X' * 2500000,
    });
    expect(await CharacterRepository(db).get(id), isNull);
  });

  test('all hydrates oversized rows so the list keeps the description', () async {
    final repo = CharacterRepository(db);
    final id = await repo.insert(
      CharacterCard(
        name: 'Gal',
        description: '可见描述',
        personality: 'p' * 1600000,
      ),
    );
    final size = (await db.db.rawQuery(
      'SELECT length(data_json) AS l FROM characters WHERE id = ?',
      [id],
    )).first['l'] as int;
    expect(size, greaterThan(1500000));

    final plain = (await repo.all()).single;
    expect(plain.card.name, 'Gal');
    expect(plain.card.description, isEmpty);
    final hydrated = (await repo.all(hydrateOversized: true)).single;
    expect(hydrated.card.name, 'Gal');
    expect(hydrated.card.description, '可见描述');
    expect(hydrated.card.personality.length, 1600000);
  });

  test('all judges oversized rows by UTF-8 bytes, not character count', () async {
    final repo = CharacterRepository(db);
    final longDescription = '大' * 400000;
    await repo.insert(CharacterCard(name: 'CJK', description: longDescription));

    final plain = (await repo.all()).single;
    expect(plain.card.name, 'CJK');
    expect(plain.card.description, isEmpty);
    final hydrated = (await repo.all(hydrateOversized: true)).single;
    expect(hydrated.card.description, longDescription);
  });

  test('all falls back to name-only when an oversized row is unparseable', () async {
    await db.db.insert('characters', {
      'name': 'Broken',
      'data_json': 'X' * 1600000,
    });
    final rec = (await CharacterRepository(db).all(hydrateOversized: true)).single;
    expect(rec.card.name, 'Broken');
    expect(rec.card.description, isEmpty);
  });

  test('insertWithWorldbook stores character and worldbook in one call', () async {
    final repo = CharacterRepository(db);
    final id = await repo.insertWithWorldbook(const CharacterCard(name: 'Alice'), const [
      WorldbookEntry(characterId: 0, keys: ['sword'], content: 'cursed'),
      WorldbookEntry(characterId: 0, keys: [], constant: true, content: 'fighting'),
    ]);
    final entries = await WorldbookRepository(db).byCharacter(id);
    expect(entries.length, 2);
    expect(entries.map((e) => e.content).toSet(), {'cursed', 'fighting'});
    expect(await repo.get(id), isNotNull);
  });

  test('update replaces the stored card', () async {
    final repo = CharacterRepository(db);
    final id = await repo.insert(const CharacterCard(name: 'Alice', description: 'knight'));
    await repo.update(id, const CharacterCard(name: 'Alicia', description: 'queen', firstMessage: 'hello'));
    final loaded = await repo.get(id);
    expect(loaded?.name, 'Alicia');
    expect(loaded?.description, 'queen');
    expect(loaded?.firstMessage, 'hello');
    expect((await repo.all()).single.id, id);
  });

  test('unknown new asset aborts update without changing card or old ref', () async {
    final repo = CharacterRepository(db);
    final id = await repo.insert(const CharacterCard(name: 'Alice'));
    final missing = 'f' * 64;
    await expectLater(
      repo.update(id, CharacterCard(name: 'Changed', avatarHash: missing)),
      throwsStateError,
    );
    expect((await repo.get(id))?.name, 'Alice');
    expect(
      await db.db.query('image_assets', where: 'hash = ?', whereArgs: [missing]),
      isEmpty,
    );
  });

  testWidgets('deleteWithCascade removes dependencies and releases every image reference', (tester) async {
    await tester.runAsync(() async {
      final avatar = await putTestImageHash(db, width: 8, height: 8);
      final background = await putTestImageHash(db, width: 9, height: 8);
      final messageImage = await putTestImageHash(db, width: 10, height: 8);
      final repo = CharacterRepository(db);
      final keepId = await repo.insert(const CharacterCard(name: 'Keep'));
      final dropId = await repo.insertWithWorldbook(
        CharacterCard(name: 'Drop', avatarHash: avatar, backgroundHash: background),
        const [WorldbookEntry(characterId: 0, keys: ['k'], content: 'lore')],
      );

      Future<int> addSession(int characterId) => db.db.insert('sessions', {
            'character_id': characterId,
            'title': 's',
            'created_at': 1,
          });
      final dropSession = await addSession(dropId);
      final keepSession = await addSession(keepId);
      await db.transaction((txn) => db.images.acquire(txn, messageImage));
      await db.db.insert('messages', {
        'session_id': dropSession,
        'role': 'assistant',
        'content': 'image',
        'seq': 1,
        'image_hash': messageImage,
      });
      await db.db.insert('messages', {
        'session_id': keepSession,
        'role': 'user',
        'content': 'stay',
        'seq': 1,
      });
      await VariableRepository(db).upsert(dropSession, 'hp', '10');
      await MemoryRepository(db).set(dropSession, 'remembered');
      await SkillRepository(db).insert(const Skill(name: 'combat', content: 'c'));

      await repo.deleteWithCascade(dropId);

      expect(await repo.get(dropId), isNull);
      expect(await repo.get(keepId), isNotNull);
      expect(await db.db.query('sessions', where: 'character_id = ?', whereArgs: [dropId]), isEmpty);
      expect(await db.db.query('messages', where: 'session_id = ?', whereArgs: [dropSession]), isEmpty);
      expect(await db.db.query('messages', where: 'session_id = ?', whereArgs: [keepSession]), hasLength(1));
      expect(await VariableRepository(db).bySession(dropSession), isEmpty);
      expect(await WorldbookRepository(db).byCharacter(dropId), isEmpty);
      expect(await MemoryRepository(db).bySession(dropSession), isEmpty);
      expect((await SkillRepository(db).all()).single.name, 'combat');
      for (final hash in [avatar, background, messageImage]) {
        expect(await testImageRefCount(db, hash), 0);
        expect(await db.images.exists(hash), isTrue, reason: '事务只释放,不物理删除');
      }
    });
  });
}
