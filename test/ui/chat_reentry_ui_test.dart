import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import 'package:microscritt/ui/widgets/message_list.dart';
import '../support/test_database.dart';

/// 复现「退出会话后重新进入,消息列表为空」的 UI 层回归:
/// 真实导航是 push/pop —— pop 销毁 ChatScreen State,重进新建 State,而
/// chatControllerProvider 是全局的,控制器仍停留在上一个会话的已加载数据上。
/// 二次进入同一会话时首帧就有「属于本屏会话」的残留状态,初始定位判定与
/// 首次进入不同;若切换窗口的隐藏分支不区分暂存转录的归属会话,列表会永远
/// 滞留在 _entrySettling 的透明态,表现为「消息列表为空」。
void main() {
  double opacityOf(WidgetTester t) => t.widget<Opacity>(
        find.byKey(const ValueKey('message-list-visibility')),
      ).opacity;

  /// 走完一次「进入会话」:挂载 ChatScreen,等异步 load 链路与定位收敛落定。
  Future<void> enterSession(WidgetTester tester, AppDatabase db, int sessionId) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: ChatScreen(
          sessionId: sessionId,
          characterId: 1,
          character: const CharacterCard(name: 'Alice'),
        ),
      ),
    ));
    // 等真实的异步 load 链路落定(与 autoscroll 测试同款:真实延时 + pump,
    // 不用 pumpAndSettle 轮询掩盖「数据帧之后才发生贴底定位」的时序)。
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  /// 退出(pop):卸载 ChatScreen,保留 ProviderScope(控制器状态残留,
  /// 与真实导航一致)。
  Future<void> exitToSessionsList(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: const SizedBox.shrink()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('re-entering the same chat screen shows messages (not a blank/hidden list)', (tester) async {
    const long = '这是一条用来撑高消息列表的正文,内容足够长,让它在测试视口里可以产生滚动范围。';
    late final AppDatabase db;
    late final int sessionA;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionA = await SessionRepository(db).create(charId, 'A');
      for (var i = 0; i < 12; i++) {
        await MessageRepository(db).append(
          sessionId: sessionA,
          role: i.isEven ? 'user' : 'assistant',
          content: '$long 第 $i 段:${'呀' * 20}',
        );
      }
    });

    await enterSession(tester, db, sessionA);
    expect(opacityOf(tester), 1.0, reason: '首次进入:定位收敛后列表应可见');

    await exitToSessionsList(tester, db);
    await enterSession(tester, db, sessionA);

    expect(opacityOf(tester), 1.0, reason: '重新进入:列表不应滞留在透明隐藏态');
    expect(find.byType(MessageList), findsOneWidget);
    expect(find.textContaining('第 11 段'), findsOneWidget, reason: '最新消息应可见');
  });

  testWidgets('A -> B -> A detour also re-enters cleanly (foreign transcript stays hidden, then reveals)', (tester) async {
    const long = '这是一条用来撑高消息列表的正文,内容足够长,让它在测试视口里可以产生滚动范围。';
    late final AppDatabase db;
    late final int sessionA;
    late final int sessionB;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionA = await SessionRepository(db).create(charId, 'A');
      sessionB = await SessionRepository(db).create(charId, 'B');
      for (var i = 0; i < 6; i++) {
        await MessageRepository(db).append(
          sessionId: sessionA,
          role: i.isEven ? 'user' : 'assistant',
          content: 'A场:$long 第 $i 段',
        );
      }
      await MessageRepository(db).append(sessionId: sessionB, role: 'user', content: 'B场唯一一条');
    });

    await enterSession(tester, db, sessionA);
    expect(opacityOf(tester), 1.0, reason: '首次进入 A 应可见');

    await exitToSessionsList(tester, db);
    await enterSession(tester, db, sessionB);
    expect(opacityOf(tester), 1.0, reason: '进入 B 应可见');
    expect(find.text('B场唯一一条'), findsOneWidget);
    expect(find.textContaining('A场:'), findsNothing, reason: 'A 的转录不得串味到 B');

    await exitToSessionsList(tester, db);
    await enterSession(tester, db, sessionA);
    expect(opacityOf(tester), 1.0, reason: '从 B 绕回再进 A 也应可见');
    expect(find.textContaining('A场:'), findsWidgets);
    expect(find.text('B场唯一一条'), findsNothing, reason: 'B 的转录不得串味回 A');
  });
}
