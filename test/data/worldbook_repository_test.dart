import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late CharacterRepository characters;
  late WorldbookRepository worldbook;

  setUp(() async {
    db = await openTestDb();
    characters = CharacterRepository(db);
    worldbook = WorldbookRepository(db);
  });

  test('replaceForCharacter persists entries and byCharacter returns them ordered', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    await worldbook.replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, keys: ['sword'], content: 'The sword is cursed', position: 1),
      WorldbookEntry(characterId: 0, keys: ['king'], constant: true, content: 'The king is wise', position: 0),
    ]);
    final entries = await worldbook.byCharacter(charId);
    expect(entries.map((e) => e.content).toList(), ['The king is wise', 'The sword is cursed']);
    expect(entries[0].keys, ['king']);
  });

  test('replaceForCharacter clears previous entries for the same character', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    await worldbook.replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, keys: ['a'], content: 'one'),
    ]);
    await worldbook.replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, keys: ['b'], content: 'two'),
    ]);
    final entries = await worldbook.byCharacter(charId);
    expect(entries.map((e) => e.content).toList(), ['two']);
  });

  test('replaceForCharacter keeps entry ids stable across saves (refId ledger)', () async {
    // 回归(2026-09-28 批):保存世界书必须保持条目 id。附件去重账本以
    // `wb:<id>` 记账,id 一变旧附件行就再也匹配不上,条目会被当成"没注入过"
    // 重新注入 —— 而旧附件行仍在活跃窗口里,同一条目于是在上下文里并存多份,
    // 面板上的附件数远超条目数。旧实现是全删再全插,AUTOINCREMENT 让每次保存
    // (哪怕只切一个启用开关)都把 id 全部前移。
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    await worldbook.replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, keys: ['a'], content: 'one'),
      WorldbookEntry(characterId: 0, keys: ['b'], content: 'two'),
    ]);
    final before = await worldbook.byCharacter(charId);
    final idsBefore = before.map((e) => e.id).toList();
    expect(idsBefore, everyElement(isNotNull));

    // 只切一个启用开关(UI 的 _toggle 正是这条路径)。
    await worldbook.replaceForCharacter(
      charId,
      [before[0].copyWith(enabled: false), before[1]],
    );

    final after = await worldbook.byCharacter(charId);
    expect(after.map((e) => e.id).toList(), idsBefore, reason: '保存不得改变条目 id');
    expect(after[0].enabled, isFalse, reason: '字段改动照常落库');
    expect(after[1].enabled, isTrue);
  });

  test('replaceForCharacter updates, inserts and deletes by id', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    await worldbook.replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, keys: ['a'], content: 'one', position: 0),
      WorldbookEntry(characterId: 0, keys: ['b'], content: 'two', position: 1),
    ]);
    final before = await worldbook.byCharacter(charId);
    final keptId = before[0].id!;

    // 改第一条内容、删掉第二条、追加一条新的 —— 三种操作一次走完。
    await worldbook.replaceForCharacter(charId, [
      before[0].copyWith(content: 'one-edited'),
      const WorldbookEntry(characterId: 0, keys: ['c'], content: 'three', position: 1),
    ]);

    final after = await worldbook.byCharacter(charId);
    expect(after.map((e) => e.content).toList(), ['one-edited', 'three']);
    expect(after[0].id, keptId, reason: '更新走原地 UPDATE,id 保持');
    expect(after[1].id, isNot(keptId), reason: '新条目分配新 id');
  });

  test('replaceForCharacter does not adopt ids belonging to another character', () async {
    final charA = await characters.insert(const CharacterCard(name: 'A'));
    final charB = await characters.insert(const CharacterCard(name: 'B'));
    await worldbook.replaceForCharacter(charA, const [
      WorldbookEntry(characterId: 0, keys: ['a'], content: 'A-entry'),
    ]);
    final aEntries = await worldbook.byCharacter(charA);
    final aId = aEntries.single.id;

    // 把 A 的条目(带着 A 的 id)写进 B —— 绝不能改到 A 的行上。
    await worldbook.replaceForCharacter(charB, [aEntries.single]);

    expect((await worldbook.byCharacter(charA)).single.content, 'A-entry');
    final bEntries = await worldbook.byCharacter(charB);
    expect(bEntries.single.content, 'A-entry');
    expect(bEntries.single.id, isNot(aId), reason: '跨角色复制必须新插一行');
  });

  test('new matching-semantics columns round-trip via replaceForCharacter', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    await worldbook.replaceForCharacter(charId, const [
      WorldbookEntry(
        characterId: 0,
        name: '圣剑',
        keys: ['sword'],
        useRegex: true,
        caseSensitive: true,
        matchWholeWords: true,
        selective: true,
        secondaryKeys: ['cursed'],
        constant: true,
        content: 'The cursed sword glows',
      ),
    ]);
    final restored = (await worldbook.byCharacter(charId)).single;
    expect(restored.name, '圣剑');
    expect(restored.keys, ['sword']);
    expect(restored.secondaryKeys, ['cursed']);
    expect(restored.selective, isTrue);
    expect(restored.caseSensitive, isTrue);
    expect(restored.matchWholeWords, isTrue);
    expect(restored.useRegex, isTrue);
    expect(restored.constant, isTrue);
  });

  test('byCharacter chunks oversized content/extra (CursorWindow-safe)', () async {
    // 20MB 级卡可能把整本设定塞进单条:整列 SELECT 在 Android 上会抛
    // "Row too big",聊天组装、状态面板与导出会一起失效。分块读回后内容完整。
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final longContent = '设' * 300000;
    final longNote = '扩' * 300000;
    await worldbook.replaceForCharacter(charId, [
      WorldbookEntry(
        characterId: 0,
        keys: ['lore'],
        content: longContent,
        extra: {'note': longNote},
      ),
    ]);

    final restored = (await worldbook.byCharacter(charId)).single;
    expect(restored.content, longContent);
    expect(restored.extra['note'], longNote);
  });

  test('v1 database upgrades to v2 by creating worldbook_entries', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('microscritt_mig');
    final path = p.join(dir.path, 'test.db');
    // Historical v1 schema (only what the migration touches needs to exist).
    final v1 = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE characters (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, avatar_base64 TEXT, data_json TEXT NOT NULL)');
      },
    ));
    await v1.close();

    final upgraded = await AppDatabase.open(factory: databaseFactoryFfi, path: path);
    final repo = WorldbookRepository(upgraded);
    await repo.replaceForCharacter(1, const [
      WorldbookEntry(characterId: 0, keys: ['a'], content: 'x'),
    ]);
    expect((await repo.byCharacter(1)).length, 1);
    await upgraded.db.close();
    dir.deleteSync(recursive: true);
  });
}
