/// 全应用统一的浮动提示入口。
///
/// 此前各页直接 `showSnackBar`,宽度、是否替换当前条与清理时机各不相同;
/// 集中后宽窗统一封顶,连续操作只保留最新一条,不再排队等待。
library;

import 'package:flutter/material.dart';

import 'layout_breakpoints.dart';

/// 宽窗下浮动提示的封顶宽度;窄窗返回 null,保持原来的满宽行为。
double? appSnackBarWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kDesktopBreakpoint
    ? kSnackBarMaxWidth
    : null;

/// 展示一条纯文本浮动提示;先收起当前条再展示。
///
/// [action] 用于撤销等行内动作;颜色、圆角与浮动行为沿用全局 snackBarTheme。
void showAppSnack(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      // width 只允许与 floating 搭配;全局 snackBarTheme 已设为 floating,
      // 这里显式声明,测试宿主未套用应用主题时也不会触发断言。
      behavior: SnackBarBehavior.floating,
      width: appSnackBarWidth(context),
      content: Text(message),
      action: action,
    ),
  );
}
