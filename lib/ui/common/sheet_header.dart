/// 底部弹层标题行:
/// - [SheetHeader]:编辑/列表类底单的把手行 + 标题 + 行内动作 + 文字关闭;
/// - [ChatSheetHeader]:聊天输入区底单的主色图标 + 标题 + 叉号关闭
///   (把手由 `showDragHandle` 绘制)。
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

/// 聊天输入区底单的标题行:主色图标 + 标题 + 叉号关闭。
///
/// 模型选择、推理等级与上下文用量三个底单共用,保证标题字号、关闭入口与
/// 内边距一致;拖动把手统一由 `showDragHandle` 提供,这里不再自绘。
class ChatSheetHeader extends StatelessWidget {
  final IconData icon;
  final String title;

  const ChatSheetHeader({
    super.key,
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
