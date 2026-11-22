/// 按钮与列表行内的紧凑加载圈。
///
/// 页面里此前反复手写 `SizedBox(width/height, child: CircularProgressIndicator(
/// strokeWidth: 2))`;集中到这里后描边宽度与尺寸语义一致,各调用点只需传
/// 用途对应的边长。
library;

import 'package:flutter/material.dart';

/// 固定边长的细描边加载圈;默认 16,用于按钮内或行尾的小型等待态。
class InlineSpinner extends StatelessWidget {
  final double size;
  final double strokeWidth;
  final Color? color;

  const InlineSpinner({
    super.key,
    this.size = 16,
    this.strokeWidth = 2,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(strokeWidth: strokeWidth, color: color),
    );
  }
}
