// 聊天页命令与导航 UI:斜杠命令按钮/建议、滚动导航折叠与自动隐藏、灵岛进度
// 反馈、窄屏输入底栏不溢出、压缩后原始消息仍留在聊天流。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import 'package:microscritt/ui/widgets/message_list.dart';
import 'package:microscritt/models/backend_config.dart';
import 'dart:async';
import '../support/test_database.dart';

/// 等待 ChatController.load 的异步 I/O 收敛(否则在假异步区 close db 会撞
/// database_closed)。load 完成后 state.sessionId 非空。
Future<void> _pumpUntilLoaded(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      if (container.read(chatControllerProvider).sessionId != null) break;
    }
    await tester.pumpAndSettle();
  });
}

/// 可受控的后端:compact 摘要调用前保持流打开,测试期间断言"压缩中"动画可见,
/// 之后再关闭流让摘要完成。
class _ControlledBackend implements LlmBackend {
  final StreamController<LlmEvent> controller = StreamController<LlmEvent>();
  @override
  String get id => 'controlled';
  @override
  Stream<LlmEvent> generate(LlmRequest request) => controller.stream;
  void finish() {
    controller.add(const TextDelta('summary.'));
    controller.add(const DoneEvent());
    controller.close();
  }
}

/// 在会话里铺 10 条活跃消息,满足 /compact(keep=6)有可压缩内容。
Future<void> _seedMessages(AppDatabase db, int sessionId) async {
  for (var i = 0; i < 10; i++) {
    await db.db.execute('''
      INSERT INTO messages(session_id, role, content, seq, is_compacted)
      VALUES($sessionId, '${i.isEven ? 'user' : 'assistant'}', 'm$i', $i, 0)
    ''');
  }
}

