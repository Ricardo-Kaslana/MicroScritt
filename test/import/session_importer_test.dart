// 会话导入测试(整串入口):export → import 全环往返、旧版本归档兼容与
// 变量权限回落。
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
import 'package:microscritt/import/session_importer.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/test_database.dart';

void main() {
  test('export → import roundtrip restores a full session into a fresh database', () async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('session_import');
    // inMemoryDatabasePath 在 ffi 下多连接共享同一内存库,导出/导入两侧
    // 必须用独立文件库才能模拟"换设备"。
    final source = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'source.db'),
    );
    final charId = await CharacterRepository(source).insert(
      const CharacterCard(name: 'Alice', description: 'knight')
          .withAvatar('aGVsbG8=')
          // 背景图随档往返:卡 JSON 不携带背景,归档以独立顶层键携带。
          .withBackground('YmFjaw=='),
    );
    // 角色配两条世界书:验证随卡导出/导入还原(以本端当前条目为准)。
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
      // 未建模字段透传:随档导出/导入往返。
      'extra': '{"probability":75}',
    });
    final sessionId = await SessionRepository(source).create(charId, '王都之旅');
    final messages = MessageRepository(source);
    // 附件行(世界书触发注入形态):验证 v4 归档的 kind/refId 往返保真。
    await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: '<system-reminder>王都的描述。</system-reminder>',
      kind: MessageKind.attachment,
      refId: 'wb:1',
    );
    await messages.append(sessionId: sessionId, role: 'user', content: 'hi');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'hello');
    await messages.insertSystem(sessionId: sessionId, content: 'summary');
    await messages.markCompacted([2], compactOf: 4);
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'aGVsbG8=',
      imageUrl: 'https://x/y.png',
      imagePrompt: 'a cave, silver light',
    );
    await VariableRepository(source).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
    await VariableRepository(source).upsert(
      sessionId,
      'constant',
      'gold',
      access: VariableAccess.readonly,
    );
    await MemoryRepository(source).set(sessionId, '用户喜欢简洁文风');
    final archive = await SessionExporter(source).export(sessionId: sessionId);
    // 背景图随档:可选顶层键,旧档缺失即无背景。
    final sourceArchive = jsonDecode(archive) as Map<String, dynamic>;
    expect(sourceArchive['characterBackgroundBase64'], 'YmFjaw==');

    // 导入到目标库:预置一个无关角色+会话+消息,让新行 id 与 seq 错开 ——
    // compact_of 的换算必须按"新行 id"落,不能靠 id==seq 的巧合通过。
    final target = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'target.db'),
    );
    final fillerChar = await CharacterRepository(target).insert(const CharacterCard(name: 'Filler'));
    final fillerSession = await SessionRepository(target).create(fillerChar, 'filler');
    await MessageRepository(target).append(sessionId: fillerSession, role: 'user', content: '占位');

    final result = await SessionImporter.importText(target, archive);

    expect(result.reusedCharacter, isFalse);
    final session = (await SessionRepository(target).get(result.sessionId))!;
    expect(session.title, '王都之旅');
    expect(session.characterId, result.characterId);

    final restored = await MessageRepository(target).bySession(result.sessionId, includeImages: true);
    expect(restored.map((m) => '${m.role}:${m.content}').toList(), [
      'user:<system-reminder>王都的描述。</system-reminder>',
      'user:hi',
      'assistant:hello',
      'system:summary',
      'assistant:',
    ]);
    // 附件行 kind/refId 往返保真:不退化成普通 chat 行。
    expect(restored[0].kind, MessageKind.attachment);
    expect(restored[0].refId, 'wb:1');
    // 压缩指向按"目标库新行 id"换算(摘要行 = restored[3]),与 id==seq 无关。
    expect(restored[1].isCompacted, isTrue);
    expect(restored[1].compactOf, restored[3].id);
    expect(restored[3].id, isNot(3)); // 目标库预置行占走了小 id,排除巧合
    expect(restored[4].imageBase64, 'aGVsbG8=');
    expect(restored[4].imageUrl, 'https://x/y.png');
    expect(restored[4].imagePrompt, 'a cave, silver light');

    final restoredVars = await VariableRepository(target).snapshot(result.sessionId);
    expect(restoredVars.values, {'hp': '10', 'constant': 'gold'});
    expect(restoredVars.access, {
      'hp': VariableAccess.full,
      'constant': VariableAccess.readonly,
    });
    expect((await MemoryRepository(target).bySession(result.sessionId)).single.content, '用户喜欢简洁文风');
    // v3 归档不再携带 skills 节(全局技能不属于会话)。
    expect(await target.db.query('skills'), isEmpty);

    // 世界书随新角色还原。
    final worldbook = await target.db
        .query('worldbook_entries', where: 'character_id = ?', whereArgs: [result.characterId]);
    expect(worldbook, isNotEmpty);

    // 世界书透传字段往返:导出合并进 character_book、导入重新捕获落列。
    expect(worldbook.single['extra'], '{"probability":75}');

    // 背景图还原:无缩图器时原样落列。
    final restoredCharRow = await target.db
        .query('characters', columns: ['background_base64'], where: 'id = ?', whereArgs: [result.characterId]);
    expect(restoredCharRow.single['background_base64'], 'YmFjaw==');
  });

  test('variable access falls back to protected and ignores unknown/extra entries', () async {
    final target = await openTestDb();
    addTearDown(target.db.close);

    Map<String, dynamic> archive({Map<String, dynamic>? access}) => {
      'version': 4,
      'character': {'name': 'Vars'},
      'messages': <dynamic>[],
      'variables': {'hp': '10', 'meter': '5'},
      if (access != null) 'variableAccess': access,
    };

    Future<Map<String, VariableAccess>> importAccess(Map<String, dynamic> raw) async {
      final result = await SessionImporter.importText(target, jsonEncode(raw));
      return (await VariableRepository(target).snapshot(result.sessionId)).access;
    }

    // 旧档缺 variableAccess → 全部 protected。
    expect(await importAccess(archive()), {
      'hp': VariableAccess.protected,
      'meter': VariableAccess.protected,
    });

    // 合法权限保真;变量表里不存在的键忽略。
    expect(
      await importAccess(archive(access: {
        'hp': 'full',
        'ghost': 'readonly',
      })),
      {
        'hp': VariableAccess.full,
        'meter': VariableAccess.protected,
      },
    );

    // 未知字符串/非字符串值一律回落 protected。
    expect(
      await importAccess(archive(access: {'hp': 'bogus', 'meter': 7})),
      {
        'hp': VariableAccess.protected,
        'meter': VariableAccess.protected,
      },
    );
  });

  test('archive without characterBackgroundBase64 imports a character with no background (EF)', () async {
    // 旧归档(缺可选键)不误报背景。
    final db = await openTestDb();
    final archive = jsonEncode({
      'version': 4,
      'character': {'name': 'NoBg'},
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
    });
    final result = await SessionImporter.importText(db, archive);
    final row = await db.db
        .query('characters', columns: ['background_base64'], where: 'id = ?', whereArgs: [result.characterId]);
    expect(row.single['background_base64'], isNull);
  });

  test('v3 archive compactOf (old row-id semantics) is dropped, not mis-mapped', () async {
    // v1–v3 归档里的 compactOf 是**原库行 id**:换设备后无从对应,旧实现的
    // seq 偏移换算在 id≠seq 的库上会指向错误行 —— 宁可丢弃(引擎只读 isCompacted)。
    final db = await openTestDb();
    final archive = jsonEncode({
      'version': 3,
      'session': {'title': '旧归档'},
      'character': {'name': 'Cara'},
      'messages': [
        {'role': 'user', 'content': 'hi', 'isCompacted': true, 'compactOf': 99},
        {'role': 'assistant', 'content': 'hey'},
      ],
    });
    final result = await SessionImporter.importText(db, archive);
    final msgs = await MessageRepository(db).bySession(result.sessionId);
    expect(msgs.first.isCompacted, isTrue);
    expect(msgs.first.compactOf, isNull);
  });

  test('legacy v2 archive skills migrate into the global catalog (disabled, deduped)', () async {
    final db = await openTestDb();
    final archive = jsonEncode({
      'version': 2,
      'session': {'title': '旧归档'},
      'character': {'name': 'Alice'},
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
      'variables': <String, dynamic>{},
      'memory': null,
      'skills': [
        {'name': '烹饪', 'description': '做饭', 'content': '可以做菜', 'active': true},
        {'name': '战斗', 'description': '', 'content': '挥剑'},
      ],
    });

    final result = await SessionImporter.importText(db, archive);

    // v2 的会话级技能迁入全局技能目录:内容保留、一律停用。
    final rows = await db.db.query('skills', orderBy: 'id');
    expect(rows.map((r) => r['name']), ['烹饪', '战斗']);
    expect(rows.every((r) => r['enabled'] == 0), isTrue);
    expect((rows.first)['description'], '做饭');
    // 不属于导入的会话(全局目录无会话归属概念)。
    expect(result.sessionId, isNotNull);
    // 共享内存库:关连接,避免本测试的 Alice 行泄漏进后续按名复用断言。
    await db.db.close();
  });

  test('reuses an existing same-name character without touching it', () async {    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice', description: 'local version'));
    final archive = jsonEncode({
      'version': 2,
      'session': {'title': '远端会话'},
      'character': {'name': 'Alice', 'description': 'remote version'},
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
      'variables': <String, dynamic>{},
      'memory': null,
      'skills': <dynamic>[],
    });

    final result = await SessionImporter.importText(db, archive);
    expect(result.reusedCharacter, isTrue);
    expect(result.characterId, charId);
    // 本地角色卡不被归档里的版本覆盖。
    final local = await CharacterRepository(db).get(charId);
    expect(local!.description, 'local version');
    // 会话正常创建并归属该角色。
    expect((await SessionRepository(db).get(result.sessionId))!.characterId, charId);
  });

  test('importBytes decodes UTF-8 archives: Chinese content is not mojibake', () async {
    // 回归:UI 曾用 String.fromCharCodes 把 UTF-8 字节当码点,中文全乱码。
    final db = await openTestDb();
    final archive = jsonEncode({
      'version': 2,
      'session': {'title': '王都之旅'},
      'character': {'name': '爱丽丝'},
      'messages': [
        {'role': 'user', 'content': '你好,王都的清晨。'},
      ],
      'variables': <String, dynamic>{},
      'memory': null,
      'skills': <dynamic>[],
    });
    final result = await SessionImporter.importBytes(db, utf8.encode(archive));
    final session = (await SessionRepository(db).get(result.sessionId))!;
    expect(session.title, '王都之旅');
    final msgs = await MessageRepository(db).bySession(result.sessionId);
    expect(msgs.single.content, '你好,王都的清晨。');
  });

  test('imports a legacy version 1 archive (no session/state nodes)', () async {
    final db = await openTestDb();
    final archive = jsonEncode({
      'version': 1,
      'character': {'name': 'Bob'},
      'messages': [
        {'role': 'user', 'content': 'old', 'isCompacted': 1},
      ],
    });
    final result = await SessionImporter.importText(db, archive);
    expect(result.reusedCharacter, isFalse);
    final session = (await SessionRepository(db).get(result.sessionId))!;
    expect(session.title, 'Bob · 导入');
    final msgs = await MessageRepository(db).bySession(result.sessionId);
    expect(msgs.single.isCompacted, isTrue); // v1 的 int 1 兼容为 true
    expect(await VariableRepository(db).bySession(result.sessionId), isEmpty);
  });

  test('rejects files that are not session archives', () async {
    final db = await openTestDb();
    expect(() => SessionImporter.importText(db, 'not json'), throwsFormatException);
    expect(
      () => SessionImporter.importText(db, jsonEncode({'character': {'name': 'A'}})),
      throwsFormatException,
    );
    expect(
      () => SessionImporter.importText(db, jsonEncode({'messages': [], 'character': {}})),
      throwsFormatException, // 角色卡缺 name
    );
  });
}
