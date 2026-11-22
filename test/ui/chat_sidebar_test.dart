// 桌面宽窗会话侧栏:≥1200 显示、按角色分组、选中高亮、切换会话与新建会话;
// 1200 以下保持纯居中列布局(不出侧栏)。
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
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import 'package:microscritt/ui/common/chat_layout.dart';
import 'package:microscritt/ui/common/section_header.dart';
import 'package:microscritt/ui/theme/app_theme.dart';
import 'package:microscritt/ui/widgets/chat_session_sidebar.dart';
import 'package:microscritt/ui/widgets/message_bubble.dart';
import 'package:microscritt/ui/widgets/message_list.dart';
import '../support/test_database.dart';

class _FakeBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield const TextDelta('回复。');
    yield const DoneEvent();
  }
}

/// 交替 runAsync + 推帧直到条件成立(切换会话/新建会话要等真实 DB 往返)。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 240; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (condition()) return;
  }
  expect(condition(), isTrue);
}

/// 有限帧推进(灵动岛后台维护期的周期计时器会让 pumpAndSettle 追到超时)。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 桌面端悬停:把鼠标移到目标中心(组头「+」悬浮才浮现,且隐藏时退出
/// 命中测试,点按前必须先悬停)。
Future<void> _hover(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pump();
}

/// 收尾:卸载组件树并让在途 DB future 在真实异步里落定(fake-zone 里
/// 启动的 sqflite 查询会留下 10s 锁计时器,timersPending 断言会炸),再关库。
Future<void> _teardown(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.runAsync(() => db.db.close());
}

_overrides(AppDatabase db, {bool sidebarCollapsed = false}) => [
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
  sidebarCollapsedProvider.overrideWith((ref) => sidebarCollapsed),
];

