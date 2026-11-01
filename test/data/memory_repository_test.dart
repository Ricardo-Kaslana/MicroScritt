import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import '../support/test_database.dart';

void main() {
  Future<int> newSession(AppDatabase db) async {
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    return SessionRepository(db).create(charId, 's');
  }

  test('set replaces the session memory and bySession returns it', () async {
    final db = await openTestDb();
    final sessionId = await newSession(db);
    final mem = MemoryRepository(db);

    await mem.set(sessionId, 'Met a dragon');
    await mem.set(sessionId, 'Met a dragon and a wizard');

    final all = await mem.bySession(sessionId);
    expect(all.length, 1);
    expect(all.single.content, 'Met a dragon and a wizard');
  });

  test('sessions keep independent memories', () async {
    final db = await openTestDb();
    final mem = MemoryRepository(db);
    final s1 = await newSession(db);
    final s2 = await newSession(db);

    await mem.set(s1, 'session1 记忆');
    await mem.set(s2, 'session2 记忆');

    expect((await mem.bySession(s1)).single.content, 'session1 记忆');
    expect((await mem.bySession(s2)).single.content, 'session2 记忆');
  });

  test('clear removes the session memory', () async {
    final db = await openTestDb();
    final sessionId = await newSession(db);
    final mem = MemoryRepository(db);

    await mem.set(sessionId, 'Met a dragon');
    await mem.clear(sessionId);

    expect(await mem.bySession(sessionId), isEmpty);
  });

  test('delete removes a single memory row by id', () async {
    final db = await openTestDb();
    final mem = MemoryRepository(db);
    final s1 = await newSession(db);
    final s2 = await newSession(db);

    // 每会话至多一条记忆(UNIQUE session_id);两个会话各一条。
    await mem.set(s1, 'first');
    await mem.set(s2, 'second');

    // 删除第一个会话的记忆行,只影响它、不影响第二个会话。
    final s1Row = (await mem.bySession(s1)).single;
    await mem.delete(s1Row.id!);

    expect(await mem.bySession(s1), isEmpty);
    expect((await mem.bySession(s2)).single.content, 'second');
    await db.db.close();
  });

  test('update rewrites a single memory row and refreshes updated_at', () async {
    final db = await openTestDb();
    final mem = MemoryRepository(db);
    final s1 = await newSession(db);
    final s2 = await newSession(db);

    await mem.set(s1, 'first');
    await mem.set(s2, 'second');
    // 拿到旧行,等一拍保证 updated_at 时间戳不同(毫秒精度)。
    final old = (await mem.bySession(s1)).single;
    await Future<void>.delayed(const Duration(milliseconds: 5));

    await mem.update(old.id!, 'first (edited)');

    final s1Row = (await mem.bySession(s1)).single;
    expect(s1Row.id, old.id); // 原地更新,不是删旧插新。
    expect(s1Row.content, 'first (edited)');
    expect(s1Row.updatedAt, greaterThan(old.updatedAt));
    // 另一会话不受影响。
    expect((await mem.bySession(s2)).single.content, 'second');
    await db.db.close();
  });
}
