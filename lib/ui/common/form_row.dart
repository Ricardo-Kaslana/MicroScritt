/// 设置表单的行与分隔线:左侧标签说明,右侧控件。
///
/// 桌面设置卡与用户资料卡共用;内容宽 ≥ [SettingsFormRow.stackBreakpoint] 时
/// 横向排布,否则控件折到说明下方。
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
                // 大字号下允许两行:设置项名称是理解开关/滑块的前提,
                // 单行省略会把关键区别截掉。
                maxLines: 2,
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
                  children: [label, const SizedBox(height: 12), control],
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

/// 桌面设置卡里的开关行:内置右侧 [Switch],保持小控件不折行。
///
/// `switchKey` 传给内部开关,行本身的 `key` 仍留给 [SettingsSwitchRow]。
class SettingsSwitchRow extends StatelessWidget {
  final Key? switchKey;
  final IconData? icon;
  final String title;
  final String? description;
  final Widget? titleTrailing;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry padding;

  const SettingsSwitchRow({
    super.key,
    this.switchKey,
    this.icon,
    required this.title,
    this.description,
    this.titleTrailing,
    required this.value,
    this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
  });

  @override
  Widget build(BuildContext context) {
    return SettingsFormRow(
      icon: icon,
      title: title,
      description: description,
      titleTrailing: titleTrailing,
      stackBreakpoint: 0,
      padding: padding,
      control: Switch(key: switchKey, value: value, onChanged: onChanged),
    );
  }
}

/// 设置行右侧的下拉选择:无下划线、白面圆角菜单、灰色 chevron。
///
/// 移动设置 ListTile 的 trailing 与桌面 [SettingsFormRow] 的 control 共用;
/// [dropdownKey] 透传给内部 [DropdownButton],便于测试定位。
class SettingsDropdown<T> extends StatelessWidget {
  final Key? dropdownKey;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final double menuMaxHeight;
  final TextStyle? style;

  const SettingsDropdown({
    super.key,
    this.dropdownKey,
    required this.value,
    required this.items,
    this.onChanged,
    this.menuMaxHeight = 240,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropdownButton<T>(
      key: dropdownKey,
      value: value,
      underline: const SizedBox.shrink(),
      dropdownColor: scheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.input),
      menuMaxHeight: menuMaxHeight,
      style: style ?? TextStyle(fontSize: 14, color: scheme.onSurface),
      iconSize: 20,
      iconEnabledColor: scheme.onSurfaceVariant,
      items: items,
      onChanged: onChanged,
    );
  }
}

/// 移动设置页的「标题 + 值 + 滑块」行:滑块放在 ListTile 的 subtitle 槽位。
///
/// 这是移动分组卡的紧凑基线,与桌面 [SettingsFormRow] 的右侧滑块
/// (`SettingsSliderControl`)是两种版式,不互相替换。
class SettingsSliderTile extends StatelessWidget {
  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? sliderLabel;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Key? sliderKey;

  const SettingsSliderTile({
    super.key,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.sliderLabel,
    this.enabled = true,
    this.onChanged,
    this.onChangeEnd,
    this.sliderKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      leading: const SizedBox.shrink(),
      title: Text(title),
      subtitle: Row(
        children: [
          Text(
            valueLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: enabled
                  ? scheme.onSurfaceVariant
                  : scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
          Expanded(
            child: Slider(
              key: sliderKey,
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: sliderLabel,
              semanticFormatterCallback: (_) => valueLabel,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled ? onChangeEnd : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面设置行右侧的滑块控件:固定宽度,值标签在左,关闭时整段置灰。
class SettingsSliderControl extends StatelessWidget {
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final Key? sliderKey;
  final double width;

  const SettingsSliderControl({
    super.key,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    this.enabled = true,
    this.onChanged,
    this.onChangeEnd,
    this.sliderKey,
    this.width = 280,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: width,
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              valueLabel,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: enabled
                    ? scheme.onSurfaceVariant
                    : scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Slider(
              key: sliderKey,
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              semanticFormatterCallback: (_) => valueLabel,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled ? onChangeEnd : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表/分组卡里的开关行:内部仍是 [SwitchListTile]。
///
/// 统一图标尺寸、标题插槽与可选的内边距;`switchTileKey` 透传给内部
/// `SwitchListTile`,保证既有测试仍按 key 取到 `SwitchListTile` 本身。
class SettingsSwitchTile extends StatelessWidget {
  final Key? switchTileKey;
  final IconData? icon;
  final double? iconSize;
  final String title;
  final String? description;
  final Widget? titleTrailing;
  final TextStyle? titleStyle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// 置灰但保留当前值:依赖条件不满足时禁用切换,由 [description] 说明原因。
  final bool enabled;
  final bool dense;
  final EdgeInsetsGeometry? contentPadding;

  const SettingsSwitchTile({
    super.key,
    this.switchTileKey,
    this.icon,
    this.iconSize,
    required this.title,
    this.description,
    this.titleTrailing,
    this.titleStyle,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.dense = false,
    this.contentPadding,
  });

  @override
  Widget build(BuildContext context) {
    final label = titleTrailing == null
        ? Text(title, style: titleStyle)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题可让位:大字号下标题与行尾说明钮并排时不能横向顶出。
              Flexible(child: Text(title, style: titleStyle)),
              const SizedBox(width: 2),
              titleTrailing!,
            ],
          );
    final subtitle = description;
    return SwitchListTile(
      key: switchTileKey,
      contentPadding: contentPadding,
      dense: dense,
      secondary: icon == null ? null : Icon(icon, size: iconSize),
      title: label,
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}
