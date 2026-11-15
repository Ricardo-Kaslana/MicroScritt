// 聊天页宽窗桌面适配:高宽度窗口下消息/输入区收敛成居中阅读列,AppBar
// 不跟列、左右内容贴窗格两缘;中窄窗口保持原满宽布局;弹层宽窗封顶居中。
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:microscritt/ui/widgets/message_bubble.dart';
import 'package:microscritt/ui/widgets/message_list.dart';
import '../support/test_database.dart';

/// 纯色 PNG base64(背景图用例:确定可解码)。
Future<String> _pngBase64() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, 8, 8),
    ui.Paint()..color = const ui.Color(0xff4477aa),
  );
  final img = await recorder.endRecording().toImage(8, 8);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return base64Encode(data!.buffer.asUint8List());
}

class _FakeBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield const TextDelta('这是一条回复正文。');
    yield const DoneEvent();
  }
}

/// 等真实异步落库完成(数据帧由 vsync 驱动,不主动 pump)。
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

/// 等会话加载完成(sessionId 就位):发送类用例的前置 —— 加载未竟时
/// trySend 会被控制器拒绝,消息永远不落库。
Future<void> _waitLoaded(WidgetTester tester, int sessionId) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      if (container.read(chatControllerProvider).sessionId == sessionId) {
        return;
      }
    }
  });
  expect(
    ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    ).read(chatControllerProvider).sessionId,
    sessionId,
  );
}

/// 等真实异步落库完成,期间交替推帧:发送管线依赖帧推进(provider 重建/
/// 流式回调),纯 runAsync 等待会饿死链路 —— 与 chat_reverse_scroll_test
/// 的发送段同一模式。
Future<void> _waitForMessagesPumping(WidgetTester tester, int expected) async {
  for (var i = 0; i < 240; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    if (container.read(chatControllerProvider).messages.length == expected) {
      return;
    }
  }
  expect(
    ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    ).read(chatControllerProvider).messages.length,
    expected,
  );
}

/// 长正文:把气泡撑到各自的宽度上限(助手与输入卡同宽 856 / 用户 520)。
final _longText = '这是一段足够长的正文内容,用来把气泡撑到宽度上限,验证宽窗下的列收敛。' * 6;

/// 有限帧推进(替代 pumpAndSettle):发送后灵动岛处于后台维护实况模式,
/// 内部 50ms 周期计时器永远有待执行帧,pumpAndSettle 会一路泵到 10 分钟
/// 超时才抛错 —— 表现为测试「卡住」。布局断言只需入场动画与定位落定,
/// 6 帧 × 120ms 足够覆盖(灵动岛入场 240ms / 路由与弹层过渡 ~300ms)。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 会话列的左右缘(窗口居中)。
({double left, double right}) _columnEdges(double windowWidth) {
  final width = chatColumnMaxWidth(windowWidth).clamp(0.0, windowWidth);
  final left = (windowWidth - width) / 2;
  return (left: left, right: left + width);
}

/// 消息区里全部气泡外框(含 12px 边距)的矩形。
List<Rect> _bubbleRects(WidgetTester tester) => tester
    .widgetList<ChatBubbleFrame>(
      find.descendant(
        of: find.byType(MessageList),
        matching: find.byType(ChatBubbleFrame),
      ),
    )
    .map((w) => tester.getRect(find.byWidget(w)))
    .toList();

Future<void> _pumpChat(
  WidgetTester tester, {
  required AppDatabase db,
  required int sessionId,
  CharacterCard character = const CharacterCard(name: 'Alice'),
  bool backgroundEnabled = false,
  Key? boundaryKey,
}) async {
  Widget screen = ChatScreen(
    sessionId: sessionId,
    characterId: 1,
    character: character,
  );
  if (boundaryKey != null) {
    screen = RepaintBoundary(key: boundaryKey, child: screen);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith((ref) => _FakeBackend()),
        // 发送管线需要可解析的后端配置(与 chat_command_test 同款假配置)。
        backendConfigProvider.overrideWith(
          (ref) => const BackendConfig(
            provider: BackendProvider.openai,
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-test',
            model: 'gpt-4o',
          ),
        ),
        appSettingsProvider.overrideWith(
          (ref) => AppSettings(chatBackgroundEnabled: backgroundEnabled),
        ),
      ],
      child: MaterialApp(
        // 弹层封顶等外观都来自应用主题,harness 必须装上真实主题。
        theme: AppTheme.light(),
        home: screen,
      ),
    ),
  );
}

