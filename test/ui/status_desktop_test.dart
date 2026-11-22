// 桌面状态工作台 widget 测试:分区导航、概览、变量表格行内编辑、记忆/生图
// 编辑与后台设置落库。宽窗断点以上由 StatusScreen 分发到桌面页。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_guide_repository.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/status_screen.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  late AppDatabase db;
  late int charId;
  late int sessionId;

  Widget harness({AppSettings settings = const AppSettings()}) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      appSettingsProvider.overrideWith((ref) => settings),
    ],
    child: MaterialApp(home: StatusScreen(sessionId: sessionId)),
  );

  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> openDesktop(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
  }) async {
    await tester.pumpWidget(harness(settings: settings));
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('status_desktop_sidebar'))
          .evaluate()
          .isNotEmpty,
    );
  }

  Future<void> openSection(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('status_nav_$name')));
    // 目标分区可能以加载转圈呈现,不能用 pumpAndSettle 等它;
    // 数据就绪由调用方的 waitUntil 判断。
    await tester.pump();
  }

  /// 先拆掉 widget 树再关库:桌面页同时订阅多份 DB provider,直接关闭会与
  /// 仍在途的查询事务撞锁(test 环境会留下 10s 定时器)。
  Future<void> closeDb(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await db.db.close();
    });
  }

  testWidgets('宽窗显示分区工作台:侧栏 + 默认概览 + 引擎页脚', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await openDesktop(tester);

    final sidebar = find.byKey(const ValueKey('status_desktop_sidebar'));
    final workspace = find.byKey(const ValueKey('status_desktop_workspace'));
    expect(sidebar, findsOneWidget);
    expect(workspace, findsOneWidget);
    expect(tester.getSize(sidebar).width, moreOrLessEquals(280));
    expect(
      find.descendant(of: sidebar, matching: find.text('工作区')),
      findsOneWidget,
    );
    for (final label in ['概览', '变量', '记忆', '生图指导']) {
      expect(
        find.descendant(of: sidebar, matching: find.text(label)),
        findsOneWidget,
      );
    }
    // 默认概览:引擎卡、维护功能、模型参数与上下文锚定都在工作区内。
    expect(
      find.descendant(of: workspace, matching: find.text('后台引擎')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: workspace, matching: find.text('维护功能')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: workspace, matching: find.text('模型与参数')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: workspace, matching: find.text('上下文锚定')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('engine_footer_switch')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await closeDb(tester);
  });

  testWidgets('分区切换:变量表格、记忆与生图编辑入口', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
      await MemoryRepository(db).set(sessionId, '旧记忆');
      await ImageGuideRepository(db).set(sessionId, 'old guide');
    });
    await openDesktop(tester);

    await openSection(tester, 'variables');
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('variable_table')), findsOneWidget);
    expect(find.byKey(const ValueKey('variable_table_footer')), findsOneWidget);
    for (final header in ['键', '值', '权限', '操作']) {
      expect(find.text(header), findsOneWidget);
    }
    // 头部动作统一为:文字次操作 + tonal 主操作 + 溢出菜单。
    expect(find.text('回收站'), findsOneWidget);
    expect(find.byKey(const ValueKey('variable_add_button')), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);

    await openSection(tester, 'memory');
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('memory_edit_button'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const ValueKey('memory_read_card')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory_info_rail')), findsOneWidget);
    expect(find.text('上下文第 0 条'), findsOneWidget);
    expect(find.textContaining('旧记忆'), findsOneWidget);
    expect(find.text('重新生成'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory_edit_button')), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);

    await openSection(tester, 'imageGuide');
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('image_guide_edit_button'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const ValueKey('image_guide_info_rail')), findsOneWidget);
    expect(find.text('保存即生效'), findsOneWidget);
    expect(find.textContaining('old guide'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('image_guide_regenerate_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('image_guide_edit_button')),
      findsOneWidget,
    );
    expect(find.byTooltip('更多操作'), findsOneWidget);

    await closeDb(tester);
  });

  testWidgets('变量行内编辑:改值保存落库', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
    });
    await openDesktop(tester);
    await openSection(tester, 'variables');
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('variable_row_hp')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('variable_edit_row')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('variable_value_field')),
      '9/10',
    );
    await tester.tap(find.byKey(const ValueKey('variable_save')));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    await waitUntil(tester, () {
      final rows = container.read(variableRowsProvider(sessionId)).value;
      return rows?.any((v) => v.key == 'hp' && v.value == '9/10') ?? false;
    });

    expect(find.text('9/10'), findsOneWidget);
    expect(find.byKey(const ValueKey('variable_edit_row')), findsNothing);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), {'hp': '9/10'});
    });
    await closeDb(tester);
  });

  testWidgets('变量行内新增、空键禁用与同名键警告', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
    });
    await openDesktop(tester);
    await openSection(tester, 'variables');
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('variable_add_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('variable_edit_row')), findsOneWidget);
    // 空键:保存按钮置灰。
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('variable_save')))
          .onPressed,
      isNull,
    );
    // 同名键:红字提示但允许保存(与移动底单语义一致)。
    await tester.enterText(
      find.byKey(const ValueKey('variable_key_field')),
      'hp',
    );
    await tester.pump();
    expect(find.textContaining('已存在同名变量'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('variable_value_field')),
      '9',
    );
    await tester.tap(find.byKey(const ValueKey('variable_save')));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    await waitUntil(tester, () {
      final rows = container.read(variableRowsProvider(sessionId)).value;
      return rows?.any((v) => v.key == 'hp' && v.value == '9') ?? false;
    });

    // 再新增一条新键,并验证搜索过滤。
    await tester.tap(find.byKey(const ValueKey('variable_add_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('variable_key_field')),
      'mood',
    );
    await tester.enterText(
      find.byKey(const ValueKey('variable_value_field')),
      'calm',
    );
    await tester.tap(find.byKey(const ValueKey('variable_save')));
    await waitUntil(tester, () {
      final rows = container.read(variableRowsProvider(sessionId)).value;
      return rows?.any((v) => v.key == 'mood' && v.value == 'calm') ?? false;
    });
    expect(find.text('mood'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('variable_search')),
        matching: find.byType(TextField),
      ),
      'mood',
    );
    await tester.pump();
    final table = find.byKey(const ValueKey('variable_table'));
    expect(
      find.descendant(of: table, matching: find.text('mood')),
      findsOneWidget,
    );
    expect(find.descendant(of: table, matching: find.text('hp')), findsNothing);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('variable_search')),
        matching: find.byType(TextField),
      ),
      '',
    );
    await tester.pump();
    expect(
      find.descendant(of: table, matching: find.text('hp')),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), {
        'hp': '9',
        'mood': 'calm',
      });
    });
    await closeDb(tester);
  });

  testWidgets('记忆编辑保存后出现待应用,生图指导保存即生效', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MemoryRepository(db).set(sessionId, '旧记忆');
      await ImageGuideRepository(db).set(sessionId, 'old guide');
    });
    await openDesktop(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    container.read(chatControllerProvider.notifier).state = ChatState(
      sessionId: sessionId,
      frozenMemory: '旧记忆',
    );
    await tester.pump();

    await openSection(tester, 'memory');
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('memory_edit_button'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('memory_edit_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('memory_text_field')),
      '新记忆',
    );
    await tester.tap(find.byKey(const ValueKey('memory_save_button')));
    await waitUntil(tester, () {
      final list = container.read(memoriesProvider(sessionId)).value;
      return list?.isNotEmpty == true && list!.first.content == '新记忆';
    });

    expect(find.textContaining('新记忆'), findsOneWidget);
    expect(find.text('待应用'), findsWidgets);
    expect(find.textContaining('记忆已修改,尚未应用到上下文'), findsOneWidget);

    await openSection(tester, 'imageGuide');
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('image_guide_edit_button'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('image_guide_edit_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('image_guide_text_field')),
      'new guide text',
    );
    await tester.tap(find.byKey(const ValueKey('image_guide_save_button')));
    await waitUntil(tester, () {
      final list = container.read(imageGuideProvider(sessionId)).value;
      return list?.isNotEmpty == true &&
          list!.first.content == 'new guide text';
    });
    expect(find.textContaining('new guide text'), findsOneWidget);

    await tester.runAsync(() async {
      expect(
        (await MemoryRepository(db).bySession(sessionId)).single.content,
        '新记忆',
      );
      expect(
        (await ImageGuideRepository(db).bySession(sessionId)).single.content,
        'new guide text',
      );
    });
    await closeDb(tester);
  });

  testWidgets('工作区溢出菜单可清空记忆与生图指导', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MemoryRepository(db).set(sessionId, '旧记忆');
      await ImageGuideRepository(db).set(sessionId, 'old guide');
    });
    await openDesktop(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );

    await openSection(tester, 'memory');
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('memory_edit_button'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await waitUntil(tester, () {
      final list = container.read(memoriesProvider(sessionId)).value;
      return list != null && list.isEmpty;
    });
    expect(find.text('暂无记忆'), findsOneWidget);

    await openSection(tester, 'imageGuide');
    await waitUntil(
      tester,
      () => find
          .byKey(const ValueKey('image_guide_edit_button'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await waitUntil(tester, () {
      final list = container.read(imageGuideProvider(sessionId)).value;
      return list != null && list.isEmpty;
    });
    expect(find.text('暂无生图指导'), findsOneWidget);

    await closeDb(tester);
  });

  testWidgets('引擎分区:直接选择 Agentic 与关闭引擎均落库', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await openDesktop(tester);

    await tester.tap(find.text('Agentic'));
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final saved = await AppSettingsRepository(db).load();
        if (saved.backgroundMode == BackgroundMode.agentic) break;
      }
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final saved = await AppSettingsRepository(db).load();
      expect(saved.backgroundEnabled, isTrue);
      expect(saved.backgroundMode, BackgroundMode.agentic);
    });

    await tester.tap(find.byKey(const ValueKey('engine_power_switch')));
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final saved = await AppSettingsRepository(db).load();
        if (!saved.backgroundEnabled) break;
      }
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final saved = await AppSettingsRepository(db).load();
      expect(saved.backgroundEnabled, isFalse);
      expect(saved.backgroundMode, BackgroundMode.agentic);
    });
    await closeDb(tester);
  });

  testWidgets('回收站对话框:删除后恢复为 protected', (tester) async {
    useDesktopSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
    });
    await openDesktop(tester);
    await openSection(tester, 'variables');
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('删除变量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await waitUntil(
      tester,
      () => find.byTooltip('已删除的变量(1)').evaluate().isNotEmpty,
    );

    await tester.tap(find.byTooltip('已删除的变量(1)'));
    await tester.pumpAndSettle();
    expect(find.text('已删除的变量'), findsOneWidget);
    expect(find.text('hp'), findsOneWidget);
    // 条目少时对话框按内容收缩,不再固定 70% 屏高。
    expect(
      tester.getSize(find.byKey(const ValueKey('status_dialog_frame'))).height,
      lessThan(600),
    );
    await tester.tap(find.byTooltip('恢复变量'));
    await waitUntil(tester, () => find.text('恢复变量').evaluate().isEmpty);

    await tester.runAsync(() async {
      final rows = await VariableRepository(db).rowsBySession(sessionId);
      expect(rows.single.key, 'hp');
      expect(rows.single.agentAccess.name, 'protected');
    });
    await closeDb(tester);
  });

  testWidgets('Agentic 增强在桌面等高设置卡内不溢出', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await openDesktop(
      tester,
      settings: const AppSettings(
        backgroundMode: BackgroundMode.agentic,
        backgroundVariableInjection: true,
        backgroundNextSuggestions: true,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('查看说明'), findsNWidgets(2));
    final injection = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '变量注入主写'),
    );
    expect(injection.onChanged, isNotNull);
    expect(injection.subtitle, isNull);
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '下一步建议'))
          .onChanged,
      isNotNull,
    );
    // 三列等高布局在断点附近最容易因文字换行低估固有高度:多宽度扫一遍。
    for (final width in [1000.0, 1100.0, 1280.0, 1366.0, 1600.0]) {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $width');
    }

    // Legacy 下两开关置灰,同样不能溢出。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await openDesktop(tester, settings: const AppSettings());
    await waitUntil(
      tester,
      () => find
          .widgetWithText(SwitchListTile, '变量注入主写')
          .evaluate()
          .isNotEmpty,
    );
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '变量注入主写'),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '下一步建议'))
          .onChanged,
      isNull,
    );
    for (final width in [1000.0, 1100.0, 1280.0, 1366.0, 1600.0]) {
      tester.view.physicalSize = Size(width, 1000);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'legacy width $width');
    }
    await closeDb(tester);
  });

  testWidgets('桌面 compact 密度下维护设置卡等高不溢出', (tester) async {
    // 桌面平台默认 VisualDensity.compact;ListTile 的固有高度不含
    // minVerticalPadding,带 InfoButton 的行实际 46、固有只报 40,
    // 双列/三列等高卡会少算 6px。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1120, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await openDesktop(
      tester,
      settings: const AppSettings(
        backgroundMode: BackgroundMode.agentic,
        backgroundVariableInjection: true,
        backgroundNextSuggestions: true,
      ),
    );
    expect(tester.takeException(), isNull);
    for (final scale in [1.0, 1.25, 1.5]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      for (final width in [1000.0, 1120.0, 1280.0, 1345.0, 1360.0, 1600.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: 'scale $scale width $width',
        );
      }
    }
    debugDefaultTargetPlatformOverride = null;
    await closeDb(tester);
  });
}
