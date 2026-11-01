/// 危险操作确认框:标题 + 可选正文 + 取消/确认两个按钮。
///
/// 只回传用户选择,不执行删除;关闭遮罩或取消按 false 处理,调用方拿到
/// true 后再动数据。
library;

import 'package:flutter/material.dart';

/// 危险操作确认对话框。返回 true 表示用户确认;关闭/取消返回 false。
///
/// [confirmLabel] 默认「删除」,用于文案不是删除的危险动作时显式覆盖;
/// 确认键固定用 `scheme.error` 着色,避免同一危险动作在不同页面颜色不一。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = '删除',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
