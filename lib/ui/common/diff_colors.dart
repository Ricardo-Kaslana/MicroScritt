/// 卡片审阅与 diff 文本共用的增删配色。
///
/// 浅色沿用原来的深绿/深红;深色卡面(#1C1C1E)上这两色对比不足,
/// 改用同色相的浅色前景。背景只做低 alpha 铺底,不参与文字对比计算。
library;

import 'package:flutter/material.dart';

class DiffColors {
  DiffColors._();

  static Color added(ColorScheme scheme) => scheme.brightness == Brightness.dark
      ? const Color(0xFF81C784)
      : const Color(0xFF2E7D32);

  static Color removed(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
      ? const Color(0xFFEF9A9A)
      : const Color(0xFFC62828);

  static Color addedBackground(ColorScheme scheme) => added(
    scheme,
  ).withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.10);

  static Color removedBackground(ColorScheme scheme) => removed(
    scheme,
  ).withValues(alpha: scheme.brightness == Brightness.dark ? 0.16 : 0.08);
}
