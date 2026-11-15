/// 系统「减弱动态效果」的统一判定与时长收敛。
///
/// iOS 的 Reduce Motion 不会体现在 `MediaQuery.disableAnimations` 上,必须
/// 直接读平台无障碍特性;Android/桌面的关闭动画则走 MediaQuery。所有自绘
/// 过渡(启动动画、牌堆、灵动岛、展开容器、滚动)统一经本文件取判定,避免
/// 各组件各读一套导致 iOS 漏判。
library;

import 'package:flutter/widgets.dart';

/// 当前是否要求减弱动态效果。
bool reduceMotionOf(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  final features =
      View.maybeOf(context)?.platformDispatcher.accessibilityFeatures ??
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
  return (media?.disableAnimations ?? false) ||
      features.disableAnimations ||
      features.reduceMotion;
}

/// 按系统偏好收敛过渡时长:减弱动态效果时归零(瞬时切换)。
Duration motionDurationOf(BuildContext context, Duration duration) =>
    reduceMotionOf(context) ? Duration.zero : duration;
