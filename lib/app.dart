/// 应用根组件:主题模式、冷启动动画与首页路由。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models/app_settings.dart';
import 'state/providers.dart';
import 'ui/character_screen.dart';
import 'ui/startup_splash.dart';
import 'ui/theme/app_theme.dart';

/// MicroScritt 的 MaterialApp 根组件。
class MicroScrittApp extends ConsumerWidget {
  const MicroScrittApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      title: 'MicroScritt',
      themeMode: switch (settings.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // 应用文案只有中文;框架内建控件(返回/关闭/复制菜单等)与读屏动作词
      // 也固定中文,避免系统语言为英文时出现中英混杂。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // 冷启动品牌动画:overlay 在 Navigator 之上,首屏在其下先构建完成,
      // 动画结束时只移除 overlay,不重建首屏。
      builder: (context, child) =>
          StartupSplash(child: child ?? const SizedBox.shrink()),
      home: const CharacterScreen(),
    );
  }
}
