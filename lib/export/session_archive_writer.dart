/// 会话归档 writer:默认写出 version 5 的 ZIP STORE `.msarc`。
///
/// `meta.json` 保存会话、角色、变量与记忆;`messages.ndjson` 逐行保存消息;
/// 所有本地图片以 `assets/<sha256>` 去重写入。图片原图与归档输出均按块流动,
/// 只有角色卡协议要求补回的头像会在导出边界单张读入并转 base64。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/character_repository.dart';
import '../data/database.dart';
import '../data/image_asset_store.dart';
import '../data/memory_repository.dart';
import '../data/message_repository.dart';
import '../data/session_repository.dart';
import '../data/variable_repository.dart';
import '../data/worldbook_repository.dart';
import '../import/session_archive_limits.dart';
import '../models/message.dart';
import '../models/worldbook_entry.dart';
import 'character_card_exporter.dart';
import 'zip_store_writer.dart';

/// 导出进度回调:`done` 为已写消息条数,`total` 为归档内消息总数。
typedef SessionExportProgress = void Function(int done, int total);

/// 导出被用户取消(UI 按「已取消」提示,不当作错误)。
class SessionExportCancelled implements Exception {
  const SessionExportCancelled();
}

/// version 5 会话归档的流式 writer。
class SessionArchiveWriter {
  final AppDatabase db;

  /// meta.json 体积上限(默认与导入端共享 64MiB)。
  ///
  /// 导入端对 meta.json 有硬上限;导出端必须用同一数值预检,否则会产出一份
  /// 「导出成功却永远导不回来」的归档。当前选择明确报错而不是把头像/大世界
  /// 书拆成独立 entry:后者会改变 v5 结构,旧版本导入端无法识别。测试可传
  /// 更小值覆盖超限路径。
  final int maxMetaBytes;

  SessionArchiveWriter(
    this.db, {
    this.maxMetaBytes = SessionArchiveLimits.maxMetaBytes,
  });

  /// 把整份归档拼成字节;只适合测试或小会话,生产路径使用 [exportToFile]。
  ///
  /// [messageIds] 非空时只导出属于该会话的选中消息(保持时间序),用于会话内
  /// 多选导出;摘要折叠关系不随部分导出保留,导入后消息全部完整可见。
  Future<Uint8List> exportBytes({
    required int sessionId,
    Set<int>? messageIds,
  }) async {
    final output = BytesBuilder(copy: false);
    final writer = ZipStoreWriter.custom(add: output.add);
    await _export(writer, sessionId: sessionId, messageIds: messageIds);
    await writer.close();
    return output.takeBytes();
  }

