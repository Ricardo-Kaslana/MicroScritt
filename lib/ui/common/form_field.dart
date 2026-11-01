/// iOS 分组表单的字段积木:外置灰色小标题 + 实底圆角输入框。
///
/// 三款字段共用同一套层级(节标题 → 字段名 → 输入框 → hint),各编辑页都从
/// 这里取字段,避免各页自绘导致留白与字号不一致。
library;

import 'package:flutter/material.dart';

import 'copy_button.dart';

/// 字段标题:小号、低饱和灰、常规字重、微字距。
class FieldLabel extends StatelessWidget {
  final String text;
  final EdgeInsets padding;
  const FieldLabel(this.text, {super.key, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
          height: 1.2,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// 单行/多行文本字段:标题在上、实底输入框在下。字段名会成为输入框的
/// `ValueKey('field_<text>')`,便于测试稳定定位。
///
/// 可选支持密钥等敏感字段:`obscureText` 配合 [suffixIcon](眼睛切换)使用;
/// 需要自定义内部 key 时传 [innerKey](如依赖当前值的 `image_xxx`)。
///
/// [copyable] 控制字段标题右侧的一键复制按钮:默认多行字段显示、
/// 单行字段隐藏;单行但内容较长的字段可显式开启。
///
/// 字段本身不做校验:必填/长度等规则由表单页在保存时判断,这里只负责版式。
class FormTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final int lines;
  final int? minLines;
  final TextInputType? keyboardType;
  final TextStyle? style;
  final ValueChanged<String>? onChanged;
  final bool obscureText;
  final Widget? suffixIcon;
  final Key? innerKey;
  final bool? copyable;

  const FormTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.lines = 1,
    this.minLines,
    this.keyboardType,
    this.style,
    this.onChanged,
    this.obscureText = false,
    this.suffixIcon,
    this.innerKey,
    this.copyable,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveLines = minLines ?? lines;
    final showCopy = copyable ?? (effectiveLines > 1);
    return Padding(
      // 每个字段自带一致的左右留白(14px),无论是否套在分组卡里,视觉内缩统一。
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: FieldLabel(label)),
              if (showCopy) CopyTextButton(controller: controller),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            key: innerKey ?? ValueKey('field_$label'),
            controller: controller,
            obscureText: obscureText,
            minLines: minLines ?? lines,
            maxLines: lines > 1 ? null : 1,
            keyboardType: keyboardType,
            style: style,
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: suffixIcon,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ).copyWith(right: suffixIcon == null ? 14 : 0),
            ),
          ),
        ],
      ),
    );
  }
}

/// 下拉字段:标题在上、下拉框在下。`value` 为当前选中展示,`items` 为候选。
/// 默认用 `ValueKey('field_<label>')`;需要随状态变化的 key 时传 [fieldKey]
/// (如依赖当前模型值的 `image_model_...`)。
class FormDropdownField<T> extends StatelessWidget {
  final T? value;
  final String label;
  final String? hint;
  final String? helperText;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T?> onChanged;
  final Key? fieldKey;

  /// 弹出菜单限高:超过即内部滚动。菜单条目仍会全部构建(不是惰性列表),
  /// 限高只解决超高菜单遮挡,不降低长候选的构建成本。
  final double? menuMaxHeight;

  const FormDropdownField({
    super.key,
    required this.value,
    required this.label,
    required this.items,
    required this.labelOf,
    required this.onChanged,
    this.hint,
    this.helperText,
    this.fieldKey,
    this.menuMaxHeight,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // 与文本字段一致:每个下拉也带 14px 左右留白。
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FieldLabel(label),
          const SizedBox(height: 6),
          DropdownButtonFormField<T>(
            key: fieldKey ?? ValueKey('field_$label'),
            initialValue: value,
            isExpanded: true,
            // 弹出面板用卡片白:不设时回退 canvasColor(主题里是页面灰底)。
            dropdownColor: scheme.surface,
            borderRadius: BorderRadius.circular(12),
            menuMaxHeight: menuMaxHeight,
            icon: const Icon(Icons.expand_more, size: 20),
            iconSize: 20,
            iconEnabledColor: scheme.onSurfaceVariant,
            decoration: InputDecoration(
              hintText: hint,
              helperText: helperText,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
            items: [
              for (final item in items)
                DropdownMenuItem(
                  value: item,
                  child: Text(labelOf(item), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
