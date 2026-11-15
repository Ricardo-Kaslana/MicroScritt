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
import 'package:microscritt/ui/theme/app_theme.dart';
import '../support/test_database.dart';

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
