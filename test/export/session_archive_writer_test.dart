// 归档 writer 测试:流式写文件与整串导出逐字节一致,取消时不留半成品。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/export/session_archive_writer.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late int sessionId;
  late Directory tmp;

  setUp(() async {
    db = await openTestDb();
    tmp = await Directory.systemTemp.createTemp('archive_writer');
    final charId = await CharacterRepository(db).insert(
      const CharacterCard(name: 'Alice').withAvatar('aGVsbG8=').withBackground('YmFjaw=='),
    );
    sessionId = await SessionRepository(db).create(charId, '王都之旅');
    final messages = MessageRepository(db);
    await messages.append(sessionId: sessionId, role: 'user', content: 'hi');
    // 1.5MB 图片:base64 远超 1MB 分块,覆盖多块读写路径。
    final image = base64Encode(List.filled(1500000, 7));
    await messages.append(sessionId: sessionId, role: 'assistant', content: '', imageBase64: image);
    await messages.insertSystem(sessionId: sessionId, content: 'summary');
    await messages.markCompacted([1], compactOf: 3);
    await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: '<system-reminder>王都。</system-reminder>',
      kind: MessageKind.attachment,
      refId: 'wb:1',
    );
    await VariableRepository(db).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
    await MemoryRepository(db).set(sessionId, '简洁文风');
  });

  tearDown(() async {
    await db.db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('exportToFile is byte-identical to exportString', () async {
    final expected = await SessionExporter(db).export(sessionId: sessionId);
    final file = File('${tmp.path}/archive.json');
    final progress = <(int, int)>[];
    await SessionExporter(db).exportToFile(
      sessionId: sessionId,
      file: file,
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(await file.readAsString(), expected);
    expect(utf8.decode(await file.readAsBytes()), expected);
    expect(progress.last, (4, 4));
    // 结构与旧导出完全一致:可被整文件 jsonDecode。
    final decoded = jsonDecode(expected) as Map<String, dynamic>;
    expect(decoded['version'], 4);
    expect(decoded['variables'], {'hp': '10'});
    expect(decoded['variableAccess'], {'hp': 'full'});
    expect((decoded['messages'] as List)[1]['imageBase64'], isNotEmpty);
  });

  test('cancel deletes the partial file', () async {
    final file = File('${tmp.path}/cancelled.json');
    await expectLater(
      SessionExporter(db).exportToFile(
        sessionId: sessionId,
        file: file,
        isCancelled: () => true,
      ),
      throwsA(isA<SessionExportCancelled>()),
    );
    expect(file.existsSync(), isFalse);
  });

  test('unknown session exports the same empty envelope through both paths', () async {
    final expected = await SessionExporter(db).export(sessionId: 99999);
    final file = File('${tmp.path}/empty.json');
    await SessionExporter(db).exportToFile(sessionId: 99999, file: file);
    expect(await file.readAsString(), expected);
    final decoded = jsonDecode(expected) as Map<String, dynamic>;
    expect(decoded['messages'], isEmpty);
    expect(decoded['character'], isEmpty);
  });
}