void main() {
  /// 常驻命令按钮行默认折叠:先点输入框底栏左侧的终端图标展开,再断言命令 chip。
  Future<void> expandCommands(WidgetTester tester) async {
    await tester.tap(find.byTooltip('展开命令按钮行'));
    await tester.pumpAndSettle();
  }

  /// 命令 chip 只把 `/命令 ` 填入输入框;真正执行还需要再按发送。
  Future<void> runCommandChip(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
  }

  testWidgets('chat input shows the five slash-command buttons', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);
    await expandCommands(tester);

    expect(find.text('/test 测试生成'), findsOneWidget);
    expect(find.text('/continue 推动剧情'), findsOneWidget);
    expect(find.text('/clear 清空历史'), findsOneWidget);
    expect(find.text('/compact 主动压缩'), findsOneWidget);
    expect(find.text('/rerun 重跑后台'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('typing / shows slash-command suggestion chips', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    final field = find.byType(TextField);
    await tester.enterText(field, '/t');
    await tester.pumpAndSettle();

    // 前缀 /t 建议 test 命令;点建议只补全输入框,不直接执行。
    expect(find.byType(ActionChip), findsWidgets);
    await tester.tap(find.text('/test 测试生成'));
    await tester.pumpAndSettle();
    final fieldWidget = tester.widget<TextField>(field);
    expect(fieldWidget.controller!.text, '/test ');
    expect(fieldWidget.controller!.selection.baseOffset, '/test '.length);
    expect(fieldWidget.focusNode!.hasFocus, isTrue);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('resident command row uses the same chips and can collapse', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 常驻命令与斜杠建议同款 chip:默认折叠,展开后五个命令各一个 ActionChip。
    expect(find.byType(ActionChip), findsNothing);
    expect(find.byTooltip('展开命令按钮行'), findsOneWidget);
    await expandCommands(tester);
    expect(find.byType(ActionChip), findsNWidgets(5));

    // 折叠按钮内置于输入框:展开时显示上收箭头,点击收起。
    await tester.tap(find.byTooltip('收起命令按钮行'));
    await tester.pumpAndSettle();
    expect(find.text('/test 测试生成'), findsNothing);
    expect(find.byType(ActionChip), findsNothing);

    // 再展开:命令恢复(折叠态输入框底栏左侧显示终端图标)。
    await tester.tap(find.byTooltip('展开命令按钮行'));
    await tester.pumpAndSettle();
    expect(find.text('/compact 主动压缩'), findsOneWidget);
    expect(find.text('/rerun 重跑后台'), findsOneWidget);
    expect(find.byType(ActionChip), findsNWidgets(5));
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('tapping a resident command chip fills the composer', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);
    await expandCommands(tester);

    // 点命令 chip 不再立即执行:命令文本写入输入框、光标在末尾,等待用户
    // 追加参数(如修改方向)后自己按发送。
    await tester.ensureVisible(find.text('/rerun 重跑后台'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/rerun 重跑后台'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '/rerun ');
    expect(field.controller!.selection.baseOffset, '/rerun '.length);
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('narrow command row stays single-line and scrolls with the mouse wheel', (tester) async {
    // 命令 chip 不换行:窄窗下靠后的命令通过横向滚动到达。桌面滚轮只有
    // 纵向 delta,组件内把它映射到横向;这里用真实鼠标滚轮事件验证。
    tester.view
      ..physicalSize = const Size(460, 700)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);
    await expandCommands(tester);

    // 直接按 ActionChip 取位置:chip 的 tooltip 文案与标签相同,悬停后
    // tooltip 覆盖层会让文本匹配出现两份。
    final chips = find.byType(ActionChip);
    expect(chips, findsNWidgets(5));
    final first = tester.getRect(chips.at(0));
    final last = tester.getRect(chips.at(4));
    expect(last.top, first.top, reason: '命令 chip 保持单行,不允许换行');
    expect(last.right, greaterThan(460.0), reason: '窄窗初始状态下最右命令在视口外');

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(chips.at(0))));
    for (var i = 0; i < 8; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 160)));
    }
    await tester.pump();

    final scrolledFirst = tester.getRect(chips.at(0));
    final scrolledLast = tester.getRect(chips.at(4));
    expect(scrolledFirst.left, lessThan(first.left), reason: '滚轮应把命令行横向滚动');
    expect(scrolledLast.right, lessThanOrEqualTo(460.0), reason: '滚动后可看到最右命令');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('floating scroll nav group collapses into a single translucent expand button', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 40; i++) {
        await MessageRepository(db).append(
          sessionId: sessionId,
          role: i.isEven ? 'user' : 'assistant',
          content: 'line $i',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 滚到列表中部:整组导航(含收起钮)可见。
    final scrollable = tester.state<ScrollableState>(find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(Scrollable),
    ));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
    await tester.pump();
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('回到底部'), findsOneWidget);
    expect(find.byTooltip('收起滚动导航'), findsOneWidget);

    // 收起:四个方向钮全部消失,只剩半透明的展开钮。
    await tester.tap(find.byTooltip('收起滚动导航'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('回到顶部'), findsNothing);
    expect(find.byTooltip('上一条消息'), findsNothing);
    expect(find.byTooltip('下一条消息'), findsNothing);
    expect(find.byTooltip('回到底部'), findsNothing);
    expect(find.byTooltip('收起滚动导航'), findsNothing);
    expect(find.byTooltip('展开滚动导航'), findsOneWidget);
    // 折叠态是半透明小钮:几乎不挡正文,但仍是页面内 FAB(hero 标签已禁用)。
    final collapsedFab = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
    expect(collapsedFab.heroTag, isNull);

    // 再展开:方向导航恢复可用。
    await tester.tap(find.byTooltip('展开滚动导航'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('回到底部'), findsOneWidget);
    expect(find.byTooltip('收起滚动导航'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('收起滚动导航 sits between the top and bottom nav halves in the expanded column', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 40; i++) {
        await MessageRepository(db).append(
          sessionId: sessionId,
          role: i.isEven ? 'user' : 'assistant',
          content: 'line $i',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 滚到列表中部:4 个方向钮 + 收起钮都在场,收起钮应夹在 上一条 与 下一条 之间。
    final scrollable = tester.state<ScrollableState>(find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(Scrollable),
    ));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
    await tester.pump();

    final topY = tester.getCenter(find.byTooltip('回到顶部')).dy;
    final prevY = tester.getCenter(find.byTooltip('上一条消息')).dy;
    final collapseY = tester.getCenter(find.byTooltip('收起滚动导航')).dy;
    final nextY = tester.getCenter(find.byTooltip('下一条消息')).dy;
    final bottomY = tester.getCenter(find.byTooltip('回到底部')).dy;
    // 收起钮在 上一条 与 下一条 之间(夹在两组方向钮中间),不与任何方向钮同位。
    expect(topY, lessThan(prevY));
    expect(prevY, lessThan(collapseY));
    expect(collapseY, lessThan(nextY));
    expect(nextY, lessThan(bottomY));
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('floating scroll nav group auto-hides while user drags the list and restores shortly after', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 40; i++) {
        await MessageRepository(db).append(
          sessionId: sessionId,
          role: i.isEven ? 'user' : 'assistant',
          content: 'line $i',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 滚到列表中部:整组可见。
    final scrollableFinder = find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(Scrollable),
    );
    final scrollable = tester.state<ScrollableState>(scrollableFinder);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
    await tester.pump();
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('收起滚动导航'), findsOneWidget);

    // 模拟用户拖动(向上 50px):ScrollStart 触发 _navAutoHidden=true,整组立即消失;
    // ScrollEnd 调度 600ms 延迟恢复(尚未到点),拖动结束后仍处于隐藏态。
    // 加 pump 确保标脏的 State 真的进入下一帧 build,否则
    // notification 派发完成时 build 可能尚未排到,断言会落在旧树上看不到隐藏。
    await tester.drag(scrollableFinder, const Offset(0, -50));
    await tester.pump();
    expect(find.byTooltip('回到顶部'), findsNothing);
    expect(find.byTooltip('回到底部'), findsNothing);
    expect(find.byTooltip('收起滚动导航'), findsNothing);

    // 跨过 600ms 延迟:计时器到点,_navAutoHidden 复位,整组恢复。
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('回到底部'), findsOneWidget);
    expect(find.byTooltip('收起滚动导航'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('floating scroll FABs do not collide with another route FAB hero tag', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 40; i++) {
        await MessageRepository(db).append(
          sessionId: sessionId,
          role: i.isEven ? 'user' : 'assistant',
          content: 'line $i',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 滚到列表中部:两个悬浮滚动 FAB(回到顶部/回到底部)同时可见。
    final scrollable = tester.state<ScrollableState>(find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(Scrollable),
    ));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
    await tester.pump();
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('回到底部'), findsOneWidget);

    // 再 push 一个带默认 hero 标签 FAB 的路由:若聊天页 FAB 仍用默认标签,
    // 过渡期的 hero 扫描会发现多个同 tag hero 而抛断言(回归)。
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(floatingActionButton: FloatingActionButton(onPressed: null)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(FloatingActionButton), findsWidgets); // 过渡正常完成
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('status-panel button sits next to the context button', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 状态面板以独立图标与"上下文"按钮并排(不藏在三点菜单)。
    expect(find.byTooltip('上下文'), findsOneWidget);
    expect(find.byTooltip('状态面板'), findsOneWidget);
    expect(find.byIcon(Icons.insights_outlined), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('tapping the status button opens the status panel', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      await SessionRepository(db).create(charId, 's');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    await tester.tap(find.byTooltip('状态面板'));
    // 状态面板会触发技能/变量/记忆三个 DB FutureProvider,pumpAndSettle 在
    // FFI 残留 isolate 下不会收敛;改为在 runAsync 内轮询到标题出现。
    await tester.runAsync(() async {
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.text('状态面板').evaluate().isNotEmpty) break;
      }
      await tester.pump();
    });
    expect(find.text('状态面板'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('/compact shows a runtime progress animation while running, then the result', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    final backend = _ControlledBackend();
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await _seedMessages(db, sessionId);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendConfigProvider.overrideWith(
            (ref) => const BackendConfig(
              provider: BackendProvider.openai,
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'sk-test',
              model: 'gpt-4o',
            ),
          ),
          backendProvider.overrideWith((ref) => backend),
        ],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 点击 /compact 填入输入框,再按发送让压缩流启动;流尚未关闭 →
    // 运行时进度动画应可见。
    await expandCommands(tester);
    await runCommandChip(tester, '/compact 主动压缩');
    await tester.pump(); // 建帧让 _busyCommand 生效
    await tester.pump(const Duration(milliseconds: 300)); // AnimatedSwitcher 淡入
    expect(find.text('正在压缩会话历史…'), findsOneWidget);

    // 关闭摘要流 → 压缩完成。先等灵动岛的成功闪示出现(证明 _runCommandFromUI
    // 已收尾、_busyCommand 已复位),再压过模式切换的形变/退场动画。
    backend.finish();
    await tester.runAsync(() async {
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.textContaining('已压缩').evaluate().isNotEmpty) break;
      }
      // 压过退场淡出,让动画移除。
      await tester.pump(const Duration(milliseconds: 400));
    });
    // 反馈以灵动岛闪示呈现(替代旧 SnackBar)。
    expect(find.textContaining('已压缩'), findsOneWidget);
    // 动画已收尾,运行时提示应消失。
    expect(find.text('正在压缩会话历史…'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('input footer fits on a narrow phone screen without overflow', (tester) async {
    tester.view.physicalSize = const Size(300, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      // 一个长模型名 + 推理等级打开,复现 footer 里 chip/推理/发送/折叠挤爆的窄屏场景。
      await LlmProviderRepository(db).saveProvider(
        LlmProviderConfig(
          id: 0,
          providerId: 'anthropic',
          displayName: 'Anthropic',
          baseUrl: 'https://api.anthropic.com',
          protocol: LlmProtocol.anthropic,
          apiKey: 'sk-an',
          isActive: true,
          models: [
            LlmModelEntry(
              id: 0,
              providerId: 0,
              modelId: 'claude-3-5-sonnet',
              displayName: 'DeepSeek V4 Flash Default Long Name',
              contextCapacity: 200000,
              maxOutput: 8192,
              isActive: true,
            ),
          ],
        ),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => const AppSettings(reasoningLevel: ReasoningLevel.high)),
        ],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // footer 若溢出会抛 RenderFlex overflow 异常,测试自动失败。
    expect(find.byTooltip('发送'), findsOneWidget);
    // 窄行与宽行:合并胶囊 → 圆环;移动端不再显示推理段。
    final chipRight = tester.getTopRight(find.byKey(const ValueKey('model_selector'))).dx;
    final ringLeft = tester.getTopLeft(find.byType(ContextUsageRing)).dx;
    expect(find.byTooltip('推理等级:High'), findsNothing, reason: '移动端不再单独显示推理档位');
    expect(find.byKey(const ValueKey('model_reasoning_capsule')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('model_reasoning_divider')),
      findsNothing,
      reason: '移动端胶囊只留模型段,不应出现分隔线',
    );
    expect(ringLeft - chipRight, closeTo(4, 0.5), reason: '圆环应紧随模型 chip 之后');
    // 命令按钮行默认折叠:此时展示的是"展开"图标(终端),不占额外行高。
    expect(find.byTooltip('展开命令按钮行'), findsOneWidget);
    expect(find.byKey(const ValueKey('model_selector')), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('mobile reasoning level switches via the model picker sheet', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      // 种入 provider,避免点 chip 走「无 provider → 设置页」分支。
      await LlmProviderRepository(db).saveProvider(
        LlmProviderConfig(
          id: 0,
          providerId: 'anthropic',
          displayName: 'Anthropic',
          baseUrl: 'https://api.anthropic.com',
          protocol: LlmProtocol.anthropic,
          apiKey: 'sk-an',
          isActive: true,
          models: [
            LlmModelEntry(
              id: 0,
              providerId: 0,
              modelId: 'claude-3-5-sonnet',
              displayName: 'Claude Sonnet',
              contextCapacity: 200000,
              maxOutput: 8192,
              isActive: true,
            ),
          ],
        ),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(
            (ref) => const AppSettings(reasoningLevel: ReasoningLevel.high),
          ),
        ],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 移动端底栏不再单独显示推理档位,调整走模型选择底单里的滑块。
    expect(find.byTooltip('推理等级:High'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('model_selector')));
    await tester.pumpAndSettle();
    expect(find.text('推理等级'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);

    // 滑块拖到最左端 = Off;松手即关闭底单并落库。
    await tester.drag(find.byType(Slider), const Offset(-600, 0));
    await tester.pumpAndSettle();

    late ReasoningLevel persisted;
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        persisted = (await AppSettingsRepository(db).load()).reasoningLevel;
        if (persisted == ReasoningLevel.off) break;
      }
    });
    expect(persisted, ReasoningLevel.off);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('/compact keeps all original messages visible in the chat flow', (tester) async {
    // 回归测试:用户反馈「/compact 后聊天页面消息丢失,只剩最近几条」——
    // 旧实现在 message_list.dart 用 `!m.isCompacted` 把被压缩的原文从聊天流里
    // 隐去,只剩 keep 条最新消息。现在已移除该过滤:被压缩的原文继续按聊天消息
    // 渲染,用户能看到完整历史;ContextAssembler 仍按原口径过滤,被压缩的原文
    // 不会再次进 LLM 上下文(见 context_assembler.dart `!m.isCompacted`)。
    //
    // ListView.builder 只会把视口内的项挂上树:把视口设高到能完整放下 10 条
    // 气泡,直接 find.text 全部命中;矮屏就分段滚动。
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late final AppDatabase db;
    late final int sessionId;
    final backend = _ControlledBackend();
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await _seedMessages(db, sessionId);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendConfigProvider.overrideWith(
            (ref) => const BackendConfig(
              provider: BackendProvider.openai,
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'sk-test',
              model: 'gpt-4o',
            ),
          ),
          backendProvider.overrideWith((ref) => backend),
        ],
        child: const MaterialApp(
          home: ChatScreen(sessionId: 1, characterId: 1, character: CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    // 压缩前:10 条 m0..m9 全部可见。
    for (var i = 0; i < 10; i++) {
      expect(find.text('m$i'), findsOneWidget, reason: 'm$i should be visible before compact');
    }

    // 触发 /compact(填入输入框后再发送)并等摘要调用完成。
    await expandCommands(tester);
    await runCommandChip(tester, '/compact 主动压缩');
    await tester.pump();
    backend.finish();
    await tester.runAsync(() async {
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.textContaining('已压缩').evaluate().isNotEmpty) break;
      }
      await tester.pump();
    });

    // 压缩后:keep=6 → 后 4 条(m6..m9)仍非压缩、原文可见;前 6 条(m0..m5)
    // 已被 is_compacted=1 标记,但仍按聊天消息渲染,用户能完整浏览历史。
    // (系统角色的摘要行不进聊天流,见 message_list.dart 过滤。)
    for (var i = 0; i < 10; i++) {
      expect(find.text('m$i'), findsOneWidget, reason: 'm$i should remain visible after compact');
    }
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('/clear 需二次确认,取消保留历史与命令文本', (tester) async {
    late final AppDatabase db;
    late final int characterId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      characterId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(characterId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sessionId, role: 'user', content: '保留我');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: characterId,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _pumpUntilLoaded(tester);

    await expandCommands(tester);
    await runCommandChip(tester, '/clear 清空历史');
    await tester.pumpAndSettle();
    expect(find.text('清空会话历史?'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('保留我'), findsOneWidget, reason: '取消不应清空历史');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text.trim(), '/clear', reason: '取消后命令文本应保留');

    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    // 等到命令完整收尾(反馈文案在 _reassembleContext 之后才推入),
    // 否则关闭 DB 会撞上仍在进行的技能查询。
    await tester.runAsync(() async {
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.textContaining('已清空会话历史').evaluate().isNotEmpty) {
          break;
        }
      }
    });
    expect(find.text('保留我'), findsNothing, reason: '确认后历史应被清空');
    await tester.runAsync(() => db.db.close());
  });
}
