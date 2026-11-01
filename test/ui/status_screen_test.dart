import 'dart:async';

import 'package:flutter/material.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/engine/background_engine.dart';
import 'package:microscritt/engine/orchestrator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_guide_repository.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/engine/background_status.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/variable.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/common/section_header.dart';
import 'package:microscritt/ui/status_screen.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

class _DeferredVariableBackend implements LlmBackend {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  String get id => 'deferred-variable';

  void unblock() {
    if (!release.isCompleted) release.complete();
  }

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    started.complete();
    await release.future;
    yield const TextDelta('{"variables":{"hp":"8"}}');
    yield const DoneEvent();
  }
}

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

  /// 把测试视口加高,避免新增的后台"维护功能"选择区把下面的技能/变量/记忆
  /// 小节挤出屏幕(否则 ListView 惰性构建时它们不渲染,find 找不到)。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'shows variables and memory (skills are global, not session state)',
    (tester) async {
      useTallSurface(tester);
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's');
        await VariableRepository(db).upsert(sessionId, 'hp', '8/10');
        await MemoryRepository(db).set(sessionId, '玩家在酒馆救了 Alice');
      });
      await tester.pumpWidget(harness());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      // CW 批起"记忆"不再出现在后台"维护功能"选择区(用户主动维护),
      // 小节标题各一次;数据文本按实际出现次数断言。
      // 技能自 v37 起是全局目录(设置页管理),状态面板不再有技能小节;
      // 记忆自 CW 批起退出后台"维护功能"选择区(用户主动维护),只剩小节标题一次。
      expect(find.text('技能'), findsNothing);
      expect(find.text('剑术'), findsNothing);
      expect(find.text('变量'), findsNWidgets(2));
      expect(find.text('hp'), findsOneWidget);
      expect(find.text('8/10'), findsOneWidget);
      expect(find.text('记忆'), findsOneWidget);
      expect(find.textContaining('玩家在酒馆救了 Alice'), findsOneWidget);
      // 记忆的两项主动维护动作作为卡片内操作行展示(不再是与卡片分离的按钮行)。
      expect(find.text('依据全部对话重生成'), findsOneWidget);
      expect(find.text('应用到上下文'), findsOneWidget);
      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets('clear memory button empties the memory section', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MemoryRepository(db).set(sessionId, '会被清掉的记忆');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(find.textContaining('会被清掉的记忆'), findsOneWidget);

    // 清空入口收进了标题行菜单:先开菜单再点「清空」。
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空记忆?'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('清空').last);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(memoriesProvider(sessionId));
        if (st.value?.isEmpty ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    expect(find.textContaining('会被清掉的记忆'), findsNothing);
    expect(find.textContaining('尚无记忆'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('each memory row has a delete button that removes that row', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MemoryRepository(db).set(sessionId, '记忆A');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(find.text('记忆A'), findsOneWidget);

    // 标题行「记忆」右侧的操作菜单(记忆每会话一条,删除与清空重合,
    // 行内操作统一收进此处)。
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    // 打开菜单点「清空」,确认对话框后该条记忆被移除。
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空记忆?'), findsOneWidget);
    await tester.tap(find.text('清空').last);
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(memoriesProvider(sessionId));
        if (st.value?.isEmpty ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    expect(find.text('记忆A'), findsNothing);
    expect(find.textContaining('尚无记忆'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets(
    'tapping a memory row opens the edit sheet and saves the content',
    (tester) async {
      useTallSurface(tester);
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's');
        await MemoryRepository(db).set(sessionId, '原始记忆');
      });
      await tester.pumpWidget(harness());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      expect(find.text('原始记忆'), findsOneWidget);

      // 点内容行直接进入编辑(编辑入口不再放在标题行菜单)。
      await tester.tap(find.text('原始记忆'));
      await tester.pumpAndSettle();
      expect(find.text('编辑记忆'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '用户手工修订后的记忆');
      await tester.tap(find.text('保存'));
      // 等 invalidate 后 memoriesProvider 重取落库结果。
      await tester.runAsync(() async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(StatusScreen)),
        );
        for (var i = 0; i < 80; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          final st = container.read(memoriesProvider(sessionId));
          if (st.value?.single.content == '用户手工修订后的记忆') break;
        }
        await tester.pumpAndSettle();
      });

      expect(find.text('原始记忆'), findsNothing);
      expect(find.textContaining('用户手工修订后的记忆'), findsOneWidget);
      // 库里也确实更新了。
      await tester.runAsync(() async {
        expect(
          (await MemoryRepository(db).bySession(sessionId)).single.content,
          '用户手工修订后的记忆',
        );
        await db.db.close();
      });
    },
  );

  testWidgets('记忆修改未应用时高亮应用入口,确认后应用到上下文', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MemoryRepository(db).set(sessionId, '旧记忆');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    // 模拟聊天控制器已装载本会话:上下文冻结副本是旧的库版本。
    container.read(chatControllerProvider.notifier).state = ChatState(
      sessionId: sessionId,
      frozenMemory: '旧记忆',
    );
    await tester.pump();
    // 记忆与冻结副本一致:入口保持普通样式。
    expect(find.text('待应用'), findsNothing);

    // 库中记忆被改写 → 入口高亮为待应用。
    await tester.runAsync(() async {
      await MemoryRepository(db).set(sessionId, '新记忆');
    });
    container.invalidate(memoriesProvider(sessionId));
    await tester.pump(); // 重建触发重新读库,再给 DB 落定窗口。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(find.text('待应用'), findsOneWidget);
    expect(find.text('记忆已修改,尚未应用到上下文'), findsOneWidget);

    // 取消确认不应用。
    await tester.tap(find.text('应用到上下文'));
    await tester.pumpAndSettle();
    expect(find.text('应用到上下文?'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(chatControllerProvider).frozenMemory, '旧记忆');
    expect(find.text('待应用'), findsOneWidget);

    // 确认后冻结副本换新,待应用标记消失。
    await tester.tap(find.text('应用到上下文'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('应用'));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (container.read(chatControllerProvider).frozenMemory == '新记忆') {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    expect(container.read(chatControllerProvider).frozenMemory, '新记忆');
    expect(find.text('待应用'), findsNothing);

    // 记忆被清空但上下文仍冻结旧版本:空态最多三行操作收在同一张卡里。
    await tester.runAsync(() async {
      await MemoryRepository(db).clear(sessionId);
    });
    container.invalidate(memoriesProvider(sessionId));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(find.text('记忆已清空,上下文仍保留旧版本'), findsOneWidget);
    final emptyActionsCard = find.ancestor(
      of: find.text('生成初始记忆'),
      matching: find.byType(GroupCard),
    );
    expect(emptyActionsCard, findsOneWidget);
    for (final label in ['生成初始记忆', '手动填写记忆', '应用到上下文']) {
      expect(
        find.descendant(of: emptyActionsCard, matching: find.text(label)),
        findsOneWidget,
        reason: '空态操作行 $label 应在同一张卡内',
      );
    }

    await tester.runAsync(() => db.db.close());
  });

  testWidgets(
    'shows a memory-init button when memory is empty and the memory feature is on',
    (tester) async {
      useTallSurface(tester);
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's');
      });
      await tester.pumpWidget(harness());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      // 记忆为空:初始化按钮出现(CW 批起不依赖后台 memory 功能开关)。
      expect(find.textContaining('尚无记忆'), findsOneWidget);
      expect(find.text('生成初始记忆'), findsOneWidget);

      // 记忆非空后按钮消失(初始化已完成,不再需要)。直接落库不会自动失效
      // memoriesProvider,经容器 invalidate 后等待重取。
      await tester.runAsync(() async {
        await MemoryRepository(db).set(sessionId, '已初始化的记忆');
      });
      await tester.runAsync(() async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(StatusScreen)),
        );
        container.invalidate(memoriesProvider(sessionId));
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          final st = container.read(memoriesProvider(sessionId));
          if (st.value?.isNotEmpty ?? false) break;
        }
        await tester.pump();
      });
      expect(find.text('生成初始记忆'), findsNothing);
      expect(find.textContaining('已初始化的记忆'), findsOneWidget);
      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'shows the memory-init button regardless of background features (CW: user-maintained)',
    (tester) async {
      useTallSurface(tester);
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's');
      });
      // CW 批起记忆是用户主动维护(不再是后台功能):即使后台agent 全关,空记忆的
      // 「生成初始记忆」按钮照常出现。
      const settings = AppSettings(
        backgroundEnabled: false,
        features: BackgroundFeatures(variables: true, image: true),
      );
      await tester.pumpWidget(harness(settings: settings));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      expect(find.textContaining('尚无记忆'), findsOneWidget);
      expect(find.text('生成初始记忆'), findsOneWidget);
      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets('empty memory can be initialized manually without an AI round', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    // 空态同时提供 AI 初始化与手动填写两条路。
    expect(find.text('生成初始记忆'), findsOneWidget);
    expect(find.text('手动填写记忆'), findsOneWidget);

    await tester.tap(find.text('手动填写记忆'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '手写初始记忆');
    // 空初始文本时「保存」首帧为禁用态,输入后需走一帧让 setState 生效。
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(memoriesProvider(sessionId));
        if (st.value?.isNotEmpty ?? false) break;
      }
      await tester.pumpAndSettle();
      expect(
        (await MemoryRepository(db).bySession(sessionId)).single.content,
        '手写初始记忆',
      );
      await db.db.close();
    });

    expect(find.text('生成初始记忆'), findsNothing);
    expect(find.textContaining('手写初始记忆'), findsOneWidget);
  });

  testWidgets('empty image guide can be initialized manually', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(find.text('生成初始指导'), findsOneWidget);
    expect(find.text('手动填写指导'), findsOneWidget);

    await tester.tap(find.text('手动填写指导'));
    await tester.pumpAndSettle();
    expect(find.text('手动填写生图指导'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      '1girl, red hair, looking at viewer',
    );
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(imageGuideProvider(sessionId));
        if (st.value?.isNotEmpty ?? false) break;
      }
      await tester.pumpAndSettle();
      expect(
        (await ImageGuideRepository(db).bySession(sessionId)).single.content,
        '1girl, red hair, looking at viewer',
      );
      await db.db.close();
    });

    expect(find.text('生成初始指导'), findsNothing);
    expect(find.textContaining('1girl'), findsOneWidget);
  });

  testWidgets(
    'tapping the image guide row edits it inline (no separate button)',
    (tester) async {
      useTallSurface(tester);
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's');
        await ImageGuideRepository(db).set(sessionId, 'old guide text');
      });
      await tester.pumpWidget(harness());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      expect(find.text('old guide text'), findsOneWidget);
      // 旧的独立「编辑指导」按钮已移除,编辑入口就是内容行本身。
      expect(find.text('编辑指导'), findsNothing);

      await tester.tap(find.text('old guide text'));
      await tester.pumpAndSettle();
      expect(find.text('编辑生图指导'), findsOneWidget);
      // 编辑区与记忆底单同高(屏幕 70%、封顶 620),不再用默认的 420。
      expect(tester.getSize(find.byType(TextField)).height, greaterThan(500));
      await tester.enterText(find.byType(TextField), 'new guide text');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.runAsync(() async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(StatusScreen)),
        );
        for (var i = 0; i < 80; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          final list = container.read(imageGuideProvider(sessionId)).value;
          if (list != null &&
              list.isNotEmpty &&
              list.first.content == 'new guide text') {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(
          (await ImageGuideRepository(db).bySession(sessionId)).single.content,
          'new guide text',
        );
        await db.db.close();
      });

      expect(find.text('old guide text'), findsNothing);
      expect(find.textContaining('new guide text'), findsOneWidget);
    },
  );

  testWidgets('shows the background-agent card and its switch state', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    // 状态卡标题 + 默认启用个开关(后台卡的第一个 Switch)。
    expect(find.text('后台agent'), findsOneWidget);
    final switchWidget = tester.widget<Switch>(find.byType(Switch).first);
    expect(switchWidget.value, isTrue);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('shows the maintenance-feature selectors when background is on', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    // 后台agent 默认启用 → 出现"维护功能"选择区,两项快状态开关
    // (技能 v37 迁出;记忆 CW 批起改为用户主动维护,同样迁出;
    // 桌面面板 2.2 起整体移除)。
    expect(find.text('维护功能'), findsOneWidget);
    // 用 SwitchListTile 内的文本定位,避免与上方"变量/记忆"小节标题撞名。
    expect(find.widgetWithText(SwitchListTile, '技能'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, '记忆'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, '桌面面板'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, '变量'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, '生图'), findsOneWidget);

    // 2 项维护功能 + 1 项删除前确认 + 2 项上下文锚定。前两者与锚定默认开,
    // 删除前确认默认关(自动删除 + 回收站可恢复)。
    final switches = tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(switches.length, 5);
    expect(find.widgetWithText(SwitchListTile, '删除前确认'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '删除前确认'))
          .value,
      isFalse,
    );
    expect(switches.where((s) => s.value).length, 4);

    // EV 批:上下文锚定小节 —— 角色卡/记忆进入后台上下文开关,默认开。
    expect(find.text('上下文锚定'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, '角色卡进入上下文'), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, '记忆进入上下文'), findsOneWidget);

    // 后台专用模型选择区:有"专用模型"标签 + 默认"跟随主写引擎"选项(未选时 null)。
    expect(find.text('专用模型'), findsOneWidget);
    expect(find.text('跟随主写引擎'), findsOneWidget);

    // v48:推理强度下拉默认"关闭"(独立于主对话的推理等级设置)。
    expect(find.text('推理强度'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('上下文锚定开关切换后落库生效,另一开关不受影响(EV 批)', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    // 默认都开。关掉「记忆进入上下文」。
    final memSwitch = find.widgetWithText(SwitchListTile, '记忆进入上下文');
    expect(tester.widget<SwitchListTile>(memSwitch).value, isTrue);
    await tester.runAsync(() async {
      await tester.tap(memSwitch);
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final s = await AppSettingsRepository(db).load();
        if (!s.backgroundMemoryAnchor) break;
      }
      await tester.pumpAndSettle();
    });

    // 记忆开关已落库为关;角色卡开关不受影响仍为开。
    await tester.runAsync(() async {
      final saved = await AppSettingsRepository(db).load();
      expect(saved.backgroundMemoryAnchor, isFalse);
      expect(saved.backgroundCharacterAnchor, isTrue);
      await db.db.close();
    });
  });

  testWidgets('a stale background model id falls back without crashing', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    // 后台专用模型指向一个已被删除的模型 id(不在任何 provider 的模型目录里):
    // dropdown 的 value 不在 items 中,DropdownButton 会断言崩溃 —— 应兜底到
    // "跟随主写引擎"且不抛错(ChatController 侧同样回退主写模型)。
    await tester.pumpWidget(
      harness(settings: const AppSettings(backgroundModelId: 42)),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('专用模型'), findsOneWidget);
    expect(find.text('跟随主写引擎'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('后台世界书底单:内容预览 + 全选/取消全选保存落库(EU/EW 批)', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(
          characterId: 0,
          name: '酒馆',
          keys: ['酒馆'],
          content: '喧闹的木质酒馆,炉火摇曳',
        ),
        WorldbookEntry(
          characterId: 0,
          name: '圣剑',
          keys: ['圣剑'],
          content: '被诅咒的银剑,剑身泛冷光',
        ),
      ]);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings()),
          chatControllerProvider.overrideWith(() => _CharState(charId)),
        ],
        child: MaterialApp(home: StatusScreen(sessionId: sessionId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(find.text('后台世界书条目'), findsOneWidget);
    expect(find.textContaining('已选 0 / 2'), findsOneWidget);

    // 打开底单 → 条目名 + 内容预览都直接可见(移动端底单形态)。
    await tester.tap(find.text('后台世界书条目'));
    await tester.pumpAndSettle();
    expect(find.text('酒馆'), findsOneWidget);
    expect(find.text('圣剑'), findsOneWidget);
    // 两行摘要预览:每条的内容文本出现在底单里。
    expect(find.text('喧闹的木质酒馆,炉火摇曳'), findsOneWidget);
    expect(find.text('被诅咒的银剑,剑身泛冷光'), findsOneWidget);
    // 每条尾部有展开箭头(点开看完整内容)。用 tooltip 定位 —— 状态面板上
    // 两个下拉框也带 expand_more 图标,底单打开时仍在树里。
    expect(find.byTooltip('展开预览'), findsNWidgets(2));
    // 保存键带实时计数(当前 0 选中)。
    expect(find.text('保存(0)'), findsOneWidget);

    // 点一行 = 切换勾选,保存键计数随之 +1。
    await tester.tap(find.text('酒馆'));
    await tester.pump();
    expect(find.text('保存(1)'), findsOneWidget);

    // 全选 → 保存,两条都进后台上下文。
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.text('保存(2)'), findsOneWidget);
    await tester.tap(find.text('保存(2)'));
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(worldbookProvider(charId));
        if (st.value?.every((e) => e.background) ?? false) break;
      }
      await tester.pumpAndSettle();
    });
    expect(find.textContaining('已选 2 / 2'), findsOneWidget);
    await tester.runAsync(() async {
      final rows = await WorldbookRepository(db).byCharacter(charId);
      expect(rows.every((e) => e.background), isTrue);
    });

    // 再开底单 → 展开一条看完整内容 → 取消全选 → 保存,全部退出。
    await tester.tap(find.text('后台世界书条目'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开预览').first);
    await tester.pump();
    // 展开后箭头翻转为收起,内容仍在(完整形态)。
    expect(find.byTooltip('收起预览'), findsOneWidget);
    expect(find.text('喧闹的木质酒馆,炉火摇曳'), findsOneWidget);
    await tester.tap(find.text('取消全选'));
    await tester.pump();
    await tester.tap(find.text('保存(0)'));
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(worldbookProvider(charId));
        if (st.value?.every((e) => !e.background) ?? false) break;
      }
      await tester.pumpAndSettle();
    });
    expect(find.textContaining('已选 0 / 2'), findsOneWidget);
    await tester.runAsync(() async {
      final rows = await WorldbookRepository(db).byCharacter(charId);
      expect(rows.every((e) => !e.background), isTrue);
      await db.db.close();
    });
  });

  testWidgets('后台世界书:停用条目不计入生效数,底单当场提示(勾选保真落库)', (tester) async {
    // 引擎口径是 `background && enabled`(BackgroundEngine._backgroundWorldbookText):
    // 停用条目勾了也不进上下文。计数与提示必须对齐该口径,否则"已选 N 条进入后台
    // 上下文"会把停用条目算成生效,排查时被带偏。
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(
          characterId: 0,
          name: '启用条',
          keys: ['a'],
          content: '生效内容',
        ),
        WorldbookEntry(
          characterId: 0,
          name: '停用条',
          keys: ['b'],
          content: '停用内容',
          enabled: false,
        ),
      ]);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings()),
          chatControllerProvider.overrideWith(() => _CharState(charId)),
        ],
        child: MaterialApp(home: StatusScreen(sessionId: sessionId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    // 空选:无停用后缀(不打扰正常路径)。
    expect(find.textContaining('已选 0 / 2 条进入后台上下文'), findsOneWidget);
    expect(find.textContaining('已停用不生效'), findsNothing);

    // 全选(含停用条)→ 底单内当场说明后果。
    await tester.tap(find.text('后台世界书条目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.text('其中 1 条已停用,勾选也不会进入后台上下文'), findsOneWidget);

    await tester.tap(find.text('保存(2)'));
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final st = container.read(worldbookProvider(charId));
        if (st.value?.every((e) => e.background) ?? false) break;
      }
      await tester.pumpAndSettle();
    });

    // 勾选保真(停用条也写 background 列,便于稍后启用),但只有 1 条算生效。
    expect(find.textContaining('已选 1 / 2 条进入后台上下文'), findsOneWidget);
    expect(find.textContaining('1 条已停用不生效'), findsOneWidget);
    await tester.runAsync(() async {
      final rows = await WorldbookRepository(db).byCharacter(charId);
      expect(rows.every((e) => e.background), isTrue);
      await db.db.close();
    });
  });

  testWidgets('后台失败诊断摘要在状态面板全文可见,不再两行省略(EO 批)', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    const tail = '诊断尾巴ENDMARK';
    final longSummary = '后台调用出错,状态维护已跳过(${'网关 502 · 上游错误,' * 30}$tail)';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings()),
          chatControllerProvider.overrideWith(
            () => _FailedBgState(longSummary),
          ),
        ],
        child: MaterialApp(home: StatusScreen(sessionId: sessionId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(find.textContaining('后台调用出错,状态维护已跳过'), findsOneWidget);
    // 全文(含引擎诊断摘要结尾)可见 —— 灵岛闪示两行省略后的全文回看处。
    expect(find.textContaining(tail), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('后台成功长摘要默认折叠为 3 行,可展开查看全文', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    final longSummary = '本轮维护成功:${'新增变量 hp→9、技能 战斗、重新生成场景图;' * 12}摘要结尾ENDMARK';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings()),
          chatControllerProvider.overrideWith(
            () => _SucceededBgState(longSummary),
          ),
        ],
        child: MaterialApp(home: StatusScreen(sessionId: sessionId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    // 即使摘要很长,状态卡顶部的图标、标题、开关仍保持同一行(垂直居中)。
    final statusCard = find
        .ancestor(of: find.text('后台agent'), matching: find.byType(Card))
        .first;
    final titleY = tester.getCenter(find.text('后台agent')).dy;
    final iconY = tester
        .getCenter(
          find.descendant(
            of: statusCard,
            matching: find.byIcon(Icons.psychology_outlined),
          ),
        )
        .dy;
    final switchY = tester
        .getCenter(
          find.descendant(of: statusCard, matching: find.byType(Switch)),
        )
        .dy;
    expect(iconY, closeTo(titleY, 1));
    expect(switchY, closeTo(titleY, 1));

    // 灰块左右边缘与「专用模型」下拉框对齐(两张卡的内边距不同,
    // 这里把两组内缩都算进去后比较实际渲染矩形)。
    final summaryBox = find.byKey(const ValueKey('background-summary-box'));
    final modelField = find.byKey(const ValueKey('background_model_follow'));
    expect(summaryBox, findsOneWidget);
    expect(modelField, findsOneWidget);
    final summaryRect = tester.getRect(summaryBox);
    final modelRect = tester.getRect(modelField);
    expect(summaryRect.left, closeTo(modelRect.left, 1));
    expect(summaryRect.right, closeTo(modelRect.right, 1));

    final summaryText = find.text(longSummary);
    expect(summaryText, findsOneWidget);
    expect(tester.widget<Text>(summaryText).maxLines, 3);
    final expandButton = find.text('展开');
    expect(expandButton, findsOneWidget);

    await tester.tap(expandButton);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(summaryText).maxLines, isNull);
    expect(find.text('收起'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  for (final rename in [false, true]) {
    testWidgets('后台挂起时${rename ? '改名' : '改值'}不被旧变量结果覆盖', (tester) async {
      useTallSurface(tester);
      late _DeferredVariableBackend backend;
      late Future<BackgroundTurnResult> pending;
      await tester.runAsync(() async {
        // 闸门若创建在假时钟区,runAsync 会等待无法推进的微任务。
        backend = _DeferredVariableBackend();
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's');
        final variables = VariableRepository(db);
        final messages = MessageRepository(db);
        await variables.upsert(sessionId, 'hp', '10');
        await messages.append(
          sessionId: sessionId,
          role: 'assistant',
          content: 'hp changes to 8',
        );
        pending =
            Orchestrator(
              BackgroundEngine(backend),
              variables,
              MemoryRepository(db),
              messages,
              ImageGuideRepository(db),
            ).runAfterTurn(
              sessionId: sessionId,
              model: 'test',
              features: const BackgroundFeatures(variables: true, image: false),
            );
        await backend.started.future;
      });
      addTearDown(backend.unblock);
      await tester.pumpWidget(harness());
      await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StatusScreen)),
      );
      await tester.tap(find.text('hp'));
      await tester.pumpAndSettle();
      if (rename) {
        await tester.enterText(find.byType(TextField).at(0), 'health');
      }
      await tester.enterText(find.byType(TextField).at(1), '5');
      await tester.tap(find.text('保存'));
      final key = rename ? 'health' : 'hp';
      await waitUntil(
        tester,
        () => container.read(variablesProvider(sessionId)).value?[key] == '5',
      );
      await tester.runAsync(() async {
        backend.unblock();
        final turn = await pending;
        expect(turn.variableConflict, isTrue);
        expect(turn.cursorSeq, isNull);
        expect(await VariableRepository(db).bySession(sessionId), {key: '5'});
      });
      await tester.pump();
      expect(find.text(key), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      if (rename) expect(find.text('hp'), findsNothing);
      await tester.runAsync(() => db.db.close());
    });
  }

  testWidgets('变量行可点开编辑底单改值,落库并刷新面板', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
    });
    await tester.pumpWidget(harness());
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );

    // 点行 = 编辑(不是删除),底单带键/值两个输入框。
    await tester.tap(find.text('hp'));
    await tester.pumpAndSettle();
    expect(find.text('编辑变量'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    // 第 0 个输入框是键,第 1 个是值。
    await tester.enterText(find.byType(TextField).at(1), '5');
    await tester.tap(find.text('保存'));
    await waitUntil(
      tester,
      () => container.read(variablesProvider(sessionId)).value?['hp'] == '5',
    );

    expect(find.text('8'), findsNothing);
    expect(find.text('5'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), {'hp': '5'});
      await db.db.close();
    });
  });

  testWidgets('变量改键名后旧键不留残行', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
    });
    await tester.pumpWidget(harness());
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    await tester.tap(find.text('hp'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'health');
    await tester.tap(find.text('保存'));
    await waitUntil(
      tester,
      () =>
          container
              .read(variablesProvider(sessionId))
              .value
              ?.containsKey('health') ??
          false,
    );

    expect(find.text('hp'), findsNothing);
    expect(find.text('health'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), {
        'health': '8',
      });
      await db.db.close();
    });
  });

  testWidgets('变量行尾删除按钮删除该条(带确认)', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
      await VariableRepository(db).upsert(sessionId, 'location', 'cave');
    });
    await tester.pumpWidget(harness());
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );

    // 从 hp 那一行内部取删除键 —— 不依赖变量在列表里的顺序。
    final hpRow = find.ancestor(
      of: find.text('hp'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: hpRow, matching: find.byTooltip('删除变量')),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除变量?'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await waitUntil(
      tester,
      () =>
          container
              .read(variablesProvider(sessionId))
              .value
              ?.containsKey('hp') ==
          false,
    );

    expect(find.text('hp'), findsNothing);
    expect(find.text('location'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), {
        'location': 'cave',
      });
      await db.db.close();
    });
  });

  testWidgets('空变量表可手动新增一条', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.textContaining('尚未写入变量').evaluate().isNotEmpty,
    );

    await tester.tap(find.text('新增变量'));
    await tester.pumpAndSettle();
    // 底单的字段标签(空态按钮与底单标题同名,故用标签定位)。
    expect(find.text('键'), findsOneWidget);
    expect(find.text('值'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'mood');
    await tester.enterText(find.byType(TextField).at(1), 'calm');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    await tester.tap(find.text('保存'));
    await waitUntil(
      tester,
      () =>
          container.read(variablesProvider(sessionId)).value?['mood'] == 'calm',
    );

    expect(find.text('mood'), findsOneWidget);
    expect(find.text('calm'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), {
        'mood': 'calm',
      });
      await db.db.close();
    });
  });

  testWidgets('人工新增默认 protected,编辑底单可改为 full', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.textContaining('尚未写入变量').evaluate().isNotEmpty,
    );

    final repo = VariableRepository(db);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    await tester.tap(find.text('新增变量'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'mood');
    await tester.enterText(find.byType(TextField).at(1), 'calm');
    await tester.tap(find.text('保存'));
    await waitUntil(
      tester,
      () =>
          container.read(variablesProvider(sessionId)).value?['mood'] == 'calm',
    );
    await tester.runAsync(() async {
      final rows = await repo.rowsBySession(sessionId);
      expect(rows.single.agentAccess, VariableAccess.protected);
    });

    await tester.tap(find.text('mood'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可改不可删'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可改可删').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await waitUntil(
      tester,
      () =>
          container
              .read(variableRowsProvider(sessionId))
              .value
              ?.single
              .agentAccess ==
          VariableAccess.full,
    );
    await tester.runAsync(() async {
      final rows = await repo.rowsBySession(sessionId);
      expect(rows.single.agentAccess, VariableAccess.full);
      await db.db.close();
    });
  });

  testWidgets('删除前确认开关落库', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.textContaining('尚未写入变量').evaluate().isNotEmpty,
    );

    await tester.tap(find.widgetWithText(SwitchListTile, '删除前确认'));
    // 开关回调里有真实 DB 写入:留在 runAsync 里让它完成,别用 pumpAndSettle
    // 在假时钟上空转(变量区若仍在 loading,pumpAndSettle 会被 spinner 拖住)。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '删除前确认'))
          .value,
      isTrue,
    );
    await tester.runAsync(() async {
      expect(
        (await AppSettingsRepository(db).load()).backgroundDeletionConfirm,
        isTrue,
      );
      await db.db.close();
    });
  });

  testWidgets('严格模式的待确认删除可执行并进入回收站', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final repo = VariableRepository(db);
      await repo.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      final before = await repo.snapshot(sessionId);
      await repo.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {},
        removals: ['a'],
        confirmRemovals: true,
      );
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.text('后台建议删除的变量 (1)').evaluate().isNotEmpty,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    await tester.tap(find.byTooltip('执行删除'));
    await waitUntil(
      tester,
      () =>
          container.read(variablesProvider(sessionId)).value?.isEmpty ?? false,
    );
    expect(find.text('后台建议删除的变量 (1)'), findsNothing);
    await tester.runAsync(() async {
      final trash = await VariableRepository(db).trash(sessionId);
      expect(trash.single.key, 'a');
      expect(trash.single.byAgent, isTrue);
      await db.db.close();
    });
  });

  testWidgets('严格模式的待确认删除可忽略,变量保持不变', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final repo = VariableRepository(db);
      await repo.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      final before = await repo.snapshot(sessionId);
      await repo.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {},
        removals: ['a'],
        confirmRemovals: true,
      );
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.text('后台建议删除的变量 (1)').evaluate().isNotEmpty,
    );

    await tester.tap(find.byTooltip('忽略建议'));
    await waitUntil(
      tester,
      () => find.text('后台建议删除的变量 (1)').evaluate().isEmpty,
    );
    expect(find.text('a'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), {'a': '1'});
      expect(await VariableRepository(db).pendingDeletions(sessionId), isEmpty);
      await db.db.close();
    });
  });

  testWidgets('变量菜单可打开回收站并恢复为 protected', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final repo = VariableRepository(db);
      await repo.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      await repo.delete(sessionId, 'a');
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.byIcon(Icons.more_vert).evaluate().isNotEmpty,
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已删除 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('已删除的变量'), findsOneWidget);
    await tester.tap(find.byTooltip('恢复变量'));
    await waitUntil(tester, () => find.text('回收站是空的').evaluate().isNotEmpty);
    await tester.runAsync(() async {
      final rows = await VariableRepository(db).rowsBySession(sessionId);
      expect(rows.single.key, 'a');
      expect(rows.single.agentAccess, VariableAccess.protected);
      await db.db.close();
    });
  });

  testWidgets('回收站可彻底删除单条变量', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final repo = VariableRepository(db);
      await repo.upsert(sessionId, 'a', '1');
      await repo.delete(sessionId, 'a');
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.byIcon(Icons.more_vert).evaluate().isNotEmpty,
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已删除 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('已删除的变量'), findsOneWidget);

    await tester.tap(find.byTooltip('彻底删除变量'));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除「a」?'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await waitUntil(tester, () => find.text('回收站是空的').evaluate().isNotEmpty);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).trash(sessionId), isEmpty);
      await db.db.close();
    });
  });

  testWidgets('回收站可一键清空', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final repo = VariableRepository(db);
      await repo.upsert(sessionId, 'a', '1');
      await repo.upsert(sessionId, 'b', '2');
      await repo.clear(sessionId);
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.byIcon(Icons.more_vert).evaluate().isNotEmpty,
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已删除 (2)'));
    await tester.pumpAndSettle();
    expect(find.text('已删除的变量'), findsOneWidget);

    await tester.tap(find.byTooltip('清空回收站'));
    await tester.pumpAndSettle();
    expect(find.text('清空回收站?'), findsOneWidget);
    await tester.tap(find.text('清空'));
    await waitUntil(tester, () => find.text('回收站是空的').evaluate().isNotEmpty);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).trash(sessionId), isEmpty);
      await db.db.close();
    });
  });

  testWidgets('变量标题行菜单可清空全部变量', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await VariableRepository(db).upsert(sessionId, 'hp', '8');
      await VariableRepository(db).upsert(sessionId, 'location', 'cave');
    });
    await tester.pumpWidget(harness());
    await waitUntil(tester, () => find.text('hp').evaluate().isNotEmpty);

    // 记忆/生图指导为空时不渲染各自的三点菜单 → 页面上只有变量节这一个。
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空全部变量?'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StatusScreen)),
    );
    await tester.tap(find.text('清空').last);
    await waitUntil(
      tester,
      () =>
          container.read(variablesProvider(sessionId)).value?.isEmpty ?? false,
    );

    expect(find.text('hp'), findsNothing);
    expect(find.textContaining('尚未写入变量'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await VariableRepository(db).bySession(sessionId), isEmpty);
      await db.db.close();
    });
  });

  testWidgets('变量全量底单支持按名称与值检索', (tester) async {
    useTallSurface(tester);
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final repo = VariableRepository(db);
      for (var i = 0; i < 9; i++) {
        await repo.upsert(sessionId, 'k$i', 'v$i');
      }
    });
    await tester.pumpWidget(harness());
    await waitUntil(
      tester,
      () => find.text('查看全部 9 个变量').evaluate().isNotEmpty,
    );

    await tester.tap(find.text('查看全部 9 个变量'));
    await tester.pumpAndSettle();

    final sheet = find.byType(BottomSheet);
    final search = find.descendant(
      of: sheet,
      matching: find.byType(TextField),
    );
    // 行内容用 ListTile 定位:检索框自身也含输入文本,不能用裸 find.text。
    Finder row(String text) => find.descendant(
      of: sheet,
      matching: find.widgetWithText(ListTile, text),
    );
    expect(sheet, findsOneWidget);
    expect(search, findsOneWidget);
    expect(row('k0'), findsOneWidget);
    // 预览只显示前 8 条:第 9 条只在全量底单里出现。
    expect(row('k8'), findsOneWidget);

    // 按键名过滤。
    await tester.enterText(search, 'k8');
    await tester.pump();
    expect(row('k8'), findsOneWidget);
    expect(row('k0'), findsNothing);

    // 按值过滤(大小写不敏感)。
    await tester.enterText(search, 'V7');
    await tester.pump();
    expect(row('k7'), findsOneWidget);
    expect(row('k8'), findsNothing);

    // 无命中显示空态,清空后恢复全量。
    await tester.enterText(search, '不存在');
    await tester.pump();
    expect(
      find.descendant(of: sheet, matching: find.text('没有匹配项')),
      findsOneWidget,
    );
    await tester.enterText(search, '');
    await tester.pump();
    expect(row('k0'), findsOneWidget);
    expect(row('k8'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });
}

/// 固定后台失败状态的 ChatController 替身:只供状态面板读取 backgroundStatus
/// 与 backgroundSummary,不触碰任何 repository(EO 批)。
class _FailedBgState extends ChatController {
  final ChatState _state;
  _FailedBgState(String summary)
    : _state = ChatState(
        backgroundStatus: BackgroundStatus.failed,
        backgroundSummary: summary,
      );
  @override
  ChatState build() => _state;
}

/// 固定后台成功状态的替身:验证长摘要默认折叠。
class _SucceededBgState extends ChatController {
  final ChatState _state;
  _SucceededBgState(String summary)
    : _state = ChatState(
        backgroundStatus: BackgroundStatus.succeeded,
        backgroundSummary: summary,
      );
  @override
  ChatState build() => _state;
}

/// 只带当前角色 id 的 ChatController 替身:供状态面板按角色取世界书条目
/// (后台世界书条目多选,EU 批)。
class _CharState extends ChatController {
  final ChatState _state;
  _CharState(int characterId) : _state = ChatState(characterId: characterId);
  @override
  ChatState build() => _state;
}
