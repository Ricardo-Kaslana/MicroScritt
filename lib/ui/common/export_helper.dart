/// 导出落盘通道:桌面 `file_picker` 直写,移动端临时文件 + 系统另存为。
///
/// 导出内容不做加密 —— 配置快照含明文 API Key,角色卡/会话可能含图片,
/// 保存位置由用户选择;临时文件在成功/取消/异常时立即清理,异常退出遗留的
/// 目录一天后回收。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 把导出 JSON 存到用户选择的位置。用户取消返回 false;成功/失败均有 SnackBar 反馈。
/// 平台差异与移动端临时文件通道见 [saveBytesFile]。
///
/// UTF-8 编码在这里完成,调用方只给字符串;含 API Key 的配置快照也走这条路,
/// 失败提示只回显系统异常文本,不回显文件内容。
Future<bool> saveJsonFile(BuildContext context, {required String fileName, required String content}) async {
  return saveBytesFile(
    context,
    fileName: fileName,
    bytes: utf8.encode(content),
    allowedExtensions: const ['json'],
  );
}

/// 把二进制字节存到用户选择的位置(JSON 之外的原始字节:图片下载等)。
/// 用户取消返回 false;成功/失败均有 SnackBar 反馈。
///
/// 移动端先写临时文件、再交给 `flutter_file_dialog` 由原生按流复制:file_picker
/// 的字节参数会把整份数据再复制一次过 MethodChannel,20MB 级角色卡导出在低端
/// 机上容易 OOM/失败;临时文件路径只传字符串,内存峰值低得多(与大会话归档
/// 导出同一套通道)。桌面端仍用 file_picker 的 bytes 直写。
Future<bool> saveBytesFile(
  BuildContext context, {
  required String fileName,
  required Uint8List bytes,
  List<String> allowedExtensions = const [],
}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return _saveOnMobile(
      context,
      fileName: fileName,
      bytes: bytes,
      allowedExtensions: allowedExtensions,
    );
  }
  try {
    final path = await FilePicker.saveFile(
      dialogTitle: '导出到文件',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
    if (path == null) return false; // 用户取消
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导出:$path')));
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败:$e')));
    }
    return false;
  }
}

/// 移动端落盘:临时文件 + 系统「另存为」。目录带时间戳,避免同名并发互相覆盖;
/// 无论成功/取消/异常都清掉临时目录(原生侧返回时已把内容流式复制到目标)。
Future<bool> _saveOnMobile(
  BuildContext context, {
  required String fileName,
  required Uint8List bytes,
  required List<String> allowedExtensions,
}) async {
  Directory? tempDir;
  try {
    final base = await getTemporaryDirectory();
    final root = Directory(p.join(base.path, 'exports'));
    await root.create(recursive: true);
    await _purgeOldExports(root);
    tempDir = Directory(
      p.join(root.path, DateTime.now().microsecondsSinceEpoch.toString()),
    );
    await tempDir.create(recursive: true);
    final safeName = _safeFileName(fileName);
    final file = File(p.join(tempDir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    final savedPath = await FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: file.path,
        fileName: safeName,
        mimeTypesFilter: _mimeTypesFor(allowedExtensions),
      ),
    );
    if (savedPath == null) {
      if (context.mounted) _toast(context, '已取消保存');
      return false;
    }
    if (context.mounted) _toast(context, '已保存到本地');
    return true;
  } catch (e) {
    if (context.mounted) _toast(context, '导出失败:$e');
    return false;
  } finally {
    try {
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // 临时目录清理失败不影响导出结果,交给系统清理。
    }
  }
}

/// 清理一天前异常退出遗留的临时导出目录(可能是含 API Key 的配置快照),
/// 正常路径已在 finally 里删除本次目录。
Future<void> _purgeOldExports(Directory root) async {
  final now = DateTime.now();
  try {
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final stat = await entity.stat();
      if (now.difference(stat.modified) > const Duration(days: 1)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // 忽略单个目录清理失败。
        }
      }
    }
  } catch (_) {
    // 清理只是卫生工作,失败不影响本次导出。
  }
}

// 文件名可能来自角色名/会话标题,含系统保留字符时另存为会失败,统一替换掉。
String _safeFileName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

// 扩展名 -> MIME 只覆盖导出会用到的格式;映射不到时不传过滤器,
// 让原生对话框自行判断,而不是拒绝对话框打开。
const Map<String, String> _mimeByExtension = {
  'json': 'application/json',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
};

List<String>? _mimeTypesFor(List<String> extensions) {
  final mimes = <String>{
    for (final ext in extensions)
      if (_mimeByExtension[ext.toLowerCase()] != null)
        _mimeByExtension[ext.toLowerCase()]!,
  };
  return mimes.isEmpty ? null : mimes.toList();
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
