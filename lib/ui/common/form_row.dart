/// 设置表单的行与分隔线:左侧标签说明,右侧控件。
///
/// 桌面设置卡与用户资料卡共用;内容宽 ≥ [SettingsFormRow.stackBreakpoint] 时
/// 横向排布,否则控件折到说明下方。
library;

import 'package:flutter/material.dart';

/// 设置卡里的一行:左标签说明 + 右控件。
///
/// 开关、下拉这类小控件传 `stackBreakpoint: 0`,任何桌面宽度都保持右侧对齐;
/// 只有分段选择、输入框与滑块在窄桌面改为上下,避免控件被挤压。
class SettingsFormRow extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? description;
  final Widget? titleTrailing;
  final Widget control;
  final double stackBreakpoint;
  final EdgeInsetsGeometry padding;

  const SettingsFormRow({
    super.key,
    this.icon,
    required this.title,
    this.description,
    this.titleTrailing,
    required this.control,
    this.stackBreakpoint = 720,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (titleTrailing != null) ...[
              const SizedBox(width: 2),
              titleTrailing!,
            ],
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: 3),
          Text(
            description!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            stackBreakpoint > 0 && constraints.maxWidth < stackBreakpoint;
        return Padding(
          padding: padding,
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label,
                    const SizedBox(height: 12),
                    control,
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 24),
                    control,
                  ],
                ),
        );
      },
    );
  }
}

/// 设置卡内行间的 hairline 分隔线。
class SettingsFormDivider extends StatelessWidget {
  const SettingsFormDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Divider(
      height: 0.5,
      thickness: 0.5,
      indent: 20,
      endIndent: 20,
      color: scheme.outlineVariant.withValues(alpha: 0.6),
    );
  }
}
