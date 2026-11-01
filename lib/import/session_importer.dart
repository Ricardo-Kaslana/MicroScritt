/// 会话归档导入:整串入口(小文件)与两遍流式文件入口(大会话)。
///
/// 归档结构兼容 version 1–4;截断/坏文件在写库前报错,文件入口失败或
/// 取消时回滚本次新建的会话与角色。
library;

import 'dart:convert';
import 'dart:io';


import '../data/character_repository.dart';
import '../data/database.dart';
import '../data/memory_repository.dart';
import '../data/message_repository.dart';
import '../data/session_repository.dart';
import '../data/skill_repository.dart';
import '../data/variable_repository.dart';
import '../models/character_card.dart';
import '../models/message.dart';
import '../models/skill.dart';
import '../models/variable.dart';
import 'json_stream_reader.dart';
import 'worldbook_importer.dart';

/// 会话导入结果:新会话 id + 角色处理方式(同名复用既有角色,或随卡新建)。
class SessionImportResult {
  final int sessionId;
  final int characterId;
  final bool reusedCharacter;
  const SessionImportResult(this.sessionId, this.characterId, this.reusedCharacter);
}

/// 导入 `SessionExporter` 产出的会话归档(version 1–4 均可;旧版本缺失的
/// session/variables/memory/skills 节按空处理)。
///
/// 角色策略:同名角色**复用既有角色**(不动其卡与世界书 —— 用户可能已在本地
/// 改过);本地没有同名角色时随卡新建(头像 + 背景图 + 世界书一并导入)。消息按原顺序
/// 落库,seq 重排为连续序列;v4 归档的 `compactOf`(摘要行的数组内索引)由
/// 落库层换算回新库行 id,v1–v3 的原库行 id 语义不可迁移、直接丢弃。
///
/// 归档里的 `skills` 节(v2 时代的会话级技能)自 v37 起迁入**全局技能目录**:
/// 按 name 幂等去重,一律以停用状态导入 —— 内容保留,但不悄悄改变任何会话的
/// 上下文(用户可在设置页甄别启用)。
class SessionImporter {
  /// 文件字节入口:按 UTF-8 解码后走 [importText]。归档 JSON 必然含中文
  /// (标题/消息),直接把字节当码点(String.fromCharCodes)会把多字节字符
  /// 拆成乱码 —— 解码统一收在这里,UI 层不再自行转字符串。
  static Future<SessionImportResult> importBytes(
    AppDatabase db,
    List<int> bytes, {
    Future<String?> Function(String?)? avatarShrinker,
  }) => importText(db, utf8.decode(bytes, allowMalformed: true), avatarShrinker: avatarShrinker);

