// 图片资产按会话统计:同会话去重、跨会话重复计、排序与上限。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import '../support/image_fixture.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同一会话内的重复引用只计一次资产', () async {
    final db = await openTestDb();
    addTearDown(() => db.db.close());
    final charId = await CharacterRepository(
      db,
    ).insert(const CharacterCard(name: 'A'));
    final sessions = SessionRepository(db);
    final first = await sessions.create(charId, '甲');
    final second = await sessions.create(charId, '乙');
    final messages = MessageRepository(db);
    final hash = await putTestImage(db);

    await messages.append(
      sessionId: first,
      role: 'user',
      content: '',
      imageHash: hash,
    );
    await messages.append(
      sessionId: first,
      role: 'assistant',
      content: '',
      imageHash: hash,
    );
    await messages.append(
      sessionId: second,
      role: 'user',
      content: '',
      imageHash: hash,
    );

    final usage = await db.images.sessionImageUsage();
    expect(usage, hasLength(2));
    final firstUsage = usage.singleWhere((row) => row.sessionId == first);
    expect(firstUsage.title, '甲');
    expect(firstUsage.assetCount, 1);
    expect(firstUsage.messageCount, 2);
    expect(firstUsage.bytes, testPngBytes().length);
    final secondUsage = usage.singleWhere((row) => row.sessionId == second);
    expect(secondUsage.assetCount, 1);
    expect(secondUsage.messageCount, 1);
  });

  test('按占用字节排序并遵守 limit', () async {
    final db = await openTestDb();
    addTearDown(() => db.db.close());
    final charId = await CharacterRepository(
      db,
    ).insert(const CharacterCard(name: 'A'));
    final sessions = SessionRepository(db);
    final smallSession = await sessions.create(charId, '小图');
    final largeSession = await sessions.create(charId, '大图');
    final messages = MessageRepository(db);
    final smallHash = (await db.images.putBytes(
      await solidTestPng(8, 8),
    )).hash;
    final largeHash = (await db.images.putBytes(
      await solidTestPng(128, 128),
    )).hash;

    await messages.append(
      sessionId: smallSession,
      role: 'user',
      content: '',
      imageHash: smallHash,
    );
    await messages.append(
      sessionId: largeSession,
      role: 'user',
      content: '',
      imageHash: largeHash,
    );

    final top = await db.images.sessionImageUsage(limit: 1);
    expect(top, hasLength(1));
    expect(top.single.sessionId, largeSession);
    expect(top.single.bytes, greaterThan(smallHash.length));
  });

  test('limit 必须为正数', () async {
    final db = await openTestDb();
    addTearDown(() => db.db.close());
    expect(
      () => db.images.sessionImageUsage(limit: 0),
      throwsA(isA<ArgumentError>()),
    );
  });
}