// 会话导出公开入口:v5 元数据、消息、世界书与头像协议边界。
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
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/import/zip_store_reader.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import '../support/image_fixture.dart';
import '../support/test_database.dart';

Future<Uint8List> _entry(ZipStoreReader reader, String name) async {
  final output = BytesBuilder(copy: false);
  final entry = reader.entries.singleWhere(
    (candidate) => candidate.name == name,
  );
  await for (final chunk in reader.openEntry(entry)) {
    output.add(chunk);
  }
  return output.takeBytes();
}

Future<Map<String, dynamic>> _meta(ZipStoreReader reader) async =>
    jsonDecode(utf8.decode(await _entry(reader, 'meta.json')))
        as Map<String, dynamic>;

Future<List<Map<String, dynamic>>> _messages(ZipStoreReader reader) async {
  final bytes = await _entry(reader, 'messages.ndjson');
  if (bytes.isEmpty) return const [];
  return [
    for (final line in const LineSplitter().convert(utf8.decode(bytes)))
      jsonDecode(line) as Map<String, dynamic>,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tmp;

  setUp(() async {
    db = await openTestDb();
    tmp = await Directory.systemTemp.createTemp('session_exporter');
  });

  tearDown(() async {
    await db.db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ZipStoreReader> exportReader(int sessionId) async {
    final file = File('${tmp.path}/$sessionId.msarc');
    await file.writeAsBytes(
      await SessionExporter(db).export(sessionId: sessionId),
    );
    return ZipStoreReader.open(file);
  }

  test(
    'exports session metadata, state and all messages including compacted',
    () async {
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      final sessionId = await SessionRepository(db).create(charId, '王都之旅');
      final messages = MessageRepository(db);
      final first = await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'hi',
      );
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: 'hello',
      );
      final summary = await messages.insertSystem(
        sessionId: sessionId,
        content: 'summary',
      );
      await messages.markCompacted([first.id!], compactOf: summary);
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: '<system-reminder>王都的描述。</system-reminder>',
        kind: MessageKind.attachment,
        refId: 'wb:7',
      );
      await VariableRepository(
        db,
      ).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
      await VariableRepository(
        db,
      ).upsert(sessionId, 'constant', 'gold', access: VariableAccess.readonly);
      await MemoryRepository(db).set(sessionId, '用户喜欢简洁文风');
      await SessionRepository(db).updateTokenUsage(
        sessionId: sessionId,
        inputTokens: 100,
        outputTokens: 50,
        cachedInputTokens: 0,
        backgroundInputTokens: 0,
        backgroundOutputTokens: 0,
        backgroundCachedInputTokens: 0,
      );

      final reader = await exportReader(sessionId);
      try {
        final meta = await _meta(reader);
        expect(meta['version'], 5);
        final session = meta['session'] as Map<String, dynamic>;
        expect(session['title'], '王都之旅');
        expect(session['characterId'], charId);
        expect((session['usage'] as Map)['inputTokens'], 100);
        expect((session['usage'] as Map)['outputTokens'], 50);
        expect((meta['character'] as Map)['name'], 'Alice');
        expect(meta['variables'], {'hp': '10', 'constant': 'gold'});
        expect(meta['variableAccess'], {'hp': 'full', 'constant': 'readonly'});
        expect(meta['memory'], '用户喜欢简洁文风');
        expect(meta.containsKey('skills'), isFalse);

        final rows = await _messages(reader);
        expect(rows, hasLength(4));
        expect(rows[0]['isCompacted'], isTrue);
        expect(rows[0]['compactOf'], 2);
        expect(rows[0].containsKey('kind'), isFalse);
        expect(rows[1]['content'], 'hello');
        expect(rows[2]['role'], 'system');
        expect(rows[3]['kind'], 'attachment');
        expect(rows[3]['refId'], 'wb:7');
      } finally {
        await reader.close();
      }
    },
  );

  test('character carries asset avatar and current worldbook', () async {
    final avatar = await putTestImage(db);
    final charId = await CharacterRepository(
      db,
    ).insert(CharacterCard(name: 'Alice', avatarHash: avatar));
    await WorldbookRepository(db).replaceForCharacter(charId, const [
      WorldbookEntry(
        characterId: 0,
        name: '王都',
        keys: ['王都'],
        constant: true,
        content: '王都的描述。',
      ),
    ]);
    final sessionId = await SessionRepository(db).create(charId, 's');
    await MessageRepository(
      db,
    ).append(sessionId: sessionId, role: 'user', content: 'hi');

    final reader = await exportReader(sessionId);
    try {
      final meta = await _meta(reader);
      final character = meta['character'] as Map<String, dynamic>;
      expect(character['avatar'], testPngBase64);
      expect(character['character_book'], isNotNull);
      expect(meta['characterAvatarHash'], avatar);
      expect(await _entry(reader, 'assets/$avatar'), testPngBytes());
    } finally {
      await reader.close();
    }
  });

  test(
    'messages contain imageHash and unknown sessions have no assets',
    () async {
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Bob'));
      final sessionId = await SessionRepository(db).create(charId, 's');
      final hash = await putTestImage(db);
      await MessageRepository(db).append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: hash,
        imagePrompt: 'a cave, silver light',
      );

      final reader = await exportReader(sessionId);
      try {
        final row = (await _messages(reader)).single;
        expect(row['imageHash'], hash);
        expect(row['imagePrompt'], 'a cave, silver light');
        expect(row.containsKey('imageBase64'), isFalse);
      } finally {
        await reader.close();
      }

      final unknown = await exportReader(999);
      try {
        final meta = await _meta(unknown);
        expect(meta['character'], isEmpty);
        expect(meta.containsKey('session'), isFalse);
        expect(meta['memory'], isNull);
        expect(await _messages(unknown), isEmpty);
        expect(unknown.entries, hasLength(2));
      } finally {
        await unknown.close();
      }
    },
  );
}
