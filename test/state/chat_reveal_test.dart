import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late int characterId;
  late int sessionId;
  late MessageRepository messages;

  setUp(() async {
    db = await openTestDb();
    messages = MessageRepository(db);
    final characters = CharacterRepository(db);
    final sessions = SessionRepository(db);
    characterId = await characters.insert(const CharacterCard(name: 'Alice'));
    sessionId = await sessions.create(characterId, 's1');
  });

  /// 直接批量种入对话行(seq 连续),避免 400 次 append 事务拖慢测试。
  Future<void> seedRows(int count) async {
    final batch = db.db.batch();
    for (var i = 0; i < count; i++) {
      batch.insert('messages', {
        'session_id': sessionId,
        'role': i.isEven ? 'user' : 'assistant',
        'content': i == 5 ? 'old target message' : 'm$i',
        'seq': i,
      });
    }
    await batch.commit(noResult: true);
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('revealMessage extends the display window back to an old row', () async {
    await seedRows(400);
    final container = makeContainer();
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    var state = container.read(chatControllerProvider);
    expect(state.messages.length, 300);
    expect(state.canLoadOlder, isTrue);
    expect(state.messages.any((m) => m.seq == 5), isFalse);

    final targetId = (await messages.searchInSession(
      sessionId,
      'old target',
    )).single.messageId;
    expect(await controller.revealMessage(targetId), isTrue);

    state = container.read(chatControllerProvider);
    expect(state.messages.any((m) => m.id == targetId), isTrue);
    expect(state.messages.first.seq, 5);
    expect(state.canLoadOlder, isTrue);

    // 窗口下界已跟着目标下移:继续向上补页只取目标之前的部分。
    await controller.loadOlder();
    state = container.read(chatControllerProvider);
    expect(state.messages.first.seq, 0);
    expect(state.canLoadOlder, isFalse);
  });

  test('revealMessage keeps an already loaded message untouched', () async {
    await seedRows(10);
    final container = makeContainer();
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    final before = container.read(chatControllerProvider).messages;
    final target = before.last;
    expect(await controller.revealMessage(target.id!), isTrue);
    final after = container.read(chatControllerProvider).messages;
    expect(after.length, before.length);
    expect(after.last.id, target.id);
  });

  test(
    'revealMessage rejects deleted, hidden, foreign or missing rows',
    () async {
      await seedRows(10);
      final system = await messages.append(
        sessionId: sessionId,
        role: 'system',
        content: 'summary',
      );
      final attachment = await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'attach',
        kind: MessageKind.attachment,
        refId: 'wb:1',
      );
      final otherSession = await SessionRepository(
        db,
      ).create(characterId, 'other');
      final foreign = await messages.append(
        sessionId: otherSession,
        role: 'user',
        content: 'foreign',
      );

      final container = makeContainer();
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      expect(await controller.revealMessage(system.id!), isFalse);
      expect(await controller.revealMessage(attachment.id!), isFalse);
      expect(await controller.revealMessage(foreign.id!), isFalse);
      expect(await controller.revealMessage(999999), isFalse);
    },
  );
}
