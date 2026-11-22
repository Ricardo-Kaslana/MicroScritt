// 会话列表页 widget 测试:条数与末条预览、文本/图片细分、检索、新建与删除会话。
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
import 'package:microscritt/ui/sessions_screen.dart';
import '../support/image_fixture.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  late AppDatabase db;
  late int charId;
  const card = CharacterCard(name: 'Alice', firstMessage: '你好,旅行者。');

  Widget harness([CharacterCard? c]) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(
      home: SessionsScreen(characterId: charId, character: c ?? card),
    ),
  );

  testWidgets('lists sessions with message count and last message preview', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(card);
      final s1 = await SessionRepository(db).create(charId, '酒馆相遇');
      await SessionRepository(db).create(charId, '空会话');
      await MessageRepository(
        db,
      ).append(sessionId: s1, role: 'assistant', content: card.firstMessage);
      await MessageRepository(
        db,
      ).append(sessionId: s1, role: 'user', content: '你好');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('酒馆相遇'), findsOneWidget);
    expect(find.text('空会话'), findsOneWidget);
    expect(find.textContaining('2 条消息'), findsOneWidget);
    expect(find.textContaining('你好'), findsWidgets); // 预览里包含最后一条消息
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('session entry shows text/image breakdown when images exist', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(card);
      final withImages = await SessionRepository(db).create(charId, '有图会话');
      final textOnly = await SessionRepository(db).create(charId, '纯文会话');
      await MessageRepository(
        db,
      ).append(sessionId: withImages, role: 'user', content: '画一张');
      await MessageRepository(db).append(
        sessionId: withImages,
        role: 'assistant',
        content: '',
        imageHash: await putTestImage(db),
      );
      await MessageRepository(
        db,
      ).append(sessionId: withImages, role: 'assistant', content: '画好了');
      await MessageRepository(
        db,
      ).append(sessionId: textOnly, role: 'user', content: '纯文本');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    // 带图会话:「x 条消息:y 条文本 + z 条图片」细分;纯文会话保持原样。
    expect(find.textContaining('3 条消息:2 条文本 + 1 条图片'), findsOneWidget);
    expect(find.textContaining('1 条消息'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('search filters sessions by title and last message', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(card);
      final tavern = await SessionRepository(db).create(charId, '酒馆相遇');
      final mountain = await SessionRepository(db).create(charId, '雪山旅途');
      await MessageRepository(
        db,
      ).append(sessionId: tavern, role: 'user', content: '来一杯麦酒');
      await MessageRepository(
        db,
      ).append(sessionId: mountain, role: 'user', content: '风雪很大');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '雪山');
    await tester.pumpAndSettle();
    expect(find.text('雪山旅途'), findsOneWidget);
    expect(find.text('酒馆相遇'), findsNothing);

    // 消息预览也参与匹配。
    await tester.enterText(find.byType(TextField), '麦酒');
    await tester.pumpAndSettle();
    expect(find.text('酒馆相遇'), findsOneWidget);
    expect(find.text('雪山旅途'), findsNothing);

    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的会话'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('FAB creates a new session with first message and opens chat', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(card);
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('还没有会话'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FloatingActionButton, '新建会话'));
      // 先等真实 I/O(create + append + push)完成,再抽帧收敛动画
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    // 新会话写入开场白并跳转到聊天页
    expect(find.byType(ChatScreen), findsOneWidget);
    var msgCount = 0;
    String? msgContent;
    await tester.runAsync(() async {
      final sessions = await SessionRepository(db).byCharacter(charId);
      expect(sessions, hasLength(1));
      expect(sessions.single.title, '新会话');
      final msgs = await MessageRepository(db).bySession(sessions.single.id);
      msgCount = msgs.length;
      msgContent = msgs.isEmpty ? null : msgs.single.content;
    });
    expect(msgCount, 1);
    expect(msgContent, '你好,旅行者。');
    // ChatScreen 的 load 是异步多步读库;等它完成后才关 db,否则
    // 后续读库抛 database_closed。
    var chatLoaded = false;
    await tester.runAsync(() async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (container.read(chatControllerProvider).characterId != null) {
          chatLoaded = true;
          break;
        }
      }
    });
    expect(
      chatLoaded,
      isTrue,
      reason: 'ChatScreen load should finish before closing the db',
    );
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('多开场白角色新建会话留空,可另选一条开场白', (tester) async {
    const multi = CharacterCard(
      name: 'Alice',
      firstMessage: '主开场白',
      alternateGreetings: ['备用一', '备用二'],
    );
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(multi);
    });
    await tester.pumpWidget(harness(multi));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('还没有会话'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FloatingActionButton, '新建会话'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.byType(ChatScreen), findsOneWidget);
    await waitUntilOrFail(
      tester,
      () => find.text('与 Alice 开始对话').evaluate().isNotEmpty,
      reason: '多开场白的新会话应停留在空态供选择',
    );
    expect(find.text('主开场白'), findsOneWidget);
    expect(find.text('备用一'), findsOneWidget);
    expect(find.text('备用二'), findsOneWidget);
    var rows = await tester.runAsync(() => db.db.query('messages'));
    expect(rows, isEmpty, reason: '选择前不应自动写入任何开场白');

    await tester.tap(find.text('备用二'));
    await waitUntilOrFail(tester, () {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      return container
              .read(chatControllerProvider)
              .lastContext
              ?.messages
              .any((m) => m.content == '备用二') ??
          false;
    }, reason: '选择备用开场白后未落库或未重算上下文');
    rows = await tester.runAsync(() => db.db.query('messages'));
    expect(rows, hasLength(1));
    expect(rows!.single['content'], '备用二');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('新建无开场白会话后宽窗侧栏立即出现该会话', (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 无开场白:新会话 0 条消息,聊天页加载不会触发消息数变化 —— 侧栏
    // 完全依赖新建时的失效,正是「侧栏看不到刚建会话」的复现场景。
    const blank = CharacterCard(name: 'Alice');
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(blank);
    });
    await tester.pumpWidget(harness(blank));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('还没有会话'), findsOneWidget);

    // 模拟「此前打开过聊天页」:侧栏跨角色分组数据已被缓存。新建会话
    // 若不失效它,进入聊天页后侧栏会停留在空分组快照 —— 回归点。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SessionsScreen)),
    );
    await tester.runAsync(() => container.read(sessionGroupsProvider.future));

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '新建会话'));
      // 先等真实 I/O(create + append + push)完成,再抽帧收敛动画。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    expect(find.byType(ChatScreen), findsOneWidget);

    var newSessionId = 0;
    await tester.runAsync(() async {
      newSessionId = (await SessionRepository(
        db,
      ).byCharacter(charId)).single.id;
    });
    // 侧栏分组重查是真实 I/O:交替 runAsync + 推帧直到行渲染出来。
    final row = find.byKey(ValueKey('sidebar-session-$newSessionId'));
    for (var i = 0; i < 120 && row.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(row, findsOneWidget);

    // 收尾:卸载并让聊天加载等在途 DB future 落定后再关库。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('delete menu item removes the session after confirmation', (
    tester,
  ) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(card);
      await SessionRepository(db).create(charId, '待删除');
    });
    await tester.pumpWidget(harness());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    // 右上角导入也收在「更多操作」菜单里,行内菜单按 ListTile 定位。
    await tester.tap(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byTooltip('更多操作'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除会话?'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('删除').last);
      // invalidate 触发的重载:轮询 provider 直到新数据落地(先抽帧启动再等 I/O)。
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SessionsScreen)),
      );
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(
          const Duration(milliseconds: 50),
        ); // 真实时间,喂给 DB isolate
        await tester.pump();
        final st = container.read(sessionInfosProvider(charId));
        final stillThere = st.value?.any((e) => e.title == '待删除') ?? true;
        if (!st.isLoading && !stillThere) break;
      }
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();

    expect(find.text('待删除'), findsNothing);
    expect(find.text('还没有会话'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });
}
