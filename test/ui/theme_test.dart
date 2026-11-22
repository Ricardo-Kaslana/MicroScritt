// 应用主题接线:appSettings 的 themeMode 决定 MaterialApp 的亮/暗主题
// (最小启动,真实 DB 仅供 provider 依赖)。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/app.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/character_screen.dart';
import 'package:microscritt/ui/common/diff_colors.dart';
import 'package:microscritt/ui/common/layout_breakpoints.dart';
import 'package:microscritt/ui/theme/app_theme.dart';
import '../support/test_database.dart';

/// 相对亮度对比度(WCAG 2.x):前景需先与底色合成为不透明色。
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('desktop CJK font', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('Windows theme pins Microsoft YaHei for CJK glyphs', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final light = AppTheme.light();
      final dark = AppTheme.dark();
      expect(light.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei');
      expect(dark.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei');
      // 按钮、浮动提示与三点菜单的文字样式都会替换默认 DefaultTextStyle,
      // 必须自带字体,否则 Windows 上中文会落到系统回退字体,出现字重/字形
      // 不一致。
      for (final theme in [light, dark]) {
        expect(
          theme.filledButtonTheme.style?.textStyle
              ?.resolve(<WidgetState>{})
              ?.fontFamily,
          'Microsoft YaHei',
        );
        expect(
          theme.snackBarTheme.contentTextStyle?.fontFamily,
          'Microsoft YaHei',
        );
      }
      expect(
        light.popupMenuTheme.labelTextStyle
            ?.resolve(<WidgetState>{})
            ?.fontFamily,
        'Microsoft YaHei',
      );
      expect(
        dark.popupMenuTheme.labelTextStyle
            ?.resolve(<WidgetState>{})
            ?.fontFamily,
        'Microsoft YaHei',
      );
    });

    test('other platforms keep their system default font', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final theme = AppTheme.light();
      expect(theme.textTheme.bodyMedium?.fontFamily, isNot('Microsoft YaHei'));
      expect(
        theme.popupMenuTheme.labelTextStyle
            ?.resolve(<WidgetState>{})
            ?.fontFamily,
        isNot('Microsoft YaHei'),
      );
      expect(
        theme.filledButtonTheme.style?.textStyle
            ?.resolve(<WidgetState>{})
            ?.fontFamily,
        isNot('Microsoft YaHei'),
      );
      expect(
        theme.snackBarTheme.contentTextStyle?.fontFamily,
        isNot('Microsoft YaHei'),
      );
    });
  });

  test('AppRadius 与主题圆角/弹层限宽接线一致', () {
    expect(AppRadius.input, 12);
    expect(AppRadius.button, 14);
    expect(AppRadius.card, 16);
    expect(AppRadius.sheet, 20);

    final theme = AppTheme.light();
    final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(cardShape.borderRadius, AppRadius.cardBorder);

    final buttonShape =
        theme.filledButtonTheme.style!.shape!.resolve(<WidgetState>{})!
            as RoundedRectangleBorder;
    expect(buttonShape.borderRadius, BorderRadius.circular(AppRadius.button));

    final inputBorder =
        theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
    expect(inputBorder.borderRadius.topLeft.x, AppRadius.input);

    final sheetShape = theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
    expect(
      sheetShape.borderRadius,
      BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    );
    expect(theme.bottomSheetTheme.constraints?.maxWidth, kSheetMaxWidth);
  });

  test('深色 SnackBar 与输入提示保持正文对比', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final snackBg = theme.snackBarTheme.backgroundColor!;
      final snackFg = theme.snackBarTheme.contentTextStyle!.color!;
      expect(
        _contrastRatio(snackFg, snackBg),
        greaterThanOrEqualTo(4.5),
        reason: 'SnackBar 前景/背景对比不足(${theme.brightness})',
      );

      final fill = theme.inputDecorationTheme.fillColor!;
      final hint = Color.alphaBlend(
        theme.inputDecorationTheme.hintStyle!.color!,
        fill,
      );
      expect(
        _contrastRatio(hint, fill),
        greaterThanOrEqualTo(4.5),
        reason: '输入提示对比不足(${theme.brightness})',
      );
    }
  });

  test('DiffColors 亮暗前景均达到正文对比', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final scheme = theme.colorScheme;
      expect(
        _contrastRatio(DiffColors.added(scheme), scheme.surface),
        greaterThanOrEqualTo(4.5),
        reason: '新增色对比不足(${theme.brightness})',
      );
      expect(
        _contrastRatio(DiffColors.removed(scheme), scheme.surface),
        greaterThanOrEqualTo(4.5),
        reason: '删除色对比不足(${theme.brightness})',
      );
    }
  });

  test('卡片主题带统一发丝边', () {
    final theme = AppTheme.light();
    final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color.a, closeTo(AppStroke.cardAlpha, 0.001));
    expect(shape.side.width, 1);
  });

  testWidgets('app uses Chinese framework localizations', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings()),
        ],
        child: const MicroScrittApp(),
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(CharacterScreen));
    expect(Localizations.localeOf(context), const Locale('zh', 'CN'));
    expect(MaterialLocalizations.of(context).backButtonTooltip, contains('返回'));
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('app applies dark theme when settings say dark', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(
            (ref) => const AppSettings(themeMode: AppThemeMode.dark),
          ),
        ],
        child: const MicroScrittApp(),
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(CharacterScreen));
    expect(Theme.of(context).brightness, Brightness.dark);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('app applies light theme when settings say light', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(
            (ref) => const AppSettings(themeMode: AppThemeMode.light),
          ),
        ],
        child: const MicroScrittApp(),
      ),
    );
    await tester.pump();
    final context = tester.element(find.byType(CharacterScreen));
    expect(Theme.of(context).brightness, Brightness.light);
    await tester.runAsync(() => db.db.close());
  });
}
