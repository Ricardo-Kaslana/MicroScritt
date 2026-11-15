/// 大会话归档的保存与分享通道。
///
/// 归档含完整对话、变量与图片,体积可达数百 MB:移动端先流式写临时文件,再
/// 按 [SessionArchiveDelivery] 交给系统另存为或分享面板;桌面端写同目录
/// `.part` 后原子替换,失败不留截断的目标文件。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../export/session_archive_writer.dart';
import 'chat_layout.dart';
import 'progress_task.dart';

/// 归档写入回调:把归档流式写到 [staging] 文件,支持取消。
typedef SessionArchiveBuilder =
    Future<File> Function(
      File staging, {
      void Function(int done, int total)? onProgress,
      bool Function()? isCancelled,
    });

/// 仅测试用:桌面测试宿主上没有移动端平台,用它覆盖保存/分享分支。
@visibleForTesting
bool? debugMobileSessionExportOverride;

/// 归档是否走移动端通道;会话菜单据此决定是否显示「分享」。
bool get isMobileSessionExport =>
    debugMobileSessionExportOverride ?? (Platform.isAndroid || Platform.isIOS);

/// 归档交付方式:保存到用户选择的位置,或交给系统分享面板(仅移动端)。
enum SessionArchiveDelivery { save, share }

/// 大会话归档的落盘通道:
/// - Android/iOS:先流式写临时文件,再按 [delivery] 交系统另存为(原生按流
///   复制)或系统分享面板;
/// - 桌面:`saveFile(bytes: null)` 只返回用户选择的路径(不写文件),归档
///   流式写到同目录 `.part` 后再 rename 替换,失败不会留下截断的目标文件。
///   分享面板只在移动端提供,桌面端显式请求分享时回落到保存。
///
/// 返回 false 表示用户取消或失败(已有 SnackBar 反馈)。
///
/// 「分享」会把整份归档交给用户选择的目标应用,内容不做脱敏;分享分支的
/// 临时档要留到接收方读完才可清理,因此不随函数返回删除。
Future<bool> saveSessionArchive(
  BuildContext context, {
  required String fileName,
  required SessionArchiveBuilder build,
  SessionArchiveDelivery delivery = SessionArchiveDelivery.save,
}) async {
  try {
    if (isMobileSessionExport) {
      return delivery == SessionArchiveDelivery.share
          ? await _shareOnMobile(context, fileName: fileName, build: build)
          : await _saveOnMobile(context, fileName: fileName, build: build);
    }
    return await _saveOnDesktop(context, fileName: fileName, build: build);
  } on SessionExportCancelled {
    _toast(context, '已取消导出');
    return false;
  } catch (e) {
    _toast(context, '导出失败:$e');
    return false;
  }
}

Future<File?> _exportToStaging(
  BuildContext context, {
  required String fileName,
  required SessionArchiveBuilder build,
  required String readyMessage,
}) async {
  final dir = Directory(
    p.join((await getTemporaryDirectory()).path, 'exports'),
  );
  await dir.create(recursive: true);
  await _purgeOldExports(dir);
  final staging = File(p.join(dir.path, _safeName(fileName)));
  if (!context.mounted) return null;

  return runWithProgress(
    context,
    title: '正在导出会话',
    task: (controller) async {
      controller.report(value: 0, message: '准备导出…');
      final result = await build(
        staging,
        onProgress: (done, total) => controller.report(
          value: total == 0 ? null : done / total,
          message: '已写入 $done / $total 条消息',
        ),
        isCancelled: () => controller.cancelled,
      );
      controller.report(value: 1, message: readyMessage);
      return result;
    },
  );
}

Future<bool> _saveOnMobile(
  BuildContext context, {
  required String fileName,
  required SessionArchiveBuilder build,
}) async {
  final file = await _exportToStaging(
    context,
    fileName: fileName,
    build: build,
    readyMessage: '选择保存位置…',
  );
  if (file == null) return false;
  try {
    final savedPath = await FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: file.path,
        mimeTypesFilter: const ['application/json'],
      ),
    );
    if (savedPath == null) {
      if (context.mounted) _toast(context, '已取消保存');
      return false;
    }
    if (context.mounted) _toast(context, '已保存到本地');
    return true;
  } finally {
    // 原生侧按流复制,返回时目标文件已写完,临时档不再需要。
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

Future<bool> _shareOnMobile(
  BuildContext context, {
  required String fileName,
  required SessionArchiveBuilder build,
}) async {
  final file = await _exportToStaging(
    context,
    fileName: fileName,
    build: build,
    readyMessage: '打开分享面板…',
  );
  if (file == null) return false;
  if (!context.mounted) return true;
  // 分享的临时档不在返回后删除:接收方可能稍后才读,交给一天后的清扫回收。
  final box = context.findRenderObject();
  final origin = box is RenderBox
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'application/json')],
      fileNameOverrides: [fileName],
      sharePositionOrigin: origin,
    ),
  );
  if (context.mounted) _toast(context, '已打开分享面板');
  return true;
}

Future<bool> _saveOnDesktop(
  BuildContext context, {
  required String fileName,
  required SessionArchiveBuilder build,
}) async {
  final path = await FilePicker.saveFile(
    dialogTitle: '导出到文件',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['json'],
    // 桌面端 bytes 为空时插件只返回路径、不写文件;内容由下面流式写入。
    bytes: null,
  );
  if (path == null) return false;
  // 先写目标同目录的 .part 再替换:失败/取消不会留下截断文件,也不必在小
  // 文件系统上多拷一遍(几百 MB 的归档)。
  final staging = File('$path.part');
  if (!context.mounted) return false;
  try {
    await runWithProgress(
      context,
      title: '正在导出会话',
      task: (controller) async {
        controller.report(value: 0, message: '准备导出…');
        await build(
          staging,
          onProgress: (done, total) => controller.report(
            value: total == 0 ? null : done / total,
            message: '已写入 $done / $total 条消息',
          ),
          isCancelled: () => controller.cancelled,
        );
        controller.report(value: 1, message: '写入目标文件…');
        await staging.parent.create(recursive: true);
        final target = File(path);
        if (await target.exists()) await target.delete();
        await staging.rename(path);
        return staging;
      },
    );
  } finally {
    try {
      if (await staging.exists()) await staging.delete();
    } catch (_) {}
  }
  if (context.mounted) _toast(context, '已导出:$path');
  return true;
}

/// 只清理一天前的旧导出(分享面板关闭后仍可能被接收方按需读取,不能立刻删)。
Future<void> _purgeOldExports(Directory dir) async {
  final now = DateTime.now();
  try {
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      if (now.difference(stat.modified) > const Duration(hours: 24)) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  } catch (_) {}
}

String _safeName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

void _toast(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(width: chatSnackBarWidth(context), content: Text(message)),
  );
}
