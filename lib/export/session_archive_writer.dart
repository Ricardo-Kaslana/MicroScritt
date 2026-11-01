/// 会话归档 writer:按 version 4 结构逐条流式写出会话 JSON。
///
/// 图片按 1MB 分块从 SQLite 读出、就地转义写入 sink(峰值内存≈一条消息),
/// 不把整会话的图片拼成一个大字符串;[exportToFile] 失败或取消时删除
/// 半成品文件。
library;

import 'dart:convert';
import 'dart:io';

import '../data/character_repository.dart';
import '../data/database.dart';
import '../data/memory_repository.dart';
import '../data/message_repository.dart';
import '../data/session_repository.dart';
import '../data/variable_repository.dart';
import '../data/worldbook_repository.dart';
import '../models/message.dart';
import '../models/worldbook_entry.dart';
import 'character_card_exporter.dart';

/// 导出进度回调:`done` 为已写消息条数,`total` 为归档内消息总数。
typedef SessionExportProgress = void Function(int done, int total);

/// 导出被用户取消(UI 按「已取消」提示,不当作错误)。
class SessionExportCancelled implements Exception {
  const SessionExportCancelled();
}

/// 会话归档 writer:归档是 version 4 的自明 JSON,逐条消息写出。
///
/// 消息图片不先汇总成整会话字符串,而是按 1MB 分块从 SQLite 读出、分块
/// 转义写入 [StringSink](峰值内存≈一条消息);[exportString] 仅用于
/// 测试/小会话,UI 一律走 [exportToFile]。
///
/// 归档字段:`version` / `session` / `character`(含世界书)/
/// `characterBackgroundBase64` / `messages`(compactOf 翻译为数组内索引、
/// 图片与 imageUrl、imagePrompt、附件行 kind/refId)/ `variables` /
/// `variableAccess` / `memory`(取最新一条)。
class SessionArchiveWriter {
  final AppDatabase db;
  SessionArchiveWriter(this.db);

  /// 每写约 8MB 主动 flush 一次,避免 IOSink 内部缓冲堆积。
  static const int _drainThreshold = 8 * 1024 * 1024;

  /// 把整份归档拼成字符串;只适合测试或小会话,大图历史会整份驻留内存。
  Future<String> exportString({required int sessionId}) async {
    final buffer = StringBuffer();
    await exportToSink(sessionId: sessionId, sink: buffer);
    return buffer.toString();
  }

