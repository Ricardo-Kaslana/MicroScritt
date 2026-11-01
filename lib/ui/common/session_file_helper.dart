import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../export/session_archive_writer.dart';
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

bool get _isMobileExport =>
    debugMobileSessionExportOverride ?? (Platform.isAndroid || Platform.isIOS);

/// 大会话归档的落盘通道:
/// - Android/iOS:先流式写临时文件,再让用户选择「保存到本地」(系统另存为
///   对话框,由原生侧按流复制)或「分享」(系统分享面板);
/// - 桌面:`saveFile(bytes: null)` 只返回用户选择的路径(不写文件),归档直接
///   流式写临时文件后复制过去,失败不会留下截断的目标文件。
///
/// 返回 false 表示用户取消或失败(已有 SnackBar 反馈)。
Future<bool> saveSessionArchive(
  BuildContext context, {
  required String fileName,
  required SessionArchiveBuilder build,
}) async {
  try {
    if (_isMobileExport) {
      final target = await _chooseMobileTarget(context);
      if (target == null || !context.mounted) return false;
      return target == _MobileExportTarget.save
          ? await _saveOnMobile(context, fileName: fileName, build: build)
          : await _shareOnMobile(context, fileName: fileName, build: build);
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

enum _MobileExportTarget { save, share }

Future<_MobileExportTarget?> _chooseMobileTarget(BuildContext context) {
  return showModalBottomSheet<_MobileExportTarget>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '导出会话',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('保存到本地'),
            subtitle: const Text('选择设备上的位置保存 JSON 归档'),
            onTap: () =>
                Navigator.of(sheetContext).pop(_MobileExportTarget.save),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('分享'),
            subtitle: const Text('发送到其他应用,或经系统分享面板转存'),
            onTap: () =>
                Navigator.of(sheetContext).pop(_MobileExportTarget.share),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
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
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
