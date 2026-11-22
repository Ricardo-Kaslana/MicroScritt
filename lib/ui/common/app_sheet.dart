/// 底部弹层统一入口:集中滚动控制、安全区与宽度覆盖。
///
/// 默认按「可滚动 + 安全区」打开,适合表单与长内容;需要系统默认的
/// 9/16 高度上限时显式传 `isScrollControlled: false`。自绘把手的弹层
/// (SheetHeader)保持 [showDragHandle] 为 false,避免出现双把手。
/// 宽窗封顶仍由主题的 BottomSheetThemeData 负责,只有制卡预览这类需要
/// 更宽画布的弹层才传 [maxWidth]。
library;

import 'package:flutter/material.dart';

Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool showDragHandle = false,
  double? maxWidth,
  Color? backgroundColor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    backgroundColor: backgroundColor,
    constraints: maxWidth == null ? null : BoxConstraints(maxWidth: maxWidth),
  );
}
