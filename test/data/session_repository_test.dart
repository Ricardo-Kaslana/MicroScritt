import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late SessionRepository sessions;
  late CharacterRepository characters;
  late MessageRepository messages;

  setUp(() async {
    db = await openTestDb();
    sessions = SessionRepository(db);
    characters = CharacterRepository(db);
    messages = MessageRepository(db);
  });

  test('create/get/byCharacter roundtrip exposes createdAt', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final id = await sessions.create(charId, 's1');

    final got = await sessions.get(id);
    expect(got, isNotNull);
    expect(got!.title, 's1');
    expect(got.characterId, charId);
    expect(got.createdAt.millisecondsSinceEpoch, greaterThan(0));

    final list = await sessions.byCharacter(charId);
    expect(list.single.id, id);
  });

  test('rename updates the title', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final id = await sessions.create(charId, 'before');
    await sessions.rename(id, 'after');
    expect((await sessions.get(id))!.title, 'after');
  });

  test(
    'deleteWithCascade removes session, its messages, variables and memories',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final keepId = await sessions.create(charId, 'keep');
      final dropId = await sessions.create(charId, 'drop');
      await messages.append(sessionId: dropId, role: 'user', content: 'hi');
      await messages.append(sessionId: keepId, role: 'user', content: 'stay');
      await VariableRepository(db).upsert(dropId, 'hp', '10');
      await VariableRepository(db).upsert(keepId, 'hp', '5');
      await MemoryRepository(db).set(dropId, 'drop memory');
      await MemoryRepository(db).set(keepId, 'keep memory');

      await sessions.deleteWithCascade(dropId);

      expect(await sessions.get(dropId), isNull);
      expect(await sessions.get(keepId), isNotNull);
      expect(await messages.bySession(dropId), isEmpty);
      expect(await messages.bySession(keepId), hasLength(1));
      expect(await VariableRepository(db).bySession(dropId), isEmpty);
      expect(await VariableRepository(db).bySession(keepId), {'hp': '5'});
      expect(await MemoryRepository(db).bySession(dropId), isEmpty);
      expect(
        (await MemoryRepository(db).bySession(keepId)).single.content,
        'keep memory',
      );
    },
  );

  test(
    'infosByCharacter reports message count and last message preview',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final s1 = await sessions.create(charId, 's1');
      final s2 = await sessions.create(charId, 's2');
      await messages.append(sessionId: s1, role: 'user', content: 'first');
      await messages.append(
        sessionId: s1,
        role: 'assistant',
        content: 'last reply',
      );

      final infos = await sessions.infosByCharacter(charId);
      expect(infos, hasLength(2));

      final i1 = infos.singleWhere((i) => i.id == s1);
      expect(i1.title, 's1');
      expect(i1.messageCount, 2);
      expect(i1.imageCount, 0); // 纯文本会话:带图数为 0,入口不展示文本/图片细分
      expect(i1.lastMessage, 'last reply');

      final i2 = infos.singleWhere((i) => i.id == s2);
      expect(i2.messageCount, 0);
      expect(i2.lastMessage, isNull);
    },
  );

  test('infosByCharacter sorts by latest visible message activity', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final old = await sessions.create(charId, 'old');
    final recent = await sessions.create(charId, 'recent');
    final empty = await sessions.create(charId, 'empty');
    await messages.append(sessionId: old, role: 'user', content: 'old message');
    await messages.append(
      sessionId: recent,
      role: 'user',
      content: 'recent message',
    );

    var infos = await sessions.infosByCharacter(charId);
    expect(infos.map((e) => e.id).toList(), [recent, old, empty]);

    await messages.append(
      sessionId: old,
      role: 'assistant',
      content: 'newer reply',
    );
    infos = await sessions.infosByCharacter(charId);
    expect(infos.map((e) => e.id).toList(), [old, recent, empty]);
  });

  test(
    'infosByCharacter previews "图片消息" when the latest message is an image',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final s1 = await sessions.create(charId, 's1');
      await messages.append(
        sessionId: s1,
        role: 'assistant',
        content: 'text reply',
      );
      // 生图落库形态:正文为空,图在 image 列;预览不得空白,显示「图片消息」。
      await messages.append(
        sessionId: s1,
        role: 'assistant',
        content: '',
        imageBase64: 'aGk=',
      );

      final i1 = (await sessions.infosByCharacter(charId)).single;
      expect(i1.messageCount, 2);
      expect(i1.imageCount, 1);
      expect(i1.lastMessage, '图片消息');
    },
  );

  test(
    'infosByCharacter splits message count into text vs image-bearing',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final s1 = await sessions.create(charId, 's1');
      await messages.append(sessionId: s1, role: 'user', content: '画一张');
      await messages.append(
        sessionId: s1,
        role: 'assistant',
        content: '',
        imageBase64: 'aGk=',
      );
      // 图文混排(正文与图同条):按「带图」计入图片侧,与总数构成干净划分。
      await messages.append(
        sessionId: s1,
        role: 'user',
        content: '看这张',
        imageBase64: 'aGk=',
      );
      await messages.append(sessionId: s1, role: 'assistant', content: '纯文本回复');
      // 空串 image_base64 不算带图,与气泡渲染的判空口径一致。
      await messages.append(
        sessionId: s1,
        role: 'assistant',
        content: '伪图消息',
        imageBase64: '',
      );
      // 附件行不参与任何计数。
      await messages.append(
        sessionId: s1,
        role: 'system',
        content: '<system-reminder>技能</system-reminder>',
        kind: MessageKind.attachment,
        refId: 'skill:1',
      );

      final info = (await sessions.infosByCharacter(charId)).single;
      expect(info.messageCount, 5);
      expect(info.imageCount, 2);
      expect(info.messageCount - info.imageCount, 3); // 文本侧
    },
  );

  test(
    'infosByCharacter excludes attachment and system rows from count and preview',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final s1 = await sessions.create(charId, 's1');
      await messages.append(sessionId: s1, role: 'user', content: '我拔剑了');
      // 附件旁路行(@技能/世界书注入)与压缩摘要(system)不进条数、不进预览。
      await messages.append(
        sessionId: s1,
        role: 'system',
        content: '<system-reminder>剑术</system-reminder>',
        kind: MessageKind.attachment,
        refId: 'skill:1',
      );
      await messages.append(
        sessionId: s1,
        role: 'assistant',
        content: 'last reply',
      );
      await messages.insertSystem(sessionId: s1, content: '压缩摘要');

      final info = (await sessions.infosByCharacter(charId)).single;
      expect(info.messageCount, 2);
      expect(info.lastMessage, 'last reply');
    },
  );
}
