// 桌面消息导航:右缘刻度条 → 悬停展开卡片 → 卡片内滚动/点击跳转;
// 移动端仍走原悬浮按键组,内容不足一屏时整组隐藏。
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import 'package:microscritt/ui/common/chat_layout.dart';
import 'package:microscritt/ui/theme/app_theme.dart';
import 'package:microscritt/ui/widgets/message_list.dart';
import '../support/test_database.dart';

class _FakeBackend implements LlmBackend {
  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield const TextDelta('这是一条回复正文。');
    yield const DoneEvent();
  }
}

const _navRailKey = ValueKey('message-nav-rail');
const _navCardKey = ValueKey('message-nav-card');
const _navListKey = ValueKey('message-nav-list');

String _userBody(int i) => '第 $i 条用户消息:这是一段足够长的正文,用来撑开列表并验证卡片里的单行摘要。';

String _assistantBody(int i) => '第 $i 条助手回复:不该出现在导航卡片里。';

Future<void> _waitForMessages(WidgetTester tester, int expected) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      if (container.read(chatControllerProvider).messages.length == expected) {
        return;
      }
    }
  });
  expect(
    ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    ).read(chatControllerProvider).messages.length,
    expected,
  );
}

/// 交替推真实异步与帧,直到条件成立(索引查询与定位滚动都靠帧推进)。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 240,
}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (condition()) return;
  }
  fail('等待条件超时');
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required AppDatabase db,
  required int sessionId,
  Size size = const Size(1100, 800),
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith((ref) => _FakeBackend()),
        backendConfigProvider.overrideWith(
          (ref) => const BackendConfig(
            provider: BackendProvider.openai,
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-test',
            model: 'gpt-4o',
          ),
        ),
        appSettingsProvider.overrideWith((ref) => const AppSettings()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: ChatScreen(
          sessionId: sessionId,
          characterId: 1,
          character: const CharacterCard(name: 'Alice'),
        ),
      ),
    ),
  );
}

/// 种 [rounds] 轮「user + assistant」,返回全部 user 消息 id(时间序)。
Future<List<int>> _seedConversation(
  AppDatabase db,
  int sessionId, {
  required int rounds,
}) async {
  final userIds = <int>[];
  final repo = MessageRepository(db);
  for (var i = 0; i < rounds; i++) {
    userIds.add(
      (await repo.append(
        sessionId: sessionId,
        role: 'user',
        content: _userBody(i),
      )).id!,
    );
    await repo.append(
      sessionId: sessionId,
      role: 'assistant',
      content: _assistantBody(i),
    );
  }
  return userIds;
}

Future<TestGesture> _hoverRail(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byKey(_navRailKey)));
  // 先落一帧让 setState 生效并启动展开动画,再推进到位 —— pump(duration)
  // 的时钟推进发生在构建前,单次调用会让动画停在起始帧。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 220));
  return gesture;
}