  /// 整串入口(测试/小文件):整体 `jsonDecode` 后按序写库。
  ///
  /// 结构或角色卡校验失败在任何写库前抛 [FormatException];写库中途失败
  /// **不自动回滚**(文件与大会话请走 [importFile],它按会话回滚)。
  ///
  /// [avatarShrinker] 可选:把内嵌头像 base64 缩到安全尺寸(Android
  /// CursorWindow ~2MB,大图不缩会 Row too big);UI 层传入
  /// shrinkBase64Image,测试可省略。
  static Future<SessionImportResult> importText(
    AppDatabase db,
    String text, {
    Future<String?> Function(String?)? avatarShrinker,
  }) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw FormatException('不是有效的 JSON 文件:$e');
    }
    if (decoded is! Map<String, dynamic>) throw const FormatException('不是会话导出文件(缺少顶层对象)');
    final rawMessages = decoded['messages'];
    if (rawMessages is! List) throw const FormatException('不是会话导出文件(缺少 messages)');
    final characterJson = decoded['character'];
    if (characterJson is! Map<String, dynamic> || CharacterCard.fromJson(characterJson).name.isEmpty) {
      throw const FormatException('会话文件缺少有效的角色卡');
    }

    // 角色匹配:同名复用,否则随卡新建(世界书经提取器还原)。
    var card = CharacterCard.fromJson(characterJson);
    final characters = await CharacterRepository(db).all();
    final existing = characters.where((c) => c.card.name == card.name).toList();
    int characterId;
    var reused = true;
    if (existing.isNotEmpty) {
      characterId = existing.first.id;
    } else {
      reused = false;
      if (avatarShrinker != null) {
        final shrunk = await avatarShrinker(card.avatarBase64);
        if (shrunk != null) card = card.replacingAvatar(shrunk);
      }
      // 背景图:归档可选键(characterBackgroundBase64)。背景列与头像同存于
      // characters 行,同样过缩图管线防 CursorWindow 爆窗;旧归档或无背景时
      // 缺键,按无背景处理。复用既有角色时不覆盖其背景(同卡策略)。
      final rawBackground = decoded['characterBackgroundBase64'];
      if (rawBackground is String && rawBackground.isNotEmpty) {
        final shrunk = avatarShrinker == null ? rawBackground : await avatarShrinker(rawBackground);
        if (shrunk != null && shrunk.isNotEmpty) card = card.withBackground(shrunk);
      }
      characterId = await CharacterRepository(db).insertWithWorldbook(card, WorldbookImporter.extract(card));
    }

    // 会话标题:v2 取导出元数据,v1 回退角色名。
    final sessionJson = decoded['session'];
    final title = sessionJson is Map<String, dynamic> && (sessionJson['title'] as String? ?? '').trim().isNotEmpty
        ? sessionJson['title'] as String
        : '${card.name} · 导入';
    final sessionId = await SessionRepository(db).create(characterId, title);

    // 消息:按文件顺序重排连续 seq。v4 起 compactOf 是"消息数组内索引",
    // 由 importMessages 换算回新库行 id;v1–v3 归档里是**原库行 id**,
    // 换设备后无从对应(旧实现的 seq 偏移换算在 id≠seq 的库上指向错误行),
    // 一律丢弃 —— 引擎只消费 isCompacted,丢指向无行为影响。
    final archiveVersion = decoded['version'] is int ? decoded['version'] as int : 0;
    final messages = <Message>[];
    for (final m in rawMessages) {
      if (m is Map<String, dynamic>) {
        messages.add(Message.fromMap(_normalizedMessage(m, compactAsIndex: archiveVersion >= 4)));
      }
    }
    await MessageRepository(db).importMessages(sessionId: sessionId, messages: messages);

    // 会话级状态与 token 用量(v1 无这些节,按空处理)。
    final variables = decoded['variables'];
    final variableAccess = decoded['variableAccess'];
    await _restoreVariables(
      db,
      sessionId,
      variables is Map<String, dynamic> ? variables : null,
      variableAccess is Map<String, dynamic> ? variableAccess : null,
    );
    final memory = decoded['memory'];
    if (memory is String && memory.trim().isNotEmpty) {
      await MemoryRepository(db).set(sessionId, memory);
    }
    // v2 归档的会话级技能:迁入全局技能目录(按 name 幂等,停用状态导入)。
    // v3 归档不再携带该节。
    final skills = decoded['skills'];
    if (skills is List) {
      for (final s in skills) {
        if (s is Map<String, dynamic> && (s['name'] as String? ?? '').trim().isNotEmpty) {
          await SkillRepository(db).importAll([
            Skill(
              name: (s['name'] as String).trim(),
              description: (s['description'] ?? '').toString(),
              content: (s['content'] ?? '').toString(),
            ),
          ], enabled: false);
        }
      }
    }
    if (sessionJson is Map<String, dynamic>) {
      final usage = sessionJson['usage'];
      if (usage is Map<String, dynamic>) {
        await SessionRepository(db).updateTokenUsage(
          sessionId: sessionId,
          inputTokens: _int(usage, 'inputTokens'),
          outputTokens: _int(usage, 'outputTokens'),
          cachedInputTokens: _int(usage, 'cachedInputTokens'),
          backgroundInputTokens: _int(usage, 'backgroundInputTokens'),
          backgroundOutputTokens: _int(usage, 'backgroundOutputTokens'),
          backgroundCachedInputTokens: _int(usage, 'backgroundCachedInputTokens'),
          compactInputTokens: _int(usage, 'compactInputTokens'),
          compactOutputTokens: _int(usage, 'compactOutputTokens'),
          compactCachedInputTokens: _int(usage, 'compactCachedInputTokens'),
        );
      }
    }

    return SessionImportResult(sessionId, characterId, reused);
  }

  /// 文件入口(内存受限):两遍流式扫描 —— 第一遍校验结构并读头部字段,
  /// 第二遍逐条消息解码、每 8 条分块事务落库。图片只在单条消息内进内存,
  /// 几百 MB 的归档也能导入;失败/取消会删除本会话与本次新建的角色。
  static Future<SessionImportResult> importFile(
    AppDatabase db,
    File file, {
    Future<String?> Function(String?)? avatarShrinker,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final reader = SessionArchiveReader(file);
    final header = await reader.readHeader();
    final characterJson = header.character;
    if (characterJson == null) throw const FormatException('会话文件缺少有效的角色卡');
    var card = CharacterCard.fromJson(characterJson);
    if (card.name.isEmpty) throw const FormatException('会话文件缺少有效的角色卡');

    final characters = await CharacterRepository(db).all();
    final existing = characters.where((c) => c.card.name == card.name).toList();
    var characterId = 0;
    var reused = true;
    if (existing.isNotEmpty) {
      characterId = existing.first.id;
    } else {
      reused = false;
      if (avatarShrinker != null) {
        final shrunk = await avatarShrinker(card.avatarBase64);
        if (shrunk != null) card = card.replacingAvatar(shrunk);
      }
      final rawBackground = header.characterBackgroundBase64;
      if (rawBackground != null) {
        final shrunk = avatarShrinker == null ? rawBackground : await avatarShrinker(rawBackground);
        if (shrunk != null && shrunk.isNotEmpty) card = card.withBackground(shrunk);
      }
      characterId = await CharacterRepository(db).insertWithWorldbook(card, WorldbookImporter.extract(card));
    }

    final sessionJson = header.session;
    final title = sessionJson != null && (sessionJson['title'] as String? ?? '').trim().isNotEmpty
        ? sessionJson['title'] as String
        : '${card.name} · 导入';

    int? sessionId;
    try {
      final created = await SessionRepository(db).create(characterId, title);
      sessionId = created;
      final messageRepo = MessageRepository(db);
      final archiveVersion = header.version;
      final rowIds = <int>[];
      final compactLinks = <(int rowIndex, int compactIndex)>[];
      final pending = <Message>[];
      var pendingStart = 0;

      Future<void> flush() async {
        if (pending.isEmpty) return;
        final ids = await messageRepo.insertMessageChunk(
          sessionId: created,
          messages: pending,
          seqStart: pendingStart,
        );
        for (var i = 0; i < pending.length; i++) {
          rowIds.add(ids[i]);
          final compact = pending[i].compactOf;
          if (compact != null) compactLinks.add((pendingStart + i, compact));
        }
        pending.clear();
      }

      await reader.forEachMessage(
        skipArrays: header.messagesArrays - 1,
        messageCount: header.messageCount,
        isCancelled: isCancelled,
        onProgress: onProgress,
        onMessage: (raw, index) async {
          final dynamic decoded;
          try {
            decoded = jsonDecode(raw);
          } catch (e) {
            throw FormatException('messages[$index] 不是有效的 JSON:$e');
          }
          if (decoded is! Map<String, dynamic>) {
            throw FormatException('messages[$index] 必须是对象');
          }
          if (pending.isEmpty) pendingStart = index;
          pending.add(Message.fromMap(_normalizedMessage(decoded, compactAsIndex: archiveVersion >= 4)));
          if (pending.length >= 8) await flush();
        },
      );
      await flush();
      await messageRepo.linkCompactOf(sessionId: created, rowIds: rowIds, links: compactLinks);

      await _restoreVariables(
        db,
        created,
        header.variables,
        header.variableAccess,
      );
      final memory = header.memory;
      if (memory != null && memory.trim().isNotEmpty) {
        await MemoryRepository(db).set(sessionId, memory);
      }
      final skills = header.skills;
      if (skills != null) {
        for (final s in skills) {
          if (s is Map<String, dynamic> && (s['name'] as String? ?? '').trim().isNotEmpty) {
            await SkillRepository(db).importAll([
              Skill(
                name: (s['name'] as String).trim(),
                description: (s['description'] ?? '').toString(),
                content: (s['content'] ?? '').toString(),
              ),
            ], enabled: false);
          }
        }
      }
      if (sessionJson != null) {
        final usage = sessionJson['usage'];
        if (usage is Map<String, dynamic>) {
          await SessionRepository(db).updateTokenUsage(
            sessionId: created,
            inputTokens: _int(usage, 'inputTokens'),
            outputTokens: _int(usage, 'outputTokens'),
            cachedInputTokens: _int(usage, 'cachedInputTokens'),
            backgroundInputTokens: _int(usage, 'backgroundInputTokens'),
            backgroundOutputTokens: _int(usage, 'backgroundOutputTokens'),
            backgroundCachedInputTokens: _int(usage, 'backgroundCachedInputTokens'),
            compactInputTokens: _int(usage, 'compactInputTokens'),
            compactOutputTokens: _int(usage, 'compactOutputTokens'),
            compactCachedInputTokens: _int(usage, 'compactCachedInputTokens'),
          );
        }
      }
    } catch (e) {
      if (sessionId != null) await SessionRepository(db).deleteWithCascade(sessionId);
      if (!reused) await CharacterRepository(db).deleteWithCascade(characterId);
      rethrow;
    }

    return SessionImportResult(sessionId, characterId, reused);
  }

  /// 导入变量及其后台权限。v66 起归档带可选 `variableAccess`;旧档缺失、
  /// 未知值或非字符串值一律回落 [VariableAccess.protected] —— 导入数据
  /// 默认不让后台删除。access 里多出的、`variables` 中不存在的键直接忽略。
  static Future<void> _restoreVariables(
    AppDatabase db,
    int sessionId,
    Map<String, dynamic>? variables,
    Map<String, dynamic>? accessRaw,
  ) async {
    if (variables == null) return;
    final access = <String, VariableAccess>{};
    if (accessRaw != null) {
      for (final entry in accessRaw.entries) {
        final value = entry.value;
        if (value is String) {
          access[entry.key] = VariableAccess.fromStorage(value);
        }
      }
    }
    final repo = VariableRepository(db);
    for (final entry in variables.entries) {
      await repo.upsert(
        sessionId,
        entry.key,
        entry.value.toString(),
        access: access[entry.key] ?? VariableAccess.protected,
      );
    }
  }

  static int _int(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// 归一化消息 Map:isCompacted 兼容 v1 的 int 0/1 与 v2 的 bool,统一为
  /// DB 列形态 int(Message.fromMap 按列类型解析);剔除空图片串。
  /// [compactAsIndex]:v4+ 归档的 compactOf 是消息数组内索引,原样透传给
  /// 落库层换算;v1–v3 的 compactOf 是原库行 id,不可迁移,置 null。
  static Map<String, Object?> _normalizedMessage(Map<String, dynamic> m, {required bool compactAsIndex}) => {
        'session_id': 0, // 占位;落库时由仓库按目标会话写入。
        'role': (m['role'] ?? 'user').toString(),
        'content': (m['content'] ?? '').toString(),
        'seq': m['seq'] is int ? m['seq'] as int : 0,
        'is_compacted': (m['isCompacted'] == true || m['isCompacted'] == 1) ? 1 : 0,
        'compact_of': compactAsIndex && m['compactOf'] is int ? m['compactOf'] as int : null,
        'image_url': m['imageUrl'] is String && (m['imageUrl'] as String).isNotEmpty ? m['imageUrl'] : null,
        'image_base64': m['imageBase64'] is String && (m['imageBase64'] as String).isNotEmpty ? m['imageBase64'] : null,
        'image_prompt': m['imagePrompt'] is String && (m['imagePrompt'] as String).isNotEmpty ? m['imagePrompt'] : null,
        // v4:附件行往返保真(旧归档缺省由 Message.fromMap 回退 chat/null)。
        'kind': m['kind'] is String ? m['kind'] as String : 'chat',
        'ref_id': m['refId'] is String && (m['refId'] as String).isNotEmpty ? m['refId'] : null,
      };
}
