import 'package:flutter/material.dart';

/// 应用图标与界面的共享品牌色。
///
/// 三点对应图标的蓝/绿/橙引擎点（主写/后台/压缩），与 `assets/branding/icon.svg`
/// 及 Android/iOS 图标资源保持同源；聊天页灵岛与启动动画共用，避免色值漂移。
class AppBrand {
  AppBrand._();

  static const Color dotBlue = Color(0xFF409CFF);
  static const Color dotGreen = Color(0xFF30D158);
  static const Color dotOrange = Color(0xFFFF9F0A);

  /// 图标胶囊底色：亮色主题近黑，深色主题提亮一档（纯黑上仍可辨）。
  static const Color capsuleLight = Color(0xFF1C1C1E);
  static const Color capsuleDark = Color(0xFF2C2C2E);
}