  /// 流式写入文件;失败或取消时删除半成品,不留截断归档。
  ///
  /// 桌面端 UI 传目标同目录的 `.part` 暂存路径,成功后自行 rename 到目标
  /// 文件 —— 目标位置永远不会出现写了一半的归档。移动端 UI 先写临时文件,
  /// 再交系统「保存到本地」或分享面板(原生侧按流复制)。`onProgress` 按
  /// 消息条数回调,`isCancelled` 在每条消息前检查,取消抛
  /// [SessionExportCancelled]。
  Future<File> exportToFile({
    required int sessionId,
    required File file,
    SessionExportProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    var ok = false;
    try {
      await exportToSink(
        sessionId: sessionId,
        sink: sink,
        onProgress: onProgress,
        isCancelled: isCancelled,
        drain: sink.flush,
      );
      await sink.flush();
      ok = true;
      return file;
    } finally {
      await sink.close();
      if (!ok) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  /// 流式写出整个归档到 [sink];[drain] 在累计约 8MB 时调用一次,供文件
  /// sink 主动 flush。会话缺失时省略 `session` 键,角色卡按空处理,不抛错
  /// (导出端不因单条坏数据中断;是否可导入由导入端校验决定)。
  ///
  /// 单条消息的图片按 1MB 分块读取并转义,内存峰值只与一条消息的图片
  /// 大小相关;`isCancelled` 在每条消息前检查,为真时抛
  /// [SessionExportCancelled],已写内容由调用方按失败处理。
  Future<void> exportToSink({
    required int sessionId,
    required StringSink sink,
    SessionExportProgress? onProgress,
    bool Function()? isCancelled,
    Future<void> Function()? drain,
  }) async {
    final session = await SessionRepository(db).get(sessionId);
    final (character, worldbook, messages, variables, memories) = await (
      session == null
          ? Future.value(null)
          : CharacterRepository(db).get(session.characterId),
      session == null
          ? Future.value(const <WorldbookEntry>[])
          : WorldbookRepository(db).byCharacter(session.characterId),
      // 轻量投影:只取 has_image 标志,图片逐条分块读取。
      MessageRepository(db).bySession(sessionId),
      VariableRepository(db).snapshot(sessionId),
      MemoryRepository(db).bySession(sessionId),
    ).wait;

    // compact_of 在库里是"摘要行 id"语义;归档里翻译为消息数组内索引。
    final fileIndexOf = <int, int>{for (final (i, m) in messages.indexed) if (m.id != null) m.id!: i};

    sink.write('{"version":4');
    if (session != null) {
      sink.write(',"session":');
      sink.write(jsonEncode(_sessionJson(session)));
    }
    sink.write(',"character":');
    sink.write(jsonEncode(
      character == null ? const <String, dynamic>{} : CharacterCardExporter.exportJson(character, worldbook: worldbook),
    ));
    if (character?.backgroundBase64 != null) {
      sink.write(',"characterBackgroundBase64":');
      sink.write(jsonEncode(character!.backgroundBase64));
    }
    sink.write(',"messages":[');

    final repo = MessageRepository(db);
    var sinceDrain = 0;
    for (final (i, message) in messages.indexed) {
      if (isCancelled?.call() ?? false) throw const SessionExportCancelled();
      if (i > 0) sink.write(',');
      sinceDrain += await _writeMessage(sink, message, fileIndexOf, repo);
      onProgress?.call(i + 1, messages.length);
      if (drain != null && sinceDrain >= _drainThreshold) {
        await drain();
        sinceDrain = 0;
      }
    }

    sink.write('],"variables":');
    sink.write(jsonEncode(variables.values));
    // v66 起变量的三档后台权限随档导出;可选键,旧导入端忽略、旧档缺失
    // 由导入端回落 protected。
    sink.write(',"variableAccess":');
    sink.write(jsonEncode({
      for (final entry in variables.access.entries) entry.key: entry.value.name,
    }));
    sink.write(',"memory":');
    sink.write(jsonEncode(memories.isEmpty ? null : memories.last.content));
    sink.write('}');
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

  /// 按原归档字段顺序写一条消息,返回写入字符数(用于 flush 节流)。
  /// 图片块逐个 `jsonEncode` 后去掉外层引号写入 —— base64 全为 ASCII,
  /// 分块转义与整串转义结果逐字节一致。
  static Future<int> _writeMessage(
    StringSink sink,
    Message message,
    Map<int, int> fileIndexOf,
    MessageRepository repo,
  ) async {
    var written = 0;
    void write(String text) {
      sink.write(text);
      written += text.length;
    }

    write('{"role":');
    write(jsonEncode(message.role));
    write(',"content":');
    write(jsonEncode(message.content));
    write(',"seq":');
    write(jsonEncode(message.seq));
    write(',"isCompacted":');
    write(jsonEncode(message.isCompacted));
    final compactIndex = message.compactOf == null ? null : fileIndexOf[message.compactOf];
    if (compactIndex != null) {
      write(',"compactOf":');
      write(jsonEncode(compactIndex));
    }
    final id = message.id;
    if (message.hasImage && id != null) {
      write(',"imageBase64":"');
      await for (final chunk in repo.imageBase64Chunks(id)) {
        final encoded = jsonEncode(chunk);
        write(encoded.substring(1, encoded.length - 1));
      }
      write('"');
    }
    if (message.imageUrl != null) {
      write(',"imageUrl":');
      write(jsonEncode(message.imageUrl));
    }
    // 生图原始描述:图片重新生成的依据。可选键,旧导入端忽略、旧档缺失为 null。
    if (message.imagePrompt != null) {
      write(',"imagePrompt":');
      write(jsonEncode(message.imagePrompt));
    }
    if (message.kind != MessageKind.chat) {
      write(',"kind":');
      write(jsonEncode(message.kind.wire));
    }
    if (message.refId != null) {
      write(',"refId":');
      write(jsonEncode(message.refId));
    }
    write('}');
    return written;
  }
}
