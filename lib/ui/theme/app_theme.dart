/// 应用主题与间距刻度:亮/暗两套主题由同一套配色规则生成。
///
/// 页面只消费 [AppTheme.light]/[AppTheme.dark] 与 [AppSpacing],不在页面里
/// 另立色值与圆角,避免亮暗两套观感漂移。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../common/layout_breakpoints.dart';

/// 全局间距刻度(4 的倍数);布局留白从这里取,不写魔法数字。
class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// 统一圆角梯度:输入 12 / 按钮 14 / 卡片 16 / 底单 20。
///
/// 主题与共享卡片容器从这里取;页面里的小裁切(头像、缩略图)仍按自身
/// 语义取值,不强行套用这四档。
class AppRadius {
  AppRadius._();
  static const double input = 12;
  static const double button = 14;
  static const double card = 16;
  static const double sheet = 20;
  static const BorderRadius cardBorder = BorderRadius.all(
    Radius.circular(card),
  );
}

/// 发丝描边与分隔线的统一透明度。
///
/// 卡片、菜单、分组分隔线此前在 0.35–0.7 间各取一档,灰底上同一层级的
/// 边界深浅不一;集中后只保留「卡片描边 / 分隔线」两档。
class AppStroke {
  AppStroke._();
  static const double cardAlpha = 0.5;
  static const double dividerAlpha = 0.6;

  static BorderSide cardSide(ColorScheme scheme) =>
      BorderSide(color: scheme.outlineVariant.withValues(alpha: cardAlpha));

  static Color divider(ColorScheme scheme) =>
      scheme.outlineVariant.withValues(alpha: dividerAlpha);
}

/// MicroScritt 的统一设计语言 —— 现代简洁、iOS 风格。
///
/// 设计原则:
/// 1. **清爽留白 + 组化平铺** —— 背景用大块灰调(iOS systemGroupedBackground),
///    卡片与内容用纯白/本色小卡。层级靠「背景灰 vs 卡片白」的明度差表达,而不是
///    阴影叠加,整体更轻盈。
/// 2. **弱化渐变** —— 底色一律用纯色 tonal;渐变只用于图片上的压暗蒙层
///    (保证叠在上面的白字可读)。
/// 3. **iOS 语言** —— 分组列表(inset grouped)、小型灰色分组标题、实底主按钮、
///    一致的圆角梯度(输入 12 / 按钮 14 / 卡片 16 / 底单 20)、系统图标语义。
/// 4. **主色** —— 用 System Blue 系做强调(seed),再把 M3 默认的重色调压下去,
///    避免大面积 `primaryContainer`/`surfaceContainerHighest` 的浓色块。
class AppTheme {
  AppTheme._();

  // 强调蓝(seed):取 System Blue 色相、略压亮度,避免 fromSeed 生成的
  // 派生色过艳。
  static const Color _accent = Color(0xFF0A7CFF);

  /// Windows 桌面端的默认字体。
  ///
  /// Windows 的 Material 字体是 Segoe UI,它没有中文字形;Flutter 在 Windows
  /// 上的缺字回退会落到日文字体,把「门」这类字的细竖画渲染成近乎不可见的
  /// 浅灰线(正文缺笔画)。显式指定系统自带的微软雅黑,让中文字形由字体自身
  /// 提供;移动端继续用系统默认字体(Android Noto / iOS 苹方)。
  static String? get _defaultFontFamily =>
      defaultTargetPlatform == TargetPlatform.windows
      ? 'Microsoft YaHei'
      : null;

  /// 浅色主题。
  static ThemeData light() => _build(Brightness.light);

  /// 深色主题;与 [light] 共用 [_build],只有背景/表面覆盖色按亮度分支。
  static ThemeData dark() => _build(Brightness.dark);

