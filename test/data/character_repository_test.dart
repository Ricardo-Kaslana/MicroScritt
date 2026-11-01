import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/export/character_card_exporter.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await openTestDb();
  });

  // inMemoryDatabasePath 是共享缓存内存库:不关连接,行会跨测试泄漏。
  tearDown(() => db.db.close());

  test('roundtrips character card through JSON blob', () async {
    final repo = CharacterRepository(db);
    final id = await repo.insert(const CharacterCard(name: 'Alice', description: 'knight'));
    final loaded = await repo.get(id);
    expect(loaded?.name, 'Alice');
    expect(loaded?.description, 'knight');
    expect((await repo.all()).length, 1);
  });

  test('roundtrips character background through the column', () async {
    final repo = CharacterRepository(db);
    final id = await repo.insert(const CharacterCard(name: 'Alice', backgroundBase64: 'aGVsbG8=bg'));
    // 背景存在 data_json 之外的独立列,get 读回。
    expect((await repo.get(id))?.backgroundBase64, 'aGVsbG8=bg');
    // update 覆盖写背景。
    await repo.update(id, const CharacterCard(name: 'Alice', backgroundBase64: 'Ym9i'));
    expect((await repo.get(id))?.backgroundBase64, 'Ym9i');
    // 未设置背景时为 null。
    final noBg = await repo.insert(const CharacterCard(name: 'Bob'));
    expect((await repo.get(noBg))?.backgroundBase64, isNull);
  });

  test('huge embedded avatar is stripped from data_json at rest (CursorWindow)', () async {
    final repo = CharacterRepository(db);
    // 20MB 卡 ≈ 14MB 内嵌头像:远超 Android SQLite 2MB CursorWindow。data_json
    // 若整存这串 base64,任何投影它的查询都 "Row too big",列表永远转圈 ——
    // 这正是"小卡正常、大卡无法加载"的根因。头像必须只落列、不进 data_json。
    final bigAvatar = 'A' * 2500000; // ≈2.5MB 的 base64 串
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {'name': 'Big', 'description': 'huge', 'avatar': bigAvatar},
    });
    final id = await repo.insert(card);

    // data_json 整行必须保持小:迁移/列表/详情在任何平台上都读得动。
    final stored = (await db.db.rawQuery('SELECT length(data_json) AS l FROM characters WHERE id = ?', [id])).first;
    expect(stored['l'] as int, lessThan(2000000));

    // 头像从列读回,名字/描述不丢。
    final loaded = await repo.get(id);
    expect(loaded?.name, 'Big');
    expect(loaded?.description, 'huge');
    expect(loaded?.avatarBase64, bigAvatar);

    // 列表不崩(回归 all() 的 SQL 兜底路径)。
    final list = await repo.all();
    expect(list.single.card.name, 'Big');
    expect(list.single.hasAvatar, isTrue);

    // update 同样不把内嵌头像写回 data_json。
    await repo.update(id, card);
    final afterUpdate = (await db.db.rawQuery('SELECT length(data_json) AS l FROM characters WHERE id = ?', [id])).first;
    expect(afterUpdate['l'] as int, lessThan(2000000));
  });

  test('get chunks an oversized data_json instead of giving up', () async {
    // 20MB 级内容卡的 data_json 单行远超 Android CursorWindow(~2MB)。旧实现
    // 整列 SELECT 直接抛 Row too big → get 返回 null → 导出按钮点了没反应。
    // 现在先查长度再 substr 分块拼接,大卡也能完整读回(含 CJK 多字节内容)。
    final repo = CharacterRepository(db);
    final longDescription = '大' * 400000; // ≈1.2MB UTF-8,字符阈值之上
    final id = await repo.insert(
      CharacterCard(name: 'Monster', description: longDescription),
    );
    final loaded = await repo.get(id);
    expect(loaded, isNotNull);
    expect(loaded!.name, 'Monster');
    expect(loaded.description, longDescription);
  });

  test('get chunks oversized avatar/background columns', () async {
    final repo = CharacterRepository(db);
    final bigAvatar = 'A' * 1500000;
    final bigBackground = 'B' * 1200000;
    final id = await repo.insert(
      CharacterCard(
        name: 'Huge',
        avatarBase64: bigAvatar,
        backgroundBase64: bigBackground,
      ),
    );

    expect(await repo.avatarBase64For(id), bigAvatar);
    expect(await repo.backgroundBase64For(id), bigBackground);
    final loaded = await repo.get(id);
    expect(loaded?.avatarBase64, bigAvatar);
    expect(loaded?.backgroundBase64, bigBackground);
  });

  test('export path reads an oversized card + worldbook back in full', () async {
    // 移动端 20MB 卡的典型导出链路:get + byCharacter 都走分块读取,
    // 拼出的 JSON 必须保留完整描述与世界书内容(旧实现两步都会 Row too big)。
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
    final exported =
        jsonDecode(
              CharacterCardExporter.export(card!, worldbook: worldbook),
            )
            as Map<String, dynamic>;
    expect(exported['description'], longDescription);
    final book = exported['character_book'] as Map<String, dynamic>;
    final entries = book['entries'] as List<dynamic>;
    expect((entries.single as Map<String, dynamic>)['content'], longLore);
  });

  test('get returns null for an unparseable oversized data_json', () async {
    // 损坏内容不把格式化异常甩给 UI:分块读得回来,但 JSON 解析失败 → null。
    final id = await db.db.insert('characters', {
      'name': 'Monster',
      'data_json': 'X' * 2500000,
    });
    expect(await CharacterRepository(db).get(id), isNull);
  });

  test('all hydrates oversized rows so the list keeps the description', () async {
    final repo = CharacterRepository(db);
    // 巨型世界书/设定把 data_json 推过列表投影阈值(1MB 字节),但行本身
    // 可读 —— 列表应像编辑页一样拿到描述,而不是只剩名字。
    final id = await repo.insert(
      CharacterCard(
        name: 'Gal',
        description: '可见描述',
        personality: 'p' * 1600000,
      ),
    );
    final size =
        (await db.db.rawQuery(
                  'SELECT length(data_json) AS l FROM characters WHERE id = ?',
                  [id],
                )).first['l']
            as int;
    expect(size, greaterThan(1500000));

    // 默认(false):导入查重等只关心名字的调用方不为大卡白读整列。
    final plain = (await repo.all()).single;
    expect(plain.card.name, 'Gal');
    expect(plain.card.description, isEmpty);

    // 展示路径:补读整列,与编辑页读到的一致。
    final hydrated = (await repo.all(hydrateOversized: true)).single;
    expect(hydrated.card.name, 'Gal');
    expect(hydrated.card.description, '可见描述');
    expect(hydrated.card.personality.length, 1600000);
  });

  test('all judges oversized rows by UTF-8 bytes, not character count', () async {
    final repo = CharacterRepository(db);
    // 40 万汉字 ≈1.2MB 字节(超过 1MB 阈值),但字符数远小于旧阈值 150 万;
    // 按字符判断会把这一行整列塞进 CursorWindow —— 必须按字节判超。
    final longDescription = '大' * 400000;
    await repo.insert(
      CharacterCard(name: 'CJK', description: longDescription),
    );

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
    final rec = (await CharacterRepository(
      db,
    ).all(hydrateOversized: true)).single;
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

  test('deleteWithCascade removes character and all dependent rows', () async {
    final repo = CharacterRepository(db);
    final keepId = await repo.insert(const CharacterCard(name: 'Keep'));
    final dropId = await repo.insertWithWorldbook(const CharacterCard(name: 'Drop'), const [
      WorldbookEntry(characterId: 0, keys: ['k'], content: 'lore'),
    ]);

    final sessions = SessionRepository(db);
    final messages = MessageRepository(db);
    final dropSession = await sessions.create(dropId, 's');
    final keepSession = await sessions.create(keepId, 's');
    await messages.append(sessionId: dropSession, role: 'user', content: 'hi');
    await messages.append(sessionId: keepSession, role: 'user', content: 'stay');
    await VariableRepository(db).upsert(dropSession, 'hp', '10');
    await MemoryRepository(db).set(dropSession, 'remembered');
    // 技能自 v37 起是全局目录:角色/会话级联删除不再触碰技能表。
    await SkillRepository(db).insert(const Skill(name: 'combat', content: 'c'));

    await repo.deleteWithCascade(dropId);

    expect(await repo.get(dropId), isNull);
    expect(await repo.get(keepId), isNotNull);
    expect(await sessions.byCharacter(dropId), isEmpty);
    expect(await messages.bySession(dropSession), isEmpty);
    expect(await messages.bySession(keepSession), hasLength(1));
    expect(await VariableRepository(db).bySession(dropSession), isEmpty);
    expect(await WorldbookRepository(db).byCharacter(dropId), isEmpty);
    expect(await MemoryRepository(db).bySession(dropSession), isEmpty);
    // 全局技能在级联删除后仍然保留。
    expect((await SkillRepository(db).all()).single.name, 'combat');
  });
}
