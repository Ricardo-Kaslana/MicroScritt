/// 会话归档导入:v5 ZIP STORE 与 v1–v4 JSON 两套边界。
///
/// v5 先完整校验 meta、NDJSON、ZIP CRC、引用闭合并逐个重算资产 SHA-256,
/// 通过后才创建角色/会话;资产写入只是零引用预提交。v4 保留两遍流式文件
/// 读取,base64 只在本边界解码并立即资产化。失败或取消均回滚新业务行与引用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/character_repository.dart';
import '../data/database.dart';
import '../data/image_asset_input.dart';
import '../data/image_asset_store.dart';
import '../data/image_codec.dart';
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
import 'session_archive_limits.dart';
import 'worldbook_importer.dart';
import 'zip_store_reader.dart';

/// 导入结果:新会话 id + 角色处理方式(同名复用既有角色,或随卡新建)。
class SessionImportResult {
  final int sessionId;
  final int characterId;
  final bool reusedCharacter;
  const SessionImportResult(
    this.sessionId,
    this.characterId,
    this.reusedCharacter,
  );
}

/// 会话归档导入器。
///
/// 角色策略保持历史行为:同名角色复用且不覆盖本地卡;本地没有同名角色时,
/// 随卡新建角色与世界书。消息按文件顺序重排连续 seq,v4+ 的 compactOf 按
/// 消息索引换算成新库行 id;v1–v3 的原库行 id 语义不可迁移,直接丢弃。
class SessionImporter {
  /// 字节入口:自动识别 v5 ZIP 与 v1–v4 JSON。
  ///
  /// [avatarShrinker] 仅为旧 UI 调用保留;图片现在统一由 image_asset_input
  /// 缩图并资产化,不再经由调用方回传 base64。
  ///
  /// [includeImages] 为 false 时只导入文本与业务状态:跳过归档资产写入,
  /// 消息的图片哈希/远程 URL/生成描述与角色头像/背景一并清空 —— 否则远程
  /// URL 仍会渲染图片,并在查看会话时被回填进资产库,「仅文本」形同虚设。
  /// 正文为空的图片消息整条略过,避免导入后只剩空气泡。
  static Future<SessionImportResult> importBytes(
    AppDatabase db,
    List<int> bytes, {
    Future<String?> Function(String?)? avatarShrinker,
    bool includeImages = true,
  }) async {
    if (_isZipBytes(bytes)) {
      final dir = await Directory.systemTemp.createTemp('microscritt-import-');
      final file = File('${dir.path}/archive.msarc');
      try {
        await file.writeAsBytes(bytes, flush: true);
        return await _importV5File(db, file, includeImages: includeImages);
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
    return importText(
      db,
      utf8.decode(bytes, allowMalformed: true),
      avatarShrinker: avatarShrinker,
      includeImages: includeImages,
    );
  }

  /// v1–v4 JSON 整串入口(测试/小文件)。v5 是二进制 ZIP,请用
  /// [importBytes] 或 [importFile]。
  static Future<SessionImportResult> importText(
    AppDatabase db,
    String text, {
    Future<String?> Function(String?)? avatarShrinker,
    bool includeImages = true,
  }) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw FormatException('不是有效的 JSON 文件:$e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('不是会话导出文件(缺少顶层对象)');
    }
    final rawMessages = decoded['messages'];
    if (rawMessages is! List) {
      throw const FormatException('不是会话导出文件(缺少 messages)');
    }
    final archiveVersion = _supportedArchiveVersion(decoded['version']);
    var card = _validCharacter(decoded['character']);

    // 整串入口先解码并资产化全部消息,坏图不会留下任何业务行。
    final parsed = <(int, Message)>[];
    for (final (index, raw) in rawMessages.indexed) {
      if (raw is Map<String, dynamic>) {
        parsed.add((
          index,
          await _v4Message(
            db,
            raw,
            archiveVersion,
            index,
            includeImages: includeImages,
          ),
        ));
      }
    }
    final messages = includeImages
        ? [for (final (_, message) in parsed) message]
        : _dropEmptyForTextOnly(parsed);

    final existingId = await _existingCharacterId(db, card.name);
    final reused = existingId != null;
    if (!reused) {
      card = await _assetizeV4Character(
        db,
        card,
        decoded['characterBackgroundBase64'],
        includeImages: includeImages,
      );
    }
    int? characterId = existingId;
    int? sessionId;
    try {
      characterId ??= await CharacterRepository(
        db,
      ).insertWithWorldbook(card, WorldbookImporter.extract(card));
      sessionId = await SessionRepository(
        db,
      ).create(characterId, _sessionTitle(decoded['session'], card.name));
      await MessageRepository(
        db,
      ).importMessages(sessionId: sessionId, messages: messages);
      await _restoreState(
        db,
        sessionId,
        sessionJson: _optionalMap(decoded['session']),
        variables: _optionalMap(decoded['variables']),
        variableAccess: _optionalMap(decoded['variableAccess']),
        memory: decoded['memory'] is String
            ? decoded['memory'] as String
            : null,
        skills: decoded['skills'] is List ? decoded['skills'] as List : null,
      );
      return SessionImportResult(sessionId, characterId, reused);
    } catch (_) {
      await _rollback(db, sessionId, characterId, reused);
      rethrow;
    }
  }

  /// 文件入口:v5 随机访问 ZIP,v1–v4 JSON 两遍流式扫描。
  ///
  /// [maxV5MessageLineBytes] / [maxV5Messages] 默认取归档共享上限;测试可
  /// 收紧以用小文件覆盖超限路径。
  static Future<SessionImportResult> importFile(
    AppDatabase db,
    File file, {
    Future<String?> Function(String?)? avatarShrinker,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    bool includeImages = true,
    int maxV5MessageLineBytes = SessionArchiveLimits.maxMessageLineBytes,
    int maxV5Messages = SessionArchiveLimits.maxMessages,
  }) async {
    if (await _isZipFile(file)) {
      return _importV5File(
        db,
        file,
        onProgress: onProgress,
        isCancelled: isCancelled,
        includeImages: includeImages,
        maxMessageLineBytes: maxV5MessageLineBytes,
        maxMessages: maxV5Messages,
      );
    }
    return _importV4File(
      db,
      file,
      onProgress: onProgress,
      isCancelled: isCancelled,
      includeImages: includeImages,
    );
  }

  static Future<SessionImportResult> _importV4File(
    AppDatabase db,
    File file, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    bool includeImages = true,
  }) async {
    final reader = SessionArchiveReader(file);
    // 第一遍读到 EOF,截断 JSON 在任何业务写库前失败。
    final header = await reader.readHeader();
    var card = _validCharacter(header.character);
    final existingId = await _existingCharacterId(db, card.name);
    final reused = existingId != null;
    if (!reused) {
      card = await _assetizeV4Character(
        db,
        card,
        header.characterBackgroundBase64,
        includeImages: includeImages,
      );
    }

    int? characterId = existingId;
    int? sessionId;
    try {
      characterId ??= await CharacterRepository(
        db,
      ).insertWithWorldbook(card, WorldbookImporter.extract(card));
      sessionId = await SessionRepository(
        db,
      ).create(characterId, _sessionTitle(header.session, card.name));
      final writer = _ChunkedMessageWriter(
        db,
        sessionId,
        dropEmpty: !includeImages,
      );
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
          await writer.add(
            await _v4Message(
              db,
              decoded,
              header.version,
              index,
              includeImages: includeImages,
            ),
            index,
          );
        },
      );
      await writer.finish();
      await _restoreState(
        db,
        sessionId,
        sessionJson: header.session,
        variables: header.variables,
        variableAccess: header.variableAccess,
        memory: header.memory,
        skills: header.skills,
      );
      return SessionImportResult(sessionId, characterId, reused);
    } catch (_) {
      await _rollback(db, sessionId, characterId, reused);
      rethrow;
    }
  }

  static Future<SessionImportResult> _importV5File(
    AppDatabase db,
    File file, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    bool includeImages = true,
    int maxMessageLineBytes = SessionArchiveLimits.maxMessageLineBytes,
    int maxMessages = SessionArchiveLimits.maxMessages,
  }) async {
    final reader = await ZipStoreReader.open(file);
    try {
      final entries = <String, ZipStoreEntry>{};
      final assets = <String, ZipStoreEntry>{};
      for (final entry in reader.entries) {
        if (entries.containsKey(entry.name)) {
          throw FormatException('v5 含重复 entry:${entry.name}');
        }
        entries[entry.name] = entry;
        if (entry.name == 'meta.json' || entry.name == 'messages.ndjson') {
          continue;
        }
        if (!entry.name.startsWith('assets/') ||
            !ImageAssetStore.isValidHash(entry.name.substring(7))) {
          throw FormatException('v5 entry 路径无效:${entry.name}');
        }
        if (entry.size <= 0 || entry.size > ImageAssetStore.maxOriginalBytes) {
          throw FormatException('v5 资产大小超过单图 16MiB 限制:${entry.name}');
        }
        assets[entry.name.substring(7)] = entry;
      }
      final metaEntry = entries['meta.json'];
      final messagesEntry = entries['messages.ndjson'];
      if (metaEntry == null || messagesEntry == null) {
        throw const FormatException('v5 缺少 meta.json 或 messages.ndjson');
      }
      if (metaEntry.size > SessionArchiveLimits.maxMetaBytes) {
        throw const FormatException('v5 meta.json 超过 64MiB 上限');
      }

      final header = await _readV5Header(
        reader,
        metaEntry,
        isCancelled,
        includeImages: includeImages,
      );
      final references = <String>{
        if (header.card.avatarHash != null) header.card.avatarHash!,
        if (header.card.backgroundHash != null) header.card.backgroundHash!,
      };
      final messageCount = await _forEachV5Message(
        reader,
        messagesEntry,
        isCancelled: isCancelled,
        includeImages: includeImages,
        maxMessageLineBytes: maxMessageLineBytes,
        maxMessages: maxMessages,
        onMessage: (message, _) {
          final hash = message.imageHash;
          if (hash != null) references.add(hash);
        },
      );
      // 仅文本模式不解包资产:不校验缺失/多余资产,也不读资产 CRC。消息与
      // 角色上的图片哈希、URL 与生成描述已在解析边界清空,不会留下悬空引用。
      if (includeImages) {
        final missing =
            references.where((hash) => !assets.containsKey(hash)).toList()
              ..sort();
        if (missing.isNotEmpty) {
          throw FormatException('v5 缺少被引用资产:${missing.join(',')}');
        }
        final unreferenced =
            assets.keys.where((hash) => !references.contains(hash)).toList()
              ..sort();
        if (unreferenced.isNotEmpty) {
          throw FormatException('v5 含未被引用资产:${unreferenced.join(',')}');
        }

        // 所有 entry 都在建业务行前完整消费:CRC、真实图片、大小及内容哈希
        // 任一不符都会中止。putStream 产生的只是零引用资产,后续仓储负责
        // acquire。
        final assetNames = assets.keys.toList()..sort();
        for (final expectedHash in assetNames) {
          _throwIfCancelled(isCancelled);
          final ref = await db.images.putStream(
            _cancellable(reader.openEntry(assets[expectedHash]!), isCancelled),
            // 归档资产必须逐字节保持文件名哈希,入库压缩不得介入。
            compress: false,
          );
          if (ref.hash != expectedHash) {
            throw FormatException(
              'v5 资产 SHA-256 与文件名不符:$expectedHash,实际为 ${ref.hash}',
            );
          }
        }
      }

      final existingId = await _existingCharacterId(db, header.card.name);
      final reused = existingId != null;
      int? characterId = existingId;
      int? sessionId;
      try {
        characterId ??= await CharacterRepository(db).insertWithWorldbook(
          header.card,
          WorldbookImporter.extract(header.card),
        );
        sessionId = await SessionRepository(
          db,
        ).create(characterId, _sessionTitle(header.session, header.card.name));
        final writer = _ChunkedMessageWriter(
          db,
          sessionId,
          dropEmpty: !includeImages,
        );
        await _forEachV5Message(
          reader,
          messagesEntry,
          isCancelled: isCancelled,
          includeImages: includeImages,
          onProgress: onProgress,
          messageCount: messageCount,
          maxMessageLineBytes: maxMessageLineBytes,
          maxMessages: maxMessages,
          onMessage: writer.add,
        );
        await writer.finish();
        await _restoreState(
          db,
          sessionId,
          sessionJson: header.session,
          variables: header.variables,
          variableAccess: header.variableAccess,
          memory: header.memory,
        );
        return SessionImportResult(sessionId, characterId, reused);
      } catch (_) {
        await _rollback(db, sessionId, characterId, reused);
        rethrow;
      }
    } finally {
      await reader.close();
    }
  }

  static Future<_V5Header> _readV5Header(
    ZipStoreReader reader,
    ZipStoreEntry entry,
    bool Function()? isCancelled, {
    bool includeImages = true,
  }) async {
    final output = BytesBuilder(copy: false);
    await for (final chunk in _cancellable(
      reader.openEntry(entry),
      isCancelled,
    )) {
      output.add(chunk);
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(output.takeBytes()));
    } catch (e) {
      throw FormatException('v5 meta.json 不是有效 JSON:$e');
    }
    if (decoded is! Map<String, dynamic> || decoded['version'] != 5) {
      throw const FormatException('不是 version 5 会话归档');
    }
    var card = _validCharacter(decoded['character']);
    final avatarHash = _v5HashField(decoded, 'characterAvatarHash');
    final backgroundHash = _v5HashField(decoded, 'characterBackgroundHash');
    if (avatarHash == null && card.importedAvatarBase64 != null) {
      throw const FormatException('v5 角色内嵌头像缺少 characterAvatarHash');
    }
    card = includeImages
        ? card.replacingAvatar(avatarHash).replacingBackground(backgroundHash)
        : card.replacingAvatar(null).replacingBackground(null);
    final session = _strictOptionalMap(decoded, 'session');
    final variables = _strictOptionalMap(decoded, 'variables');
    final access = _strictOptionalMap(decoded, 'variableAccess');
    final memory = decoded['memory'];
    if (memory != null && memory is! String) {
      throw const FormatException('v5 memory 必须是字符串或 null');
    }
    return _V5Header(
      card: card,
      session: session,
      variables: variables,
      variableAccess: access,
      memory: memory as String?,
    );
  }

  static Future<int> _forEachV5Message(
    ZipStoreReader reader,
    ZipStoreEntry entry, {
    required FutureOr<void> Function(Message message, int index) onMessage,
    bool Function()? isCancelled,
    bool includeImages = true,
    void Function(int done, int total)? onProgress,
    int? messageCount,
    int maxMessageLineBytes = SessionArchiveLimits.maxMessageLineBytes,
    int maxMessages = SessionArchiveLimits.maxMessages,
  }) async {
    final lines = utf8.decoder
        .bind(_cancellable(reader.openEntry(entry), isCancelled))
        .transform(const LineSplitter());
    var index = 0;
    await for (final line in lines) {
      _throwIfCancelled(isCancelled);
      if (index >= maxMessages) {
        throw FormatException('v5 消息条数超过 $maxMessages 上限');
      }
      if (_utf8LengthExceeds(line, maxMessageLineBytes)) {
        throw FormatException(
          'messages.ndjson 第 ${index + 1} 行超过 ${maxMessageLineBytes ~/ (1024 * 1024)}MiB 上限',
        );
      }
      final dynamic decoded;
      try {
        decoded = jsonDecode(line);
      } catch (e) {
        throw FormatException('messages.ndjson 第 ${index + 1} 行不是有效 JSON:$e');
      }
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('messages.ndjson 第 ${index + 1} 行必须是对象');
      }
      await onMessage(_v5Message(decoded, includeImages: includeImages), index);
      index++;
      if (onProgress != null) onProgress(index, messageCount ?? index);
    }
    return index;
  }

  /// 行文本的 UTF-8 字节数是否超过 [maxBytes];UTF-16 码元数不超过字节数,
  /// 可先用长度快速判断,避免为每条正常消息做精确计数。
  static bool _utf8LengthExceeds(String text, int maxBytes) {
    if (text.length > maxBytes) return true;
    // UTF-8 字节数至多 3×码元数(代理对为 2 码元/4 字节);整行远低于上限时
    // 无需逐字符计数 —— 大归档两遍扫描都省掉这趟全量遍历。
    if (text.length * 3 <= maxBytes) return false;
    var bytes = 0;
    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code < 0x80) {
        bytes += 1;
      } else if (code < 0x800) {
        bytes += 2;
      } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        // 代理对合计 4 字节,跳过低位代理。
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
      if (bytes > maxBytes) return true;
    }
    return false;
  }

  static Message _v5Message(
    Map<String, dynamic> raw, {
    bool includeImages = true,
  }) {
    final value = raw['imageHash'];
    String? hash;
    if (value != null) {
      if (value is! String || !ImageAssetStore.isValidHash(value)) {
        throw FormatException('消息 imageHash 不是 64 位小写 SHA-256:$value');
      }
      if (includeImages) hash = value;
    }
    return Message.fromMap(
      _normalizedMessage(
        raw,
        compactAsIndex: true,
        imageHash: hash,
        includeImages: includeImages,
      ),
    );
  }

  static Future<Message> _v4Message(
    AppDatabase db,
    Map<String, dynamic> raw,
    int archiveVersion,
    int index, {
    bool includeImages = true,
  }) async {
    String? hash;
    final encoded = raw['imageBase64'];
    if (includeImages && encoded is String && encoded.isNotEmpty) {
      final label = 'messages[$index].imageBase64';
      final bytes = _decodeBase64Image(encoded, label);
      try {
        // 归档字节保持原样:重编码会改变哈希,破坏内容寻址与后续修复。
        hash = (await db.images.putBytes(bytes, compress: false)).hash;
      } on FormatException catch (e) {
        throw FormatException('$label 图片无效:${e.message}');
      }
    }
    return Message.fromMap(
      _normalizedMessage(
        raw,
        compactAsIndex: archiveVersion >= 4,
        imageHash: hash,
        includeImages: includeImages,
      ),
    );
  }

  static Future<CharacterCard> _assetizeV4Character(
    AppDatabase db,
    CharacterCard card,
    Object? rawBackground, {
    bool includeImages = true,
  }) async {
    if (!includeImages) {
      return card.replacingAvatar(null).replacingBackground(null);
    }
    final avatar = await _assetizeExternalImage(
      db,
      card.importedAvatarBase64,
      label: 'character.avatar',
      maxDim: 1024,
    );
    final background = await _assetizeExternalImage(
      db,
      rawBackground is String ? rawBackground : null,
      label: 'characterBackgroundBase64',
      maxDim: 2048,
    );
    return card.replacingAvatar(avatar).replacingBackground(background);
  }

  static Future<String?> _assetizeExternalImage(
    AppDatabase db,
    String? encoded, {
    required String label,
    required int maxDim,
  }) async {
    if (encoded == null || encoded.isEmpty) return null;
    final bytes = _decodeBase64Image(encoded, label);
    try {
      final hash = await assetizeImageBytes(db, bytes, maxDim: maxDim);
      if (hash == null) throw const FormatException('图片损坏或无法解码');
      return hash;
    } on FormatException catch (e) {
      throw FormatException('$label 图片无效:${e.message}');
    }
  }

  static Uint8List _decodeBase64Image(String encoded, String label) {
    var value = encoded.trim();
    var start = 0;
    if (value.startsWith('data:')) {
      final comma = value.indexOf(',');
      if (comma < 0) throw FormatException('$label 不是有效的 data URI');
      start = comma + 1;
    }
    final maxEncoded = 4 * ((ImageAssetStore.maxOriginalBytes + 2) ~/ 3);
    var encodedLength = 0;
    for (var index = start; index < value.length; index++) {
      final code = value.codeUnitAt(index);
      if (code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d) {
        continue;
      }
      encodedLength++;
      if (encodedLength > maxEncoded) {
        throw FormatException('$label 超过单图 16MiB 上限');
      }
    }
    final bytes = safeBase64Decode(value.substring(start));
    if (bytes == null) throw FormatException('$label 不是有效的 base64 图片');
    if (bytes.length > ImageAssetStore.maxOriginalBytes) {
      throw FormatException('$label 超过单图 16MiB 上限');
    }
    return bytes;
  }

  static CharacterCard _validCharacter(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('会话文件缺少有效的角色卡');
    }
    final card = CharacterCard.fromJson(raw);
    if (card.name.trim().isEmpty) {
      throw const FormatException('会话文件缺少有效的角色卡');
    }
    return card;
  }

  /// v1–v4 只接受显式支持版本;类型错误、缺失或过高直接失败,避免未来格式
  /// 被旧客户端按当前语义误读。
  static int _supportedArchiveVersion(Object? raw) {
    if (raw is! int || raw < 1 || raw > 4) {
      throw FormatException('不支持的会话归档版本:$raw(仅支持 1–4)');
    }
    return raw;
  }

  static Future<int?> _existingCharacterId(AppDatabase db, String name) async {
    final characters = await CharacterRepository(db).all();
    for (final character in characters) {
      if (character.card.name == name) return character.id;
    }
    return null;
  }

  static String _sessionTitle(Object? rawSession, String characterName) {
    final session = rawSession is Map<String, dynamic> ? rawSession : null;
    final title = session?['title'];
    return title is String && title.trim().isNotEmpty
        ? title
        : '$characterName · 导入';
  }

  static Map<String, dynamic>? _optionalMap(Object? value) =>
      value is Map<String, dynamic> ? value : null;

  static Map<String, dynamic>? _strictOptionalMap(
    Map<String, dynamic> raw,
    String key,
  ) {
    final value = raw[key];
    if (value == null) return null;
    if (value is! Map<String, dynamic>) {
      throw FormatException('v5 $key 必须是对象或 null');
    }
    return value;
  }

  static String? _v5HashField(Map<String, dynamic> raw, String key) {
    final value = raw[key];
    if (value == null) return null;
    if (value is! String || !ImageAssetStore.isValidHash(value)) {
      throw FormatException('v5 $key 不是 64 位小写 SHA-256');
    }
    return value;
  }

  static Future<void> _restoreState(
    AppDatabase db,
    int sessionId, {
    Map<String, dynamic>? sessionJson,
    Map<String, dynamic>? variables,
    Map<String, dynamic>? variableAccess,
    String? memory,
    List<dynamic>? skills,
  }) async {
    await _restoreVariables(db, sessionId, variables, variableAccess);
    if (memory != null && memory.trim().isNotEmpty) {
      await MemoryRepository(db).set(sessionId, memory);
    }
    if (skills != null) {
      for (final raw in skills) {
        if (raw is Map<String, dynamic> &&
            (raw['name'] as String? ?? '').trim().isNotEmpty) {
          await SkillRepository(db).importAll([
            Skill(
              name: (raw['name'] as String).trim(),
              description: (raw['description'] ?? '').toString(),
              content: (raw['content'] ?? '').toString(),
            ),
          ], enabled: false);
        }
      }
    }
    final usage = sessionJson?['usage'];
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

  /// 恢复变量权限;旧档缺失、未知值与非字符串一律回落 protected。
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

  static Future<void> _rollback(
    AppDatabase db,
    int? sessionId,
    int? characterId,
    bool reusedCharacter,
  ) async {
    if (sessionId != null) {
      await SessionRepository(db).deleteWithCascade(sessionId);
    }
    if (!reusedCharacter && characterId != null) {
      await CharacterRepository(db).deleteWithCascade(characterId);
    }
  }

  static int _int(Map<String, dynamic> raw, String key) {
    final value = raw[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  /// 仅文本导入丢弃正文为空的消息(图片消息清空图片后没有可展示内容,
  /// 留着只会渲染成空气泡),并把 compactOf 的归档数组索引换算到过滤后的
  /// 列表位置;目标被丢弃时链接一并作废。
  static List<Message> _dropEmptyForTextOnly(List<(int, Message)> parsed) {
    final kept = <(int, Message)>[];
    for (final entry in parsed) {
      if (entry.$2.content.trim().isNotEmpty) kept.add(entry);
    }
    if (kept.length == parsed.length) {
      return [for (final (_, message) in kept) message];
    }
    final positions = <int, int>{
      for (final (newIndex, entry) in kept.indexed) entry.$1: newIndex,
    };
    return [
      for (final (_, message) in kept)
        message.compactOf == null
            ? message
            : _withCompactOf(message, positions[message.compactOf!]),
    ];
  }

  static Message _withCompactOf(Message message, int? compactOf) => Message(
    id: message.id,
    sessionId: message.sessionId,
    role: message.role,
    content: message.content,
    seq: message.seq,
    isCompacted: message.isCompacted,
    compactOf: compactOf,
    imageHash: message.imageHash,
    imageUrl: message.imageUrl,
    imagePrompt: message.imagePrompt,
    kind: message.kind,
    refId: message.refId,
  );

  static Map<String, Object?> _normalizedMessage(
    Map<String, dynamic> raw, {
    required bool compactAsIndex,
    required String? imageHash,
    required bool includeImages,
  }) {
    final kind = raw['kind'] is String ? raw['kind'] as String : 'chat';
    return {
      'session_id': 0,
      'role': (raw['role'] ?? 'user').toString(),
      'content': (raw['content'] ?? '').toString(),
      'seq': raw['seq'] is int ? raw['seq'] as int : 0,
      'is_compacted': (raw['isCompacted'] == true || raw['isCompacted'] == 1)
          ? 1
          : 0,
      'compact_of': compactAsIndex && raw['compactOf'] is int
          ? raw['compactOf'] as int
          : null,
      'image_hash': imageHash,
      'image_url':
          includeImages &&
              raw['imageUrl'] is String &&
              (raw['imageUrl'] as String).isNotEmpty
          ? raw['imageUrl']
          : null,
      'image_prompt':
          includeImages &&
              raw['imagePrompt'] is String &&
              (raw['imagePrompt'] as String).isNotEmpty
          ? raw['imagePrompt']
          : null,
      'kind': kind,
      // 附件 refId 含来源库自增 id(wb:<id> / skill:<id>),跨库导入后几乎
      // 必然指向另一条同名条目或不存在,继续保留会让去重逻辑错误抑制注入。
      // 正文保留;世界书另按条目名去重,丢掉 id 不会重复注入。
      'ref_id':
          kind != 'attachment' &&
              raw['refId'] is String &&
              (raw['refId'] as String).isNotEmpty
          ? raw['refId']
          : null,
    };
  }

  static bool _isZipBytes(List<int> bytes) =>
      bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b;

  static Future<bool> _isZipFile(File file) async {
    final handle = await file.open();
    try {
      return _isZipBytes(await handle.read(2));
    } finally {
      await handle.close();
    }
  }

  static void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const ArchiveScanCancelled();
  }

  static Stream<List<int>> _cancellable(
    Stream<List<int>> source,
    bool Function()? isCancelled,
  ) async* {
    _throwIfCancelled(isCancelled);
    await for (final chunk in source) {
      _throwIfCancelled(isCancelled);
      yield chunk;
    }
  }
}

class _V5Header {
  final CharacterCard card;
  final Map<String, dynamic>? session;
  final Map<String, dynamic>? variables;
  final Map<String, dynamic>? variableAccess;
  final String? memory;

  const _V5Header({
    required this.card,
    required this.session,
    required this.variables,
    required this.variableAccess,
    required this.memory,
  });
}

/// v4/v5 文件导入共用的 8 条分块落库与 compactOf 换算。
///
/// [dropEmpty] 供仅文本导入使用:正文为空的消息(图片消息清空图片后没有可
/// 展示内容)整条略过,并在归档索引序列里留 -1 占位,让 compactOf 的索引
/// 换算不因缺失行错位;seq 仍按实际落库顺序连续编号。
class _ChunkedMessageWriter {
  final MessageRepository _repo;
  final int _sessionId;
  final bool _dropEmpty;
  final List<int> _rowIds = <int>[];
  final List<(int, int)> _compactLinks = <(int, int)>[];
  final List<Message> _pending = <Message>[];
  final List<int> _pendingIndices = <int>[];
  int _nextSeq = 0;

  _ChunkedMessageWriter(
    AppDatabase db,
    this._sessionId, {
    bool dropEmpty = false,
  }) : _dropEmpty = dropEmpty,
       _repo = MessageRepository(db);

  Future<void> add(Message message, int index) async {
    assert(index == _rowIds.length, '消息必须按归档顺序逐条写入');
    _rowIds.add(-1);
    if (_dropEmpty && message.content.trim().isEmpty) return;
    _pending.add(message);
    _pendingIndices.add(index);
    if (_pending.length >= 8) await _flush();
  }

  Future<void> finish() async {
    await _flush();
    // 仅文本导入丢掉了空正文的图片消息,它们的归档索引位置保留 -1 占位;
    // linkCompactOf 的越界与 -1 守卫负责跳过指向这些位置的外键。
    await _repo.linkCompactOf(
      sessionId: _sessionId,
      rowIds: _rowIds,
      links: _compactLinks,
    );
  }

  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final ids = await _repo.insertMessageChunk(
      sessionId: _sessionId,
      messages: _pending,
      seqStart: _nextSeq,
    );
    for (var i = 0; i < _pending.length; i++) {
      _rowIds[_pendingIndices[i]] = ids[i];
      final compact = _pending[i].compactOf;
      if (compact != null) {
        _compactLinks.add((_pendingIndices[i], compact));
      }
    }
    _nextSeq += _pending.length;
    _pending.clear();
    _pendingIndices.clear();
  }
}