Future<void> _pumpChat(
  WidgetTester tester, {
  required AppDatabase db,
  required int sessionId,
  required int characterId,
  required CharacterCard character,
  bool sidebarCollapsed = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(db, sidebarCollapsed: sidebarCollapsed),
      child: MaterialApp(
        theme: AppTheme.light(),
        home: ChatScreen(
          sessionId: sessionId,
          characterId: characterId,
          character: character,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('宽窗侧栏按角色分组,选中会话高亮,1200 以下不出侧栏', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int bobId;
    late final int a1;
    late final int a2;
    late final int b1;
    await tester.runAsync(() async {
      db = await openTestDb();
      final chars = CharacterRepository(db);
      aliceId = await chars.insert(const CharacterCard(name: 'Alice'));
      bobId = await chars.insert(const CharacterCard(name: 'Bob'));
      final sessions = SessionRepository(db);
      final messages = MessageRepository(db);
      a1 = await sessions.create(aliceId, '会话甲');
      await messages.append(sessionId: a1, role: 'user', content: '甲的第一句');
      a2 = await sessions.create(aliceId, '会话乙');
      b1 = await sessions.create(bobId, '会话丙');
      await messages.append(sessionId: b1, role: 'user', content: '丙的内容');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-session-$b1')).evaluate().isNotEmpty,
    );
    // 侧栏数据可能先于聊天载入就绪:等消息真正渲染再测几何 —— 未载入时
    // 消息区是零宽空态(SizedBox.shrink),居中在列心,左缘不是列左缘。
    await _pumpUntil(
      tester,
      () => find
          .descendant(
            of: find.byType(MessageList),
            matching: find.text('甲的第一句'),
          )
          .evaluate()
          .isNotEmpty,
    );

    // 侧栏在左;消息列表铺满右窗(桌面滚动条因此贴窗口最右缘),行内容
    // 收敛到右窗内居中的会话列(1600 时列宽 880) —— 用户气泡外框右缘 = 列右缘。
    final sidebarRect = tester.getRect(find.byType(ChatSessionSidebar));
    expect(sidebarRect.width, kChatSidebarWidth);
    final listRect = tester.getRect(find.byType(MessageList));
    expect(listRect.left, closeTo(kChatSidebarWidth, 1));
    expect(listRect.right, closeTo(1600, 1));
    final columnRight =
        kChatSidebarWidth +
        (1600 - kChatSidebarWidth + chatColumnMaxWidth(1600)) / 2;
    final userBubble = tester
        .widgetList<ChatBubbleFrame>(
          find.descendant(
            of: find.byType(MessageList),
            matching: find.byType(ChatBubbleFrame),
          ),
        )
        .map((w) => tester.getRect(find.byWidget(w)))
        .reduce((a, b) => a.right > b.right ? a : b);
    expect(userBubble.right, closeTo(columnRight, 1));

    // 分组:两个角色组;组内会话按最近活动排列(甲 有消息、乙 无消息)。
    expect(find.byKey(ValueKey('sidebar-group-$aliceId')), findsOneWidget);
    expect(find.byKey(ValueKey('sidebar-group-$bobId')), findsOneWidget);
    final sidebar = find.byType(ChatSessionSidebar);
    expect(
      find.descendant(of: sidebar, matching: find.text('会话乙')),
      findsOneWidget,
    );
    // 侧栏只做导航:不展示任何消息内容(末条预览/占位文案都不出现)。
    expect(
      find.descendant(of: sidebar, matching: find.text('甲的第一句')),
      findsNothing,
    );
    expect(
      find.descendant(of: sidebar, matching: find.text('暂无消息')),
      findsNothing,
    );
    // 行尾展示可扫读的元信息:消息条数;每行都有「···」操作菜单。
    expect(
      find.descendant(
        of: find.byKey(ValueKey('sidebar-session-$a1')),
        matching: find.text('1 条'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('sidebar-menu-$a1')), findsOneWidget);

    // 当前会话(会话甲)高亮:标题用主色。
    final scheme = Theme.of(
      tester.element(find.byType(ChatScreen)),
    ).colorScheme;
    final selectedTitle = tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('sidebar-session-$a1')),
        matching: find.text('会话甲'),
      ),
    );
    expect(selectedTitle.style?.color, scheme.primary);
    final otherTitle = tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('sidebar-session-$a2')),
        matching: find.text('会话乙'),
      ),
    );
    expect(otherTitle.style?.color, isNot(scheme.primary));

    // 层级:角色名(组头)字号大于会话名 —— 会话从属于角色卡。
    final groupName = tester.widget<Text>(
      find.descendant(
        of: find.byKey(ValueKey('sidebar-group-$aliceId')),
        matching: find.text('Alice'),
      ),
    );
    final groupSize = groupName.style?.fontSize;
    final sessionSize = selectedTitle.style?.fontSize;
    expect(groupSize, isNotNull);
    expect(sessionSize, isNotNull);
    expect(groupSize!, greaterThan(sessionSize!));

    // 组头头像放大到 24(radius 12);分组之间以 hairline 分割线隔开,
    // 首个分组之上不出现分割线。
    final groupAvatar = tester.widget<CircleAvatar>(
      find.descendant(
        of: find.byKey(ValueKey('sidebar-group-$aliceId')),
        matching: find.byType(CircleAvatar),
      ),
    );
    expect(groupAvatar.radius, 12);
    // 两个分组之间恰有一条分割线(挂在靠后分组的组头之上;分组顺序按最近
    // 活动排,不假设哪个角色在前)。
    final groupDivider = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(
            'sidebar-group-divider-',
          ),
    );
    expect(groupDivider, findsOneWidget);

    // 会话区扁平化:不套卡片容器,行直接铺在侧栏底色上。
    expect(
      find.descendant(
        of: find.byType(ChatSessionSidebar),
        matching: find.byType(GroupCard),
      ),
      findsNothing,
    );

    // 1200 以下(1100):侧栏不瞬移消失,槽宽收窄把面板滑出视口(动画中
    // 面板部分可见),收展完成后卸载并让出满宽给聊天区。
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final sliding = tester.getRect(find.byType(ChatSessionSidebar));
    expect(sliding.right, greaterThan(0));
    expect(sliding.right, lessThan(kChatSidebarWidth));
    await _pumpFrames(tester);
    expect(find.byType(ChatSessionSidebar), findsNothing);
    expect(tester.getRect(find.byType(MessageList)).left, closeTo(0, 1));

    // 拉回宽窗:侧栏滑入重新挂载,宽度回到满宽。
    tester.view.physicalSize = const Size(1600, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.getRect(find.byType(ChatSessionSidebar)).right,
      lessThan(kChatSidebarWidth),
    );
    await _pumpFrames(tester);
    expect(
      tester.getRect(find.byType(ChatSessionSidebar)).width,
      kChatSidebarWidth,
    );

    await _teardown(tester, db);
  });

  testWidgets('点击侧栏会话切换到其它角色并加载其消息', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int bobId;
    late final int a1;
    late final int b1;
    await tester.runAsync(() async {
      db = await openTestDb();
      final chars = CharacterRepository(db);
      aliceId = await chars.insert(const CharacterCard(name: 'Alice'));
      bobId = await chars.insert(const CharacterCard(name: 'Bob'));
      final sessions = SessionRepository(db);
      final messages = MessageRepository(db);
      a1 = await sessions.create(aliceId, '会话甲');
      await messages.append(sessionId: a1, role: 'user', content: '甲的第一句');
      b1 = await sessions.create(bobId, '会话丙');
      await messages.append(sessionId: b1, role: 'user', content: '丙的内容');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-session-$b1')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(ValueKey('sidebar-session-$b1')));
    // 侧栏行也显示同一条末条预览,消息断言限定在消息列表内。
    Finder inList(String text) => find.descendant(
      of: find.byType(MessageList),
      matching: find.text(text),
    );
    await _pumpUntil(tester, () => inList('丙的内容').evaluate().isNotEmpty);

    // AppBar 角色名与消息都切到 Bob 的会话;侧栏仍完整(新实例同布局)。
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Bob')),
      findsOneWidget,
    );
    expect(inList('丙的内容'), findsOneWidget);
    expect(find.byType(ChatSessionSidebar), findsOneWidget);

    // 切回 Alice 的会话甲。
    await tester.tap(find.byKey(ValueKey('sidebar-session-$a1')));
    await _pumpUntil(tester, () => inList('甲的第一句').evaluate().isNotEmpty);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Alice')),
      findsOneWidget,
    );

    await _teardown(tester, db);
  });

  testWidgets('空分组用组头「+」建会话,占位提示不与选中标题同色', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int bobId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      final chars = CharacterRepository(db);
      aliceId = await chars.insert(const CharacterCard(name: 'Alice'));
      bobId = await chars.insert(const CharacterCard(name: 'Bob'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    final bobGroup = find.byKey(ValueKey('sidebar-group-$bobId'));
    await _pumpUntil(
      tester,
      () => find
          .descendant(of: bobGroup, matching: find.byIcon(Icons.add))
          .evaluate()
          .isNotEmpty,
    );

    // 新建入口统一在组头「+」:空分组不再有蓝色行动行(与选中会话的
    // 主色标题同色,分不清谁是当前会话),只留弱化占位提示。
    expect(find.text('开始新会话'), findsNothing);
    final hint = find.descendant(
      of: find.byKey(ValueKey('sidebar-empty-$bobId')),
      matching: find.text('还没有会话'),
    );
    expect(hint, findsOneWidget);
    final scheme = Theme.of(
      tester.element(find.byType(ChatScreen)),
    ).colorScheme;
    expect(tester.widget<Text>(hint).style?.color, scheme.outline);
    expect(tester.widget<Text>(hint).style?.color, isNot(scheme.primary));
    // 选中会话标题仍是主色,但与占位提示已可区分。
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(ValueKey('sidebar-session-$a1')),
              matching: find.text('会话甲'),
            ),
          )
          .style
          ?.color,
      scheme.primary,
    );

    // 空分组的「+」此前是禁用态(点按无反应),现在直接建会话并进入;
    // 「+」悬浮组头才浮现。
    final addButton = find.descendant(
      of: bobGroup,
      matching: find.byType(IconButton),
    );
    await _hover(tester, bobGroup);
    expect(tester.widget<IconButton>(addButton).onPressed, isNotNull);
    await tester.tap(addButton);
    await _pumpUntil(
      tester,
      () => find.text('与 Bob 开始对话').evaluate().isNotEmpty,
    );
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Bob')),
      findsOneWidget,
    );
    final sessions = await tester.runAsync(
      () => SessionRepository(db).byCharacter(bobId),
    );
    expect(sessions!.length, 1);
    // 新建后侧栏分组即时更新:新会话行直接出现并成为当前会话。
    await _pumpUntil(
      tester,
      () =>
          find
              .byKey(ValueKey('sidebar-session-${sessions.single.id}'))
              .evaluate()
              .isNotEmpty,
    );

    await _teardown(tester, db);
  });

  testWidgets('宽窗可折叠侧栏:收起让出满宽,再展开恢复', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-session-$a1')).evaluate().isNotEmpty,
    );
    // 收起/展开入口都在 AppBar 左端(展开态为收起键)。
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('收起会话侧栏'),
      ),
      findsOneWidget,
    );

    // 收起:宽度动画中面板仍部分可见,结束后卸载并让出满宽。
    await tester.tap(find.byTooltip('收起会话侧栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final slidingOut = tester.getRect(find.byType(ChatSessionSidebar));
    expect(slidingOut.right, greaterThan(0));
    expect(slidingOut.right, lessThan(kChatSidebarWidth));
    await _pumpFrames(tester);
    expect(find.byType(ChatSessionSidebar), findsNothing);
    expect(tester.getRect(find.byType(MessageList)).left, closeTo(0, 1));
    // 侧栏折叠后,展开入口接在 AppBar 左端。
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('展开会话侧栏'),
      ),
      findsOneWidget,
    );

    // 展开:滑入后恢复满宽侧栏。
    await tester.tap(find.byTooltip('展开会话侧栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.getRect(find.byType(ChatSessionSidebar)).right,
      lessThan(kChatSidebarWidth),
    );
    await _pumpFrames(tester);
    expect(
      tester.getRect(find.byType(ChatSessionSidebar)).width,
      kChatSidebarWidth,
    );

    await _teardown(tester, db);
  });

  testWidgets('折叠偏好为收起时宽窗直接不出现侧栏', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
      sidebarCollapsed: true,
    );
    await _pumpFrames(tester);
    expect(find.byType(ChatSessionSidebar), findsNothing);
    expect(tester.getRect(find.byType(MessageList)).left, closeTo(0, 1));
    expect(find.byTooltip('展开会话侧栏'), findsOneWidget);

    await _teardown(tester, db);
  });

  testWidgets('侧栏 home 键一键返回应用首页', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
    });

    // 首页路由之上推入聊天页(home 键需要栈里有可弹回的首页)。
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(db),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        sessionId: a1,
                        characterId: aliceId,
                        character: const CharacterCard(name: 'Alice'),
                      ),
                    ),
                  ),
                  child: const Text('打开聊天'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开聊天'));
    await _pumpFrames(tester);
    expect(find.byType(ChatScreen), findsOneWidget);

    await tester.tap(find.byTooltip('返回首页'));
    await _pumpFrames(tester);
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('打开聊天'), findsOneWidget);

    await _teardown(tester, db);
  });

  testWidgets('组头「新建会话」创建空会话并直接进入', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find
          .descendant(
            of: find.byKey(ValueKey('sidebar-group-$aliceId')),
            matching: find.byIcon(Icons.add),
          )
          .evaluate()
          .isNotEmpty,
    );

    // 「+」悬浮组头才浮现:悬停前透明不可点,悬停后浮现。
    final aliceGroup = find.byKey(ValueKey('sidebar-group-$aliceId'));
    Finder addOpacity() => find.ancestor(
      of: find.descendant(of: aliceGroup, matching: find.byIcon(Icons.add)),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(addOpacity()).opacity, 0);
    await _hover(tester, aliceGroup);
    expect(tester.widget<AnimatedOpacity>(addOpacity()).opacity, 1);
    await tester.tap(
      find.descendant(of: aliceGroup, matching: find.byIcon(Icons.add)),
    );
    // 当前会话 a1 也是空会话,空态文案在新建前就存在,不能作为新建完成
    // 的信号 —— 等新会话行真正出现在侧栏。
    await _pumpUntil(
      tester,
      () => find
          .descendant(
            of: find.byType(ChatSessionSidebar),
            matching: find.text('新会话'),
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.descendant(
        of: find.byType(ChatSessionSidebar),
        matching: find.text('新会话'),
      ),
      findsOneWidget,
    );
    expect(find.text('与 Alice 开始对话'), findsOneWidget);
    // 库中确实多了一条会话。
    final sessions = await tester.runAsync(
      () => SessionRepository(db).byCharacter(aliceId),
    );
    expect(sessions!.length, 2);

    await _teardown(tester, db);
  });

  testWidgets('侧栏行菜单:重命名会话并即时刷新', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
      await MessageRepository(
        db,
      ).append(sessionId: a1, role: 'user', content: '你好');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-menu-$a1')).evaluate().isNotEmpty,
    );

    // 选中行常驻显示「···」菜单;打开后三种动作齐备。
    await tester.tap(find.byKey(ValueKey('sidebar-menu-$a1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(dialogField, findsOneWidget);
    await tester.enterText(dialogField, '改名后的会话');
    await tester.tap(find.text('确定'));
    await _pumpUntil(tester, () => find.text('改名后的会话').evaluate().isNotEmpty);

    final renamed = await tester.runAsync(() => SessionRepository(db).get(a1));
    expect(renamed!.title, '改名后的会话');

    await _teardown(tester, db);
  });

  testWidgets('侧栏行菜单:置顶会话聚到顶部,取消置顶回到角色分组', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    late final int a2;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      final sessions = SessionRepository(db);
      a1 = await sessions.create(aliceId, '会话甲');
      a2 = await sessions.create(aliceId, '会话乙');
      await MessageRepository(
        db,
      ).append(sessionId: a1, role: 'user', content: '你好');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    final pinnedRow = find.byKey(ValueKey('sidebar-pinned-session-$a2'));
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-menu-$a2')).evaluate().isNotEmpty,
    );

    // 菜单首项是「置顶」;点选后行从角色分组抽出,进入顶部置顶区。
    await tester.tap(find.byKey(ValueKey('sidebar-menu-$a2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('置顶'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await _pumpUntil(
      tester,
      () =>
          pinnedRow.evaluate().isNotEmpty &&
          find.byKey(ValueKey('sidebar-session-$a2')).evaluate().isEmpty,
    );

    // 置顶区标题 + 置顶行;行内补角色名区分来源,分组里不再重复。
    expect(find.byKey(const ValueKey('sidebar-pinned-header')), findsOneWidget);
    expect(
      find.descendant(of: pinnedRow, matching: find.textContaining('Alice')),
      findsOneWidget,
    );
    final pinnedInfo = await tester.runAsync(() async {
      final infos = await SessionRepository(db).infosAll();
      return infos.singleWhere((i) => i.id == a2);
    });
    expect(pinnedInfo!.pinnedAt, isNotNull);

    // 取消置顶:行回到角色分组,置顶区随之消失。
    await tester.tap(find.byKey(ValueKey('sidebar-pinned-menu-$a2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('取消置顶'));
    await _pumpUntil(
      tester,
      () =>
          find.byKey(ValueKey('sidebar-session-$a2')).evaluate().isNotEmpty &&
          pinnedRow.evaluate().isEmpty,
    );
    expect(find.byKey(const ValueKey('sidebar-pinned-header')), findsNothing);
    final unpinnedInfo = await tester.runAsync(() async {
      final infos = await SessionRepository(db).infosAll();
      return infos.singleWhere((i) => i.id == a2);
    });
    expect(unpinnedInfo!.pinnedAt, isNull);

    await _teardown(tester, db);
  });

  testWidgets('会话全部置顶时分组给出弱化说明而不是空态文案', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-menu-$a1')).evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(ValueKey('sidebar-menu-$a1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('置顶'));
    await _pumpUntil(
      tester,
      () => find
          .byKey(ValueKey('sidebar-pinned-session-$a1'))
          .evaluate()
          .isNotEmpty,
    );

    // 分组仍在(组头「+」保留新建入口),但不再误报「还没有会话」。
    expect(find.byKey(ValueKey('sidebar-group-$aliceId')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('sidebar-empty-$aliceId')),
        matching: find.text('会话已全部置顶'),
      ),
      findsOneWidget,
    );
    expect(find.text('还没有会话'), findsNothing);

    await _teardown(tester, db);
  });

  testWidgets('AppBar 会话操作菜单:重命名会话并即时落库', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      a1 = await SessionRepository(db).create(aliceId, '会话甲');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find.byTooltip('会话操作').evaluate().isNotEmpty,
    );

    // 会话操作菜单与侧栏行菜单同口径:重命名/导出/删除齐备。
    await tester.tap(find.byTooltip('会话操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('重命名会话'), findsOneWidget);
    expect(find.text('导出会话'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);

    // 对话框以当前标题预填;确认后新标题落库。
    await tester.tap(find.text('重命名会话'));
    await _pumpUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(dialogField).controller?.text,
      '会话甲',
    );
    await tester.enterText(dialogField, '改名后的会话');
    await tester.tap(find.text('确定'));
    await _pumpUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isEmpty,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final renamed = await tester.runAsync(() => SessionRepository(db).get(a1));
    expect(renamed!.title, '改名后的会话');

    await _teardown(tester, db);
  });

  testWidgets('侧栏行菜单:删除非当前会话留在原页并即时移除', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int aliceId;
    late final int a1;
    late final int a2;
    await tester.runAsync(() async {
      db = await openTestDb();
      aliceId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      final sessions = SessionRepository(db);
      a1 = await sessions.create(aliceId, '会话甲');
      a2 = await sessions.create(aliceId, '会话乙');
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: a1,
      characterId: aliceId,
      character: const CharacterCard(name: 'Alice'),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-session-$a2')).evaluate().isNotEmpty,
    );

    // 悬停前菜单不可见但仍可命中(桌面端移动鼠标到行上即淡入)。
    await tester.tap(find.byKey(ValueKey('sidebar-menu-$a2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('删除'));
    // 等确认弹窗出现(菜单退场与弹窗可能短暂并存,确认键按弹窗作用域点)。
    await _pumpUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await _pumpUntil(
      tester,
      () => find.byKey(ValueKey('sidebar-session-$a2')).evaluate().isEmpty,
    );

    // 删除的是非当前会话:仍停留在原会话,库中该行已消失。
    expect(find.byKey(ValueKey('sidebar-session-$a1')), findsOneWidget);
    final gone = await tester.runAsync(() => SessionRepository(db).get(a2));
    expect(gone, isNull);

    await _teardown(tester, db);
  });
}
