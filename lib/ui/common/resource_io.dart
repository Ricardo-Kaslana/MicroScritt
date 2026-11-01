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
  final bytes = await pickedFileBytes(picked?.files.single);
  if (bytes == null) return;
  try {
    final result = await importer(bytes);
    onImported();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // 导入往往紧跟一次导出/其它提示;直接清掉旧 SnackBar,别让结果排队等 4 秒。
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(
        result.skipped == 0
            ? '已导入 ${result.imported} 项$label'
            : '已导入 ${result.imported} 项$label,跳过 ${result.skipped} 项(同名)',
      ),
    ));
  } on FormatException catch (e) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('导入失败:${e.message}')));
  } catch (e) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('导入失败:$e')));
  }
}
