// 会话导入:v5 二进制全环往返、v4 图片资产化、旧版本兼容与变量权限。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_asset_store.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/import/session_importer.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/image_fixture.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'v5 export → importBytes restores original images and full session',
    () async {
      final dir = Directory.systemTemp.createTempSync('session_import_v5');
      final source = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: p.join(dir.path, 'source.db'),
        imageRootPath: p.join(dir.path, 'source-images'),
      );
      final target = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: p.join(dir.path, 'target.db'),
        imageRootPath: p.join(dir.path, 'target-images'),
      );
      addTearDown(() async {
        await source.db.close();
        await target.db.close();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final avatar = await putTestImage(source);
      final background = await putTestImage(source, alternate: true);
      final charId = await CharacterRepository(source).insert(
        CharacterCard(
          name: 'Alice',
          description: 'knight',
          avatarHash: avatar,
          backgroundHash: background,
        ),
      );
      await source.db.insert('worldbook_entries', {
        'character_id': charId,
        'kind': 'rule',
        'name': '王都',
        'key': '["王都","首都"]',
        'use_regex': 0,
        'constant': 1,
        'content': '王都的描述。',
        'position': 0,
        'enabled': 1,
        'extra': '{"probability":75}',
      });
      final sessionId = await SessionRepository(source).create(charId, '王都之旅');
      final messages = MessageRepository(source);
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: '<system-reminder>王都的描述。</system-reminder>',
        kind: MessageKind.attachment,
        refId: 'wb:1',
      );
      final user = await messages.append(
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
      await messages.markCompacted([user.id!], compactOf: summary);
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: avatar,
        imageUrl: 'https://x/y.png',
        imagePrompt: 'a cave, silver light',
      );
      await VariableRepository(
        source,
      ).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
      await VariableRepository(
        source,
      ).upsert(sessionId, 'constant', 'gold', access: VariableAccess.readonly);
      await MemoryRepository(source).set(sessionId, '用户喜欢简洁文风');
      final archive = await SessionExporter(
        source,
      ).export(sessionId: sessionId);

      final fillerChar = await CharacterRepository(
        target,
      ).insert(const CharacterCard(name: 'Filler'));
      final fillerSession = await SessionRepository(
        target,
      ).create(fillerChar, 'filler');
      await MessageRepository(
        target,
      ).append(sessionId: fillerSession, role: 'user', content: '占位');

      final result = await SessionImporter.importBytes(target, archive);

      expect(result.reusedCharacter, isFalse);
      expect(
        (await SessionRepository(target).get(result.sessionId))!.title,
        '王都之旅',
      );
      final restored = await MessageRepository(
        target,
      ).bySession(result.sessionId);
      expect(restored.map((m) => '${m.role}:${m.content}').toList(), [
        'user:<system-reminder>王都的描述。</system-reminder>',
        'user:hi',
        'assistant:hello',
        'system:summary',
        'assistant:',
      ]);
      expect(restored[0].kind, MessageKind.attachment);
      // 附件 refId 含源库自增 id,导入后丢弃;正文照常保留。
      expect(restored[0].refId, isNull);
      expect(restored[1].isCompacted, isTrue);
      expect(restored[1].compactOf, restored[3].id);
      expect(restored[3].id, isNot(3));
      expect(restored[4].imageHash, avatar);
      expect(restored[4].imageUrl, 'https://x/y.png');
      expect(restored[4].imagePrompt, 'a cave, silver light');
      expect(await target.images.fileFor(avatar).readAsBytes(), testPngBytes());

      final restoredCard = (await CharacterRepository(
        target,
      ).get(result.characterId))!;
      expect(restoredCard.avatarHash, avatar);
      expect(restoredCard.backgroundHash, background);
      expect(restoredCard.importedAvatarBase64, isNull);
      expect(
        await target.images.fileFor(background).readAsBytes(),
        testPngBytes(alternate: true),
      );
      expect(await imageRefCount(target, avatar), 2); // 角色头像 + 一条消息
      expect(await imageRefCount(target, background), 1);

      final restoredVars = await VariableRepository(
        target,
      ).snapshot(result.sessionId);
      expect(restoredVars.values, {'hp': '10', 'constant': 'gold'});
      expect(restoredVars.access, {
        'hp': VariableAccess.full,
        'constant': VariableAccess.readonly,
      });
      expect(
        (await MemoryRepository(
          target,
        ).bySession(result.sessionId)).single.content,
        '用户喜欢简洁文风',
      );
      expect(await target.db.query('skills'), isEmpty);
      final worldbook = await target.db.query(
        'worldbook_entries',
        where: 'character_id = ?',
        whereArgs: [result.characterId],
      );
      expect(worldbook.single['extra'], '{"probability":75}');
    },
  );

  test(
    'v4 imageBase64/avatar/background are assetized and deduplicated',
    () async {
      final db = await openTestDb();
      addTearDown(db.db.close);
      final archive = jsonEncode({
        'version': 4,
        'character': {
          'name': 'LegacyImages',
          'avatar': 'data:image/png;base64,$testPngBase64',
        },
        'characterBackgroundBase64': testPngBase64Alt,
        'messages': [
          {'role': 'assistant', 'content': 'one', 'imageBase64': testPngBase64},
          {'role': 'assistant', 'content': 'two', 'imageBase64': testPngBase64},
        ],
      });

      final result = await SessionImporter.importText(db, archive);
      final card = (await CharacterRepository(db).get(result.characterId))!;
      final messages = await MessageRepository(db).bySession(result.sessionId);
      expect(card.avatarHash, testPngHash());
      expect(card.backgroundHash, testPngHash(alternate: true));
      expect(card.importedAvatarBase64, isNull);
      expect(messages.map((m) => m.imageHash), [testPngHash(), testPngHash()]);
      expect(
        await db.images.fileFor(testPngHash()).readAsBytes(),
        testPngBytes(),
      );
      expect(await imageRefCount(db, testPngHash()), 3);
      expect(await imageRefCount(db, testPngHash(alternate: true)), 1);
      expect(await db.db.query('image_assets'), hasLength(2));
    },
  );

  test(
    'v4 text-only import drops empty image messages and remaps compact links',
    () async {
      final db = await openTestDb();
      addTearDown(db.db.close);
      final archive = jsonEncode({
        'version': 4,
        'character': {'name': 'TextOnlyCompact'},
        'messages': [
          {
            'role': 'user',
            'content': 'first',
            'isCompacted': true,
            'compactOf': 3,
          },
          {
            'role': 'assistant',
            'content': '',
            'imageUrl': 'https://example.com/a.png',
            'imagePrompt': 'a prompt',
          },
          {
            'role': 'assistant',
            'content': 'reply',
            'isCompacted': true,
            'compactOf': 3,
          },
          {'role': 'system', 'content': 'summary'},
        ],
      });

      final result = await SessionImporter.importText(
        db,
        archive,
        includeImages: false,
      );

      // 空正文图片消息被略过后,compactOf 仍要指向摘要行(归档索引 3 →
      // 过滤后位置 2),不能因索引错位折叠到错误的消息。
      final rows = await MessageRepository(db).bySession(result.sessionId);
      expect(rows.map((message) => message.content), [
        'first',
        'reply',
        'summary',
      ]);
      expect(rows[0].isCompacted, isTrue);
      expect(rows[0].compactOf, rows[2].id);
      expect(rows[1].compactOf, rows[2].id);
      expect(rows.every((message) => message.imageUrl == null), isTrue);
      expect(rows.every((message) => message.imagePrompt == null), isTrue);
      expect(await db.db.query('image_assets'), isEmpty);
    },
  );

  test(
    'v4 bad and oversized images fail clearly before business writes',
    () async {
      final db = await openTestDb();
      addTearDown(db.db.close);
      Map<String, dynamic> archive(String image) => {
        'version': 4,
        'character': {'name': 'BadImage'},
        'messages': [
          {'role': 'assistant', 'imageBase64': image},
        ],
      };

      await expectLater(
        SessionImporter.importText(db, jsonEncode(archive('not-base64'))),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('imageBase64'),
          ),
        ),
      );
      final maxEncoded = 4 * ((ImageAssetStore.maxOriginalBytes + 2) ~/ 3);
      await expectLater(
        SessionImporter.importText(
          db,
          jsonEncode(archive('A' * (maxEncoded + 1))),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('16MiB'),
          ),
        ),
      );
      expect(await CharacterRepository(db).all(), isEmpty);
      expect(await db.db.query('sessions'), isEmpty);
      expect(await db.db.query('messages'), isEmpty);
    },
  );

  test(
    'variable access falls back to protected and ignores unknown/extra entries',
    () async {
      final target = await openTestDb();
      addTearDown(target.db.close);

      Map<String, dynamic> archive({Map<String, dynamic>? access}) => {
        'version': 4,
        'character': {'name': 'Vars'},
        'messages': <dynamic>[],
        'variables': {'hp': '10', 'meter': '5'},
        if (access != null) 'variableAccess': access,
      };

      Future<Map<String, VariableAccess>> importAccess(
        Map<String, dynamic> raw,
      ) async {
        final result = await SessionImporter.importText(
          target,
          jsonEncode(raw),
        );
        return (await VariableRepository(
          target,
        ).snapshot(result.sessionId)).access;
      }

      expect(await importAccess(archive()), {
        'hp': VariableAccess.protected,
        'meter': VariableAccess.protected,
      });
      expect(
        await importAccess(
          archive(access: {'hp': 'full', 'ghost': 'readonly'}),
        ),
        {'hp': VariableAccess.full, 'meter': VariableAccess.protected},
      );
      expect(await importAccess(archive(access: {'hp': 'bogus', 'meter': 7})), {
        'hp': VariableAccess.protected,
        'meter': VariableAccess.protected,
      });
    },
  );

  test(
    'v4 archive without background imports a character with no background',
    () async {
      final db = await openTestDb();
      addTearDown(db.db.close);
      final result = await SessionImporter.importText(
        db,
        jsonEncode({
          'version': 4,
          'character': {'name': 'NoBg'},
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      final row = await db.db.query(
        'characters',
        columns: ['background_hash'],
        where: 'id = ?',
        whereArgs: [result.characterId],
      );
      expect(row.single['background_hash'], isNull);
    },
  );

  test('v3 archive compactOf old row-id semantics is dropped', () async {
    final db = await openTestDb();
    addTearDown(db.db.close);
    final result = await SessionImporter.importText(
      db,
      jsonEncode({
        'version': 3,
        'session': {'title': '旧归档'},
        'character': {'name': 'Cara'},
        'messages': [
          {
            'role': 'user',
            'content': 'hi',
            'isCompacted': true,
            'compactOf': 99,
          },
          {'role': 'assistant', 'content': 'hey'},
        ],
      }),
    );
    final messages = await MessageRepository(db).bySession(result.sessionId);
    expect(messages.first.isCompacted, isTrue);
    expect(messages.first.compactOf, isNull);
  });

  test(
    'legacy v2 skills migrate into the global catalog disabled and deduped',
    () async {
      final db = await openTestDb();
      addTearDown(db.db.close);
      final result = await SessionImporter.importText(
        db,
        jsonEncode({
          'version': 2,
          'session': {'title': '旧归档'},
          'character': {'name': 'Alice'},
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
          'variables': <String, dynamic>{},
          'memory': null,
          'skills': [
            {
              'name': '烹饪',
              'description': '做饭',
              'content': '可以做菜',
              'active': true,
            },
            {'name': '战斗', 'description': '', 'content': '挥剑'},
          ],
        }),
      );

      final rows = await db.db.query('skills', orderBy: 'id');
      expect(rows.map((r) => r['name']), ['烹饪', '战斗']);
      expect(rows.every((r) => r['enabled'] == 0), isTrue);
      expect(rows.first['description'], '做饭');
      expect(result.sessionId, isNotNull);
    },
  );

  test('reuses an existing same-name character without touching it', () async {
    final db = await openTestDb();
    addTearDown(db.db.close);
    final charId = await CharacterRepository(
      db,
    ).insert(const CharacterCard(name: 'Alice', description: 'local version'));
    final result = await SessionImporter.importText(
      db,
      jsonEncode({
        'version': 2,
        'session': {'title': '远端会话'},
        'character': {'name': 'Alice', 'description': 'remote version'},
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
      }),
    );

    expect(result.reusedCharacter, isTrue);
    expect(result.characterId, charId);
    expect(
      (await CharacterRepository(db).get(charId))!.description,
      'local version',
    );
    expect(
      (await SessionRepository(db).get(result.sessionId))!.characterId,
      charId,
    );
  });

  test('importBytes decodes UTF-8 v4 archives without mojibake', () async {
    final db = await openTestDb();
    addTearDown(db.db.close);
    final archive = jsonEncode({
      'version': 2,
      'session': {'title': '王都之旅'},
      'character': {'name': '爱丽丝'},
      'messages': [
        {'role': 'user', 'content': '你好,王都的清晨。'},
      ],
    });
    final result = await SessionImporter.importBytes(db, utf8.encode(archive));
    expect((await SessionRepository(db).get(result.sessionId))!.title, '王都之旅');
    expect(
      (await MessageRepository(db).bySession(result.sessionId)).single.content,
      '你好,王都的清晨。',
    );
  });

  test('imports a legacy version 1 archive', () async {
    final db = await openTestDb();
    addTearDown(db.db.close);
    final result = await SessionImporter.importText(
      db,
      jsonEncode({
        'version': 1,
        'character': {'name': 'Bob'},
        'messages': [
          {'role': 'user', 'content': 'old', 'isCompacted': 1},
        ],
      }),
    );
    expect(result.reusedCharacter, isFalse);
    expect(
      (await SessionRepository(db).get(result.sessionId))!.title,
      'Bob · 导入',
    );
    final messages = await MessageRepository(db).bySession(result.sessionId);
    expect(messages.single.isCompacted, isTrue);
    expect(await VariableRepository(db).bySession(result.sessionId), isEmpty);
  });

  test('importText rejects unsupported versions, blank names and non-map cards', () async {
    final db = await openTestDb();
    addTearDown(db.db.close);
    for (final version in <Object?>[0, 5, '4', null]) {
      await expectLater(
        SessionImporter.importText(
          db,
          jsonEncode({
            'version': version,
            'character': {'name': 'A'},
            'messages': <Object>[],
          }),
        ),
        throwsFormatException,
      );
    }
    await expectLater(
      SessionImporter.importText(
        db,
        jsonEncode({
          'version': 4,
          'character': {'name': '   '},
          'messages': <Object>[],
        }),
      ),
      throwsFormatException,
    );
    await expectLater(
      SessionImporter.importText(
        db,
        jsonEncode({
          'version': 4,
          'character': ['not', 'a', 'map'],
          'messages': <Object>[],
        }),
      ),
      throwsFormatException,
    );
    expect(await CharacterRepository(db).all(), isEmpty);
  });

  test(
    'importText rolls back the new session and character on mid-write failure',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'session_import_rollback',
      );
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: p.join(dir.path, 'rollback.db'),
        imageRootPath: p.join(dir.path, 'images'),
      );
      addTearDown(() async {
        await db.db.close();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      await db.db.execute(
        'CREATE TRIGGER fail_skill_import BEFORE INSERT ON skills '
        "BEGIN SELECT RAISE(ABORT, 'skill import failed'); END;",
      );
      final archive = jsonEncode({
        'version': 4,
        'session': {'title': '回滚会话'},
        'character': {'name': 'Rollback'},
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'variables': {'hp': '10'},
        'memory': '会回滚的记忆',
        'skills': [
          {'name': 'rollback-skill', 'content': 'x'},
        ],
      });

      await expectLater(
        SessionImporter.importText(db, archive),
        throwsA(anything),
      );
      expect(await CharacterRepository(db).all(), isEmpty);
      for (final table in [
        'sessions',
        'messages',
        'variables',
        'memories',
        'skills',
      ]) {
        expect(await db.db.query(table), isEmpty, reason: '$table 应随回滚清空');
      }
    },
  );

  test('rejects files that are not session archives', () async {
    final db = await openTestDb();
    addTearDown(db.db.close);
    expect(
      () => SessionImporter.importText(db, 'not json'),
      throwsFormatException,
    );
    expect(
      () => SessionImporter.importText(
        db,
        jsonEncode({
          'character': {'name': 'A'},
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => SessionImporter.importText(
        db,
        jsonEncode({'messages': [], 'character': {}}),
      ),
      throwsFormatException,
    );
  });
}
