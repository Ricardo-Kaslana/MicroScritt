// 聊天消息列表:操作排、选中语义与上报时序、连续气泡分组、草稿打字指示与
// 超长草稿降级、头像占位、爬楼动画时长与长历史定位。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/bubble_style.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/ui/widgets/message_list.dart';
import 'package:microscritt/ui/widgets/rich_message_text.dart';

Widget _harness({
  required List<Message> messages,
  GlobalKey<MessageListState>? listKey,
  void Function(Message, MessageAction)? onAction,
  ImageProvider? userAvatarImage,
  ImageProvider? assistantAvatarImage,
  String draft = '',
  bool streaming = false,
  bool canLoadOlder = false,
  bool loadingOlder = false,
  int? highlightedMessageId,
  ValueChanged<bool>? onActionsVisibleChanged,
  BubbleStyle? assistantBubbleStyle,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: MessageList(
          key: listKey,
          messages: messages,
          draft: draft,
          streaming: streaming,
          controller: ScrollController(),
          canLoadOlder: canLoadOlder,
          loadingOlder: loadingOlder,
          onMessageAction: onAction,
          userAvatarImage: userAvatarImage,
          assistantAvatarImage: assistantAvatarImage,
          highlightedMessageId: highlightedMessageId,
          onActionsVisibleChanged: onActionsVisibleChanged,
          assistantBubbleStyle: assistantBubbleStyle,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('history footer shows load hint and progress', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'hello',
      id: 1,
      seq: 0,
    );
    await tester.pumpWidget(
      _harness(messages: const [msg], canLoadOlder: true),
    );
    await tester.pump();
    expect(find.text('上滑加载更早消息'), findsOneWidget);

    await tester.pumpWidget(
      _harness(messages: const [msg], canLoadOlder: true, loadingOlder: true),
    );
    await tester.pump();
    expect(find.text('正在加载更早消息…'), findsOneWidget);
  });

  testWidgets(
    'tapping a bubble reveals its action buttons; tapping again hides them',
    (tester) async {
      const msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'hello',
        id: 1,
        seq: 0,
      );
      await tester.pumpWidget(
        _harness(messages: const [msg], onAction: (_, _) {}),
      );
      await tester.pumpAndSettle();

      // 未选中前没有操作按钮。
      expect(find.byIcon(Icons.copy_outlined), findsNothing);

      await tester.tap(find.text('hello'));
      await tester.pumpAndSettle();
      // 文本气泡只保留复制/编辑/多选;删除等完整动作在长按与三点菜单。
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.checklist_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.byIcon(Icons.edit_note), findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);

      await tester.tap(find.text('hello'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
    },
  );

  testWidgets(
    'selecting a different message moves the action row (single selection)',
    (tester) async {
      // 选中态走逐条目监听的共享 notifier,点选一条只重建该条;
      // 但单选语义不变:点另一条时操作行整体移过去,旧条目不再持有选中态。
      const a = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'first',
        id: 1,
        seq: 0,
      );
      const b = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'second',
        id: 2,
        seq: 1,
      );
      await tester.pumpWidget(
        _harness(messages: const [a, b], onAction: (_, _) {}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(
        tester.getCenter(find.byIcon(Icons.copy_outlined)).dy,
        lessThan(tester.getCenter(find.text('second')).dy),
        reason: '测试前提:操作行应先出现在第一条消息下方',
      );

      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(
        tester.getCenter(find.byIcon(Icons.copy_outlined)).dy,
        greaterThan(tester.getCenter(find.text('second')).dy),
        reason: '点另一条后操作行应移到后点选的消息下方,旧条目不再持有选中态',
      );
    },
  );

  testWidgets('user text bubbles keep only copy, edit and multi-select', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: 'hi',
      id: 1,
      seq: 0,
    );
    await tester.pumpWidget(
      _harness(messages: const [msg], onAction: (_, _) {}),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('hi'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.checklist_outlined), findsOneWidget);
    // 重新发送与删除已收进长按/三点菜单,不再占底部操作排。
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byIcon(Icons.send_outlined), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('multi-select button dispatches the select action', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: 'hi',
      id: 1,
      seq: 0,
    );
    final actions = <MessageAction>[];
    await tester.pumpWidget(
      _harness(messages: const [msg], onAction: (m, a) => actions.add(a)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('hi'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();

    expect(actions, [MessageAction.select]);
  });

  testWidgets('action buttons dispatch the matching callback', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'hello',
      id: 1,
      seq: 0,
    );
    final actions = <MessageAction>[];
    await tester.pumpWidget(
      _harness(messages: const [msg], onAction: (m, a) => actions.add(a)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('hello'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();

    expect(actions, [
      MessageAction.copy,
      MessageAction.edit,
      MessageAction.select,
    ]);
  });

  testWidgets('pure image messages offer download and multi-select only', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      id: 1,
      seq: 0,
      imageUrl: 'https://example.com/image.png',
      imagePrompt: 'a cave',
    );
    final actions = <MessageAction>[];
    await tester.pumpWidget(
      _harness(messages: const [msg], onAction: (m, a) => actions.add(a)),
    );
    await tester.pump();

    // 图片本身点击打开全屏;点气泡边缘(图片外留白)选中并显示操作行。
    final imageRect = tester.getRect(find.byType(ClipRRect).first);
    await tester.tapAt(Offset(imageRect.left - 6, imageRect.center.dy));
    await tester.pump();
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    expect(find.byIcon(Icons.checklist_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byIcon(Icons.autorenew), findsNothing);
    expect(find.byIcon(Icons.copy_outlined), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byIcon(Icons.send_outlined), findsNothing);

    await tester.tap(find.byIcon(Icons.download_outlined));
    expect(actions, [MessageAction.download]);
  });

  testWidgets(
    'image messages with captions still only offer download and multi-select',
    (tester) async {
      const msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'caption',
        id: 1,
        seq: 0,
        imageUrl: 'https://example.com/image.png',
      );
      await tester.pumpWidget(
        _harness(messages: const [msg], onAction: (_, _) {}),
      );
      await tester.pump();
      await tester.tap(find.text('caption'));
      await tester.pump();

      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.byIcon(Icons.checklist_outlined), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byIcon(Icons.autorenew), findsNothing);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    },
  );

  testWidgets(
    'image regeneration shows a progress overlay and keeps quick actions',
    (tester) async {
      const msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        id: 1,
        seq: 0,
        imageUrl: 'https://example.com/image.png',
        imagePrompt: 'a cave',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: MessageList(
                messages: const [msg],
                draft: '',
                controller: ScrollController(),
                regeneratingImageId: 1,
                onMessageAction: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      final imageRect = tester.getRect(find.byType(ClipRRect).first);
      await tester.tapAt(Offset(imageRect.left - 6, imageRect.center.dy));
      await tester.pump();
      // 重新生成已收进三点菜单;底部只保留图片快捷操作。
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.byIcon(Icons.checklist_outlined), findsOneWidget);
      expect(find.byIcon(Icons.autorenew), findsNothing);
    },
  );

  testWidgets('long-press menu entry still works alongside the buttons', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'hello',
      id: 1,
      seq: 0,
    );
    var menuOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: MessageList(
              messages: const [msg],
              draft: '',
              streaming: false,
              controller: ScrollController(),
              onMessageLongPress: (_) => menuOpened = true,
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('hello'));
    expect(menuOpened, isTrue);
  });

  testWidgets('user avatar renders as image while assistant falls back to '
      'placeholder', (tester) async {
    // 1x1 transparent PNG payload.
    const avatarBytes = [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      1,
      8,
      6,
      0,
      0,
      0,
      31,
      21,
      196,
      137,
      0,
      0,
      0,
      13,
      73,
      68,
      65,
      84,
      120,
      156,
      99,
      248,
      255,
      255,
      63,
      3,
      0,
      0,
      3,
      0,
      1,
      220,
      181,
      103,
      33,
      0,
      0,
      0,
      0,
      73,
      69,
      78,
      68,
      174,
      66,
      96,
      130,
    ];
    final msgUser = const Message(
      sessionId: 1,
      role: 'user',
      content: 'hi',
      id: 1,
      seq: 0,
    );
    final msgAssistant = const Message(
      sessionId: 1,
      role: 'assistant',
      content: 'hello',
      id: 2,
      seq: 1,
    );
    await tester.pumpWidget(
      _harness(
        messages: [msgUser, msgAssistant],
        userAvatarImage: MemoryImage(Uint8List.fromList(avatarBytes)),
      ),
    );
    await tester.pumpAndSettle();

    // 用户头像用图片;助手未设置头像时仍渲染占位头像(描边人形图标)。
    expect(find.byType(CircleAvatar), findsNWidgets(2));
    expect(
      tester
          .widgetList<CircleAvatar>(find.byType(CircleAvatar))
          .where((a) => a.foregroundImage != null)
          .length,
      1,
    );
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets(
    'assistant avatar renders as image while user falls back to placeholder',
    (tester) async {
      const avatarBytes = [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
        8,
        6,
        0,
        0,
        0,
        31,
        21,
        196,
        137,
        0,
        0,
        0,
        13,
        73,
        68,
        65,
        84,
        120,
        156,
        99,
        248,
        255,
        255,
        63,
        3,
        0,
        0,
        3,
        0,
        1,
        220,
        181,
        103,
        33,
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130,
      ];
      final msgUser = const Message(
        sessionId: 1,
        role: 'user',
        content: 'hi',
        id: 1,
        seq: 0,
      );
      final msgAssistant = const Message(
        sessionId: 1,
        role: 'assistant',
        content: 'hello',
        id: 2,
        seq: 1,
      );
      await tester.pumpWidget(
        _harness(
          messages: [msgUser, msgAssistant],
          assistantAvatarImage: MemoryImage(Uint8List.fromList(avatarBytes)),
        ),
      );
      await tester.pumpAndSettle();

      // 助手消息上方带图片头像;用户未设置头像时仍渲染占位头像(人形图标)。
      expect(find.byType(CircleAvatar), findsNWidgets(2));
      expect(
        tester
            .widgetList<CircleAvatar>(find.byType(CircleAvatar))
            .where((a) => a.foregroundImage != null)
            .length,
        1,
      );
      expect(find.byIcon(Icons.person), findsOneWidget);
    },
  );

  testWidgets('empty draft while streaming shows animated typing dots', (
    tester,
  ) async {
    final msg = const Message(
      sessionId: 1,
      role: 'user',
      content: 'hi',
      id: 1,
      seq: 0,
    );
    await tester.pumpWidget(
      _harness(messages: [msg], draft: '', streaming: true),
    );
    await tester.pump();
    // 打字指示器出现(三圆点),不再显示静止的『…』。
    expect(find.byKey(const ValueKey('typing-dots')), findsOneWidget);
    expect(find.text('…'), findsNothing);
    // 未设置角色头像时,草稿气泡上方同样显示占位头像。
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('non-empty draft while streaming renders the draft text', (
    tester,
  ) async {
    final msg = const Message(
      sessionId: 1,
      role: 'user',
      content: 'hi',
      id: 1,
      seq: 0,
    );
    await tester.pumpWidget(
      _harness(messages: [msg], draft: 'partial reply', streaming: true),
    );
    await tester.pump();
    expect(find.text('partial reply'), findsOneWidget);
    expect(find.byKey(const ValueKey('typing-dots')), findsNothing);
  });

  testWidgets('streaming draft inherits character bubble font and size', (
    tester,
  ) async {
    // 草稿气泡与落库后的助手气泡共用角色级样式:字体/字号在流式期间就要
    // 生效,否则流结束落库的瞬间会从默认字体跳到角色设定的衬线字体。
    await tester.pumpWidget(
      _harness(
        messages: const [],
        draft: 'partial reply',
        streaming: true,
        assistantBubbleStyle: const BubbleStyle(
          fontFamily: 'serif',
          fontSize: 21,
        ),
      ),
    );
    await tester.pump();

    final body = tester.widget<RichMessageText>(find.byType(RichMessageText));
    expect(
      body.style.fontFamily,
      defaultTargetPlatform == TargetPlatform.windows ? 'SimSun' : 'serif',
    );
    expect(body.style.fontSize, 21);
  });

  testWidgets(
    'grouped messages: only the last of a same-role run keeps the tail corner',
    (tester) async {
      // 连续两条助手消息:前一条四角全圆(无尾巴),末条左下保留小尾巴圆角。
      final m1 = const Message(
        sessionId: 1,
        role: 'assistant',
        content: 'a1',
        id: 1,
        seq: 0,
      );
      final m2 = const Message(
        sessionId: 1,
        role: 'assistant',
        content: 'a2',
        id: 2,
        seq: 1,
      );
      final m3 = const Message(
        sessionId: 1,
        role: 'user',
        content: 'u',
        id: 3,
        seq: 2,
      );
      await tester.pumpWidget(_harness(messages: [m1, m2, m3]));
      await tester.pump();

      // 组内中间消息:底部两个角都是大圆角(19≈18,小尾巴只有 6)。
      final first = tester.widget<Container>(
        find
            .ancestor(of: find.text('a1'), matching: find.byType(Container))
            .first,
      );
      final firstRadius =
          (first.decoration! as BoxDecoration).borderRadius as BorderRadius;
      expect(firstRadius.bottomLeft, const Radius.circular(18));
      expect(firstRadius.bottomRight, const Radius.circular(18));

      // 组内末条:左下保留小尾巴圆角,右下仍是大圆角。
      final last = tester.widget<Container>(
        find
            .ancestor(of: find.text('a2'), matching: find.byType(Container))
            .first,
      );
      final lastRadius =
          (last.decoration! as BoxDecoration).borderRadius as BorderRadius;
      expect(lastRadius.bottomLeft, const Radius.circular(6));
      expect(lastRadius.bottomRight, const Radius.circular(18));

      // 用户消息:尾巴在右下(用户侧),左下大圆角。
      final user = tester.widget<Container>(
        find
            .ancestor(of: find.text('u'), matching: find.byType(Container))
            .first,
      );
      final userRadius =
          (user.decoration! as BoxDecoration).borderRadius as BorderRadius;
      expect(userRadius.bottomLeft, const Radius.circular(18));
      expect(userRadius.bottomRight, const Radius.circular(6));
    },
  );

  testWidgets(
    'streaming draft beyond the plain-text threshold skips rich parsing',
    (tester) async {
      // 超长流式草稿每 40ms 节流块都会全文重跑富文本解析(主正则/
      // 词典/span 树),几万字级回复尾段吃满帧预算 —— 超过阈值后草稿降级为
      // 纯文本(仅剥 system-reminder + 宏替换),常规长度不受影响。
      final long = '甲' * (kStreamingDraftPlainThreshold + 16);
      await tester.pumpWidget(
        _harness(messages: const [], draft: long, streaming: true),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(RichMessageText),
        findsNothing,
        reason: '超长草稿应走纯文本快路径',
      );
      expect(find.textContaining('甲甲甲'), findsOneWidget, reason: '降级后正文照常显示');

      // 常规长度草稿仍走完整管线(样式无损)。
      await tester.pumpWidget(
        _harness(messages: const [], draft: '短的草稿', streaming: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RichMessageText), findsOneWidget);
    },
  );

  test('crawl animation duration scales with distance within bounds', () {
    // 爬楼动画时长按距离缩放(旧实现固定 200ms —— 跨超长消息一闪
    // 而过、短跳拖沓)。4 视口内线性放大,下限 120ms、上限 400ms,零距离
    // 零时长。600 视口下:600px(1 视口)→ 1/4 档位 190ms,2400px 封顶 400ms。
    expect(crawlAnimationDuration(0, 600), Duration.zero);
    expect(crawlAnimationDuration(-5, 600), Duration.zero);
    expect(crawlAnimationDuration(600, 600), const Duration(milliseconds: 190));
    expect(
      crawlAnimationDuration(2400, 600),
      const Duration(milliseconds: 400),
    );
    expect(
      crawlAnimationDuration(9600, 600),
      const Duration(milliseconds: 400),
    );
  });

  testWidgets(
    'selected message vanishing on rebuild reports closed post-frame, not during build (EL)',
    (tester) async {
      // 回归防护「build 期同步上报炸导航组」:选中一条消息后,
      // 消息被删除/重发改写(列表整体替换、选中 id 消失)时,旧实现在 build 期间
      // 同步调用 onActionsVisibleChanged(false)。监听方(聊天页导航组的
      // AnimatedBuilder)不是本列表的后代而是兄弟子树 —— build 期 markNeedsBuild
      // 直接抛 setState() called during build(真机必现,每次重建重复)。
      // 本用例按 chat_screen 的真实拓扑搭出「列表 + 兄弟 AnimatedBuilder」,
      // 缺一不可:只写回调不接监听者,旧 bug 不会现形。
      final navOpen = ValueNotifier<bool>(false);
      addTearDown(navOpen.dispose);
      final reports = <bool>[];
      const msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '会消失的',
        id: 7,
        seq: 0,
      );

      Widget harness(List<Message> messages) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: Column(
              children: [
                // 兄弟 AnimatedBuilder:监听回调写入的 notifier(= 聊天页导航组)。
                AnimatedBuilder(
                  animation: navOpen,
                  builder: (context, _) => Text(navOpen.value ? '让位' : '正常'),
                ),
                Expanded(
                  child: MessageList(
                    messages: messages,
                    draft: '',
                    controller: ScrollController(),
                    // 操作排按钮仅在动作回调非空时渲染。
                    onMessageAction: (_, _) {},
                    onActionsVisibleChanged: (open) {
                      navOpen.value = open;
                      reports.add(open);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(harness(const [msg]));
      await tester.pumpAndSettle();
      expect(find.text('正常'), findsOneWidget);

      await tester.tap(find.text('会消失的'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(find.text('让位'), findsOneWidget);
      expect(reports, [true]);

      // 重建:选中 id 从列表里消失(模拟删除/重发改写)。
      await tester.pumpWidget(
        harness(const [
          Message(
            sessionId: 1,
            role: 'assistant',
            content: '新的',
            id: 8,
            seq: 1,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      // 修复前:这里抛 setState() called during build。
      expect(tester.takeException(), isNull);
      // false 补报推迟到帧末,但同一次 pumpAndSettle 内必达 —— 导航组不残留
      // "操作排可见"的让位态。
      expect(reports, [true, false]);
      expect(find.text('正常'), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
    },
  );

  testWidgets('revealMessage scrolls a long history to the target message', (
    tester,
  ) async {
    final key = GlobalKey<MessageListState>();
    final messages = List.generate(
      400,
      (i) => Message(
        sessionId: 1,
        role: i.isEven ? 'user' : 'assistant',
        content: 'msg-$i',
        id: i + 1,
        seq: i,
      ),
    );
    await tester.pumpWidget(_harness(messages: messages, listKey: key));
    await tester.pumpAndSettle();
    // 初始停在最新一条。
    expect(find.text('msg-399'), findsOneWidget);
    expect(find.text('msg-19'), findsNothing);

    var done = false;
    bool? ok;
    final future = key.currentState!.revealMessage(20).then((value) {
      ok = value;
      done = true;
    });
    for (var i = 0; i < 100 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(done, isTrue, reason: '定位应在有限帧内收敛');
    await future;
    expect(ok, isTrue);
    final finder = find.text('msg-19');
    expect(finder, findsOneWidget);
    final top = tester.getTopLeft(finder).dy;
    // 目标顶边对齐视口顶部附近(定位边距 12,气泡内边距另计)。
    expect(top, greaterThanOrEqualTo(0));
    expect(top, lessThan(200));
  });

  testWidgets(
    'revealMessage converges on mixed-height history without ping-ponging',
    (tester) async {
      final key = GlobalKey<MessageListState>();
      // 高度差异极大的历史(短文本 vs 上千字长文):懒加载下 maxScrollExtent
      // 只是估算,定位必须靠多帧收敛。用户报告过这类列表里定位会在两条
      // 消息间来回抖动。
      final messages = List.generate(
        300,
        (i) => Message(
          sessionId: 1,
          role: i.isEven ? 'user' : 'assistant',
          content: i % 7 == 0 ? 'long-$i ${'很长的正文用来撑高气泡。' * 120}' : 'msg-$i',
          id: i + 1,
          seq: i,
        ),
      );
      await tester.pumpWidget(_harness(messages: messages, listKey: key));
      await tester.pumpAndSettle();

      var done = false;
      bool? ok;
      key.currentState!.revealMessage(80).then((value) {
        ok = value;
        done = true;
      });
      final offsets = <double>[];
      for (var i = 0; i < 200 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        offsets.add(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
        );
      }
      expect(done, isTrue, reason: '定位应在有限帧内收敛');
      expect(ok, isTrue);

      // 允许一次估算过冲后的回对齐,但不允许反复反向(来回抖动)。
      // 帧间还存在框架对 maxScrollExtent 的像素级修正(十几 px、肉眼不可
      // 感知),以视口 5% 作为「真实反向」的门槛,捕捉的是跨消息的大幅
      // 来回拉扯,而不是边界收紧。
      final minDelta =
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .viewportDimension *
          0.05;
      var reversals = 0;
      for (var i = 2; i < offsets.length; i++) {
        final prev = offsets[i - 1] - offsets[i - 2];
        final next = offsets[i] - offsets[i - 1];
        if (prev.abs() > minDelta &&
            next.abs() > minDelta &&
            prev.sign != next.sign) {
          reversals++;
        }
      }
      expect(reversals, lessThanOrEqualTo(1));
      expect(find.text('msg-79'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('msg-79')).dy,
        inInclusiveRange(0, 200),
      );
    },
  );

  testWidgets('a newer reveal cancels the older convergence loop', (
    tester,
  ) async {
    final key = GlobalKey<MessageListState>();
    final messages = List.generate(
      400,
      (i) => Message(
        sessionId: 1,
        role: i.isEven ? 'user' : 'assistant',
        content: 'msg-$i',
        id: i + 1,
        seq: i,
      ),
    );
    await tester.pumpWidget(_harness(messages: messages, listKey: key));
    await tester.pumpAndSettle();

    // 连点两个条目(或搜索返回后立刻点导航):两个收敛循环若同时 jumpTo,
    // 视口会在两个目标之间来回拉扯。后发起者必须作废先发起者。
    final first = key.currentState!.revealMessage(20);
    final second = key.currentState!.revealMessage(350);
    var done = false;
    second.then((_) => done = true);
    for (var i = 0; i < 200 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(find.text('msg-349'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('msg-349')).dy,
      inInclusiveRange(0, 200),
    );
  });

  testWidgets('visibleUserMessageId tracks the real top visible user message', (
    tester,
  ) async {
    final key = GlobalKey<MessageListState>();
    final messages = List.generate(
      200,
      (i) => Message(
        sessionId: 1,
        role: i.isEven ? 'user' : 'assistant',
        content: i % 5 == 0 ? 'msg-$i ${'长正文' * 80}' : 'msg-$i',
        id: i + 1,
        seq: i,
      ),
    );
    await tester.pumpWidget(_harness(messages: messages, listKey: key));
    await tester.pumpAndSettle();

    // 偶数 i 是 user(id = i+1)。跳到 i=120 后,可见锚点必须是它自己 ——
    // 导航卡片的高亮按这个 id 判断。
    var done = false;
    bool? ok;
    key.currentState!.revealMessage(121).then((value) {
      ok = value;
      done = true;
    });
    for (var i = 0; i < 200 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(ok, isTrue);
    expect(key.currentState!.visibleUserMessageId(), 121);

    // 手动滚向历史后,锚点跟着离开目标、落到更旧的一条 user 上。
    await tester.drag(find.byType(ListView), const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(key.currentState!.visibleUserMessageId(), lessThan(121));
  });

  testWidgets('consecutive reveals to adjacent early users both land', (
    tester,
  ) async {
    final key = GlobalKey<MessageListState>();
    final messages = List.generate(
      200,
      (i) => Message(
        sessionId: 1,
        role: i.isEven ? 'user' : 'assistant',
        // 第一条撑到远超一屏,让第二条落在已布局窗口之外:连续跳转时
        // 第二跳必须走「目标未布局」的推进路径。
        content: i == 0 ? 'msg-$i ${'长正文用来把第一条撑高。' * 1000}' : 'msg-$i',
        id: i + 1,
        seq: i,
      ),
    );
    await tester.pumpWidget(_harness(messages: messages, listKey: key));
    await tester.pumpAndSettle();

    Future<bool> reveal(int id) async {
      var done = false;
      bool? result;
      key.currentState!.revealMessage(id).then((value) {
        result = value;
        done = true;
      });
      for (var i = 0; i < 200 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(done, isTrue, reason: 'id=$id 定位应在有限帧内收敛');
      return result!;
    }

    // 第 1 条 user(id 1) → 第 2 条 user(id 3):第二次目标就在当前视口
    // 下方。旧实现按可能反向的斜率估算推进,会在两个位置间来回抖且
    // 最终到不了目标。
    expect(await reveal(1), isTrue);
    expect(key.currentState!.visibleUserMessageId(), 1);
    expect(await reveal(3), isTrue);
    expect(key.currentState!.visibleUserMessageId(), 3);
    expect(find.byKey(const ValueKey('msg-3')), findsOneWidget);
  });

  testWidgets(
    'revealMessage reaches a far target whose distance exceeds the estimated '
    'scroll extent',
    (tester) async {
      final key = GlobalKey<MessageListState>();
      // 前 150 条是长文、后 350 条是短文本:从底部往上定位时,窗口内的
      // 平均高度与远端真实高度相差一个数量级,懒加载列表的 maxScrollExtent
      // 远远低于目标真实位置。旧实现在估算边界处直接放弃(boundary 推进
      // 小于 1px 即 return false),这类长文/图片混排会话永远跳不过去。
      final messages = List.generate(
        500,
        (i) => Message(
          sessionId: 1,
          role: i.isEven ? 'user' : 'assistant',
          content: i < 150 ? 'msg-$i ${'超长正文用来撑高气泡。' * 300}' : 'msg-$i',
          id: i + 1,
          seq: i,
        ),
      );
      await tester.pumpWidget(_harness(messages: messages, listKey: key));
      await tester.pumpAndSettle();
      expect(find.text('msg-499'), findsOneWidget);

      var done = false;
      bool? ok;
      key.currentState!.revealMessage(5).then((value) {
        ok = value;
        done = true;
      });
      for (var i = 0; i < 200 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(done, isTrue, reason: '跨上百条长文的定位应在有限帧内收敛');
      expect(ok, isTrue, reason: '目标在估算 maxScrollExtent 之外也必须继续推进');
      expect(find.byKey(const ValueKey('msg-5')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('msg-5'))).dy,
        inInclusiveRange(0, 200),
      );
    },
  );
}
