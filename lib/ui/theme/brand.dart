/// 应用图标、启动动画与聊天页灵岛的共享品牌色(三点与胶囊底色)。
///
/// 三点对应主写/后台/压缩三个引擎点,与 `assets/branding/icon.svg` 及
/// Android/iOS 图标资源同源;改色需同步图标资源,避免色值漂移。
library;

import 'package:flutter/material.dart';

/// 品牌三点与胶囊底色的常量容器。
///
/// 只读、不随主题联动:胶囊底色给了亮/暗两档,由调用方按当前亮度选取;
/// 聊天页灵岛与启动动画同样取这里的色值,不要在页面里另写同色常量。
class AppBrand {
  AppBrand._();

  /// 主写引擎点。
  static const Color dotBlue = Color(0xFF409CFF);

  /// 后台引擎点。
  static const Color dotGreen = Color(0xFF30D158);

  /// 压缩引擎点。
  static const Color dotOrange = Color(0xFFFF9F0A);

  /// 图标胶囊底色:亮色主题近黑,深色主题提亮一档(纯黑上仍可辨)。
  static const Color capsuleLight = Color(0xFF1C1C1E);
  static const Color capsuleDark = Color(0xFF2C2C2E);
}
