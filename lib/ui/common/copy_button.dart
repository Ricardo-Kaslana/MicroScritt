/// 剪贴板写入与文本框旁的一键复制按钮。
///
/// 复制内容取 [TextEditingController] 的当前值,空白内容不写入剪贴板,
/// 避免用空串覆盖用户已有内容。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 把 [text] 写入剪贴板;空白内容不写入并返回 false。
///
/// 返回值供调用方决定是否给成功反馈(对勾/提示),失败不抛异常。
Future<bool> copyTextToClipboard(String text) async {
  if (text.trim().isEmpty) return false;
  await Clipboard.setData(ClipboardData(text: text));
  return true;
}

/// 文本框标题旁的一键复制按钮:复制时直接读控制器当前文本,不缓存副本;
/// 监听内容只为驱动置灰与提示,无内容时按钮不可点,复制成功后短暂变对勾。
class CopyTextButton extends StatefulWidget {
  final TextEditingController controller;
  final String tooltip;

  const CopyTextButton({
    super.key,
    required this.controller,
    this.tooltip = '复制文本',
  });

  @override
  State<CopyTextButton> createState() => _CopyTextButtonState();
}

class _CopyTextButtonState extends State<CopyTextButton> {
  static const _feedbackDuration = Duration(milliseconds: 1200);

  Timer? _resetTimer;
  bool _copied = false;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    if (!await copyTextToClipboard(widget.controller.text)) return;
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(_feedbackDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final hasText = value.text.trim().isNotEmpty;
        final tooltip = _copied
            ? '已复制'
            : hasText
            ? widget.tooltip
            : '没有可复制的内容';
        return IconButton(
          tooltip: tooltip,
          icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded),
          color: _copied ? scheme.primary : null,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          onPressed: hasText ? _copy : null,
        );
      },
    );
  }
}
