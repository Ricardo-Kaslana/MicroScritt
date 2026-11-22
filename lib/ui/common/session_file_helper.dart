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
import 'app_snack_bar.dart';
import 'export_helper.dart';
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
    showAppSnack(context, '已取消导出');
    return false;
  } catch (e) {
    showAppSnack(context, '导出失败:$e');
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
  final staging = File(p.join(dir.path, sanitizeExportFileName(fileName)));  if (!context.mounted) return null;

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
        mimeTypesFilter: const ['application/zip'],
      ),
    );
    if (savedPath == null) {
      if (context.mounted) showAppSnack(context, '已取消保存');
      return false;
    }
    if (context.mounted) showAppSnack(context, '已保存到本地');
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
      files: [XFile(file.path, mimeType: 'application/zip')],
      fileNameOverrides: [sanitizeExportFileName(fileName)],
      sharePositionOrigin: origin,
    ),
  );
  if (context.mounted) showAppSnack(context, '已打开分享面板');
  return true;
}

Future<bool> _saveOnDesktop(
  BuildContext context, {
  required String fileName,
  required SessionArchiveBuilder build,
}) async {
  final path = await FilePicker.saveFile(
    dialogTitle: '导出到文件',
    fileName: sanitizeExportFileName(fileName),
    type: FileType.custom,
    allowedExtensions: const ['msarc'],
    // 桌面端 bytes 为空时插件只返回路径、不写文件;内容由下面流式写入。
    bytes: null,
  );
  if (path == null) return false;
  // 先写目标同目录的 .part 再替换:失败/取消不会留下截断文件,也不必在小
  // 文件系统上多拷一遍(几百 MB 的归档)。
  final staging = File('$path.part');
  if (!context.mounted) return false;
  var keepStaging = false;
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
        await _replaceWithBackup(
          staging,
          path,
          preserveStaging: () => keepStaging = true,
        );
        return staging;
      },
    );
  } finally {
    // 回滚失败时 helper 会置 preserveStaging,staging 与旧 .bak 至少保留
    // 一份;其余路径(成功/取消/普通失败)只清理本次暂存文件。
    if (!keepStaging) {
      try {
        if (await staging.exists()) await staging.delete();
      } catch (_) {}
    }
  }
  if (context.mounted) showAppSnack(context, '已导出:$path');
  return true;
}

/// 用 staging 替换目标文件:旧目标先 rename 成 `.bak`,staging 成功后再删
/// `.bak`;staging rename 失败时回滚旧文件。绝不先删旧目标 —— 旧文件已删、
/// staging 又被 finally 清掉会让用户同时失去新旧两份数据。
Future<void> _replaceWithBackup(
  File staging,
  String path, {
  required void Function() preserveStaging,
}) async {
  final target = File(path);
  final backup = File('$path.bak');
  // 上次中断可能留下 .bak:目标还在说明它是陈旧备份,目标缺失则先恢复旧档。
  if (await backup.exists()) {
    if (await target.exists()) {
      await backup.delete();
    } else {
      await backup.rename(path);
    }
  }
  final hadTarget = await target.exists();
  if (hadTarget) {
    await target.rename(backup.path);
  }
  try {
    await staging.rename(path);
  } catch (error, stack) {
    var restored = false;
    if (hadTarget) {
      try {
        if (await backup.exists()) {
          await backup.rename(path);
          restored = true;
        }
      } catch (_) {}
    }
    // 旧文件恢复失败或本来就没有旧文件:保留 staging,连同 .bak(若有)
    // 一起留给用户手工恢复,不能只清理暂存。
    if (!restored) preserveStaging();
    Error.throwWithStackTrace(error, stack);
  }
  if (hadTarget) {
    // 陈旧备份清理失败不影响导出结果,下次导出会再尝试。
    try {
      if (await backup.exists()) await backup.delete();
    } catch (_) {}
  }
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