void main() {
  testWidgets('桌面端:右缘显示刻度条,不出现旧悬浮爬楼按钮组', (tester) async {
    // 平台覆盖值必须在测试体内复位:framework 的不变量检查先于 addTearDown。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      await _seedConversation(db, sid, rounds: 20);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 40);
    await _pumpUntil(
      tester,
      () => find.byKey(_navRailKey).evaluate().isNotEmpty,
    );

    expect(find.byKey(_navRailKey), findsOneWidget);
    expect(find.byKey(_navCardKey), findsNothing);
    // 桌面端不再挂载悬浮 FAB 组。
    expect(find.byTooltip('回到底部'), findsNothing);
    expect(find.byTooltip('回到顶部'), findsNothing);

    // 收起态只占右缘窄条,不参与消息列布局。
    final rail = tester.getRect(find.byKey(_navRailKey));
    expect(rail.width, kChatNavRailWidth);
    expect(rail.right, closeTo(1100 - kChatNavInset, 1));

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('悬停刻度条展开卡片:只列 user 消息,摘要单行', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      await _seedConversation(db, sid, rounds: 20);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 40);
    await _pumpUntil(
      tester,
      () => find.byKey(_navRailKey).evaluate().isNotEmpty,
    );

    final gesture = await _hoverRail(tester);
    expect(find.byKey(_navCardKey), findsOneWidget);

    final card = find.byKey(_navCardKey);
    final rect = tester.getRect(card);
    expect(rect.width, closeTo(kChatNavCardWidth, 0.01));
    expect(rect.right, closeTo(1100 - kChatNavInset, 1));
    // 不叠加投影(外层裁切会只剩圆角处的灰弧):靠发丝边 + 明度差分层次。
    final material = tester.widget<Material>(
      find.descendant(of: card, matching: find.byType(Material)).first,
    );
    expect(material.elevation, 0);
    expect(material.shape, isA<RoundedRectangleBorder>());
    // 垂直居中于消息区(卡片不覆盖输入区)。
    final area = tester.getRect(find.byKey(const ValueKey('messages-area')));
    expect(rect.top - area.top, closeTo(area.bottom - rect.bottom, 1));

    // 只有 user 消息:助手回复的正文不会出现在卡片里。
    expect(
      find.descendant(of: card, matching: find.textContaining('第 19 条用户消息')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('助手回复')),
      findsNothing,
    );
    final list = tester.widget<ListView>(find.byKey(_navListKey));
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 20);

    // 鼠标移出右缘后延迟收起。
    await gesture.moveTo(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(_navCardKey), findsNothing);
    expect(find.byKey(_navRailKey), findsOneWidget);
    // 20 条 user 消息:刻度高度按条数展开(上下留白 + 19 个间距)。
    expect(
      tester.getRect(find.byKey(_navRailKey)).height,
      closeTo(kChatNavRailPadding * 2 + 19 * kChatNavTickSpacing, 1),
    );

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('刻度条高度随消息数自适应:少消息时不撑满卡片', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      final repo = MessageRepository(db);
      await repo.append(sessionId: sid, role: 'user', content: _userBody(0));
      // 一条超长助手回复把内容撑到可滚动,但不增加刻度条条数。
      await repo.append(
        sessionId: sid,
        role: 'assistant',
        content: '很长很长的助手回复,用来把消息列表撑出滚动范围。' * 400,
      );
      await repo.append(sessionId: sid, role: 'user', content: _userBody(1));
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 3);
    await _pumpUntil(
      tester,
      () => find.byKey(_navRailKey).evaluate().isNotEmpty,
    );

    // 2 条 user 消息 = 上下留白 + 1 个间距,而不是整张卡片高度里只剩
    // 顶部/底部两根孤线。
    final rail = tester.getRect(find.byKey(_navRailKey));
    expect(rail.width, kChatNavRailWidth);
    expect(
      rail.height,
      closeTo(kChatNavRailPadding * 2 + kChatNavTickSpacing, 1),
    );

    // 刻度条收缩不影响展开卡片:卡片仍按消息区高度成形。
    await _hoverRail(tester);
    final card = tester.getRect(find.byKey(_navCardKey));
    expect(card.width, closeTo(kChatNavCardWidth, 0.01));
    expect(card.height, greaterThan(rail.height * 4));

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('卡片内可用滚轮/拖动滚动,点击条目跳转并高亮', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    late final List<int> userIds;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      userIds = await _seedConversation(db, sid, rounds: 30);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 60);
    await _pumpUntil(
      tester,
      () => find.byKey(_navRailKey).evaluate().isNotEmpty,
    );

    await _hoverRail(tester);
    final card = find.byKey(_navCardKey);
    final list = find.byKey(_navListKey);

    // 展开时自动定位到当前(贴底最新)附近:最后一条 user 消息可见。
    expect(
      find.descendant(of: card, matching: find.textContaining('第 29 条用户消息')),
      findsOneWidget,
    );

    // 向上滚到最早的一条:卡片自身的滚动不驱动消息列表。
    await tester.drag(list, const Offset(0, 2400));
    await tester.pump(const Duration(milliseconds: 200));
    final first = find.descendant(
      of: card,
      matching: find.textContaining('第 0 条用户消息'),
    );
    expect(first, findsOneWidget);

    // 点击第一条 user 消息:消息列表滚到目标附近,气泡进入视口。
    await tester.tap(first);
    final listScrollable = find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(Scrollable),
    );
    await _pumpUntil(tester, () {
      if (listScrollable.evaluate().isEmpty) return false;
      // 等定位完全落定且高亮已经跟到目标,而不是只等滚动开始。
      return tester.state<ScrollableState>(listScrollable).position.pixels >
              100 &&
          find
              .byKey(ValueKey('nav-current-${userIds.first}'))
              .evaluate()
              .isNotEmpty;
    });

    final target = find.byKey(ValueKey('msg-${userIds.first}'));
    expect(target, findsOneWidget);
    final targetRect = tester.getRect(target);
    expect(targetRect.bottom, greaterThan(0));
    expect(targetRect.top, lessThan(800));
    // 卡片高亮必须落在刚跳到的这条,而不是滚动比例指到的相邻消息。
    expect(
      find.byKey(ValueKey('nav-current-${userIds.first}')),
      findsOneWidget,
    );

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('连点两条相邻导航项:后一次接管,最终停在第二条 user', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    late final List<int> userIds;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      userIds = await _seedConversation(db, sid, rounds: 30);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 60);
    await _pumpUntil(
      tester,
      () => find.byKey(_navRailKey).evaluate().isNotEmpty,
    );

    await _hoverRail(tester);
    final card = find.byKey(_navCardKey);
    final list = find.byKey(_navListKey);
    await tester.drag(list, const Offset(0, 2400));
    await tester.pump(const Duration(milliseconds: 200));

    final first = find.descendant(
      of: card,
      matching: find.textContaining('第 0 条用户消息'),
    );
    final second = find.descendant(
      of: card,
      matching: find.textContaining('第 1 条用户消息'),
    );
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);

    // 第一跳还在飞,立刻点第二条。旧实现用 `_revealRunning` 把第二次点击
    // 静默丢弃(用户看到"点了没反应"),或两个收敛循环同时 jumpTo 互拉
    // (视口在两条之间疯狂抖动)。后发请求必须接管,最终停在第二条。
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(second);

    await _pumpUntil(
      tester,
      () => find
          .byKey(ValueKey('nav-current-${userIds[1]}'))
          .evaluate()
          .isNotEmpty,
    );

    final target = find.byKey(ValueKey('msg-${userIds[1]}'));
    expect(target, findsOneWidget, reason: '最终应停在第二次点击的目标');
    final targetRect = tester.getRect(target);
    expect(targetRect.bottom, greaterThan(0));
    expect(targetRect.top, lessThan(800));
    expect(
      find.byKey(ValueKey('nav-current-${userIds[1]}')),
      findsOneWidget,
      reason: '高亮必须指向最后一次点击的目标',
    );

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('回到顶部/回到底部后卡片高亮与列表都跟随边界', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    late final List<int> userIds;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      userIds = await _seedConversation(db, sid, rounds: 30);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 60);
    await _pumpUntil(
      tester,
      () => find.byKey(_navRailKey).evaluate().isNotEmpty,
    );

    await _hoverRail(tester);

    // 用户手动滚到会话中段(不经过导航跳转,因此不存在两秒高亮锁定)。
    final listScrollable = find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(Scrollable),
    );
    await tester.drag(listScrollable, const Offset(0, 600));
    await tester.pump(const Duration(milliseconds: 200));
    final dragged = tester.state<ScrollableState>(listScrollable).position;
    expect(dragged.pixels, greaterThan(0), reason: '测试前提:视口已离开底部');
    expect(
      dragged.pixels,
      lessThan(dragged.maxScrollExtent - 80),
      reason: '测试前提:视口在中段,回顶按钮应可用而非已贴顶禁用',
    );

    // 回到顶部:程序性 jumpTo 在布局更新前就发出了滚动通知,旧实现读到
    // null 后保留中段锚点;跳转结束后又不再有滚动事件,高亮与卡片列表
    // 就永久停在中间某条。帧末重算 + 卡片跟随才能落到最旧一条。
    expect(find.byKey(_navCardKey), findsOneWidget, reason: '拖动后卡片应仍展开');
    expect(find.byTooltip('回到顶部'), findsOneWidget, reason: '回顶按钮应可点');
    await tester.tap(find.byTooltip('回到顶部'));
    await _pumpUntil(tester, () {
      final pos = tester.state<ScrollableState>(listScrollable).position;
      return pos.pixels >= pos.maxScrollExtent - 1;
    });
    final topPos = tester.state<ScrollableState>(listScrollable).position;
    expect(
      topPos.pixels,
      greaterThanOrEqualTo(topPos.maxScrollExtent - 1),
      reason: '回到顶部必须落到绝对顶部,不能停在估算的旧顶',
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(ValueKey('nav-current-${userIds[0]}'))
          .evaluate()
          .isNotEmpty,
    );

    // 回到底部:同理,锚点与卡片列表都必须跟到最新一段。
    await tester.tap(find.byTooltip('回到底部'));
    final from = userIds.length > 8 ? userIds.length - 8 : 0;
    await _pumpUntil(tester, () {
      for (var i = from; i < userIds.length; i++) {
        if (find
            .byKey(ValueKey('nav-current-${userIds[i]}'))
            .evaluate()
            .isNotEmpty) {
          return true;
        }
      }
      return false;
    });

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('内容不足一屏时导航整组不出现', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      final repo = MessageRepository(db);
      await repo.append(sessionId: sid, role: 'user', content: '只有一条');
      await repo.append(sessionId: sid, role: 'assistant', content: '回复');
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 2);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(_navRailKey), findsNothing);
    expect(find.byKey(_navCardKey), findsNothing);

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('移动端保留原悬浮按键组,不出现消息导航', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      await _seedConversation(db, sid, rounds: 20);
    });

    await _pumpChat(tester, db: db, sessionId: sid, size: const Size(400, 800));
    await _waitForMessages(tester, 40);
    await _pumpUntil(
      tester,
      () => find.byTooltip('回到顶部').evaluate().isNotEmpty,
    );

    expect(find.byKey(_navRailKey), findsNothing);
    expect(find.byKey(_navCardKey), findsNothing);
    expect(find.byTooltip('回到顶部'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('导航覆盖全部历史:索引不被显示窗口裁剪', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late final AppDatabase db;
    late final int sid;
    // 320 行 > 首屏 300 行窗口:最早的 20 行不在显示窗口里,导航仍要能看到
    // 全部 160 条 user 消息。
    const rounds = 160;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      await _seedConversation(db, sid, rounds: rounds);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 300);
    await _pumpUntil(
      tester,
      () => find.byKey(_navRailKey).evaluate().isNotEmpty,
    );
    // 160 条 user 消息远超卡片高度:刻度条封顶为卡片高度。
    final railHeight = tester.getRect(find.byKey(_navRailKey)).height;
    await _hoverRail(tester);
    expect(
      railHeight,
      closeTo(tester.getRect(find.byKey(_navCardKey)).height, 1),
    );

    final list = tester.widget<ListView>(find.byKey(_navListKey));
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, rounds);

    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => db.db.close());
  });
}
