// 桌面设置工作台 widget 测试:侧栏骨架、分区切换、外观/对话落库、用户内联
// 保存、服务列表、图片存储、配置区与断点回退。宽窗断点以上由 SettingsScreen 分发。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/user_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/user.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/settings_screen.dart';
import 'package:microscritt/ui/user_screen.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  late AppDatabase db;

  Widget harness({UserProfile profile = const UserProfile()}) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      userProfileProvider.overrideWith((ref) => profile),
    ],
    child: const MaterialApp(home: SettingsScreen()),
  );

  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> openDesktop(
    WidgetTester tester, {
    UserProfile profile = const UserProfile(),
  }) async {
    await tester.pumpWidget(harness(profile: profile));
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('settings_desktop_sidebar'))
          .evaluate()
          .isNotEmpty,
    );
  }

  Future<void> openSection(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('settings_nav_$name')));
    await tester.pump();
  }

  /// 桌面页同时订阅多份 DB provider,先拆树再关库,避免在途查询撞锁。
  Future<void> closeDb(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await db.db.close();
    });
  }

  Future<void> waitForSettings(
    WidgetTester tester,
    bool Function(AppSettings settings) predicate,
  ) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        final settings = await AppSettingsRepository(db).load();
        if (predicate(settings)) return;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  testWidgets('宽窗显示分区工作台:侧栏 + 默认用户工作区', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);

    final sidebar = find.byKey(const ValueKey('settings_desktop_sidebar'));
    final workspace = find.byKey(const ValueKey('settings_desktop_workspace'));
    expect(sidebar, findsOneWidget);
    expect(workspace, findsOneWidget);
    expect(tester.getSize(sidebar).width, moreOrLessEquals(280));
    for (final label in [
      '用户',
      '外观',
      '对话与后台',
      'LLM 后端',
      '生图',
      '内容与扩展',
      '统计',
      '图片与存储',
      '配置',
      '关于',
    ]) {
      expect(
        find.descendant(of: sidebar, matching: find.text(label)),
        findsOneWidget,
      );
    }
    // 默认「用户」工作区:内联表单而不是跳转入口。
    expect(find.byKey(const ValueKey('settings_scroll_user')), findsOneWidget);
    expect(find.text('选择头像'), findsOneWidget);
    expect(find.widgetWithText(TextField, '用户名'), findsOneWidget);
    expect(find.byType(UserScreen), findsNothing);
    expect(tester.takeException(), isNull);

    await closeDb(tester);
  });

  testWidgets('分区切换与已访问工作区状态保留', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);

    // 用户工作区留下草稿,切区再回来不丢。
    final nameField = find.widgetWithText(TextField, '用户名');
    await tester.enterText(nameField, '草稿名');
    await tester.pump();
    await openSection(tester, 'appearance');
    expect(
      find.byKey(const ValueKey('settings_theme_selector')),
      findsOneWidget,
    );
    expect(find.text('聊天背景'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings_chat_background_switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chatBackgroundBlurSlider')),
      findsOneWidget,
    );

    await openSection(tester, 'conversation');
    expect(find.text('上下文自动压缩'), findsOneWidget);
    expect(find.text('单轮附件上限'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings_auto_compact_switch')),
      findsOneWidget,
    );

    await openSection(tester, 'extensions');
    expect(find.text('技能'), findsOneWidget);
    expect(find.text('全局提示词'), findsOneWidget);
    expect(find.text('Hooks'), findsOneWidget);
    expect(find.text('正则脚本'), findsOneWidget);

    await openSection(tester, 'storage');
    expect(
      find.byKey(const ValueKey('settings_scroll_storage')),
      findsOneWidget,
    );
    expect(find.text('整理存储'), findsOneWidget);

    await openSection(tester, 'config');
    expect(find.text('导出配置'), findsOneWidget);
    expect(find.text('导入配置'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);

    await openSection(tester, 'user');
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '用户名'))
          .controller
          ?.text,
      '草稿名',
    );

    await closeDb(tester);
  });

  testWidgets('外观设置落库:主题与聊天背景', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);
    await openSection(tester, 'appearance');

    await tester.tap(find.text('深色'));
    await waitForSettings(tester, (s) => s.themeMode == AppThemeMode.dark);

    await tester.tap(
      find.byKey(const ValueKey('settings_chat_background_switch')),
    );
    await waitForSettings(tester, (s) => s.chatBackgroundEnabled);

    await closeDb(tester);
  });

  testWidgets('对话设置落库:单轮附件上限', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);
    await openSection(tester, 'conversation');

    await tester.tap(
      find.byKey(const ValueKey('settings_attachment_dropdown')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('关闭').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await waitForSettings(tester, (s) => s.maxAutoAttachments == 0);

    await closeDb(tester);
  });

  testWidgets('用户内联保存:落库且不退出桌面页', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);

    // 没有修改时保存键禁用;输入后出现未保存提示并启用。
    final save = find.byKey(const ValueKey('settings_user_save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(find.text('用户名与头像保存在本机'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '用户名'), '小明');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(find.text('有未保存的修改'), findsOneWidget);

    await tester.tap(save);
    await waitUntil(tester, () => find.text('用户信息已保存').evaluate().isNotEmpty);

    late String savedName;
    await tester.runAsync(() async {
      savedName = (await UserRepository(db).load()).name;
    });
    expect(savedName, '小明');
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(UserScreen), findsNothing);
    expect(
      find.byKey(const ValueKey('settings_desktop_sidebar')),
      findsOneWidget,
    );
    // 落库后回到未修改状态,保存键再次禁用。
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(find.text('用户名与头像保存在本机'), findsOneWidget);

    await closeDb(tester);
  });

  testWidgets('用户头像带框,点击打开放大预览', (tester) async {
    useDesktopSurface(tester);
    late final String avatar;
    await tester.runAsync(() async {
      db = await openTestDb();
      avatar = await putTestImageHash(db);
    });
    await openDesktop(
      tester,
      profile: UserProfile(name: '小明', avatarHash: avatar),
    );

    final avatarFinder = find.byKey(const ValueKey('settings_user_avatar'));
    expect(avatarFinder, findsOneWidget);
    await tester.tap(avatarFinder);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings_user_avatar_dialog')),
      findsOneWidget,
    );
    expect(find.text('知道了'), findsOneWidget);
    expect(find.text('小明'), findsWidgets);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings_user_avatar_dialog')),
      findsNothing,
    );

    await closeDb(tester);
  });

  testWidgets('服务区:LLM 空态与添加 Provider 入口', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);
    await openSection(tester, 'llm');
    await waitUntil(
      tester,
      () => find.textContaining('暂无 LLM Provider').evaluate().isNotEmpty,
    );

    expect(find.textContaining('还没有配置任何 LLM provider'), findsOneWidget);
    final addButton = find.byKey(const ValueKey('settings_add_provider'));
    expect(addButton, findsOneWidget);
    await tester.tap(addButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('新建 Provider'), findsOneWidget);

    await closeDb(tester);
  });

  testWidgets('服务区:生图空态与插件/风格入口', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);
    await openSection(tester, 'image');
    await waitUntil(
      tester,
      () => find.textContaining('暂无生图服务').evaluate().isNotEmpty,
    );

    expect(find.text('管理生图插件'), findsOneWidget);
    expect(find.text('管理自定义风格'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings_add_image_provider')),
      findsOneWidget,
    );

    await closeDb(tester);
  });

  testWidgets('设置行随内容宽响应,999 宽回到移动页', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await openDesktop(tester);
    await openSection(tester, 'appearance');

    final themeRow = find.byKey(const ValueKey('settings_theme_row'));
    final themeControl = find.byKey(const ValueKey('settings_theme_selector'));

    // 1280 窗宽:工作区内容 936,主题行横向,控件与标签同一行且在右侧。
    expect(tester.getSize(themeRow).height, lessThan(100));
    expect(
      tester.getCenter(themeControl).dx,
      greaterThan(tester.getCenter(themeRow).dx),
    );
    expect(
      tester.getTopLeft(themeControl).dy,
      lessThan(tester.getBottomLeft(find.text('主题')).dy),
    );
    expect(tester.takeException(), isNull);

    // 1000 窗宽:内容宽 656,主题行改为上下,控件折到标题下方。
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pump();
    expect(tester.getSize(themeRow).height, greaterThan(100));
    expect(
      tester.getTopLeft(themeControl).dy,
      greaterThan(tester.getBottomLeft(find.text('主题')).dy),
    );
    expect(tester.takeException(), isNull);

    // 对话与后台在同一窄桌面宽度下也不溢出。
    await openSection(tester, 'conversation');
    expect(
      find.byKey(const ValueKey('settings_auto_compact_row')),
      findsOneWidget,
    );
    expect(find.text('单轮附件上限'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 999 宽:分发回移动单列页。
    tester.view.physicalSize = const Size(999, 900);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('settings_desktop_sidebar')),
      findsNothing,
    );
    expect(find.text('用户管理'), findsOneWidget);

    await closeDb(tester);
  });
}
