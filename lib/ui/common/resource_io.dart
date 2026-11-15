/// 资源(角色卡/世界书等)导入导出的 UI 入口:选文件 → 解析 → 落库 → 提示。
///
/// 导入的结构错误统一转成 SnackBar 文案,不向外抛;导出沿用
/// [saveJsonFile] 的保存语义。
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../import/resource_importer.dart';
import 'export_helper.dart';
import 'pick_file_bytes.dart';

/// 资源导出的统一入口(与设置页/角色卡相同的 file_picker 保存语义)。
Future<void> exportResourceFile(
  BuildContext context, {
  required String fileName,
  required String content,
}) => saveJsonFile(context, fileName: fileName, content: content);

/// 资源导入:选文件 → 解析校验 → 落库 → 失效列表 → 提示导入/跳过数。
/// 结构错误由 [importer] 抛 [FormatException],这里统一转成 SnackBar 文案。
Future<void> importResourceFile(
  BuildContext context, {
  required String label,
  required Future<ResourceImportResult> Function(Uint8List bytes) importer,
  required VoidCallback onImported,
}) async {
  final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
  // 系统文件选择器的返回键是标准取消路径,取消不是失败。
  if (picked == null) {
    if (!context.mounted) return;
    _snack(context, '已取消导入');
    return;
  }
  try {
    final bytes = await pickedFileBytes(picked.files.single);
    if (bytes == null) {
      if (!context.mounted) return;
      _snack(context, '导入失败:未读取到所选文件');
      return;
    }
    final result = await importer(bytes);
    onImported();
    if (!context.mounted) return;
    // 导入往往紧跟一次导出/其它提示;直接清掉旧 SnackBar,别让结果排队等 4 秒。
    _snack(
      context,
      result.skipped == 0
          ? '已导入 ${result.imported} 项$label'
          : '已导入 ${result.imported} 项$label,跳过 ${result.skipped} 项(同名)',
    );
  } on FormatException catch (e) {
    if (!context.mounted) return;
    _snack(context, '导入失败:${e.message}');
  } catch (e) {
    if (!context.mounted) return;
    _snack(context, '导入失败:$e');
  }
}

void _snack(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
  messenger.showSnackBar(SnackBar(content: Text(message)));
}
