// 消息仓储:图片资产引用、压缩折叠、分页检索与进程内缓存。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import '../support/image_fixture.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MessageRepository messages;
  late SessionRepository sessions;
  late CharacterRepository characters;

  setUp(() async {
    db = await openTestDb();
    messages = MessageRepository(db);
    sessions = SessionRepository(db);
    characters = CharacterRepository(db);
  });

  tearDown(() => db.db.close());

  test('appends messages and returns them ordered by seq', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'first');
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'second',
    );

    final all = await messages.bySession(sessionId);
    expect(all.map((m) => m.content).toList(), ['first', 'second']);
    expect(all[0].seq, 0);
    expect(all[1].seq, 1);
  });

  test('searchInSession is literal, newest-first, and respects beforeSeq', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'the dragon wakes');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'The DRAGON sleeps');
    await messages.append(sessionId: sessionId, role: 'user', content: '100% sure');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'later dragon');

    final all = await messages.searchInSession(sessionId, 'dragon');
    expect(all.map((h) => h.seq).toList(), [3, 1, 0]);
    // seq < 3 只保留前两次命中
    final capped = await messages.searchInSession(sessionId, 'dragon', beforeSeq: 3);
    expect(capped.map((h) => h.seq).toList(), [1, 0]);
    // LIKE 通配符按字面量处理
    expect((await messages.searchInSession(sessionId, '%')).single.seq, 2);
  });

  test('bySessionPageAfter returns forward rows inside the optional bound', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'm0');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'm1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'm2');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'm3');

    final after = await messages.bySessionPageAfter(sessionId, afterSeq: 0, limit: 2);
    expect(after.map((m) => m.content).toList(), ['m1', 'm2']);
    final bounded = await messages.bySessionPageAfter(
      sessionId,
      afterSeq: 0,
      beforeSeq: 3,
      limit: 10,
    );
    expect(bounded.map((m) => m.content).toList(), ['m1', 'm2']);
  });

  test(
    'appends and reads an image hash while acquiring its asset reference',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final hash = await putTestImage(db);
      expect(await imageRefCount(db, hash), 0);

      final appended = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: hash,
      );

      final all = await messages.bySession(sessionId);
      expect(all.single.imageHash, hash);
      expect(all.single.hasImage, isTrue);
      expect(all.single.hasVisualImage, isTrue);
      expect(appended.imageHash, hash);
      expect(await imageRefCount(db, hash), 1);
      expect(await db.images.fileFor(hash).readAsBytes(), testPngBytes());
    },
  );

  test('repairImageAsset restores a missing file only on a hash match', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final hash = await putTestImage(db);
    final message = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: hash,
    );
    await db.images.fileFor(hash).delete();

    expect(await messages.repairImageAsset(message.id!, testPngBytes()), isTrue);
    expect(await db.images.fileFor(hash).readAsBytes(), testPngBytes());
    expect(await imageRefCount(db, hash), 1);
    expect((await messages.bySession(sessionId)).single.imageHash, hash);
  });

  test('repairImageAsset never swaps in a different remote image', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final hash = await putTestImage(db);
    final message = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: hash,
    );
    await db.images.fileFor(hash).delete();

    expect(
      await messages.repairImageAsset(
        message.id!,
        testPngBytes(alternate: true),
      ),
      isFalse,
    );
    expect(await db.images.fileFor(hash).exists(), isFalse);
    expect((await messages.bySession(sessionId)).single.imageHash, hash);
    expect(await imageRefCount(db, hash), 1);
    expect(
      await imageRefCount(db, testPngHash(alternate: true)),
      0,
    );
  });

  test('repairImageAsset restores a missing acquire when count is zero', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final hash = await putTestImage(db);
    final message = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: hash,
    );
    await db.images.fileFor(hash).delete();
    await db.db.update(
      'image_assets',
      {'ref_count': 0},
      where: 'hash = ?',
      whereArgs: [hash],
    );

    expect(await messages.repairImageAsset(message.id!, testPngBytes()), isTrue);
    expect(await imageRefCount(db, hash), 1);
  });

  test(
    'insertMessageChunk keeps seq continuous and linkCompactOf maps indexes',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');

      final firstIds = await messages.insertMessageChunk(
        sessionId: sessionId,
        seqStart: 0,
        messages: [
          for (var i = 0; i < 3; i++)
            Message(
              sessionId: sessionId,
              role: 'user',
              content: 'a$i',
              seq: i,
              isCompacted: i < 2,
              compactOf: 3,
            ),
        ],
      );
      final hash = await putTestImage(db);
      final secondIds = await messages.insertMessageChunk(
        sessionId: sessionId,
        seqStart: 3,
        messages: [
          Message(
            sessionId: sessionId,
            role: 'system',
            content: 'summary',
            seq: 3,
          ),
          Message(
            sessionId: sessionId,
            role: 'assistant',
            content: 'b',
            seq: 4,
            imageHash: hash,
          ),
        ],
      );
      final rowIds = [...firstIds, ...secondIds];
      expect(rowIds, hasLength(5));

      // 归档索引 3 是摘要行;越界索引(9)应被丢弃。
      await messages.linkCompactOf(
        sessionId: sessionId,
        rowIds: rowIds,
        links: const [(0, 3), (1, 3), (2, 9)],
      );

      final restored = await messages.bySession(sessionId);
      expect(restored.map((m) => m.seq), [0, 1, 2, 3, 4]);
      expect(restored[0].compactOf, rowIds[3]);
      expect(restored[1].compactOf, rowIds[3]);
      expect(restored[2].compactOf, isNull);
      expect(restored[4].imageHash, hash);
      expect(await imageRefCount(db, hash), 1);
    },
  );

  test(
    'append rejects an unknown asset hash without inserting the message',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final missing = '0' * 64;

      await expectLater(
        messages.append(
          sessionId: sessionId,
          role: 'assistant',
          content: '',
          imageHash: missing,
        ),
        throwsStateError,
      );
      expect(await messages.bySession(sessionId), isEmpty);
      expect(await db.db.query('image_assets'), isEmpty);
    },
  );

  test('appends and reads a message with image url', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageUrl: 'https://img.example.com/api/images/img_x/content',
    );
    final all = await messages.bySession(sessionId);
    expect(
      all.single.imageUrl,
      'https://img.example.com/api/images/img_x/content',
    );
  });

  test('append persists the original image prompt and hash', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final hash = await putTestImage(db);
    final row = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: hash,
      imagePrompt: '1girl, silver hair',
    );

    final stored = (await messages.bySession(sessionId)).single;
    expect(stored.imagePrompt, '1girl, silver hair');
    expect(stored.imageHash, hash);
    expect(await messages.imagePromptFor(row.id!), '1girl, silver hair');
    expect(await messages.imagePromptFor(999), isNull);
  });

  test(
    'replaceImage swaps hashes and never acquires on a condition miss',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final row = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageUrl: 'https://img.example/old.png',
        imagePrompt: 'a cave',
      );
      final hash = await putTestImage(db);
      final rejectedHash = await putTestImage(db, alternate: true);

      expect(
        await messages.replaceImage(
          row.id!,
          imageHash: hash,
          imageUrl: null,
          expectedPrompt: 'a cave',
        ),
        isTrue,
      );
      final stored = (await messages.bySession(sessionId)).single;
      expect(stored.imagePrompt, 'a cave');
      expect(stored.imageUrl, isNull, reason: '新图没有 URL 时旧 URL 不得残留');
      expect(stored.imageHash, hash);
      expect(await imageRefCount(db, hash), 1);

      expect(
        await messages.replaceImage(
          row.id!,
          imageHash: rejectedHash,
          imageUrl: null,
          expectedPrompt: 'other',
        ),
        isFalse,
      );
      expect(
        await messages.replaceImage(
          999,
          imageHash: rejectedHash,
          imageUrl: null,
          expectedPrompt: 'a cave',
        ),
        isFalse,
      );
      expect(await imageRefCount(db, rejectedHash), 0);
      expect(stored.imageHash, hash);
    },
  );

  test(
    'replaceImage rewrites the prompt and releases the old hash atomically',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final oldHash = await putTestImage(db, alternate: true);
      final newHash = await putTestImage(db);
      final row = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: oldHash,
        imagePrompt: 'a cave',
      );
      expect(await imageRefCount(db, oldHash), 1);

      expect(
        await messages.replaceImage(
          row.id!,
          imageHash: newHash,
          imageUrl: 'https://img.example/new.png',
          expectedPrompt: 'a cave',
          newImagePrompt: 'a torch-lit hall',
        ),
        isTrue,
      );
      final stored = (await messages.bySession(sessionId)).single;
      expect(stored.imagePrompt, 'a torch-lit hall');
      expect(stored.imageUrl, 'https://img.example/new.png');
      expect(stored.imageHash, newHash);
      expect(await imageRefCount(db, oldHash), 0);
      expect(await imageRefCount(db, newHash), 1);

      expect(
        await messages.replaceImage(
          row.id!,
          imageHash: newHash,
          imageUrl: null,
          expectedPrompt: 'a cave',
          newImagePrompt: 'x',
        ),
        isFalse,
      );
      expect((await messages.bySession(sessionId)).single.imageHash, newHash);
      expect(await imageRefCount(db, newHash), 1);
    },
  );

  test(
    'clearImage clears all image fields and releases the old reference',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final oldHash = await putTestImage(db, alternate: true);
      final newHash = await putTestImage(db);
      final row = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: oldHash,
        imageUrl: 'https://img.example/old.png',
        imagePrompt: 'a cave',
      );

      await messages.clearImage(row.id!);

      final stored = (await messages.bySession(sessionId)).single;
      expect(stored.hasImage, isFalse);
      expect(stored.imageHash, isNull);
      expect(stored.imageUrl, isNull);
      expect(stored.imagePrompt, isNull);
      expect(await imageRefCount(db, oldHash), 0);
      expect(
        await messages.replaceImage(
          row.id!,
          imageHash: newHash,
          imageUrl: null,
          expectedPrompt: 'a cave',
        ),
        isFalse,
      );
      expect(await imageRefCount(db, newHash), 0);
    },
  );

  test(
    'insertSystemAndCompact atomically writes summary and marks originals',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      for (var i = 0; i < 3; i++) {
        await messages.append(
          sessionId: sessionId,
          role: 'user',
          content: 'm$i',
        );
      }
      final all = await messages.bySession(sessionId);
      final summaryId = await messages.insertSystemAndCompact(
        sessionId: sessionId,
        content: 'SUMMARY',
        compactIds: all.map((m) => m.id!).toList(),
      );

      final after = await messages.bySession(sessionId);
      final summary = after.singleWhere((m) => m.role == 'system');
      expect(summary.id, summaryId);
      expect(summary.content, 'SUMMARY');
      expect(summary.seq, 3); // appended after the 3 live rows
      expect(after.where((m) => m.isCompacted).length, 3);
      expect(
        after
            .where((m) => m.isCompacted)
            .every((m) => m.compactOf == summaryId),
        isTrue,
      );
    },
  );

  test(
    'append and insertSystemAndCompact under explicit transactions keep unique seq',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      // 交替执行追加与压缩摘要,覆盖两条事务路径里的 seq 计算。
      await messages.append(sessionId: sessionId, role: 'user', content: 'a');
      await messages.insertSystemAndCompact(
        sessionId: sessionId,
        content: 's',
        compactIds: const [],
      );
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'b',
      );

      final all = await messages.bySession(sessionId);
      expect(all.map((m) => m.seq).toList(), [0, 1, 2]);
      expect(all.map((m) => m.role).toList(), ['user', 'system', 'assistant']);
    },
  );

  test('delete removes a single message row', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'keep');
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'drop',
    );

    final all = await messages.bySession(sessionId);
    final dropId = all.singleWhere((m) => m.content == 'drop').id!;
    await messages.delete(dropId);

    final after = await messages.bySession(sessionId);
    expect(after.single.content, 'keep');
  });

  test('delete releases one asset reference per removed message', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final hash = await putTestImage(db);
    final first = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'first',
      imageHash: hash,
    );
    final second = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'second',
      imageHash: hash,
    );
    expect(await imageRefCount(db, hash), 2);

    await messages.delete(first.id!);
    expect(await imageRefCount(db, hash), 1);
    await messages.delete(second.id!);
    expect(await imageRefCount(db, hash), 0);
    expect(await db.images.exists(hash), isTrue, reason: '释放引用不物理删除文件');
  });

  test(
    'deleteWithSnapshot restores a hash-only image snapshot in place',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final hash = await putTestImage(db);
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'keep',
      );
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'drop',
        imageHash: hash,
      );

      final all = await messages.bySession(sessionId);
      final row = all.singleWhere((m) => m.content == 'drop');
      final snapshot = await messages.deleteWithSnapshot(row.id!);
      expect(snapshot, isNotNull);
      expect(snapshot!.seq, row.seq);
      expect(snapshot.imageHash, hash);
      expect(await imageRefCount(db, hash), 0);

      expect((await messages.bySession(sessionId)).single.content, 'keep');
      await messages.restoreDeleted(snapshot);

      final after = await messages.bySession(sessionId);
      expect(after.map((m) => m.content).toList(), ['keep', 'drop']);
      expect(after.last.seq, row.seq);
      expect(after.last.role, 'assistant');
      expect(after.last.imageHash, hash);
      expect(await imageRefCount(db, hash), 1);
      expect(await db.images.fileFor(hash).readAsBytes(), testPngBytes());
    },
  );

  test(
    'restoreDeleted moves to the end when the original seq was reused',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      await messages.append(sessionId: sessionId, role: 'user', content: 'a');
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'b',
      );

      final row = (await messages.bySession(
        sessionId,
      )).singleWhere((m) => m.content == 'b');
      final snapshot = await messages.deleteWithSnapshot(row.id!);
      // 删除后新行复用空出的 seq:撤销恢复必须让位到末尾,不能留重复 seq。
      await messages.append(sessionId: sessionId, role: 'user', content: 'c');
      await messages.restoreDeleted(snapshot!);

      final after = await messages.bySession(sessionId);
      expect(after.map((m) => m.content).toList(), ['a', 'c', 'b']);
      expect(after.map((m) => m.seq).toSet(), hasLength(3));
    },
  );

  test('updateContent rewrites the text and keeps role/seq', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'old');

    final row = (await messages.bySession(sessionId)).single;
    await messages.updateContent(row.id!, 'new text');

    final after = (await messages.bySession(sessionId)).single;
    expect(after.content, 'new text');
    expect(after.role, 'user');
    expect(after.seq, row.seq);
  });

  test('deleteFrom removes the target and every later message', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    for (var i = 0; i < 4; i++) {
      await messages.append(
        sessionId: sessionId,
        role: i.isEven ? 'user' : 'assistant',
        content: 'm$i',
      );
    }

    final all = await messages.bySession(sessionId);
    final target = all.singleWhere((m) => m.content == 'm2');
    final removed = await messages.deleteFrom(target.id!);
    expect(removed, 2); // m2, m3

    final after = await messages.bySession(sessionId);
    expect(after.map((m) => m.content).toList(), ['m0', 'm1']);
  });

  test(
    'deleteFrom restores rows folded by a deleted summary',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final m0 = await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'm0',
      );
      final m1 = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'm1',
      );
      final target = await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'm2',
      );
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'm3',
      );
      // 软挡压缩在回复落库后追加摘要:摘要 seq 大于 target。
      await messages.insertSystemAndCompact(
        sessionId: sessionId,
        content: 'summary',
        compactIds: [m0.id!, m1.id!],
      );
      expect(
        (await messages.activeWindow(sessionId)).map((m) => m.content).toList(),
        ['m2', 'm3', 'summary'],
      );

      await messages.deleteFrom(target.id!);

      final remaining = await messages.bySession(sessionId);
      expect(remaining.map((m) => m.content).toList(), ['m0', 'm1']);
      expect(remaining.every((m) => !m.isCompacted), isTrue);
      expect(remaining.every((m) => m.compactOf == null), isTrue);
      // 恢复后的历史重新进入组装窗口,可被下一次压缩承接。
      expect(
        (await messages.activeWindow(sessionId)).map((m) => m.content).toList(),
        ['m0', 'm1'],
      );
    },
  );

  test(
    'deleteFrom releases references for the target and all later rows',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final hash = await putTestImage(db);
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'keep',
      );
      final target = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'target',
        imageHash: hash,
      );
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'tail',
        imageHash: hash,
      );
      expect(await imageRefCount(db, hash), 2);

      expect(await messages.deleteFrom(target.id!), 2);
      expect((await messages.bySession(sessionId)).single.content, 'keep');
      expect(await imageRefCount(db, hash), 0);
    },
  );

  test(
    'clearSession removes every message and releases every image reference',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final hash = await putTestImage(db);
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'a',
        imageHash: hash,
      );
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'b',
        imageHash: hash,
      );
      await messages.insertSystem(sessionId: sessionId, content: 'summary');
      expect(await imageRefCount(db, hash), 2);

      await messages.clearSession(sessionId);

      expect(await messages.bySession(sessionId), isEmpty);
      expect(await imageRefCount(db, hash), 0);
    },
  );

  test(
    'replaceImage rolls back the new acquire when the update fails',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      final oldHash = await putTestImage(db, alternate: true);
      final newHash = await putTestImage(db);
      final row = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: oldHash,
        imagePrompt: 'a cave',
      );
      await db.db.execute('''
      CREATE TEMP TRIGGER abort_image_replace
      BEFORE UPDATE ON messages
      WHEN OLD.id = ${row.id} AND NEW.image_hash = '$newHash'
      BEGIN
        SELECT RAISE(ABORT, 'forced image replace failure');
      END
    ''');

      await expectLater(
        messages.replaceImage(
          row.id!,
          imageHash: newHash,
          imageUrl: null,
          expectedPrompt: 'a cave',
        ),
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('forced image replace failure'),
          ),
        ),
      );
      expect((await messages.bySession(sessionId)).single.imageHash, oldHash);
      expect(await imageRefCount(db, oldHash), 1);
      expect(await imageRefCount(db, newHash), 0);
    },
  );

  test(
    'repeated reads without writes hit the memory cache (same instance)',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      await messages.append(sessionId: sessionId, role: 'user', content: 'a');

      final first = await messages.bySession(sessionId);
      final second = await messages.bySession(sessionId);
      // 无写操作时,两次查询应命中同一缓存实例(等价不可变快照),不重复查库。
      expect(identical(first, second), isTrue);
    },
  );

  test('writes invalidate the cache so the next read is fresh', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');

    // 预热缓存为空会话,再 append:失效后必须能看到新行。
    await messages.bySession(sessionId);
    await messages.append(sessionId: sessionId, role: 'user', content: 'a');
    expect((await messages.bySession(sessionId)).single.content, 'a');

    // updateContent:失效后内容更新可见。
    final row = (await messages.bySession(sessionId)).single;
    await messages.updateContent(row.id!, 'b');
    expect((await messages.bySession(sessionId)).single.content, 'b');

    // deleteFrom:失效后尾部删除可见。
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'tail',
    );
    final tail = (await messages.bySession(
      sessionId,
    )).singleWhere((m) => m.content == 'tail');
    await messages.deleteFrom(tail.id!);
    expect((await messages.bySession(sessionId)).single.content, 'b');

    // clearSession:失效后为空。
    await messages.clearSession(sessionId);
    expect(await messages.bySession(sessionId), isEmpty);
  });

  test(
    'append returns the persisted row and extends the cached list',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      await messages.append(sessionId: sessionId, role: 'user', content: 'a');

      final before = await messages.bySession(sessionId);
      final hash = await putTestImage(db);
      final appended = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'b',
        imageHash: hash,
        imageUrl: 'https://example.com/x.png',
      );
      expect(appended.id, isNotNull);
      expect(appended.seq, before.last.seq + 1);
      expect(appended.hasImage, isTrue);

      final after = await messages.bySession(sessionId);
      expect(after.length, before.length + 1);
      expect(after.last.id, appended.id);
      expect(identical(after, before), isFalse, reason: '缓存应替换为新列表实例');
      expect(before.length, 1, reason: '旧列表实例保持冻结,不被原地追加');
      expect(after.last.imageHash, hash);
      expect(after.last.hasImage, isTrue);
      expect(after.last.imageUrl, 'https://example.com/x.png');

      final sessionId2 = await sessions.create(charId, 's2');
      final appended2 = await messages.append(
        sessionId: sessionId2,
        role: 'user',
        content: 'x',
      );
      expect((await messages.bySession(sessionId2)).single.id, appended2.id);
    },
  );

  test(
    'cache evicts the oldest entries beyond the cap and re-reads them on demand',
    () async {
      // 缓存容量上限 12:缓存只服务"同轮交互的重复读",不必为重度多会话
      // 使用常驻几十份全量消息列表。容量是实现细节,这里用 16 个会话(cap=12
      // 时必然逐出最早的几个)验证 FIFO 逐出与按需重建。
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final ids = [
        for (var i = 0; i < 16; i++) await sessions.create(charId, 's$i'),
      ];
      await messages.append(sessionId: ids[0], role: 'user', content: 'm0');

      final s0first = await messages.bySession(ids[0]);
      for (final id in ids.skip(1)) {
        await messages.bySession(id);
      }

      // 最早的条目已被逐出:重读拿到新实例(回库),再次读命中缓存。
      final s0after = await messages.bySession(ids[0]);
      expect(identical(s0after, s0first), isFalse, reason: '超出容量的最早条目应被逐出重读');
      expect(
        identical(s0after, await messages.bySession(ids[0])),
        isTrue,
        reason: '重读后重新入缓存',
      );
      expect(s0after.single.id, s0first.single.id);
    },
  );

  test(
    'sessionWindowFloor returns null when the display tail covers the session',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      for (var i = 0; i < 10; i++) {
        await messages.append(
          sessionId: sessionId,
          role: 'user',
          content: 'm$i',
        );
      }
      expect(
        await messages.sessionWindowFloor(
          sessionId: sessionId,
          displayCount: 300,
        ),
        isNull,
        reason: '显示行不足 displayCount 时无需窗口化',
      );
    },
  );

  test('sessionWindowFloor takes the display boundary only', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    // seq 0..29 共 30 条 chat 行,其中 seq 6..19 正文为空;seq 3 插一条
    // system 摘要行(显示口径排除,空正文行仍算显示行)。
    for (var i = 0; i < 30; i++) {
      if (i == 3) {
        await messages.append(
          sessionId: sessionId,
          role: 'system',
          content: '摘要',
        );
        continue;
      }
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: i >= 6 && i <= 19 ? '' : 'm$i',
      );
    }
    // 显示行 seq = 0..2,4..29 共 29 条,第 10 倒数 = seq 20。
    // 组装口径已退役(组装窗口由 activeWindow 独立界定),floor 只看显示口径。
    final floor = await messages.sessionWindowFloor(
      sessionId: sessionId,
      displayCount: 10,
    );
    expect(floor, 20);
  });

  test(
    'activeWindow returns every system row plus all unfolded active rows',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final s2 = await sessions.create(charId, 's2');
      for (var i = 0; i < 40; i++) {
        final id = await db.db.insert('messages', {
          'session_id': s2,
          'role': 'user',
          'content': 'm$i',
          'seq': i,
          'is_compacted': i < 30 ? 1 : 0,
        });
        expect(id, isNotNull);
      }
      await messages.append(sessionId: s2, role: 'system', content: '摘要');
      final window = await messages.activeWindow(s2);
      // 组装窗口 = 全部 system 行 + 全部未折叠活跃行(seq 30..39),折叠行不进来。
      expect(window.where((m) => m.role != 'system').length, 10);
      expect(
        window.where((m) => m.role == 'system').map((m) => m.content),
        contains('摘要'),
      );
      expect(window.firstWhere((m) => m.role != 'system').content, 'm30');
    },
  );

  test(
    'bySessionSince keeps every system row and trims strictly by seq',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      for (var i = 0; i < 40; i++) {
        if (i == 5 || i == 30) {
          await messages.append(
            sessionId: sessionId,
            role: 'system',
            content: '摘要$i',
          );
          continue;
        }
        await messages.append(
          sessionId: sessionId,
          role: 'user',
          content: 'm$i',
        );
      }
      final since25 = await messages.bySessionSince(sessionId, sinceSeq: 25);
      // system 行(含老摘要 seq 5)全部在窗;非 system 行只剩 seq >= 25。
      expect(
        since25.any((m) => m.role == 'system' && m.seq == 5),
        isTrue,
        reason: '老摘要行必须全部在窗',
      );
      expect(since25.any((m) => m.role != 'system' && m.seq < 25), isFalse);
      // seq 30 是 system 行,只出现在 system 断言里(seq 25 是普通行)。
      expect(
        since25.where((m) => m.role != 'system').map((m) => m.seq).toList(),
        [
          for (var i = 25; i < 40; i++)
            if (i != 30) i,
        ],
      );
      // sinceSeq=null 走全量缓存路径。
      final full = await messages.bySessionSince(sessionId);
      expect(full.length, 40);
    },
  );

  test(
    'bySessionPageBefore pages display rows only, ascending, until exhausted',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sessionId = await sessions.create(charId, 's1');
      for (var i = 0; i < 60; i++) {
        if (i == 10) {
          await messages.append(
            sessionId: sessionId,
            role: 'system',
            content: '摘要',
          );
          continue;
        }
        if (i == 20) {
          await messages.append(
            sessionId: sessionId,
            role: 'user',
            content: '附件',
            kind: MessageKind.attachment,
            refId: 'wb:1',
          );
          continue;
        }
        await messages.append(
          sessionId: sessionId,
          role: i.isEven ? 'user' : 'assistant',
          content: 'm$i',
        );
      }
      final page = await messages.bySessionPageBefore(
        sessionId,
        beforeSeq: 50,
        limit: 15,
      );
      expect(page.length, 15);
      // 只含显示口径行(seq 10 的 system、seq 20 的附件不入页),升序。
      expect(page.every((m) => m.isChat && m.role != 'system'), isTrue);
      // seq < 50 的显示行为 0..9、11..19、21..49 共 48 条,最后一页取最高的
      // 15 条:seq 35..49。
      expect(page.map((m) => m.seq).toList(), [
        for (var i = 35; i < 50; i++) i,
      ]);
      // 边界行本身不入页(严格 seq < beforeSeq)。
      expect(page.any((m) => m.seq >= 50), isFalse);

      // 取尽:剩余不足一页时返回剩余全部(耗尽探测的依据)。
      // seq < 35 的显示行 = 0..34 共 35 个 seq 去掉 10(system)与 20(附件)= 33 条。
      final rest = await messages.bySessionPageBefore(
        sessionId,
        beforeSeq: 35,
        limit: 100,
      );
      expect(rest.length, 33);
      expect(rest.first.seq, 0);
      expect(rest.last.seq, 34);
    },
  );

  test(
    'searchInSession matches visible chat rows only, newest first',
    () async {
      final charId = await characters.insert(const CharacterCard(name: 'A'));
      final sid = await sessions.create(charId, 's1');
      final other = await sessions.create(charId, 's2');
      await messages.append(
        sessionId: sid,
        role: 'user',
        content: '第一条:魔法学院的清晨',
      );
      await messages.append(
        sessionId: sid,
        role: 'assistant',
        content: '第二条:他学会了 Dragon 火焰',
      );
      await messages.append(
        sessionId: sid,
        role: 'assistant',
        content: '第三条:魔法再次出现',
      );
      await messages.append(
        sessionId: sid,
        role: 'system',
        content: '魔法摘要(不应命中)',
      );
      await messages.append(
        sessionId: sid,
        role: 'user',
        content: '魔法附件(不应命中)',
        kind: MessageKind.attachment,
        refId: 'wb:1',
      );
      await messages.append(sessionId: other, role: 'user', content: '魔法其他会话');

      final magic = await messages.searchInSession(sid, '魔法');
      expect(magic.map((h) => h.seq).toList(), [2, 0]);
      expect(magic.first.content, '第三条:魔法再次出现');
      expect(magic.every((h) => h.role != 'system'), isTrue);

      // SQLite LIKE 对 ASCII 大小写不敏感;跨会话不串味。
      final dragon = await messages.searchInSession(sid, 'DRAGON');
      expect(dragon.single.seq, 1);
      expect(magic.any((h) => h.content.contains('其他会话')), isFalse);

      // limit 按最新优先截断。
      final limited = await messages.searchInSession(sid, '魔法', limit: 1);
      expect(limited.single.seq, 2);
      expect(await messages.searchInSession(sid, '   '), isEmpty);
    },
  );

  test('searchInSession treats LIKE wildcards as literals', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sid = await sessions.create(charId, 's1');
    await messages.append(
      sessionId: sid,
      role: 'user',
      content: '命中率 100% 的那一次',
    );
    await messages.append(
      sessionId: sid,
      role: 'assistant',
      content: '编号 a_b 的记录',
    );

    expect((await messages.searchInSession(sid, '100%')).single.seq, 0);
    expect(await messages.searchInSession(sid, '100_'), isEmpty);
    expect((await messages.searchInSession(sid, 'a_b')).single.seq, 1);
    expect(await messages.searchInSession(sid, 'a%b'), isEmpty);
  });

  test('locate returns minimal coordinates and visibility', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sid = await sessions.create(charId, 's1');
    final chat = await messages.append(
      sessionId: sid,
      role: 'user',
      content: 'chat',
    );
    final system = await messages.append(
      sessionId: sid,
      role: 'system',
      content: 'summary',
    );
    final attachment = await messages.append(
      sessionId: sid,
      role: 'user',
      content: 'attach',
      kind: MessageKind.attachment,
      refId: 'wb:1',
    );

    final located = (await messages.locate(chat.id!))!;
    expect(located.sessionId, sid);
    expect(located.seq, chat.seq);
    expect(located.visible, isTrue);
    expect((await messages.locate(system.id!))!.visible, isFalse);
    expect((await messages.locate(attachment.id!))!.visible, isFalse);
    expect(await messages.locate(999999), isNull);
  });

  test('adoptRemoteImage makes a URL-only message local', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final message = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageUrl: 'https://example.com/a.png',
    );
    expect(message.imageHash, isNull);

    expect(
      await messages.adoptRemoteImage(
        message.id!,
        'https://example.com/a.png',
        testPngBytes(),
      ),
      isTrue,
    );

    final stored = (await messages.bySession(sessionId)).single;
    expect(stored.imageHash, testPngHash());
    expect(stored.imageUrl, 'https://example.com/a.png');
    expect(stored.hasImage, isTrue);
    expect(await imageRefCount(db, testPngHash()), 1);
    expect(
      await db.images.fileFor(testPngHash()).readAsBytes(),
      testPngBytes(),
    );
  });

  test('adoptRemoteImage refuses a URL that changed while downloading', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final message = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageUrl: 'https://example.com/b.png',
    );

    expect(
      await messages.adoptRemoteImage(
        message.id!,
        'https://example.com/a.png',
        testPngBytes(),
      ),
      isFalse,
    );
    expect((await messages.bySession(sessionId)).single.imageHash, isNull);
    expect(await imageRefCount(db, testPngHash()), 0);
    expect(await db.images.fileFor(testPngHash()).exists(), isFalse);
  });

  test('adoptRemoteImage never overwrites an existing local image', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final hash = await putTestImage(db);
    final message = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: hash,
      imageUrl: 'https://example.com/a.png',
    );

    expect(
      await messages.adoptRemoteImage(
        message.id!,
        'https://example.com/a.png',
        testPngBytes(alternate: true),
      ),
      isFalse,
    );
    final stored = (await messages.bySession(sessionId)).single;
    expect(stored.imageHash, hash);
    expect(await imageRefCount(db, hash), 1);
    expect(await imageRefCount(db, testPngHash(alternate: true)), 0);
  });

  test('deleteManyWithSnapshots releases refs and restores in order', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final otherSession = await sessions.create(charId, 'other');
    final hash = await putTestImage(db);
    await messages.append(sessionId: sessionId, role: 'user', content: 'a');
    final second = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'b',
      imageHash: hash,
    );
    final third = await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: 'c',
      imageHash: hash,
    );
    final foreign = await messages.append(
      sessionId: otherSession,
      role: 'user',
      content: 'other',
    );

    final snapshots = await messages.deleteManyWithSnapshots(sessionId, {
      second.id!,
      third.id!,
      foreign.id!,
    });

    expect(snapshots.map((s) => s.content).toList(), ['b', 'c']);
    expect(
      (await messages.bySession(sessionId)).map((m) => m.content).toList(),
      ['a'],
    );
    expect(
      (await messages.bySession(otherSession)).single.content,
      'other',
    );
    expect(await imageRefCount(db, hash), 0);
    expect(
      await messages.deleteManyWithSnapshots(sessionId, {999999}),
      isEmpty,
    );

    await messages.restoreManyDeleted(snapshots);
    final restored = await messages.bySession(sessionId);
    expect(restored.map((m) => m.content).toList(), ['a', 'b', 'c']);
    expect(restored.map((m) => m.seq).toList(), [0, 1, 2]);
    expect(await imageRefCount(db, hash), 2);
  });

  test('batch restore appends rows whose seq was taken during undo', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'a');
    final second = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'b',
    );
    final third = await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: 'c',
    );
    final snapshots = await messages.deleteManyWithSnapshots(sessionId, {
      second.id!,
      third.id!,
    });
    // 撤销窗口内新消息占用 seq 1;恢复的两条都必须排到它后面。
    await messages.append(sessionId: sessionId, role: 'user', content: 'd');

    await messages.restoreManyDeleted(snapshots);
    final rows = await messages.bySession(sessionId);
    expect(rows.map((m) => m.content).toList(), ['a', 'd', 'b', 'c']);
    expect(rows.map((m) => m.seq).toList(), [0, 1, 2, 3]);
  });
}
