// 会话内搜索 UI:命中列表与内部注入剥离、空态、命中返 id、跳转旧消息并
// 短暂高亮。
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
import 'package:microscritt/ui/chat_search_screen.dart';
import '../support/test_database.dart';

/// 轮询真实异步(DB 查询)与帧:搜索页的防抖 Timer 在假时钟里推进,DB 读
/// 需要 runAsync 的真实窗口。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 80 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

/// 等 ChatController.load 完整落定(与 chat_screen_test 同款等待)。
Future<void> _settleChat(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      final loaded = container.read(chatControllerProvider).sessionId != null;
      final llmReady = !container.read(llmProvidersProvider).isLoading;
      if (loaded && llmReady) break;
    }
  });
}

/// 读气泡描边宽度:搜索定位高亮是 2px 强调色描边,计时到点后回到 1px 发丝边,
/// 用它观测高亮的生命周期。
double _bubbleBorderWidth(WidgetTester tester, String text) {
  final container = find
      .ancestor(of: find.text(text), matching: find.byType(Container))
      .first;
  final decoration =
      tester.widget<Container>(container).decoration as BoxDecoration;
  return (decoration.border! as Border).top.width;
}

void main() {
  testWidgets('search lists visible hits and returns the tapped message id', (
    tester,
  ) async {
    late AppDatabase db;
    late int sessionId;
    late int firstId;
    late int thirdId;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final messages = MessageRepository(db);
      firstId = (await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: '第一句:魔法学院的清晨',
      )).id!;
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '第二句:他学会了 Dragon 火焰',
      );
      thirdId = (await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '第三句:魔法再次出现',
      )).id!;
      // 命中只存在于内部注入里:展示口径剥离后不应出现在结果中。
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: '<system-reminder>隐藏的魔法备忘</system-reminder>正常内容',
      );
    });

    int? popped;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<int>(
                      MaterialPageRoute(
                        builder: (_) => ChatSearchScreen(
                          sessionId: sessionId,
                          characterName: 'Alice',
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '魔法');
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntil(
      tester,
      () => find.textContaining('条结果').evaluate().isNotEmpty,
    );
    expect(find.text('2 条结果'), findsOneWidget);
    expect(find.textContaining('第三句'), findsOneWidget);
    expect(find.textContaining('第一句'), findsOneWidget);
    expect(find.textContaining('隐藏的魔法备忘'), findsNothing);
    expect(find.byKey(ValueKey('chat-search-hit-$firstId')), findsOneWidget);
    expect(find.byKey(ValueKey('chat-search-hit-$thirdId')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('chat-search-hit-$thirdId')));
    await tester.pumpAndSettle();
    expect(popped, thirdId);
    expect(find.byType(ChatSearchScreen), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('search shows an empty state before and after no matches', (
    tester,
  ) async {
    late AppDatabase db;
    late int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sessionId, role: 'user', content: '只有这一句');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatSearchScreen(sessionId: sessionId, characterName: 'Alice'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('搜索聊天记录'), findsWidgets);
    expect(find.text('输入关键词,检索这段会话的全部历史消息。'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntil(tester, () => find.text('没有匹配的消息').evaluate().isNotEmpty);
    expect(find.text('换一个关键词试试。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('chat search jumps to an old message and highlights it briefly', (
    tester,
  ) async {
    late AppDatabase db;
    late int characterId;
    late int sessionId;
    late int targetId;
    await tester.runAsync(() async {
      db = await openTestDb();
      characterId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(characterId, 's');
      final batch = db.db.batch();
      for (var i = 0; i < 340; i++) {
        batch.insert('messages', {
          'session_id': sessionId,
          'role': i.isEven ? 'user' : 'assistant',
          'content': i == 5 ? '远古的目标消息' : 'm$i',
          'seq': i,
        });
      }
      await batch.commit(noResult: true);
      targetId = (await MessageRepository(
        db,
      ).searchInSession(sessionId, '远古的目标')).single.messageId;
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
    await _settleChat(tester);
    // 首屏只加载尾部窗口,目标在更早的历史里。
    expect(find.text('远古的目标消息'), findsNothing);

    await tester.tap(find.byTooltip('搜索聊天记录'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatSearchScreen), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(ChatSearchScreen),
        matching: find.byType(TextField),
      ),
      '远古的目标',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntil(
      tester,
      () => find
          .byKey(ValueKey('chat-search-hit-$targetId'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byKey(ValueKey('chat-search-hit-$targetId')));

    // 搜索页的命中片段也含同样的文本,必须等路由退场后聊天气泡才是唯一来源。
    await _pumpUntil(
      tester,
      () =>
          find.byType(ChatSearchScreen).evaluate().isEmpty &&
          find.text('远古的目标消息').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 50));
    final top = tester.getTopLeft(find.text('远古的目标消息')).dy;
    expect(top, greaterThanOrEqualTo(0));
    expect(top, lessThan(260), reason: '目标气泡应被定位到视口顶部附近');
    expect(_bubbleBorderWidth(tester, '远古的目标消息'), 2);

    // 高亮是短暂的:2 秒计时到点后回到普通发丝边。
    await tester.pump(const Duration(seconds: 3));
    expect(_bubbleBorderWidth(tester, '远古的目标消息'), 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });
}
