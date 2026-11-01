import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import '../support/test_database.dart';

void main() {
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

  test('appends messages and returns them ordered by seq', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'first');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'second');

    final all = await messages.bySession(sessionId);
    expect(all.map((m) => m.content).toList(), ['first', 'second']);
    expect(all[0].seq, 0);
    expect(all[1].seq, 1);
  });

  test('appends and reads a message with image base64', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await db.db.insert('messages', {
      'session_id': sessionId,
      'role': 'assistant',
      'content': '',
      'seq': 0,
      'image_base64': 'aGVsbG8=',
    });
    final all = await messages.bySession(sessionId, includeImages: true);
    expect(all.single.imageBase64, 'aGVsbG8=');
  });

  test('imageBase64For reads oversized base64 in chunks (Android CursorWindow limit)', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    // 2MB+12345:超过 Android CursorWindow 单行 2MB 上限的量级,且跨过 1MB
    // 分块的多个边界。桌面 ffi 无此限制,这里验证分块拼接的完整性与边界。
    final big = 'A' * (2 * 1024 * 1024 + 12345);
    final id = await db.db.insert('messages', {
      'session_id': sessionId,
      'role': 'assistant',
      'content': '',
      'seq': 0,
      'image_base64': big,
    });

    expect(await messages.imageBase64For(id), big);

    // 流式导出用的分块流:拼接结果与整体读取一致,且每块不超过 1MB。
    final pieces = await messages.imageBase64Chunks(id).toList();
    expect(pieces.join(), big);
    expect(pieces.length, greaterThan(1));
    expect(pieces.every((piece) => piece.length <= 1024 * 1024), isTrue);

    // 导出路径(includeImages)同样经分块回填,不整列 bulk SELECT。
    final full = await messages.bySession(sessionId, includeImages: true);
    expect(full.single.imageBase64, big);
    // 轻量视图只带 has_image 标志。
    expect((await messages.bySession(sessionId)).single.hasImage, isTrue);
    expect((await messages.bySession(sessionId)).single.imageBase64, isNull);
  });

  test('insertMessageChunk keeps seq continuous and linkCompactOf maps indexes', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');

    final firstIds = await messages.insertMessageChunk(
      sessionId: sessionId,
      seqStart: 0,
      messages: [
        for (var i = 0; i < 3; i++)
          Message(sessionId: sessionId, role: 'user', content: 'a$i', seq: i, isCompacted: i < 2, compactOf: 3),
      ],
    );
    final secondIds = await messages.insertMessageChunk(
      sessionId: sessionId,
      seqStart: 3,
      messages: [
        Message(sessionId: sessionId, role: 'system', content: 'summary', seq: 3),
        Message(sessionId: sessionId, role: 'assistant', content: 'b', seq: 4),
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
  });

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
    expect(all.single.imageUrl, 'https://img.example.com/api/images/img_x/content');
  });

  test('append persists the original image prompt in light and full views', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final row = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'aGVsbG8=',
      imagePrompt: '1girl, silver hair',
    );

    expect((await messages.bySession(sessionId)).single.imagePrompt, '1girl, silver hair');
    expect((await messages.bySession(sessionId, includeImages: true)).single.imagePrompt, '1girl, silver hair');
    expect(await messages.imagePromptFor(row.id!), '1girl, silver hair');
    expect(await messages.imagePromptFor(999), isNull);
  });

  test('replaceImage swaps bytes under the expected prompt and invalidates caches', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final row = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageUrl: 'https://img.example/old.png',
      imagePrompt: 'a cave',
    );
    expect((await messages.bySession(sessionId)).single.imageUrl, 'https://img.example/old.png');

    expect(
      await messages.replaceImage(
        row.id!,
        imageBase64: 'bmV3',
        imageUrl: null,
        expectedPrompt: 'a cave',
      ),
      isTrue,
    );
    final light = (await messages.bySession(sessionId)).single;
    expect(light.imagePrompt, 'a cave');
    expect(light.imageUrl, isNull, reason: '新图没有 URL 时旧 URL 不得残留');
    expect(light.hasImage, isTrue);
    expect(await messages.imageBase64For(row.id!), 'bmV3');
    expect((await messages.bySession(sessionId, includeImages: true)).single.imageBase64, 'bmV3');
    // 条件不匹配(描述已变/消息不存在)时不写入。
    expect(
      await messages.replaceImage(row.id!, imageBase64: 'eA==', imageUrl: null, expectedPrompt: 'other'),
      isFalse,
    );
    expect(await messages.replaceImage(999, imageBase64: 'eA==', imageUrl: null, expectedPrompt: 'a cave'), isFalse);
  });

  test('replaceImage can rewrite the stored prompt in the same conditional update', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final row = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'b2xk',
      imagePrompt: 'a cave',
    );

    // 后台重跑:换了场景描述仍原地换图,描述一并更新 —— 否则该消息的
    // 「重新生成图片」会按旧描述重绘。
    expect(
      await messages.replaceImage(
        row.id!,
        imageBase64: 'bmV3',
        imageUrl: 'https://img.example/new.png',
        expectedPrompt: 'a cave',
        newImagePrompt: 'a torch-lit hall',
      ),
      isTrue,
    );
    final light = (await messages.bySession(sessionId)).single;
    expect(light.imagePrompt, 'a torch-lit hall');
    expect(light.imageUrl, 'https://img.example/new.png');
    expect(await messages.imageBase64For(row.id!), 'bmV3');

    // 条件用的是**替换前**的描述:旧描述已失效,同一目标再来一次不写入。
    expect(
      await messages.replaceImage(
        row.id!,
        imageBase64: 'eA==',
        imageUrl: null,
        expectedPrompt: 'a cave',
        newImagePrompt: 'x',
      ),
      isFalse,
    );
    expect(await messages.imageBase64For(row.id!), 'bmV3');
    expect((await messages.bySession(sessionId)).single.imagePrompt, 'a torch-lit hall');
  });

  test('clearImage also drops the prompt so a stale batch cannot resurrect the image', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    final row = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'aGVsbG8=',
      imagePrompt: 'a cave',
    );

    await messages.clearImage(row.id!);

    final light = (await messages.bySession(sessionId)).single;
    expect(light.hasImage, isFalse);
    expect(light.imagePrompt, isNull);
    expect(await messages.imageBase64For(row.id!), isNull);
    expect(
      await messages.replaceImage(row.id!, imageBase64: 'bmV3', imageUrl: null, expectedPrompt: 'a cave'),
      isFalse,
    );
  });

  test('insertSystemAndCompact atomically writes summary and marks originals', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    for (var i = 0; i < 3; i++) {
      await messages.append(sessionId: sessionId, role: 'user', content: 'm$i');
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
    expect(after.where((m) => m.isCompacted).every((m) => m.compactOf == summaryId), isTrue);
  });

  test('append and insertSystemAndCompact under explicit transactions keep unique seq', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    // Interleave patterned appends with a compacted summary to exercise the
    // seq computation inside both transactional paths.
    await messages.append(sessionId: sessionId, role: 'user', content: 'a');
    await messages.insertSystemAndCompact(sessionId: sessionId, content: 's', compactIds: const []);
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'b');

    final all = await messages.bySession(sessionId);
    expect(all.map((m) => m.seq).toList(), [0, 1, 2]);
    expect(all.map((m) => m.role).toList(), ['user', 'system', 'assistant']);
  });

  test('delete removes a single message row', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'keep');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'drop');

    final all = await messages.bySession(sessionId);
    final dropId = all.singleWhere((m) => m.content == 'drop').id!;
    await messages.delete(dropId);

    final after = await messages.bySession(sessionId);
    expect(after.single.content, 'keep');
  });

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
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'm$i');
    }

    final all = await messages.bySession(sessionId);
    final target = all.singleWhere((m) => m.content == 'm2');
    final removed = await messages.deleteFrom(target.id!);
    expect(removed, 2); // m2, m3

    final after = await messages.bySession(sessionId);
    expect(after.map((m) => m.content).toList(), ['m0', 'm1']);
  });

  test('clearSession removes every message of a session', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'a');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'b');
    await messages.insertSystem(sessionId: sessionId, content: 'summary');

    await messages.clearSession(sessionId);

    expect(await messages.bySession(sessionId), isEmpty);
  });

  test('repeated reads without writes hit the memory cache (same instance)', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'a');

    final first = await messages.bySession(sessionId);
    final second = await messages.bySession(sessionId);
    // 无写操作时,两次查询应命中同一缓存实例(等价不可变快照),不重复查库。
    expect(identical(first, second), isTrue);
    // includeImages 变体独立缓存,互不影响。
    final light = await messages.bySession(sessionId);
    final full = await messages.bySession(sessionId, includeImages: true);
    expect(identical(light, full), isFalse);
  });

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
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'tail');
    final tail = (await messages.bySession(sessionId)).singleWhere((m) => m.content == 'tail');
    await messages.deleteFrom(tail.id!);
    expect((await messages.bySession(sessionId)).single.content, 'b');

    // clearSession:失效后为空。
    await messages.clearSession(sessionId);
    expect(await messages.bySession(sessionId), isEmpty);
  });

  test('append returns the persisted row and extends the cached list without a re-read', () async {
    // DS 批:append 返回落库后的完整行(id/seq 已定),并把轻量缓存替换为
    // 追加后的新列表 —— 发送管线每轮「落库 → bySession」由整表重读变为缓存
    // 命中。旧列表实例保持冻结(持有旧快照的调用方不受影响);轻量口径剥掉
    // 图片字节只置标志;带图缓存条目失效,下次 includeImages 读库回填。
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    await messages.append(sessionId: sessionId, role: 'user', content: 'a');

    final before = await messages.bySession(sessionId);
    final appended = await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'b',
      imageBase64: 'aGVsbG8=',
      imageUrl: 'https://example.com/x.png',
    );
    expect(appended.id, isNotNull);
    expect(appended.seq, before.last.seq + 1);
    expect(appended.hasImage, isTrue, reason: 'append 的返回行是完整行口径');

    final after = await messages.bySession(sessionId);
    expect(after.length, before.length + 1);
    expect(after.last.id, appended.id);
    expect(identical(after, before), isFalse, reason: '缓存应替换为新列表实例');
    expect(before.length, 1, reason: '旧列表实例保持冻结,不被原地追加');
    expect(after.last.imageBase64, isNull, reason: '轻量口径不携带图片字节');
    expect(after.last.hasImage, isTrue);
    expect(after.last.imageUrl, 'https://example.com/x.png');

    final full = await messages.bySession(sessionId, includeImages: true);
    expect(full.last.imageBase64, 'aGVsbG8=', reason: '带图缓存条目应已失效并回填字节');

    // 缓存本就不在的会话(未被读过)append 后首次读,行为与旧行为一致。
    final sessionId2 = await sessions.create(charId, 's2');
    final appended2 = await messages.append(sessionId: sessionId2, role: 'user', content: 'x');
    expect((await messages.bySession(sessionId2)).single.id, appended2.id);
  });

  test('cache evicts the oldest entries beyond the cap and re-reads them on demand', () async {
    // DT 批:缓存容量从 64 收敛到 12 —— 缓存只服务"同轮交互的重复读",
    // 不必为重度多会话使用常驻几十份全量消息列表。容量是实现细节,这里用
    // 16 个会话(cap=12 时必然逐出最早的几个)验证 FIFO 逐出与按需重建。
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final ids = [for (var i = 0; i < 16; i++) await sessions.create(charId, 's$i')];
    await messages.append(sessionId: ids[0], role: 'user', content: 'm0');

    final s0first = await messages.bySession(ids[0]);
    for (final id in ids.skip(1)) {
      await messages.bySession(id);
    }

    // 最早的条目已被逐出:重读拿到新实例(回库),再次读命中缓存。
    final s0after = await messages.bySession(ids[0]);
    expect(identical(s0after, s0first), isFalse, reason: '超出容量的最早条目应被逐出重读');
    expect(identical(s0after, await messages.bySession(ids[0])), isTrue, reason: '重读后重新入缓存');
    expect(s0after.single.id, s0first.single.id);
  });

  test('sessionWindowFloor returns null when the display tail covers the session', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    for (var i = 0; i < 10; i++) {
      await messages.append(sessionId: sessionId, role: 'user', content: 'm$i');
    }
    expect(
      await messages.sessionWindowFloor(sessionId: sessionId, displayCount: 300),
      isNull,
      reason: '显示行不足 displayCount 时无需窗口化',
    );
  });

  test('sessionWindowFloor takes the display boundary only', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    // seq 0..29 共 30 条 chat 行,其中 seq 6..19 正文为空;seq 3 插一条
    // system 摘要行(显示口径排除,空正文行仍算显示行)。
    for (var i = 0; i < 30; i++) {
      if (i == 3) {
        await messages.append(sessionId: sessionId, role: 'system', content: '摘要');
        continue;
      }
      await messages.append(sessionId: sessionId, role: 'user', content: i >= 6 && i <= 19 ? '' : 'm$i');
    }
    // 显示行 seq = 0..2,4..29 共 29 条,第 10 倒数 = seq 20。
    // 组装口径已退役(组装窗口由 activeWindow 独立界定),floor 只看显示口径。
    final floor = await messages.sessionWindowFloor(sessionId: sessionId, displayCount: 10);
    expect(floor, 20);
  });

  test('activeWindow returns every system row plus all unfolded active rows', () async {
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
    expect(window.where((m) => m.role == 'system').map((m) => m.content), contains('摘要'));
    expect(window.firstWhere((m) => m.role != 'system').content, 'm30');
  });

  test('bySessionSince keeps every system row and trims strictly by seq', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    for (var i = 0; i < 40; i++) {
      if (i == 5 || i == 30) {
        await messages.append(sessionId: sessionId, role: 'system', content: '摘要$i');
        continue;
      }
      await messages.append(sessionId: sessionId, role: 'user', content: 'm$i');
    }
    final since25 = await messages.bySessionSince(sessionId, sinceSeq: 25);
    // system 行(含老摘要 seq 5)全部在窗;非 system 行只剩 seq >= 25。
    expect(since25.any((m) => m.role == 'system' && m.seq == 5), isTrue, reason: '老摘要行必须全部在窗');
    expect(since25.any((m) => m.role != 'system' && m.seq < 25), isFalse);
    // seq 30 是 system 行,只出现在 system 断言里(seq 25 是普通行)。
    expect(since25.where((m) => m.role != 'system').map((m) => m.seq).toList(),
        [for (var i = 25; i < 40; i++) if (i != 30) i]);
    // sinceSeq=null 走全量缓存路径。
    final full = await messages.bySessionSince(sessionId);
    expect(full.length, 40);
  });

  test('bySessionPageBefore pages display rows only, ascending, until exhausted', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    for (var i = 0; i < 60; i++) {
      if (i == 10) {
        await messages.append(sessionId: sessionId, role: 'system', content: '摘要');
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
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'm$i');
    }
    final page = await messages.bySessionPageBefore(sessionId, beforeSeq: 50, limit: 15);
    expect(page.length, 15);
    // 只含显示口径行(seq 10 的 system、seq 20 的附件不入页),升序。
    expect(page.every((m) => m.isChat && m.role != 'system'), isTrue);
    // seq < 50 的显示行为 0..9、11..19、21..49 共 48 条,最后一页取最高的
    // 15 条:seq 35..49。
    expect(page.map((m) => m.seq).toList(), [for (var i = 35; i < 50; i++) i]);
    // 边界行本身不入页(严格 seq < beforeSeq)。
    expect(page.any((m) => m.seq >= 50), isFalse);

    // 取尽:剩余不足一页时返回剩余全部(耗尽探测的依据)。
    // seq < 35 的显示行 = 0..34 共 35 个 seq 去掉 10(system)与 20(附件)= 33 条。
    final rest = await messages.bySessionPageBefore(sessionId, beforeSeq: 35, limit: 100);
    expect(rest.length, 33);
    expect(rest.first.seq, 0);
    expect(rest.last.seq, 34);
  });

  test('searchInSession matches visible chat rows only, newest first', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sid = await sessions.create(charId, 's1');
    final other = await sessions.create(charId, 's2');
    await messages.append(sessionId: sid, role: 'user', content: '第一条:魔法学院的清晨');
    await messages.append(sessionId: sid, role: 'assistant', content: '第二条:他学会了 Dragon 火焰');
    await messages.append(sessionId: sid, role: 'assistant', content: '第三条:魔法再次出现');
    await messages.append(sessionId: sid, role: 'system', content: '魔法摘要(不应命中)');
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
  });

  test('searchInSession treats LIKE wildcards as literals', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sid = await sessions.create(charId, 's1');
    await messages.append(sessionId: sid, role: 'user', content: '命中率 100% 的那一次');
    await messages.append(sessionId: sid, role: 'assistant', content: '编号 a_b 的记录');

    expect((await messages.searchInSession(sid, '100%')).single.seq, 0);
    expect(await messages.searchInSession(sid, '100_'), isEmpty);
    expect((await messages.searchInSession(sid, 'a_b')).single.seq, 1);
    expect(await messages.searchInSession(sid, 'a%b'), isEmpty);
  });

  test('locate returns minimal coordinates and visibility', () async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sid = await sessions.create(charId, 's1');
    final chat = await messages.append(sessionId: sid, role: 'user', content: 'chat');
    final system = await messages.append(sessionId: sid, role: 'system', content: 'summary');
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
}
