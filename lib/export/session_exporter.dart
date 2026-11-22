/// 会话归档导出入口:小会话字节导出与流式写文件两条路径。
///
/// 默认格式为 version 5 ZIP STORE `.msarc`;结构见 [SessionArchiveWriter]。
library;

import 'dart:io';
import 'dart:typed_data';

import '../data/database.dart';
import 'session_archive_writer.dart';

/// 会话导出入口。
///
/// [export] 会把整份 ZIP 拼成字节,仅适合测试或小会话;UI 一律走
/// [exportToFile],由现有交付层负责桌面原子替换与移动端保存/分享。
class SessionExporter {
  final AppDatabase db;
  SessionExporter(this.db);

  /// 整包字节导出;大会话会整份驻留内存,生产路径请用 [exportToFile]。
  Future<Uint8List> export({
    required int sessionId,
    Set<int>? messageIds,
  }) => SessionArchiveWriter(db).exportBytes(
    sessionId: sessionId,
    messageIds: messageIds,
  );

  /// 流式写文件;失败或取消时删除半成品,不留截断归档。
  Future<File> exportToFile({
    required int sessionId,
    required File file,
    Set<int>? messageIds,
    SessionExportProgress? onProgress,
    bool Function()? isCancelled,
  }) => SessionArchiveWriter(db).exportToFile(
    sessionId: sessionId,
    file: file,
    messageIds: messageIds,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}
