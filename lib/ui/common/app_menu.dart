import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 统一的菜单动作项模型:三点菜单([AppPopupMenuButton])与底部操作弹层
/// ([showAppActionSheet])共用同一份数据,页面层只声明动作、不关心排版。
///
/// [subtitle] 仅在底部弹层渲染(三点菜单空间有限不显示);[destructive]
/// 为真时图标与文字统一渲染 `scheme.error` 红,与 iOS 危险动作惯例一致。
class MenuAction<T> {
  final T value;
  final String label;
  final IconData icon;
  final String? subtitle;
  final bool destructive;

  const MenuAction({
    required this.value,
    required this.label,
    required this.icon,
    this.subtitle,
    this.destructive = false,
  });
}

/// 三点菜单按钮:内部仍是真 `PopupMenuButton`,外观(圆角/描边/项文字)由
/// 全局 `popupMenuTheme` 统一,这里负责把 [MenuAction] 映射成一致的
/// 「图标 + 12 间距 + 文字」排版与危险项红色。
class AppPopupMenuButton<T> extends StatelessWidget {
  final List<MenuAction<T>> actions;
  final ValueChanged<T> onSelected;
  final String? tooltip;
  final IconData icon;
  final double? iconSize;
  final Color? iconColor;
  final EdgeInsetsGeometry padding;

  const AppPopupMenuButton({
    super.key,
    required this.actions,
    required this.onSelected,
    this.tooltip,
    this.icon = Icons.more_vert,
    this.iconSize,
    this.iconColor,
    this.padding = const EdgeInsets.all(8),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      icon: Icon(icon, size: iconSize, color: iconColor),
      padding: padding,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final a in actions)
          PopupMenuItem<T>(
            value: a.value,
            child: Row(
              children: [
                Icon(a.icon, size: 20, color: a.destructive ? scheme.error : null),
                const SizedBox(width: AppSpacing.md),
                Flexible(
                  child: Text(
                    a.label,
                    overflow: TextOverflow.ellipsis,
                    style: a.destructive ? TextStyle(color: scheme.error) : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 底部操作菜单弹层:与三点菜单共用 [MenuAction],每项一行
/// (图标 + 标题 + 可选副标题),项间 hairline 分隔(GroupCard 同款约定)。
///
/// 返回值驱动:点选条目返回对应 `value`,点遮罩关闭返回 `null`,调用方
/// 用外层 context 继续后续动作,无需处理弹层内 `sheetContext`。
Future<T?> showAppActionSheet<T>(
  BuildContext context, {
  required List<MenuAction<T>> actions,
}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, a) in actions.indexed) ...[
              if (i > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  indent: 16,
                  endIndent: 16,
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ListTile(
                leading: Icon(a.icon, color: a.destructive ? scheme.error : null),
                title: Text(a.label, style: a.destructive ? TextStyle(color: scheme.error) : null),
                subtitle: a.subtitle == null ? null : Text(a.subtitle!),
                onTap: () => Navigator.pop(sheetContext, a.value),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    ),
  );
}
