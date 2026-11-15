/// 管理列表的通用条目行:前缀图标、标题/副标题、行尾删除与启用开关。
///
/// 技能、Hooks、提示词、正则、生图插件与世界书六处曾各自拼一份相同的
/// `ListTile + IconButton + Switch`,这里统一版式与命中区,避免行为漂移。
library;

import 'package:flutter/material.dart';

/// 带删除与启停的管理条目行。
///
/// - [enabled]/[onToggle] 同时非空时在行尾渲染开关;
/// - [onDelete] 非空时渲染删除键,[deleteEnabled] 控制内置条目等不可删场景
///   (置灰但仍显示,用户能理解为什么不能删);
/// - [extra] 放在删除键之前,供"设为当前使用"等单行附加动作使用。
class ToggleDeleteTile extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final TextStyle? subtitleStyle;
  final VoidCallback? onTap;
  final bool? enabled;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onDelete;
  final bool deleteEnabled;
  final String deleteTooltip;
  final IconData deleteIcon;
  final Widget? extra;

  const ToggleDeleteTile({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.subtitleStyle,
    this.onTap,
    this.enabled,
    this.onToggle,
    this.onDelete,
    this.deleteEnabled = true,
    this.deleteTooltip = '删除',
    this.deleteIcon = Icons.delete_outline,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: subtitleStyle,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (extra != null) extra!,
          if (onDelete != null)
            IconButton(
              tooltip: deleteTooltip,
              icon: Icon(deleteIcon),
              onPressed: deleteEnabled ? onDelete : null,
            ),
          if (enabled != null) Switch(value: enabled!, onChanged: onToggle),
        ],
      ),
      onTap: onTap,
    );
  }
}