  /// 流式写入文件;失败或取消时删除半成品,不留截断归档。
  ///
  /// 桌面端 UI 传目标同目录的 `.part` 暂存路径,成功后自行 rename 到目标
  /// 文件;移动端 UI 先写临时文件再交系统保存或分享。交付语义不因 ZIP 格式
  /// 改变;[onProgress] 按消息条数回调,[isCancelled] 在消息与资产边界检查。
  Future<File> exportToFile({
    required int sessionId,
    required File file,
    Set<int>? messageIds,
    SessionExportProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    var ok = false;
    try {
      final writer = ZipStoreWriter(sink);
      await _export(
        writer,
        sessionId: sessionId,
        messageIds: messageIds,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      await writer.close();
      await sink.flush();
      ok = true;
      return file;
    } finally {
      try {
        await sink.close();
      } finally {
        if (!ok) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _export(
    ZipStoreWriter writer, {
    required int sessionId,
    Set<int>? messageIds,
    SessionExportProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final session = await SessionRepository(db).get(sessionId);
    final allMessages = await MessageRepository(db).bySession(sessionId);
    final messages = messageIds == null
        ? allMessages
        : allMessages
              .where((m) => m.id != null && messageIds.contains(m.id))
              .toList(growable: false);
    if (messageIds != null && messages.isEmpty) {
      throw const FormatException('没有可导出的选中消息');
    }
    if (messages.length > SessionArchiveLimits.maxMessages) {
      throw const FormatException('会话消息条数超过 2,000,000 上限,无法导出');
    }
    final (character, worldbook, variables, memories) = await (
      session == null
          ? Future.value(null)
          : CharacterRepository(db).get(session.characterId),
      session == null
          ? Future.value(const <WorldbookEntry>[])
          : WorldbookRepository(db).byCharacter(session.characterId),
      VariableRepository(db).snapshot(sessionId),
      MemoryRepository(db).bySession(sessionId),
    ).wait;

    // 部分导出不保留压缩摘要关系:摘要行未选中时保留 is_compacted 会让导入
    // 后的这些消息在上下文组装中被跳过,却没有摘要可供回看。
    final partial = messageIds != null;

    final avatarHash = _validAssetHash(character?.avatarHash, '角色头像');
    final backgroundHash = _validAssetHash(character?.backgroundHash, '角色背景');
    final assetHashes = <String>{
      if (avatarHash != null) avatarHash,
      if (backgroundHash != null) backgroundHash,
      for (final message in messages)
        if (_validAssetHash(message.imageHash, '消息图片') != null)
          message.imageHash!,
    };

    // ST 角色卡协议仍以 avatar base64 表示头像;只在归档这一外边界补回。
    // 背景不是 ST 字段,v5 使用独立 hash 并与其他图片共用 assets 去重。
    String? avatarBase64;
    if (avatarHash != null) {
      final avatarFile = db.images.fileFor(avatarHash);
      final avatarSize = await avatarFile.length();
      if (avatarSize <= 0 || avatarSize > ImageAssetStore.maxOriginalBytes) {
        throw FormatException('导出头像大小无效:$avatarHash ($avatarSize)');
      }
      final bytes = await avatarFile.readAsBytes();
      avatarBase64 = base64Encode(bytes);
    }
    final meta = <String, Object?>{
      'version': 5,
      if (session != null) 'session': _sessionJson(session),
      'character': character == null
          ? const <String, dynamic>{}
          : CharacterCardExporter.exportJson(
              character,
              worldbook: worldbook,
              avatarBase64: avatarBase64,
            ),
      if (avatarHash != null) 'characterAvatarHash': avatarHash,
      if (backgroundHash != null) 'characterBackgroundHash': backgroundHash,
      'variables': variables.values,
      'variableAccess': {
        for (final entry in variables.access.entries)
          entry.key: entry.value.name,
      },
      'memory': memories.isEmpty ? null : memories.last.content,
    };
    final metaBytes = utf8.encode(jsonEncode(meta));
    if (metaBytes.length > maxMetaBytes) {
      throw FormatException(
        '导出元数据(角色卡/世界书/变量/记忆)超过 ${maxMetaBytes ~/ (1024 * 1024)}MiB 上限,'
        '导入端将拒绝该归档;请精简角色卡或世界书后重试',
      );
    }
    await writer.addBytes('meta.json', metaBytes);

    // compact_of 在库里是摘要行 id;归档内统一翻译成消息行索引。
    final fileIndexOf = <int, int>{
      for (final (index, message) in messages.indexed)
        if (message.id != null) message.id!: index,
    };
    Stream<List<int>> messageLines() async* {
      for (final (index, message) in messages.indexed) {
        if (isCancelled?.call() ?? false) {
          throw const SessionExportCancelled();
        }
        final line = utf8.encode(
          '${jsonEncode(_messageJson(message, fileIndexOf, partial: partial))}\n',
        );
        // 与导入端单行上限同源:超限的归档导出后必然导入失败,这里提前
        // 明确报错,而不是交付一份坏档。
        if (line.length > SessionArchiveLimits.maxMessageLineBytes) {
          throw FormatException(
            '第 ${index + 1} 条消息超过 '
            '${SessionArchiveLimits.maxMessageLineBytes ~/ (1024 * 1024)}MiB 上限,无法导出',
          );
        }
        yield line;
        onProgress?.call(index + 1, messages.length);
      }
    }

    await writer.addStream('messages.ndjson', messageLines());
    for (final hash in assetHashes) {
      if (isCancelled?.call() ?? false) throw const SessionExportCancelled();
      final file = db.images.fileFor(hash);
      final size = await file.length();
      if (size <= 0 || size > ImageAssetStore.maxOriginalBytes) {
        throw FormatException('导出图片大小无效:$hash ($size)');
      }
      await writer.addStream('assets/$hash', file.openRead(), size: size);
    }
  }

  static String? _validAssetHash(String? hash, String label) {
    if (hash == null || hash.isEmpty) return null;
    if (!ImageAssetStore.isValidHash(hash)) {
      throw FormatException('$label引用不是有效的 SHA-256:$hash');
    }
    return hash;
  }

  static Map<String, Object?> _sessionJson(Session session) => {
    'id': session.id,
    'title': session.title,
    'characterId': session.characterId,
    'createdAt': session.createdAt.toIso8601String(),
    'usage': {
      'inputTokens': session.inputTokens,
      'outputTokens': session.outputTokens,
      'cachedInputTokens': session.cachedInputTokens,
      'backgroundInputTokens': session.backgroundInputTokens,
      'backgroundOutputTokens': session.backgroundOutputTokens,
      'backgroundCachedInputTokens': session.backgroundCachedInputTokens,
      'compactInputTokens': session.compactInputTokens,
      'compactOutputTokens': session.compactOutputTokens,
      'compactCachedInputTokens': session.compactCachedInputTokens,
    },
  };

  static Map<String, Object?> _messageJson(
    Message message,
    Map<int, int> fileIndexOf, {
    required bool partial,
  }) => {
    'role': message.role,
    'content': message.content,
    'seq': message.seq,
    // 部分导出没有摘要行,清空折叠标记,避免导入后消息被上下文组装跳过。
    'isCompacted': partial ? false : message.isCompacted,
    if (!partial &&
        message.compactOf != null &&
        fileIndexOf[message.compactOf] != null)
      'compactOf': fileIndexOf[message.compactOf],
    if (message.hasImage) 'imageHash': message.imageHash,
    if (message.imageUrl != null) 'imageUrl': message.imageUrl,
    if (message.imagePrompt != null) 'imagePrompt': message.imagePrompt,
    if (message.kind != MessageKind.chat) 'kind': message.kind.wire,
    if (message.refId != null) 'refId': message.refId,
  };
}
