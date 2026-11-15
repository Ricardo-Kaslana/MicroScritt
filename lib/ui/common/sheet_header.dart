/// 底部弹层统一标题行:拖拽把手 + 标题 + 行内动作 + 关闭。
///
/// 记忆/变量编辑、变量全量列表与回收站此前各拼一份相同版式;集中到这里
/// 后把手尺寸、标题字号与关闭入口保持一致,新增底单也不会再各写一套。
library;

import 'package:flutter/material.dart';

/// 底部弹层标题行。[actions] 渲染在关闭按钮之前(如复制、清空)。
class SheetHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final String closeLabel;

  const SheetHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.closeLabel = '关闭',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: scheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ...actions,
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(closeLabel),
        ),
      ],
    );
  }
}