  /// 按亮度生成主题:配色规则只写在这里,亮暗差异集中在少数覆盖色上。
  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    // iOS 分组背景:浅色 #F2F2F7 / 深色 #000000。卡片在浅色里是白、深色里是
    // surface 阶的深灰 —— 靠背景灰度差把小卡「浮」出来。
    final groupedBg = isDark
        ? const Color(0xFF000000)
        : const Color(0xFFF2F2F7);
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: brightness,
      // 把 M3 默认的重色调压下去:容器色贴近表面,只留一点点色相,叠在灰底上
      // 时是「浅墨水色块」而非大块主色,观感更现代干净(少用浓渐变/大色块)。
      surface: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF),
      surfaceBright: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF),
      surfaceContainerLowest: isDark
          ? const Color(0xFF141414)
          : const Color(0xFFFFFFFF),
    );

    final base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      fontFamily: _defaultFontFamily,
    );

    final textColor = scheme.onSurface;
    final textTheme = base.textTheme
        .apply(bodyColor: textColor, displayColor: textColor)
        .copyWith(
          // 分组标题:小号、灰、微字距,语义为「区段锚点」而非正文。
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: scheme.onSurfaceVariant,
          ),
        );

    // 统一的圆角语言;数值来源见 [AppRadius]。
    const cardRadius = AppRadius.card;
    const buttonRadius = AppRadius.button;

    // 组件级文字样式(按钮 / 浮动提示 / 三点菜单)会替换 Material 默认的
    // DefaultTextStyle,不继承 ThemeData.fontFamily;统一从这里取主题字体,
    // 否则 Windows 中文会落到系统回退字体,出现字重/字形不一致。
    final fontFamily = textTheme.bodyLarge?.fontFamily;

    return base.copyWith(
      scaffoldBackgroundColor: groupedBg,
      canvasColor: groupedBg,
      textTheme: textTheme,
      dividerColor: AppStroke.divider(scheme),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: AppStroke.cardSide(scheme),
        ),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          textStyle: TextStyle(
            fontFamily: fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary),
      ),
      // 浮动提示沿用 M3 的反色层级:浅色主题深底白字、深色主题浅底深字。
      // 此前只写死白字不设底色,深色主题下会落到浅色 inverseSurface 上,
      // 白字几乎不可读。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: scheme.inverseSurface,
        actionTextColor: scheme.inversePrimary,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: scheme.onInverseSurface,
        ),
      ),
      // 桌面滚动条:细圆角拇指取自主题色(静置发丝灰、悬停/拖动转主色),
      // 与 iOS 式轻层级一致,不用系统默认的粗灰块。
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(4),
        thickness: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.dragged) ? 6.0 : 4.0,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.outlineVariant,
        ),
        crossAxisMargin: 3,
        mainAxisMargin: 6,
      ),
      dividerTheme: const DividerThemeData(space: 1, thickness: 0.5),
      popupMenuTheme: _popupMenuTheme(scheme, fontFamily),
      bottomSheetTheme: _bottomSheetTheme(scheme),
    );
  }

  /// 三点菜单 / PopupMenu 的统一外观:与卡片同色的白面、按钮级圆角 14
  /// (输入 12 < 按钮 14 < 卡片 16)、GroupCard 同款 hairline 描边把菜单从
  /// 灰底上分出来,层级靠描边而非重阴影。
  static PopupMenuThemeData _popupMenuTheme(
    ColorScheme scheme,
    String? fontFamily,
  ) {
    // 字体必须显式带上主题字体:PopupMenuTheme 的 labelTextStyle 会直接
    // 覆盖 DefaultTextStyle,不继承 ThemeData.fontFamily —— 漏掉它时菜单
    // 中文会走 Windows 的日文回退字体,与页面其它文字观感不一致。
    final itemTextStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      fontFamily: fontFamily,
    );
    return PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        side: AppStroke.cardSide(scheme),
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      textStyle: itemTextStyle.copyWith(color: scheme.onSurface),
      labelTextStyle: WidgetStatePropertyAll(
        itemTextStyle.copyWith(color: scheme.onSurface),
      ),
      iconColor: scheme.onSurfaceVariant,
      iconSize: 20,
    );
  }

  /// 底部弹层统一外观:卡片白面、顶部 20 圆角(面积最大的表面配最大圆角)、
  /// 无 tint。drag handle 不在此全局开启——重型滚动 sheet(模型选择器等)自带
  /// 拖动交互,全局把手会重复;操作菜单类弹层在调用处显式开启。
  /// 宽窗桌面封顶 640 居中(showModalBottomSheet 对受限弹层水平居中),
  /// 不再把底单拉成整窗宽;窄于封顶的移动窗口不受影响。
  static BottomSheetThemeData _bottomSheetTheme(ColorScheme scheme) {
    return BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      constraints: const BoxConstraints(maxWidth: kSheetMaxWidth),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      clipBehavior: Clip.antiAlias,
    );
  }

  /// 输入框:内嵌灰底、无外描边;聚焦只加 1.4 宽的主色描边,错误态换成
  /// `scheme.error`,不叠加红底,保证文字可读。
  static InputDecorationTheme _inputTheme(ColorScheme scheme, bool isDark) {
    // iOS 表单用内嵌灰输入框:无外描边,填一档与背景可区分的灰。浅色用比
    // 分组背景(#F2F2F7)略深一点的灰,深色用比 #000 背景略亮的 #2C2C2E,保证
    // 边框文字都能看清。
    final fill = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFECECEF);
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide.none,
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: scheme.error, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide.none,
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
      hintStyle: TextStyle(
        // 0.7 在浅色灰底上约 3.7:1,低于小字号正文门槛;0.85 仍弱于
        // 输入值但足够可读。
        color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
        fontSize: 14,
      ),
    );
  }
}
