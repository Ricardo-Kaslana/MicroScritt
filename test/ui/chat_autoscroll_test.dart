// 聊天页滚动回归:流式自动跟随让位给用户手势(拖动/惯性/滚轮),进入会话
// 贴底不闪旧内容,分页/回顶/导航显隐与视口变化均须落位准确。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import '../support/test_database.dart';

/// 等 ChatController.load 整体落定(sessionId + 种子消息都就位)后再开始断言。
Future<void> _settleLoaded(WidgetTester tester, int expectedMessages) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      final st = container.read(chatControllerProvider);
      if (st.sessionId != null &&
          st.messages.length == expectedMessages &&
          !container.read(llmProvidersProvider).isLoading) {
        break;
      }
    }
  });
}

/// 只等真实异步完成、**不主动 pump**(贴近真机:帧由 vsync 驱动,加载完成的
/// 那一刻才出现数据帧)。供进入会话贴底回归用:复现依赖"数据帧之后才发生
/// 贴底定位"这一时序,pumpAndSettle 式轮询会掩盖它。
Future<void> _waitForMessages(WidgetTester tester, int expectedMessages) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      if (container.read(chatControllerProvider).messages.length == expectedMessages) {
        return;
      }
    }
  });
}

void main() {
  testWidgets('streaming auto-follow does not hijack an in-progress user drag', (tester) async {
    // 真实 DB + 一段足够长的消息列表:600 高的测试视口里必须有滚动范围,
    // 才能验证"贴底跟随 ⇄ 用户上滑打断"的完整行为。
    late final AppDatabase db;
    late final int sid;
    const long = '这是一条用来撑高消息列表的正文,内容足够长,让它在测试视口里可以产生滚动范围。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 12; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 第 $i 段:${'呀' * 20}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 12);
    // 等初始贴底与首帧渲染落定。
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0, reason: '加载完成应贴底(reverse:offset 0 = 最新)');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final notifier = container.read(chatControllerProvider.notifier);
    void pushDraft(String text) {
      // 草稿在独立 provider,streaming 仍在 ChatState:分两处写,
      // 与生产侧 ChatController 的写入路径同构。
      container.read(chatDraftProvider.notifier).set(text);
      notifier.state = container.read(chatControllerProvider).copyWith(streaming: true);
    }

    // 对照:贴底且未触摸时,新块照常自动跟随(跟随逻辑本体仍工作)。
    pushDraft('流式第一段');
    await tester.pumpAndSettle();
    expect(position.pixels, 0, reason: '贴底时新块应跟随到底部');

    // 用户手指按下并小幅下拉(向下拖 = 往更旧的历史方向滚,偏移增大;仍处于
    // 底部 80px 邻域 → _nearBottom 保持 true),保持按住 —— 模拟"正在拖动时
    // 流式块到达"。注意 dragStartBehavior.start 下第一次 move 只是触发拖动手势
    // 启动(位移被吸收为起点),第二次 move 才真正滚动。
    final gesture = await tester.startGesture(tester.getCenter(scrollable));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60)); // 触发 drag start(被吸收)
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40)); // 实际生效的位移:向更旧方向滚动
    await tester.pump();
    final dragged = position.pixels;
    expect(dragged, greaterThan(0), reason: '小幅下拉应生效(离开底部)');
    expect(
      dragged,
      lessThanOrEqualTo(80),
      reason: '小幅下拉后仍应处于"贴底邻域"内(否则 _nearBottom 已变 false,回归点不成立)',
    );

    // 拖动中到达新流式块:不得把画面拽回底部、不得打断拖动(回归点)。
    pushDraft('流式第二段,拖动中到达');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 旧逻辑的 animateTo 在此已跑完
    expect(
      position.pixels,
      greaterThan(0),
      reason: '拖动中的用户手势不应被自动跟随拽回底部',
    );
    expect(
      position.activity,
      isA<DragScrollActivity>(),
      reason: '流式块到达不得 dispose 掉进行中的拖动',
    );

    // 继续拖动仍然生效(拖动没被杀死)。
    final before = position.pixels;
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    expect(position.pixels, greaterThan(before + 60), reason: '拖动应继续生效,画面继续上移');

    // 松开手指且已远离底部:后续新块不再自动跟随。
    await gesture.up();
    await tester.pumpAndSettle();
    final away = position.pixels;
    pushDraft('流式第三段,已松开');
    await tester.pumpAndSettle();
    expect(position.pixels, away, reason: '松开且远离底部后,新块不应再把画面拽回底部');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('streaming auto-follow does not hijack a fling still coasting on inertia', (tester) async {
    // 回归:抬手后的惯性段不受 _userDragging 保护(抬手瞬间 ScrollEnd 即复位),
    // 流式块到达时 jumpTo 会 dispose 掉惯性滚动、把画面拽回底部,表现为
    // "流式时想上滑看一眼历史,气泡却停不下来"。
    late final AppDatabase db;
    late final int sid;
    const long = '这是一条用来撑高消息列表的正文,内容足够长,让它在测试视口里可以产生滚动范围。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 12; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 第 $i 段:${'呀' * 20}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 12);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0, reason: '加载完成应贴底(reverse:offset 0 = 最新)');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final notifier = container.read(chatControllerProvider.notifier);
    void pushDraft(String text) {
      // 草稿在独立 provider,streaming 仍在 ChatState:分两处写,
      // 与生产侧 ChatController 的写入路径同构。
      container.read(chatDraftProvider.notifier).set(text);
      notifier.state = container.read(chatControllerProvider).copyWith(streaming: true);
    }

    // 小幅甩动(手指下拉 = 往更旧方向滚,偏移增大):位移与惯性都停在贴底邻域
    // 内 —— 这正是旧逻辑的回归面(惯性进行中到达的流式块会把画面整个拽回底部)。
    await tester.fling(scrollable, const Offset(0, 30), 150);
    final afterFling = position.pixels;
    expect(afterFling, greaterThan(0), reason: '小幅甩动应使画面离开底部');

    // 惯性进行中/刚抬手即到达新流式块:不得打断惯性、不得拽回底部(回归点)。
    pushDraft('流式块,惯性段到达');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      position.pixels,
      greaterThanOrEqualTo(afterFling),
      reason: '惯性段进行中,新流式块不得把画面拽回底部',
    );
    await tester.pumpAndSettle();
    expect(
      position.pixels,
      greaterThan(0),
      reason: '小幅甩动停稳后仍在贴底邻域内,也不得被立刻拽回底部',
    );

    // 大幅甩动离开贴底邻域:后续跟随永久停止(_nearBottom 闩住)。
    await tester.fling(scrollable, const Offset(0, 240), 900);
    await tester.pumpAndSettle();
    final settled = position.pixels;
    expect(settled, greaterThan(80), reason: '大幅甩动后应离开贴底邻域');
    pushDraft('离开邻域后到达');
    await tester.pumpAndSettle();
    expect(position.pixels, settled, reason: '离开贴底邻域后,新块不应再把画面拽回底部');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('streaming auto-follow does not hijack mouse wheel scrolls', (tester) async {
    // 回归:鼠标滚轮每次滚动是瞬时 forcePixels(activity 不驻留、也不进
    // _userDragging),紧随其后到达的流式块会把刚滚出的距离立刻跳回底部。
    // 修复后按 UserScrollNotification 打点,给滚轮一个宽限窗。
    late final AppDatabase db;
    late final int sid;
    const long = '这是一条用来撑高消息列表的正文,内容足够长,让它在测试视口里可以产生滚动范围。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 12; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 第 $i 段:${'呀' * 20}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 12);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0, reason: '加载完成应贴底(reverse:offset 0 = 最新)');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final notifier = container.read(chatControllerProvider.notifier);
    void pushDraft(String text) {
      // 草稿在独立 provider,streaming 仍在 ChatState:分两处写,
      // 与生产侧 ChatController 的写入路径同构。
      container.read(chatDraftProvider.notifier).set(text);
      notifier.state = container.read(chatControllerProvider).copyWith(streaming: true);
    }

    // 一记滚轮(与 Scrollable 处理 PointerScrollEvent 同路径;reverse 下往更旧
    // 方向滚 = 偏移增大,与真实滚轮的方向翻转同构)。
    position.pointerScroll(60);
    await tester.pump();
    final afterWheel = position.pixels;
    expect(afterWheel, greaterThan(0), reason: '滚轮滚动应生效(离开底部)');

    // 宽限窗内到达新流式块:不得把刚滚出的距离跳回底部(回归点)。
    pushDraft('流式块,滚轮刚滚完到达');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(position.pixels, afterWheel, reason: '滚轮宽限窗内不得被拽回底部');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('tapping scroll-to-bottom FAB returns to the exact bottom', (tester) async {
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 30; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息编号 $i : ${'测试' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 30);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;

    // 先滚动到最顶部(reverse 下顶部 = maxScrollExtent)
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(80), reason: '应已离开底部邻域');

    // 此时远离底部,出现「回到底部」悬浮按钮
    final scrollToBottomFab = find.byTooltip('回到底部');
    expect(scrollToBottomFab, findsOneWidget);

    // 点击「回到底部」按钮
    await tester.tap(scrollToBottomFab);
    await tester.pumpAndSettle();

    // 应落到精确底部(offset 0),且末条消息在视口内可见(不会出现空白)
    expect(position.pixels, 0);
    expect(find.textContaining('消息编号 29'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('climbing navigation buttons allow jumping to previous and next messages', (tester) async {
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度以提供可滚动的聊天区域。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 15; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息序号 $i : ${'长内容测试文本' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 15);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;

    // 1. 处于底部时:显示「回到顶部」和「上一条消息」,不显示「下一条消息」和「回到底部」
    expect(position.pixels, lessThanOrEqualTo(80), reason: '进入应贴底(reverse:offset 0)');
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('上一条消息'), findsOneWidget);
    expect(find.byTooltip('下一条消息'), findsNothing);
    expect(find.byTooltip('回到底部'), findsNothing);

    // 2. 点击「上一条消息」:向更旧方向跳转一条消息(偏移增大)
    final bottomOffset = position.pixels;
    await tester.tap(find.byTooltip('上一条消息'));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(bottomOffset), reason: '应向上滚动到上一条消息');

    // 此时处于中间态:四个导航按钮全部呈现
    expect(find.byTooltip('回到顶部'), findsOneWidget);
    expect(find.byTooltip('上一条消息'), findsOneWidget);
    expect(find.byTooltip('下一条消息'), findsOneWidget);
    expect(find.byTooltip('回到底部'), findsOneWidget);

    // 3. 再次点击「上一条消息」:继续向上爬楼
    final middleOffset1 = position.pixels;
    await tester.tap(find.byTooltip('上一条消息'));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(middleOffset1), reason: '再次点击应继续向上跳转');

    // 4. 点击「下一条消息」:向下跳回一条消息(偏移减小)
    final middleOffset2 = position.pixels;
    await tester.tap(find.byTooltip('下一条消息'));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(middleOffset2), reason: '点击下一条应向下跳转');

    // 5. 点击「回到顶部」:落到顶部(reverse 下 = maxScrollExtent)
    await tester.tap(find.byTooltip('回到顶部'));
    await tester.pumpAndSettle();
    expect(
      position.pixels,
      greaterThanOrEqualTo(position.maxScrollExtent - 80),
      reason: '回到顶部后应落在顶部邻域内',
    );

    // 处于顶部时:不显示「回到顶部」和「上一条消息」,显示「下一条消息」和「回到底部」
    expect(find.byTooltip('回到顶部'), findsNothing);
    expect(find.byTooltip('上一条消息'), findsNothing);
    expect(find.byTooltip('下一条消息'), findsOneWidget);
    expect(find.byTooltip('回到底部'), findsOneWidget);

    // 6. 从顶部点击「下一条消息」:向更新方向跳出顶部
    await tester.tap(find.byTooltip('下一条消息'));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(position.maxScrollExtent), reason: '从顶部点击下一条应跳出顶部');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('scroll nav auto-hides on mouse wheel scrolls and restores after the pause', (tester) async {
    // 滚轮每次滚动是瞬时 forcePixels、没有拖动段:旧逻辑只在带 dragDetails 的
    // ScrollStart 时隐藏导航,滚轮滚动时按钮一直压着正在滚动的内容。
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度以提供可滚动的聊天区域。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 15; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息序号 $i : ${'长内容测试文本' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 15);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    // 先到列表中部:导航组完整呈现。
    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起滚动导航'), findsOneWidget);

    // 一记滚轮上滚(与 Scrollable 处理 PointerScrollEvent 同路径):导航立即隐藏。
    position.pointerScroll(-60);
    await tester.pump();
    expect(find.byTooltip('收起滚动导航'), findsNothing, reason: '滚轮滚动期间导航应自动隐藏');

    // 连续滚轮 tick(间隔小于恢复延时)期间保持隐藏:每个非 idle 的
    // UserScrollNotification 都会撤销未到期的恢复计时。
    await tester.pump(const Duration(milliseconds: 400));
    position.pointerScroll(-60);
    await tester.pump();
    expect(find.byTooltip('收起滚动导航'), findsNothing, reason: '短间隔连续滚轮期间导航应保持隐藏');

    // 停下 600ms 后恢复。
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byTooltip('收起滚动导航'), findsOneWidget, reason: '滚动停下 600ms 后导航应恢复');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('scroll nav yields while a message action row is visible and returns on deselect', (tester) async {
    // 选中(点按)最后一条用户消息时,操作按钮排(复制/编辑/删除/重新发送)
    // 贴在列表内容最底端,正落在右下角导航组的位置上 —— 最右的「重新发送」
    // 会被 FAB 盖住。操作排可见期间整组让位,取消选中即恢复。
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度以提供可滚动的聊天区域。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      // 偶数下标为用户消息:最后一条(i=14)是用户消息,带「重新发送」。
      for (var i = 0; i < 15; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息序号 $i : ${'长内容测试文本' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 15);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(0);
    await tester.pumpAndSettle();
    // 贴底时导航组只剩「收起」一颗(方向组隐藏),它正压在最后一条消息的操作排区域。
    expect(find.byTooltip('收起滚动导航'), findsOneWidget);

    // 点选最后的用户消息:操作排出现,导航组让位。
    await tester.tap(find.textContaining('消息序号 14'));
    await tester.pump();
    expect(find.byTooltip('重新发送'), findsOneWidget, reason: '选中后应出现操作按钮排');
    expect(find.byTooltip('收起滚动导航'), findsNothing, reason: '操作排可见期间导航组应让位');

    // 再点一次取消选中:操作排收起,导航组恢复。
    await tester.tap(find.textContaining('消息序号 14'));
    await tester.pump();
    expect(find.byTooltip('重新发送'), findsNothing);
    expect(find.byTooltip('收起滚动导航'), findsOneWidget, reason: '取消选中后导航组应恢复');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('scroll nav stays hidden through a long inertial coast and only restores after it truly stops', (tester) async {
    // 惯性段行为回归:恢复只允许发生在"滚动真正停止"之后。非 idle 的
    // UserScrollNotification 与惯性段每帧的 ScrollUpdate 都会撤销已武装的
    // 恢复计时 —— 即便某些时序下拖动段收尾会先报一次 ScrollEnd(activity
    // 切换序列因 Flutter 版本而异),惯性段随后的帧更新也必须把计时撤销,
    // 按钮不得在滑行途中弹回;只有最后一个 ScrollEnd 之后 600ms 才恢复。
    // (旧实现还有第二重问题:每次显隐都整页 setState,连续滚动的手势间
    // 停顿一旦超时就弹回按钮、又随下次滚动隐藏,交替显隐 + 整页重建卡顿。)
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度以提供可滚动的聊天区域。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 40; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息序号 $i : ${'长内容测试文本' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 40);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;

    // 高速甩动(手指下拉 = 内容上滚进历史),随后惯性段持续滑行。
    await tester.fling(scrollable, const Offset(0, 300), 2000);
    // 逐帧跟随惯性段:只要还在动(相邻采样 offset 仍在变),导航就必须保持
    // 隐藏 —— 旧逻辑在抬手 400ms 后就会中途恢复,这里每一帧都是回归点。
    var last = position.pixels;
    var movedSamples = 0;
    for (var step = 0; step < 40; step++) {
      await tester.pump(const Duration(milliseconds: 50));
      final current = position.pixels;
      if ((current - last).abs() > 0.5) {
        movedSamples++;
        expect(
          find.byTooltip('收起滚动导航'),
          findsNothing,
          reason: '惯性段第 $step 帧(仍在滑行,已离抬手 ${step * 50}ms)导航不得中途恢复',
        );
      }
      last = current;
    }
    // 甩动必须确实产生了一段足够长的滑行(否则用例退化为空转):至少覆盖
    // 超过恢复延时(600ms)的运动窗口。
    expect(movedSamples, greaterThan(12), reason: '测试前提:惯性段应滑行超过 600ms');

    // 滑行真正结束 + 600ms 静止后,导航恢复。
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byTooltip('收起滚动导航'), findsOneWidget, reason: '滚动真正停止 600ms 后导航应恢复');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('viewport shrinking after entry still lands at the true bottom', (tester) async {
    // 回归:进入会话贴底收敛完成后,若视口/内容尺寸后到地变化(图片解码撑高、
    // 软键盘弹出、窗口缩放等),maxScrollExtent 随之变大而 pixels 不动 —— 旧的
    // "消息数变化才跟随"逻辑捕捉不到这种尺寸变化,最终停在最新消息上方。修复后
    // 监听 ScrollMetricsNotification:贴底状态下尺寸一变即重新贴底。
    // (错误提示已由灵岛悬浮胶囊承载,不再占布局空间,不构成尺寸变化源。)
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度以提供可滚动的聊天区域。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 30; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息序号 $i : ${'长内容测试文本' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 30);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0, reason: '进入会话应先贴底(reverse:offset 0)');

    // 贴底后压缩视口(等效软键盘弹出/窗口缩小)。reverse 下贴底是 offset 0,
    // 与内容总高度、视口高度都无关 —— 视口怎么变,都还停在最新消息处。
    final viewportBefore = position.viewportDimension;
    tester.view.physicalSize = const Size(800, 450);
    await tester.pumpAndSettle();

    expect(position.viewportDimension, lessThan(viewportBefore), reason: '测试前提:视口确实变小了');
    expect(
      position.pixels,
      0,
      reason: '视口被压缩后仍应停在底部,而不是停在最新消息上方',
    );
    expect(find.textContaining('消息序号 29'), findsOneWidget, reason: '末条消息应仍可见');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('scroll nav keeps even gaps between the remaining buttons at the edges', (tester) async {
    // 排版回归:贴顶/贴底只剩单侧方向组 + 收起钮共 3 颗时,旧实现的 6px 间距
    // 条件是"上下两组同时可见才加",收起钮会与最近的方向钮贴在一起。
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度以提供可滚动的聊天区域。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 15; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息序号 $i : ${'长内容测试文本' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleLoaded(tester, 15);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;

    /// 读导航列里的 FAB 数与 6px 间距数:用来断言贴顶/贴底只剩单侧方向组时,
    /// 收起钮仍与最近的方向钮保持间距。
    (int fabs, int gaps) navLayout() {
      final column = tester.widget<Column>(
        find
            .ancestor(of: find.byTooltip('收起滚动导航'), matching: find.byType(Column))
            .first,
      );
      final fabs = column.children.whereType<FloatingActionButton>().length;
      final gaps = column.children
          .whereType<SizedBox>()
          .where((b) => b.height == 6)
          .length;
      return (fabs, gaps);
    }

    // 贴底:回到顶部/上一条/收起 3 颗,两两之间各一枚 6px 间距。
    expect(position.pixels, 0);
    var (fabs, gaps) = navLayout();
    expect(fabs, 3, reason: '贴底时应剩 3 颗按钮');
    expect(gaps, 2, reason: '贴底时 3 颗按钮两两之间都应有 6px 间距');

    // 贴顶:收起/下一条/回到底部 3 颗,同样两两有间距。
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    (fabs, gaps) = navLayout();
    expect(fabs, 3, reason: '贴顶时应剩 3 颗按钮');
    expect(gaps, 2, reason: '贴顶时 3 颗按钮两两之间都应有 6px 间距');

    // 中部对照:5 颗钮 4 枚间距(原行为不回归)。
    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    (fabs, gaps) = navLayout();
    expect(fabs, 5);
    expect(gaps, 4);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('entering a session with oversized leading messages lands at true bottom without dead zone', (tester) async {
    // 回归:进入会话偶发整屏空白、需手动滑动气泡才出现。旧正序实现里,开头几条
    // 消息远高于平均时(长开场白/卡面介绍),首帧对 maxScrollExtent 的估算数倍于
    // 真实高度;贴底定位落在估算处后布局把 max 下修到真实末尾,视口停在内容之外
    // 的空白死区且不再纠偏。reverse 列表把贴底变成恒为 0 的精确位置,本用例继续
    // 守「无论首屏条目多高,进入都直接落底且空白只出现在隐藏期」。
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 50; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: i < 5 ? '开场长文 $i : ${'很长的正文' * 200}' : '短消息 $i',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sid, characterId: 1, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _waitForMessages(tester, 50);
    // 数据帧 + 少量稀疏帧(33ms ≈ 真机帧间隔):不允许出现"用户可见的无消息
    // 帧"。初始定位隐藏期(Opacity 0)允许视口短暂无消息,但只要列表处于显示
    // 态,视口内必须有消息 —— 空白若发生在可见阶段,或隐藏态未随贴底解除,
    // 都会在这里挂掉。
    await tester.pump();
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    final visibility = find.byKey(const ValueKey('message-list-visibility'));
    for (var step = 0; step < 12; step++) {
      await tester.pump(const Duration(milliseconds: 33));
      final hidden =
          tester.widget<Opacity>(visibility).opacity == 0;
      final anyBubbleVisible = find.textContaining('开场长文').evaluate().isNotEmpty ||
          find.textContaining('短消息').evaluate().isNotEmpty;
      expect(
        hidden || anyBubbleVisible,
        isTrue,
        reason: '第 $step 帧:视口空白只允许发生在初始定位的隐藏期,不得让用户看见',
      );
    }
    await tester.pumpAndSettle();

    // 落点断言:列表必须已显示、offset 0(reverse 下即精确贴底),且末条消息
    // 在视口内可见。
    expect(tester.widget<Opacity>(visibility).opacity, 1, reason: '贴底后列表应已显示');
    expect(position.pixels, 0, reason: '贴底 = offset 0');
    expect(find.textContaining('短消息 49'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('entering a session whose trailing messages are oversized still chases down to the true bottom', (tester) async {
    // 另一种异高分布(开头短、结尾长):旧正序实现的初始估算会欠估、需要多帧
    // 追赶;reverse 化后 offset 0 与内容高度无关,本用例守「首尾如何异高都直接
    // 落底」。
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 50; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: i < 45 ? 'hi $i' : '长回复 $i : ${'很长的正文' * 200}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sid, characterId: 1, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _waitForMessages(tester, 50);
    await tester.pump();
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    final visibility = find.byKey(const ValueKey('message-list-visibility'));
    for (var step = 0; step < 12; step++) {
      await tester.pump(const Duration(milliseconds: 33));
      final hidden =
          tester.widget<Opacity>(visibility).opacity == 0;
      final anyBubbleVisible = find.textContaining('hi ').evaluate().isNotEmpty ||
          find.textContaining('长回复').evaluate().isNotEmpty;
      expect(
        hidden || anyBubbleVisible,
        isTrue,
        reason: '第 $step 帧:追赶途中视口空白只允许发生在隐藏期,不得让用户看见',
      );
    }
    await tester.pumpAndSettle();

    expect(tester.widget<Opacity>(visibility).opacity, 1, reason: '贴底后列表应已显示');
    expect(position.pixels, 0, reason: '贴底 = offset 0');
    expect(find.textContaining('长回复 49'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('entering a very long session via route push still lands at the true bottom', (tester) async {
    // 回归:旧正序实现的贴底收敛预算固定 32 帧、每帧最多 6 个视口高 —— 几百条
    // 消息的长会话走不完,收敛链耗尽后静默停在中途历史里,表现为"进入会话总是
    // 不最新"。reverse 化后贴底恒为 offset 0,本用例继续守超长会话;真实路径
    // 还带 MaterialPageRoute 转场,一并覆盖(其余进入用例都是 home 直挂)。
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      // 160 条高气泡消息 ≈ 13.7 万像素,远超旧正序实现的收敛预算。条数与重复
      // 段压着选,总高不变的前提下把 DB 追加与逐帧布局的负载降到最低 —— 全量
      // 并行时过重的用例会挤爆邻组时序敏感用例(如 message_edit_sheet)的 4s
      // 真实异步窗口。
      for (var i = 0; i < 160; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '消息 $i:${'均匀长度的正文内容,用来撑起真实角色的滚动高度,这一段重复垫高单条气泡。' * 40}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    sessionId: sid,
                    characterId: 1,
                    character: const CharacterCard(name: 'Alice'),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // 转场先走完(ChatScreen 已挂载),再等真实异步把全部消息载入,最后逐帧
    // 推进让贴底定位与首帧渲染落定(高气泡下列表布局更重,帧数给足)。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _waitForMessages(tester, 160);
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(
      position.pixels,
      0,
      reason: '进入超长会话也必须贴底(reverse:offset 0):pixels=${position.pixels}',
    );
    expect(find.textContaining('消息 159'), findsOneWidget, reason: '末条消息应可见');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('entering a session keeps the list invisible until it settles at the bottom', (tester) async {
    // 回归:进入会话时贴底定位的每一帧都画在屏上 —— 用户看着消息从最旧一路
    // 「扫」到最新,而 QQ/微信式打开应当第一眼就是最新消息。修复后初始定位期
    // 列表以 Opacity 0 渲染(数据首帧即隐藏,不闪最旧消息);列表 reverse:true
    // 后首帧 offset 0 就是最新消息,不存在"扫"的过程,隐藏期缩到一帧。
    late final AppDatabase db;
    late final int sid;
    const long = '长正文段落用来撑起高度以提供可滚动的聊天区域。';
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 40; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 消息序号 $i : ${'长内容测试文本' * 30}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    // 只等真实异步载入、不主动 pump(与真机时序同构:数据就位后才有数据帧)。
    await _waitForMessages(tester, 40);
    await tester.pump(); // 数据帧:初始定位在本帧发起,列表必须本帧起就隐藏。

    final visibility = find.byKey(const ValueKey('message-list-visibility'));
    expect(visibility, findsOneWidget);
    double opacity() => tester.widget<Opacity>(visibility).opacity;
    expect(opacity(), 0, reason: '数据帧起列表应完全透明,不得闪现最旧消息');

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;

    // reverse 列表首帧 offset 0 即最新消息,贴底不再需要多帧收敛 —— 隐藏期只有
    // 一帧(不闪最旧消息),下一帧即显示,且第一眼就是最新消息。
    await tester.pump(const Duration(milliseconds: 33));
    expect(opacity(), 1, reason: '贴底无需多帧收敛,下一帧即应显示');
    expect(position.pixels, 0, reason: '显示时必须已贴底(offset 0)');
    expect(find.textContaining('消息序号 39'), findsOneWidget, reason: '首屏直接是最新消息');

    await tester.pumpAndSettle();
    expect(opacity(), 1, reason: '不得滞留隐藏态');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('switching sessions keeps the previous transcript until the new session data lands', (tester) async {
    // 回归:load 曾先整包清空 state,复用同屏切换会话的瞬间会闪出
    // 『发一条消息开始对话』空态。现在元数据立即清空(send 门控/上下文面板
    // 不残留)但消息转录保留;切换窗口内旧转录按初始定位隐藏(不闪空态也
    // 不暴露旧内容),新数据就绪后走初始定位、贴底后一次性显示。
    late final AppDatabase db;
    late final int charId;
    late final int sessionA;
    late final int sessionB;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      final sessions = SessionRepository(db);
      sessionA = await sessions.create(charId, 'a');
      sessionB = await sessions.create(charId, 'b');
      for (var i = 0; i < 3; i++) {
        await MessageRepository(db).append(sessionId: sessionA, role: 'user', content: '甲会话消息 $i');
      }
      for (var i = 0; i < 20; i++) {
        await MessageRepository(db).append(sessionId: sessionB, role: 'user', content: '乙会话消息 $i');
      }
    });

    Widget harness(int sid) => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: ChatScreen(sessionId: sid, characterId: charId, character: const CharacterCard(name: 'Alice')),
      ),
    );

    await tester.pumpWidget(harness(sessionA));
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
        final st = container.read(chatControllerProvider);
        if (st.sessionId == sessionA && st.messages.isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('甲会话消息'), findsWidgets);

    // 复用同屏切到会话 B:load 的清空在微任务里、DB 读依赖真实异步 —— 此处
    // 只 pump 不 runAsync,精确停 in 切换窗口内(旧转录暂存、新数据未到)。
    await tester.pumpWidget(harness(sessionB));
    await tester.pump();
    expect(find.textContaining('甲会话消息'), findsWidgets, reason: '切换窗口内应保留上一会话转录');
    expect(find.text('发一条消息开始对话'), findsNothing, reason: '切换窗口内不得闪出空态');

    // 等会话 B 数据落地(真实异步),贴底收敛完成后原子替换为 B 的转录。
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
        final st = container.read(chatControllerProvider);
        if (st.sessionId == sessionB && st.messages.isNotEmpty) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('乙会话消息'), findsWidgets, reason: '新数据落地后应显示会话 B');
    expect(find.textContaining('甲会话消息'), findsNothing, reason: '会话 A 的转录应被整体替换');
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0, reason: '会话 B 应完成初始定位、贴底显示(reverse:offset 0)');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('windowed session lands at bottom and pages in history when scrolled to top', (tester) async {
    // 回归:超长会话(400 条 > 300 条显示窗口)进入只载尾部窗口,贴底
    // 定位照旧;贴顶触发向上分页,老消息补入、视口锚定在原内容上,取尽后
    // 收口。400 条使首窗后只剩一页(100 < 每页 120),一次贴顶即取尽。
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 400; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '窗口消息 $i',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sid, characterId: 1, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _waitForMessages(tester, 300);
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0, reason: '窗口化进入仍应贴底(reverse:offset 0)');
    expect(find.textContaining('窗口消息 399'), findsOneWidget);
    expect(find.textContaining('窗口消息 0'), findsNothing, reason: '测试前提:窗口外历史未加载');

    // 翻到最旧一端(reverse 下顶部 = maxScrollExtent)→ 触发向上分页(取尽剩余
    // 100 条)。补页追加在列表远端,已有条目位置不变,故视口**不需要锚定**:
    // 它停在原内容上,用户继续上滑即可看到新页。
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (!container.read(chatControllerProvider).canLoadOlder) break;
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    // 分页断言走状态层:ListView 懒构建,视口外的消息不会进树,find 不到
    // 不代表没加载。全列表应为 400 条且以最早消息开头。
    expect(container.read(chatControllerProvider).messages.length, 400);
    expect(container.read(chatControllerProvider).messages.first.content, '窗口消息 0');
    expect(container.read(chatControllerProvider).canLoadOlder, isFalse, reason: '不足一页即取尽收口');
    // 无锚定也无需锚定:补页不移动视口,用户正在看的那条仍在视口内,且偏移
    // 仍远大于 0(没有被拽回底部)。
    expect(find.textContaining('窗口消息 100'), findsOneWidget, reason: '用户正在看的内容应保持在视口内');
    expect(position.pixels, greaterThan(0), reason: '补页不应把视口拽回底部');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('scroll-to-top FAB pages in all older history and lands at the absolute top', (tester) async {
    // 回归:旧实现只发一段 animateTo,动画进入贴顶 80px 邻域即触发锚定分页 ——
    // 补页的 jumpTo 打断进行中的动画,视口被锚回"新页之下",只要还有更早历史就
    // 永远到不了真顶,且「回到顶部」按钮在贴顶邻域消失,用户卡在半截历史。现在
    // 点击后逐页取尽全部旧历史(期间导航组换成常驻进度钮),取尽后多帧收敛到
    // 顶部(reverse 下 = maxScrollExtent,仍是估算值,需小步逼近)。
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 400; i++) {
        await MessageRepository(db).append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '回顶消息 $i',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sid, characterId: 1, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _waitForMessages(tester, 300);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(
      container.read(chatControllerProvider).canLoadOlder,
      isTrue,
      reason: '测试前提:窗口之上还有未加载的旧页',
    );

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0, reason: '进入应贴底(reverse:offset 0)');

    // 贴底时「回到顶部」可见;点击进入逐页取旧,导航组换成进度钮并常驻
    // (不随贴顶邻域/自动隐藏消失)。
    await tester.tap(find.byTooltip('回到顶部'));
    await tester.pump();
    expect(find.byTooltip('正在加载更早的历史…'), findsOneWidget, reason: '逐页取旧期间应显示常驻进度钮');

    // loadOlder 走真实异步(DB),循环每页还要等帧落定:endOfFrame 依赖泵帧。
    // runAsync 轮询驱动,直至取尽且视口落到绝对顶部。
    await tester.runAsync(() async {
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        final st = container.read(chatControllerProvider);
        if (!st.canLoadOlder &&
            st.messages.length == 400 &&
            position.pixels >= position.maxScrollExtent - 1) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();

    expect(
      position.pixels,
      greaterThanOrEqualTo(position.maxScrollExtent - 1),
      reason: '取尽全部旧页后应落到顶部(reverse 下 = maxScrollExtent)',
    );
    final st = container.read(chatControllerProvider);
    expect(st.messages.length, 400, reason: '全部历史都应在窗');
    expect(st.messages.first.content, '回顶消息 0', reason: '最早一条应已加载');
    expect(st.canLoadOlder, isFalse, reason: '历史取尽收口');
    // 进度钮退场;绝对顶部处顶部方向组消失、底部方向组恢复。
    expect(find.byTooltip('正在加载更早的历史…'), findsNothing);
    expect(find.byTooltip('回到顶部'), findsNothing);
    expect(find.byTooltip('回到底部'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });
}