void main() {
  testWidgets('宽窗:消息/输入区收敛进居中列,AppBar 贴窗格两缘', (tester) async {
    // 1100:已进入居中列布局,但未到 1200 的侧栏阈值 —— 本组用例只守列收敛。
    tester.view
      ..physicalSize = const Size(1100, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      final repo = MessageRepository(db);
      await repo.append(sessionId: sid, role: 'assistant', content: _longText);
      await repo.append(sessionId: sid, role: 'user', content: _longText);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 2);
    await _pumpFrames(tester);

    final edges = _columnEdges(1100);
    expect(edges.left, 110);
    final rects = _bubbleRects(tester);
    expect(rects.length, 2);
    // 助手气泡贴列左缘(外框含 12 边距),上限与输入卡同宽:856 + 24 = 880。
    final assistant = rects.reduce((a, b) => a.left < b.left ? a : b);
    expect(assistant.left, closeTo(edges.left, 1));
    expect(assistant.width, closeTo(880, 1));
    // 用户气泡贴列右缘,封顶 520 + 24 = 544 —— 不再飞到窗口右缘。
    // 助手气泡撑满后两者右缘相同(列右缘),按宽度区分:更窄的是用户气泡。
    final user = rects.reduce((a, b) => a.width < b.width ? a : b);
    expect(user.right, closeTo(edges.right, 1));
    expect(user.width, closeTo(544, 1));

    // 输入区与气泡同列同缘:输入卡左右缘分别对齐助手气泡可见左缘与
    // 用户气泡可见右缘(气泡外框各含 12 边距)。
    final fieldRect = tester.getRect(find.byType(TextField));
    expect(fieldRect.right, lessThan(edges.right));
    expect(fieldRect.left, greaterThan(edges.left));
    expect(assistant.left + 12, closeTo(fieldRect.left, 1));
    expect(user.right - 12, closeTo(fieldRect.right, 1));

    // AppBar 与正文列脱钩:头像贴窗格最左缘,操作组贴窗格最右缘
    // (操作组尾部自带 4 的收边)。
    final avatarLeft = tester
        .getTopLeft(find.byKey(const ValueKey('appbar-character-avatar')))
        .dx;
    expect(avatarLeft, closeTo(0, 1));
    final menuRight = tester.getTopRight(find.byTooltip('会话操作')).dx;
    expect(menuRight, closeTo(1092, 1));

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('宽窗发送回路:新回复仍落在居中列内', (tester) async {
    tester.view
      ..physicalSize = const Size(1100, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitLoaded(tester, sid);
    await _pumpFrames(tester);

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await _waitForMessagesPumping(tester, 2);
    await _pumpFrames(tester);

    final edges = _columnEdges(1100);
    for (final rect in _bubbleRects(tester)) {
      expect(rect.left, greaterThanOrEqualTo(edges.left - 1));
      expect(rect.right, lessThanOrEqualTo(edges.right + 1));
    }
    // 发送后输入框已清空、仍可在列内继续输入。
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('中宽与窄窗:保持满宽布局', (tester) async {
    tester.view
      ..physicalSize = const Size(900, 700)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      final repo = MessageRepository(db);
      await repo.append(sessionId: sid, role: 'assistant', content: _longText);
      await repo.append(sessionId: sid, role: 'user', content: _longText);
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitForMessages(tester, 2);
    await _pumpFrames(tester);

    // 900 < 阈值:助手贴窗口左缘、用户贴窗口右缘(原舒适布局不动)。
    var rects = _bubbleRects(tester);
    var assistant = rects.reduce((a, b) => a.left < b.left ? a : b);
    var user = rects.reduce((a, b) => a.right > b.right ? a : b);
    expect(assistant.left, closeTo(0, 1));
    expect(user.right, closeTo(900, 1));

    // 缩到手机宽度再拉回宽窗:布局随窗口实时切换,不残留旧约束。
    tester.view.physicalSize = const Size(390, 844);
    await _pumpFrames(tester);
    rects = _bubbleRects(tester);
    assistant = rects.reduce((a, b) => a.left < b.left ? a : b);
    user = rects.reduce((a, b) => a.right > b.right ? a : b);
    expect(assistant.left, closeTo(0, 1));
    // 窄窗气泡外框 = 内容上限(390-24)+ 左右 12 边距 = 整行宽。
    expect(assistant.width, closeTo(390, 1));
    expect(user.right, closeTo(390, 1));

    tester.view.physicalSize = const Size(1100, 900);
    await _pumpFrames(tester);
    final edges = _columnEdges(1100);
    rects = _bubbleRects(tester);
    assistant = rects.reduce((a, b) => a.left < b.left ? a : b);
    user = rects.reduce((a, b) => a.right > b.right ? a : b);
    expect(assistant.left, closeTo(edges.left, 1));
    expect(user.right, closeTo(edges.right, 1));

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('改变窗口宽度跨断点:背景层与消息列表不重建', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final String art;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      art = await _pngBase64();
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(CharacterCard(name: 'Alice', avatarBase64: art));
      sid = await SessionRepository(db).create(charId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sid, role: 'assistant', content: _longText);
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: sid,
      character: CharacterCard(name: 'Alice', avatarBase64: art),
      backgroundEnabled: true,
    );
    await _waitForMessages(tester, 1);
    await _pumpFrames(tester);

    // 跨 1000 断点必须复用同一棵内容树:旧实现 <1000 与 ≥1000 用两套不同
    // 结构的 Scaffold,跨断点整棵内容子树换父重挂,背景层 State 重建、大图
    // 重新解码,暗色主题下露出脚手架黑底闪一帧(回归:改窗口宽度闪黑)。
    final bg = tester.state(find.byKey(const ValueKey('chat-background')));
    final list = tester.state(find.byType(MessageList));
    tester.view.physicalSize = const Size(990, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.state(find.byKey(const ValueKey('chat-background'))), same(bg));
    expect(tester.state(find.byType(MessageList)), same(list));

    // 1200 断点(侧栏收展)同样只动侧栏槽,不重建内容层。
    tester.view.physicalSize = const Size(1410, 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.state(find.byKey(const ValueKey('chat-background'))), same(bg));
    expect(tester.state(find.byType(MessageList)), same(list));

    // 收尾:卸载并让侧栏数据查询等在途 DB future 落定后再关库。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('宽窗有背景图:会话列保持透明,背景层照常渲染', (tester) async {
    tester.view
      ..physicalSize = const Size(1100, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // PNG 编码是引擎真实异步,必须在 runAsync 里做,否则 fake async 区死等。
    late final String art;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      art = await _pngBase64();
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(CharacterCard(name: 'Alice', avatarBase64: art));
      sid = await SessionRepository(db).create(charId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sid, role: 'assistant', content: _longText);
    });

    await _pumpChat(
      tester,
      db: db,
      sessionId: sid,
      character: CharacterCard(name: 'Alice', avatarBase64: art),
      backgroundEnabled: true,
    );
    await _waitForMessages(tester, 1);
    await _pumpFrames(tester);

    expect(find.byKey(const ValueKey('chat-background')), findsOneWidget);
    // 气泡仍收敛在居中列内。
    final edges = _columnEdges(1100);
    final rect = _bubbleRects(tester).single;
    expect(rect.left, closeTo(edges.left, 1));

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('宽窗背景图模糊不渗出聊天窗格:侧栏左缘无染色', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final String art;
    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      art = await _pngBase64();
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(CharacterCard(name: 'Alice', avatarBase64: art));
      sid = await SessionRepository(db).create(charId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sid, role: 'assistant', content: _longText);
    });

    const shotKey = ValueKey('wide-shot');
    await _pumpChat(
      tester,
      db: db,
      sessionId: sid,
      character: CharacterCard(name: 'Alice', avatarBase64: art),
      backgroundEnabled: true,
      boundaryKey: shotKey,
    );
    await _waitForMessages(tester, 1);
    await _pumpFrames(tester);

    // 默认模糊 18:ImageFiltered 的模糊输出会越出布局边界,背景层若不按
    // 窗格裁剪,背景色会在侧栏贴边处晕染(回归:侧栏右缘出现渐隐染色带)。
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(shotKey),
    );
    final image = await tester.runAsync(boundary.toImage);
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int channel(int x, int y, int c) =>
        data!.getUint8((y * image!.width + x) * 4 + c);
    // y=300 处只有背景层(气泡聚在底部且不越出会话列,侧栏内无内容)。
    final farLeft = [for (var c = 0; c < 3; c++) channel(120, 300, c)];
    final nearEdge = [for (var c = 0; c < 3; c++) channel(280, 300, c)];
    final justInside = [for (var c = 0; c < 3; c++) channel(310, 300, c)];
    image!.dispose();
    // 贴窗格边界的侧栏像素与侧栏内部完全一致:模糊输出被裁在窗格内。
    expect(nearEdge, farLeft);
    // 窗格内确实有背景层(否则「没染色」只是背景没渲染)。
    expect(justInside, isNot(farLeft));

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('宽窗弹层封顶 640 居中:头像状态卡不再拉满整窗', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice', description: '一位旅人'));
      sid = await SessionRepository(db).create(charId, 's');
    });

    await _pumpChat(tester, db: db, sessionId: sid);
    await _waitLoaded(tester, sid);
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const ValueKey('appbar-character-avatar')));
    await _pumpFrames(tester);

    // BottomSheet 外框是全宽 Align,640 约束作用在内层 Material 表面。
    final surface = find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Material),
        )
        .first;
    final rect = tester.getRect(surface);
    expect(rect.width, closeTo(640, 1));
    expect(rect.center.dx, closeTo(800, 1));
    expect(find.text('编辑角色卡'), findsOneWidget);

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('宽窗压栈进入:返回键内联在窗格左缘,可正常返回', (tester) async {
    tester.view
      ..physicalSize = const Size(1100, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith((ref) => _FakeBackend()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
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
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 等加载落定再断言/返回:并行负载下 load 可能迟到, pop 后才完成会
    // 留下悬空计时器(测试尾检 timersPending 炸)。
    await _waitLoaded(tester, sid);
    await _pumpFrames(tester);

    // 返回键内联贴窗格最左缘;操作组贴窗格最右缘,不再与输入列对齐。
    final backLeft = tester.getTopLeft(find.byType(BackButton)).dx;
    expect(backLeft, closeTo(0, 1));
    final menuRight = tester.getTopRight(find.byTooltip('会话操作')).dx;
    expect(menuRight, closeTo(1092, 1));

    await tester.pageBack();
    await _pumpFrames(tester);
    expect(find.text('open'), findsOneWidget);

    // 显式卸载再收尾:路由弹栈动画/迟到的 provider 回调全部落定。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() => db.db.close());
  });
}
