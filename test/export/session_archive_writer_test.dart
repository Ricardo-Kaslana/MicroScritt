// v5 归档 writer:ZIP 字节一致、原图去重、NDJSON 引用与取消清理。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/export/session_archive_writer.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/import/zip_store_reader.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import '../support/image_fixture.dart';
import '../support/test_database.dart';

Future<Uint8List> _entryBytes(ZipStoreReader reader, String name) async {
  final entry = reader.entries.singleWhere(
    (candidate) => candidate.name == name,
  );
  final output = BytesBuilder(copy: false);
  await for (final chunk in reader.openEntry(entry)) {
    output.add(chunk);
  }
  return output.takeBytes();
}

Future<List<Map<String, dynamic>>> _messages(ZipStoreReader reader) async {
  final text = utf8.decode(await _entryBytes(reader, 'messages.ndjson'));
  if (text.isEmpty) return const [];
  return [
    for (final line in const LineSplitter().convert(text))
      jsonDecode(line) as Map<String, dynamic>,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late int sessionId;
  late Directory tmp;
  late String avatarHash;
  late String backgroundHash;

  setUp(() async {
    db = await openTestDb();
    tmp = await Directory.systemTemp.createTemp('archive_writer');
    avatarHash = await putTestImage(db);
    backgroundHash = await putTestImage(db, alternate: true);
    final charId = await CharacterRepository(db).insert(
      CharacterCard(
        name: 'Alice',
        avatarHash: avatarHash,
        backgroundHash: backgroundHash,
      ),
    );
    sessionId = await SessionRepository(db).create(charId, '王都之旅');
    final messages = MessageRepository(db);
    final first = await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: 'hi',
    );
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: avatarHash,
      imageUrl: 'https://example.com/a.png',
      imagePrompt: 'silver light',
    );
    final summary = await messages.insertSystem(
      sessionId: sessionId,
      content: 'summary',
    );
    await messages.markCompacted([first.id!], compactOf: summary);
    await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: '<system-reminder>王都。</system-reminder>',
      kind: MessageKind.attachment,
      refId: 'wb:1',
    );
    // 同一资产跨消息引用,归档仍只能出现一个 assets entry。
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: 'again',
      imageHash: avatarHash,
    );
    await VariableRepository(
      db,
    ).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
    await MemoryRepository(db).set(sessionId, '简洁文风');
  });

  tearDown(() async {
    await db.db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
    'exportToFile is byte-identical and stores each original once',
    () async {
      final expected = await SessionExporter(db).export(sessionId: sessionId);
      final file = File('${tmp.path}/archive.msarc');
      final progress = <(int, int)>[];
      await SessionExporter(db).exportToFile(
        sessionId: sessionId,
        file: file,
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(await file.readAsBytes(), expected);
      expect(progress.last, (5, 5));
      final reader = await ZipStoreReader.open(file);
      try {
        expect(reader.entries.map((entry) => entry.name), [
          'meta.json',
          'messages.ndjson',
          'assets/$avatarHash',
          'assets/$backgroundHash',
        ]);
        final meta =
            jsonDecode(utf8.decode(await _entryBytes(reader, 'meta.json')))
                as Map<String, dynamic>;
        expect(meta['version'], 5);
        expect(meta['variableAccess'], {'hp': 'full'});
        expect(meta['characterAvatarHash'], avatarHash);
        expect(meta['characterBackgroundHash'], backgroundHash);
        expect((meta['character'] as Map)['avatar'], testPngBase64);
        expect(meta.containsKey('characterBackgroundBase64'), isFalse);

        final messages = await _messages(reader);
        expect(messages, hasLength(5));
        expect(messages[0]['compactOf'], 2);
        expect(messages[1]['imageHash'], avatarHash);
        expect(messages[1]['imageUrl'], 'https://example.com/a.png');
        expect(messages[1]['imagePrompt'], 'silver light');
        expect(messages[1].containsKey('imageBase64'), isFalse);
        expect(messages[3]['kind'], 'attachment');
        expect(messages[4]['imageHash'], avatarHash);
        expect(await _entryBytes(reader, 'assets/$avatarHash'), testPngBytes());
        expect(
          await _entryBytes(reader, 'assets/$backgroundHash'),
          testPngBytes(alternate: true),
        );
      } finally {
        await reader.close();
      }
    },
  );

  test('cancel deletes the partial ZIP', () async {
    final file = File('${tmp.path}/cancelled.msarc');
    await expectLater(
      SessionExporter(
        db,
      ).exportToFile(sessionId: sessionId, file: file, isCancelled: () => true),
      throwsA(isA<SessionExportCancelled>()),
    );
    expect(file.existsSync(), isFalse);
  });

  test('partial export keeps only selected rows and drops compact links', () async {
    final rows = await MessageRepository(db).bySession(sessionId);
    final selected = {rows[0].id!, rows[1].id!, rows[4].id!};
    final file = File('${tmp.path}/partial.msarc');
    final progress = <(int, int)>[];
    await SessionExporter(db).exportToFile(
      sessionId: sessionId,
      file: file,
      messageIds: selected,
      onProgress: (done, total) => progress.add((done, total)),
    );

    expect(progress.last, (3, 3));
    final reader = await ZipStoreReader.open(file);
    try {
      final messages = await _messages(reader);
      expect(messages, hasLength(3));
      expect(messages.map((m) => m['content']).toList(), ['hi', '', 'again']);
      // 摘要行未选中:折叠标记清空,导入后消息不会被上下文组装跳过。
      expect(messages[0]['isCompacted'], isFalse);
      expect(messages[0].containsKey('compactOf'), isFalse);
      // 角色头像/背景仍随会话导出,消息图去重后只出现一次。
      expect(reader.entries.map((entry) => entry.name), [
        'meta.json',
        'messages.ndjson',
        'assets/$avatarHash',
        'assets/$backgroundHash',
      ]);
    } finally {
      await reader.close();
    }
  });

  test('partial export rejects an empty selection', () async {
    final file = File('${tmp.path}/empty-selection.msarc');
    await expectLater(
      SessionExporter(db).exportToFile(
        sessionId: sessionId,
        file: file,
        messageIds: {99999},
      ),
      throwsFormatException,
    );
    expect(file.existsSync(), isFalse);
  });

  test('export fails instead of writing a meta.json import would reject', () async {
    final file = File('${tmp.path}/meta-too-big.msarc');
    await expectLater(
      SessionArchiveWriter(db, maxMetaBytes: 64).exportToFile(
        sessionId: sessionId,
        file: file,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('导入端将拒绝'),
        ),
      ),
    );
    expect(file.existsSync(), isFalse);
  });

  test('unknown session keeps the empty v5 envelope on both paths', () async {
    final expected = await SessionExporter(db).export(sessionId: 99999);
    final file = File('${tmp.path}/empty.msarc');
    await SessionExporter(db).exportToFile(sessionId: 99999, file: file);
    expect(await file.readAsBytes(), expected);

    final reader = await ZipStoreReader.open(file);
    try {
      final meta =
          jsonDecode(utf8.decode(await _entryBytes(reader, 'meta.json')))
              as Map<String, dynamic>;
      expect(meta['version'], 5);
      expect(meta['character'], isEmpty);
      expect(meta.containsKey('session'), isFalse);
      expect(meta['variables'], isEmpty);
      expect(meta['variableAccess'], isEmpty);
      expect(await _messages(reader), isEmpty);
      expect(reader.entries, hasLength(2));
    } finally {
      await reader.close();
    }
  });
}
