/// 说明型弹窗:标题 + 项目符号正文 + 可选的注释与脚注 + 「知道了」。
///
/// 设置页与 provider 编辑页此前各写一份相同的 AlertDialog 骨架;集中后
/// 弹窗动作、间距与按钮层级保持一致,调用方只提供文案。
library;

import 'package:flutter/material.dart';

/// 展示只读说明弹窗。
///
/// [bullets] 之间固定 6 间距;[note] 前留 10,用于与项目符号段拉开层次;
/// [footnotes] 每段前留 6,承接补充说明。确认键沿用全局 FilledButton。
Future<void> showInfoDialog(
  BuildContext context, {
  required String title,
  required List<String> bullets,
  String? note,
  List<String> footnotes = const [],
  String confirmLabel = '知道了',
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, bullet) in bullets.indexed) ...[
            if (i > 0) const SizedBox(height: 6),
            Text(bullet),
          ],
          if (note != null) ...[
            const SizedBox(height: 10),
            Text(note),
          ],
          for (final footnote in footnotes) ...[
            const SizedBox(height: 6),
            Text(footnote),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}
