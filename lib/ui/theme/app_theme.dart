import 'package:flutter/material.dart';

/// MicroScritt 的统一设计语言 —— 现代简洁、iOS 风格。
///
/// 设计原则:
/// 1. **清爽留白 + 组化平铺** —— 背景用大块灰调(iOS systemGroupedBackground),
///    卡片与内容用纯白/本色小卡。层级靠「背景灰 vs 卡片白」的明度差表达,而不是
///    阴影叠加,整体更轻盈。
/// 2. **弱化渐变** —— 只用纯色 tonal 底;头像/占位不再用 LinearGradient。
/// 3. **iOS 语言** —— 分组列表(inset grouped)、大写小型分组标题、胶囊主按钮、
///    一致的圆角梯度(卡片 12 / 输入 pill 24 / 主按钮 22)、系统图标语义。
/// 4. **主色** —— 用 System Blue 系做强调(后续可换),低饱和次级色补足,避免
///    M3 默认那套大面积 `primaryContainer`/`surfaceContainerHighest` 的浓色调。
class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

class AppTheme {
  AppTheme._();

  // iOS 系统色(SF)参考:蓝色即 Apple Blue #0A84FF。
  static const Color _accent = Color(0xFF0A7CFF);

  /// 页面整体主题:浅色 / 深色。
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    // iOS 分组背景:浅色 #F2F2F7 / 深色 #000000。卡片在浅色里是白、深色里是
    // surface 阶的深灰 —— 靠背景灰度差把小卡「浮」出来。
    final groupedBg = isDark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: brightness,
      // 把 M3 默认的重色调压下去:容器色贴近表面,只留一点点色相,叠在灰底上
      // 时是「浅墨水色块」而非大块主色,观感更现代干净(少用浓渐变/大色块)。
      surface: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
      surfaceBright: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF),
      surfaceContainerLowest: isDark ? const Color(0xFF141414) : const Color(0xFFFFFFFF),
    );

    final base = ThemeData(colorScheme: scheme, brightness: brightness, useMaterial3: true);

    final textColor = scheme.onSurface;
    final textTheme = base.textTheme
        .apply(bodyColor: textColor, displayColor: textColor)
        .copyWith(
          // 分组标题:小号、灰、全大写,语义为「区段锚点」而非正文。
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: scheme.onSurfaceVariant,
          ),
        );

    // 统一的圆角语言。
    const cardRadius = 16.0;
    const buttonRadius = 14.0;

    return base.copyWith(
      scaffoldBackgroundColor: groupedBg,
      canvasColor: groupedBg,
      textTheme: textTheme,
      dividerColor: scheme.outlineVariant.withValues(alpha: 0.6),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 16,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        textColor: scheme.onSurface,
        titleTextStyle: textTheme.bodyLarge,
      ),
      inputDecorationTheme: _inputTheme(scheme, isDark),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentTextStyle: const TextStyle(color: Color(0xFFFFFFFF)),
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 0.5),
      popupMenuTheme: _popupMenuTheme(scheme),
      bottomSheetTheme: _bottomSheetTheme(scheme),
    );
  }

  /// 三点菜单 / PopupMenu 的统一外观:与卡片同色的白面、按钮级圆角 14
  /// (输入 12 < 按钮 14 < 卡片 16)、GroupCard 同款 hairline 描边把菜单从
  /// 灰底上分出来,层级靠描边而非重阴影。
  static PopupMenuThemeData _popupMenuTheme(ColorScheme scheme) {
    const itemTextStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
    return PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      textStyle: itemTextStyle.copyWith(color: scheme.onSurface),
      labelTextStyle: WidgetStatePropertyAll(itemTextStyle.copyWith(color: scheme.onSurface)),
      iconColor: scheme.onSurfaceVariant,
      iconSize: 20,
    );
  }

  /// 底部弹层统一外观:卡片白面、顶部 20 圆角(面积最大的表面配最大圆角)、
  /// 无 tint。drag handle 不在此全局开启——重型滚动 sheet(模型选择器等)自带
  /// 拖动交互,全局把手会重复;操作菜单类弹层在调用处显式开启。
  static BottomSheetThemeData _bottomSheetTheme(ColorScheme scheme) {
    return BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      clipBehavior: Clip.antiAlias,
    );
  }

  static InputDecorationTheme _inputTheme(ColorScheme scheme, bool isDark) {
    // iOS 表单用内嵌灰输入框:无外描边,填一档与背景可区分的灰。浅色用比
    // 分组背景(#F2F2F7)略深一点的灰,深色用比 #000 背景略亮的 #2C2C2E,保证
    // 边框文字都能看清。
    final fill = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFECECEF);
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7), fontSize: 14),
    );
  }
}
