import 'dart:async';

import 'package:flutter/material.dart';

/// 长任务进度对话框的控制器:进度值(0–1,可空=不确定进度)、说明文案与
/// 取消标记。[cancelled] 由任务在消息边界轮询,决定是否中止。
class ProgressController {
  final String title;
  final ValueNotifier<double?> _value = ValueNotifier<double?>(null);
  final ValueNotifier<String> _message = ValueNotifier<String>('');
  bool _cancelled = false;
  bool _disposed = false;

  ProgressController(this.title);

  bool get cancelled => _cancelled;

  void requestCancel() => _cancelled = true;

  /// [value] 为 null 表示不确定进度。每次调用都会重设进度值 —— 从"读取
  /// 35%"切换到"解析卡片…"时,进度条应回到转圈而不是僵在 35%。
  void report({double? value, String? message}) {
    if (_disposed) return;
    _value.value = value;
    if (message != null) _message.value = message;
  }

  void dispose() {
    _disposed = true;
    _value.dispose();
    _message.dispose();
  }
}

/// 显示不可取消(仅"取消"按钮置标记)的进度对话框并执行 [task]。
///
/// 任务结束后无论成功/抛错都会关闭对话框;调用方自行处理 SnackBar。
Future<T> runWithProgress<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function(ProgressController controller) task,
}) async {
  final controller = ProgressController(title);
  var dialogOpen = true;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProgressDialog(controller: controller),
  ));
  try {
    return await task(controller);
  } finally {
    if (dialogOpen && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      dialogOpen = false;
    }
    controller.dispose();
  }
}

class _ProgressDialog extends StatelessWidget {
  final ProgressController controller;
  const _ProgressDialog({required this.controller});

  @override
  Widget build(BuildContext context) {
    // 系统返回键不能把进度对话框单独弹掉 —— 否则任务结束时的 finally 会
    // 再 pop 一次,把下面的页面(角色列表等)也关掉。取消只能走按钮,
    // 由任务在阶段边界决定是否中止。
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(controller.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: controller._value,
              builder: (_, value, __) => value == null
                  ? const LinearProgressIndicator()
                  : LinearProgressIndicator(value: value),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<String>(
              valueListenable: controller._message,
              builder: (_, message, __) => Text(message),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: controller.requestCancel, child: const Text('取消')),
        ],
      ),
    );
  }
}
