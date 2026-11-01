/// 管理列表共用的检索输入组件:圆角浅底、前置放大镜、有内容时显示清除键。
///
/// 只负责输入与清除,过滤逻辑由页面按 [AppSearchField.onChanged] 的文本
/// 自行处理;检索词的 trim/大小写归一也不在这里。
library;

import 'package:flutter/material.dart';

/// 检索框的焦点与清除交互。
///
/// 失焦:Flutter 默认只在桌面平台于点击框外时自动失焦,移动端点空白处、
/// 按软键盘搜索键都不会退出输入态(列表无结果时连拖动收键盘都没有),
/// 因此这里统一主动撤销焦点、收起软键盘,三端行为一致。
class AppSearchField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
  final EdgeInsets padding;

  /// 页面打开即聚焦并弹出软键盘(独立搜索页用;列表页默认不抢焦点)。
  final bool autofocus;

  const AppSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = '搜索',
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 4),
    this.autofocus = false,
  });

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: widget.padding,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.controller,
        builder: (context, value, _) => TextField(
          controller: widget.controller,
          focusNode: _focus,
          autofocus: widget.autofocus,
          onChanged: widget.onChanged,
          textInputAction: TextInputAction.search,
          onTapOutside: (_) => _focus.unfocus(),
          onSubmitted: (_) => _focus.unfocus(),
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      widget.controller.clear();
                      widget.onChanged('');
                      _focus.unfocus();
                    },
                  ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}
