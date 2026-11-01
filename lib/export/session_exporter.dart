/// 会话归档导出入口:整串导出(测试/小会话)与流式写文件(UI)两条路径。
///
/// 归档结构与流式内存约束见 [SessionArchiveWriter];本类只负责入口转发。
library;

import 'dart:io';

import '../data/database.dart';
import 'session_archive_writer.dart';

/// 会话导出入口。归档结构为 version 4 的自明 JSON(结构说明见
/// [SessionArchiveWriter]):会话元数据/token 用量、角色卡(含头像补回与
/// 世界书随卡)、全部消息(含图片、生图原始描述、压缩标记与附件行
/// kind/refId)、会话级状态(变量/变量权限/记忆)。
///
/// [export] 会把整份归档拼成一个字符串,仅适合测试或小会话;UI 一律走
/// [exportToFile] —— 逐条消息分块写文件,几百 MB 的图片历史也不会 OOM。
class SessionExporter {
  final AppDatabase db;
  SessionExporter(this.db);

  /// 整串导出;大会话会整份驻留内存,生产路径请用 [exportToFile]。
  Future<String> export({required int sessionId}) =>
      SessionArchiveWriter(db).exportString(sessionId: sessionId);

  /// 流式写文件;失败或取消时删除半成品,不留截断归档。
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
