// 会话文件导入测试:两遍流式读取、图片跨缓冲还原、截断与取消都不留半截数据。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/import/json_stream_reader.dart';
import 'package:microscritt/import/session_importer.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/variable.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('session_file_import');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<AppDatabase> openDb(String name) => AppDatabase.open(
    factory: databaseFactoryFfi,
    path: p.join(tmp.path, '$name.db'),
  );

  Future<File> buildArchive(AppDatabase source) async {
    final charId = await CharacterRepository(source).insert(
      const CharacterCard(name: 'Alice', description: 'knight')
          .withAvatar('aGVsbG8=')
          .withBackground('YmFjaw=='),
    );
    final sessionId = await SessionRepository(source).create(charId, '王都之旅');
    final messages = MessageRepository(source);
    for (var i = 0; i < 12; i++) {
      await messages.append(sessionId: sessionId, role: 'user', content: 'm$i');
    }
    await messages.insertSystem(sessionId: sessionId, content: 'summary');
    final summary = (await messages.bySession(sessionId)).last;
    await messages.markCompacted([1, 2], compactOf: summary.id!);
    // 1.2MB 图片:base64 远超扫描器的 64KB 缓冲,覆盖跨缓冲拼回的图片还原。
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: base64Encode(List.filled(1200000, 9)),
    );
    await VariableRepository(source).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
    await MemoryRepository(source).set(sessionId, '简洁文风');
    await SessionRepository(source).updateTokenUsage(
      sessionId: sessionId,
      inputTokens: 100,
      outputTokens: 50,
      cachedInputTokens: 0,
      backgroundInputTokens: 0,
      backgroundOutputTokens: 0,
      backgroundCachedInputTokens: 0,
    );
    final file = File(p.join(tmp.path, 'archive.json'));
    await SessionExporter(source).exportToFile(sessionId: sessionId, file: file);
    return file;
  }

  test('importFile restores a full session across chunk boundaries', () async {
    final source = await openDb('source');
    final target = await openDb('target');
    addTearDown(() async {
      await source.db.close();
      await target.db.close();
    });
    final archive = await buildArchive(source);

    // 目标库先有无关数据,让新行 id / seq 与源库错开。
    final fillerChar = await CharacterRepository(target).insert(const CharacterCard(name: 'Filler'));
    final fillerSession = await SessionRepository(target).create(fillerChar, 'filler');
    await MessageRepository(target).append(sessionId: fillerSession, role: 'user', content: 'placeholder');

    final progress = <(int, int)>[];
    final result = await SessionImporter.importFile(
      target,
      archive,
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(result.reusedCharacter, isFalse);
    expect(progress.last, (14, 14));

    final session = (await SessionRepository(target).get(result.sessionId))!;
    expect(session.title, '王都之旅');
    expect((await CharacterRepository(target).get(result.characterId))!.name, 'Alice');

    final restored = await MessageRepository(target).bySession(result.sessionId, includeImages: true);
    expect(restored, hasLength(14));
    expect(restored.take(12).map((m) => m.content), [for (var i = 0; i < 12; i++) 'm$i']);
    expect(restored[0].isCompacted, isTrue);
    // compactOf 越过两个分块(前 12 条里有 8+4 两条 chunk),仍换算到摘要行新 id。
    expect(restored[0].compactOf, restored[12].id);
    expect(restored[1].compactOf, restored[12].id);
    expect(restored[13].imageBase64, base64Encode(List.filled(1200000, 9)));
    final restoredVars = await VariableRepository(target).snapshot(result.sessionId);
    expect(restoredVars.values, {'hp': '10'});
    expect(restoredVars.access, {'hp': VariableAccess.full});
    expect((await MemoryRepository(target).bySession(result.sessionId)).last.content, '简洁文风');
    final usage = (await SessionRepository(target).get(result.sessionId))!;
    expect(usage.inputTokens, 100);
    expect(usage.outputTokens, 50);
  });

  test('truncated archive fails before any write', () async {
    final source = await openDb('trunc_source');
    final target = await openDb('trunc_target');
    addTearDown(() async {
      await source.db.close();
      await target.db.close();
    });
    final archive = await buildArchive(source);
    final bytes = await archive.readAsBytes();
    final truncated = File(p.join(tmp.path, 'truncated.json'));
    await truncated.writeAsBytes(bytes.sublist(0, (bytes.length * 0.6).round()));

    await expectLater(
      SessionImporter.importFile(target, truncated),
      throwsA(isA<FormatException>()),
    );
    expect(await CharacterRepository(target).all(), isEmpty);
    expect(await target.db.query('sessions'), isEmpty);
    expect(await target.db.query('messages'), isEmpty);
  });

  test('cancel rolls back the new session and character', () async {
    final source = await openDb('cancel_source');
    final target = await openDb('cancel_target');
    addTearDown(() async {
      await source.db.close();
      await target.db.close();
    });
    final archive = await buildArchive(source);

    var checks = 0;
    await expectLater(
      SessionImporter.importFile(
        target,
        archive,
        isCancelled: () => ++checks > 1,
      ),
      throwsA(isA<ArchiveScanCancelled>()),
    );
    expect(await CharacterRepository(target).all(), isEmpty);
    expect(await target.db.query('sessions'), isEmpty);
    expect(await target.db.query('messages'), isEmpty);
  });

  test('reuses a same-name character and keeps its card untouched', () async {
    final source = await openDb('reuse_source');
    final target = await openDb('reuse_target');
    addTearDown(() async {
      await source.db.close();
      await target.db.close();
    });
    final archive = await buildArchive(source);
    final existingId = await CharacterRepository(target).insert(
      const CharacterCard(name: 'Alice', description: 'local edit'),
    );

    final result = await SessionImporter.importFile(target, archive);
    expect(result.reusedCharacter, isTrue);
    expect(result.characterId, existingId);
    expect((await CharacterRepository(target).get(existingId))!.description, 'local edit');
  });
}
