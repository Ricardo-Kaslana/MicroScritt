import 'dart:io';

import '../data/database.dart';
import 'session_archive_writer.dart';

/// 会话导出入口。归档结构仍是 version 4 的自明 JSON(结构说明见
/// [SessionArchiveWriter]):会话元数据/token 用量、角色卡(含头像补回与
/// 世界书随卡、生图原始描述)、全部消息(含图片、压缩标记与附件行 kind/refId)、
/// 会话级状态(变量/记忆)。
///
/// [export] 会把整份归档拼成一个字符串,仅适合测试或小会话;UI 一律走
/// [exportToFile] —— 逐条消息分块写文件,几百 MB 的图片历史也不会 OOM。
class SessionExporter {
  final AppDatabase db;
  SessionExporter(this.db);

  Future<String> export({required int sessionId}) =>
      SessionArchiveWriter(db).exportString(sessionId: sessionId);

  Future<File> exportToFile({
    required int sessionId,
    required File file,
    SessionExportProgress? onProgress,
    bool Function()? isCancelled,
  }) => SessionArchiveWriter(db).exportToFile(
    sessionId: sessionId,
    file: file,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}
