// 会话导出测试:归档 v4 字段(元数据/用量/消息/会话状态)与未知会话的空信封。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import '../support/test_database.dart';

void main() {
  test('exports session metadata, state and all messages including compacted', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    final sessionId = await SessionRepository(db).create(charId, '王都之旅');
    final messages = MessageRepository(db);
    await messages.append(sessionId: sessionId, role: 'user', content: 'hi');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'hello');
    await messages.insertSystem(sessionId: sessionId, content: 'summary');
    await messages.markCompacted([1], compactOf: 3);
    // 附件行(v4 起随档导出 kind/refId):世界书触发注入的形态。
    await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: '<system-reminder>王都的描述。</system-reminder>',
      kind: MessageKind.attachment,
      refId: 'wb:7',
    );
    await VariableRepository(db).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
    await VariableRepository(db).upsert(
      sessionId,
      'constant',
      'gold',
      access: VariableAccess.readonly,
    );
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

    final json = await SessionExporter(db).export(sessionId: sessionId);
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect(decoded['version'], 4);

    // 会话元数据 + token 用量。
    final session = decoded['session'] as Map<String, dynamic>;
    expect(session['title'], '王都之旅');
    expect(session['characterId'], charId);
    expect(session['createdAt'], isNotEmpty);
    final usage = session['usage'] as Map<String, dynamic>;
    expect(usage['inputTokens'], 100);
    expect(usage['outputTokens'], 50);

    expect((decoded['character'] as Map)['name'], 'Alice');
    final msgs = decoded['messages'] as List;
    expect(msgs.length, 4);

    expect(msgs[0]['role'], 'user');
    expect(msgs[0]['content'], 'hi');
    expect(msgs[0]['seq'], 0);
    expect(msgs[0]['isCompacted'], isTrue);
    // v4:compactOf 是摘要行的"消息数组内索引"(库里行 id=3 → 数组下标 2),
    // 不再透出与目标库无关的原库行 id。
    expect(msgs[0]['compactOf'], 2);
    expect(msgs[0]['kind'], isNull); // 普通行不带 kind 键

    expect(msgs[1]['role'], 'assistant');
    expect(msgs[1]['content'], 'hello');
    expect(msgs[1]['isCompacted'], isFalse);
    expect(msgs[1]['compactOf'], isNull);

    expect(msgs[2]['role'], 'system');
    expect(msgs[2]['content'], 'summary');

    // 附件行往返保真:kind 与来源标识都进档。
    expect(msgs[3]['kind'], 'attachment');
    expect(msgs[3]['refId'], 'wb:7');

    // 会话级状态:变量/权限/记忆;技能不再是会话状态。
    expect(decoded['variables'], {'hp': '10', 'constant': 'gold'});
    expect(decoded['variableAccess'], {'hp': 'full', 'constant': 'readonly'});
    expect(decoded['memory'], '用户喜欢简洁文风');
    // 全局技能(v37 起)不属于任何会话,归档不携带 skills 节。
    expect(decoded.containsKey('skills'), isFalse);
  });

  test('character part carries avatar and current worldbook (same as card export)', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(
      const CharacterCard(name: 'Alice').withAvatar('aGVsbG8='),
    );
    await WorldbookRepository(db).replaceForCharacter(
      charId,
      const [
        WorldbookEntry(
          characterId: 0,
          name: '王都',
          keys: ['王都'],
          constant: true,
          content: '王都的描述。',
        ),
      ],
    );
    final sessionId = await SessionRepository(db).create(charId, 's');
    await MessageRepository(db).append(sessionId: sessionId, role: 'user', content: 'hi');

    final decoded = jsonDecode(await SessionExporter(db).export(sessionId: sessionId)) as Map<String, dynamic>;
    final character = decoded['character'] as Map<String, dynamic>;
    // 头像补回(toStorageJson 剥掉,导出必须还原)。
    expect(character['avatar'], 'aGVsbG8=');
    // 世界书随会话导出(以本端当前条目为准)。
    final book = character['character_book'] as Map<String, dynamic>?;
    expect(book, isNotNull);
  });

  test('includes image base64 and exports empty fields for an unknown session', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Bob'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    await MessageRepository(db).append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'aGVsbG8=',
      imagePrompt: 'a cave, silver light',
    );

    final json = jsonDecode(await SessionExporter(db).export(sessionId: sessionId)) as Map<String, dynamic>;
    expect((json['messages'] as List).single['imageBase64'], 'aGVsbG8=');
    expect((json['messages'] as List).single['imagePrompt'], 'a cave, silver light');

    final unknown = jsonDecode(await SessionExporter(db).export(sessionId: 999)) as Map<String, dynamic>;
    expect(unknown['character'], isEmpty);
    expect(unknown['messages'], isEmpty);
    expect(unknown.containsKey('session'), isFalse);
    expect(unknown['memory'], isNull);
    expect(unknown['variables'], isEmpty);
    expect(unknown['variableAccess'], isEmpty);
  });
}
