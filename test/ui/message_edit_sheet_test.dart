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

/// 等 ChatController.load 整体完成(sessionId 落定)+ llmProvidersProvider 就绪,
/// 之后才能安全关闭 DB(与 chat_screen_test 同款)。轮询上限给足 4s —— 全量
/// 并行跑时 CPU 竞争会显著拉长真实异步(sqflite/Provider 链路)的收敛时间,
/// 60×20ms 的旧窗口曾被击穿(偶发红,单跑必绿)。
Future<void> _settleChat(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      final loaded = container.read(chatControllerProvider).sessionId != null;
      final llmReady = !container.read(llmProvidersProvider).isLoading;
      if (loaded && llmReady) break;
    }
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('edit flow: opens bottom sheet, saves edits and refreshes bubble', (tester) async {
    late final AppDatabase db;
    late int sessionId;
    late int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(db).append(sessionId: sessionId, role: 'user', content: '原始内容');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sessionId, characterId: charId, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _settleChat(tester);

    // 点气泡(选中) → 下方出现操作按钮,再点"编辑"。
    await tester.tap(find.text('原始内容'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // 底部编辑区出现:标题正确、含取消/保存与字数统计。
    expect(find.text('编辑消息'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('4 字符'), findsOneWidget); // “原始内容” = 4 个字符

    // 布局回归:编辑区按内容高度收缩,而不是撑满整屏 —— 若根 Align 少了
    // heightFactor:1,sheet 表面会被拉满,「编辑消息」上方留一大块空白。
    final sheetSize = tester.getSize(find.byType(BottomSheet));
    expect(sheetSize.height, lessThan(600 * 0.9));

    // 清空重写后保存 → 气泡内容刷新为改后文本。
    await tester.enterText(find.byType(TextField).last, '新的编辑内容');
    await tester.pump();
    expect(find.text('6 字符'), findsOneWidget);
    await tester.tap(find.text('保存'));
    // editMessage 落库+刷新是真实异步(sqflite),必须等它收敛后再断言。这里
    // 只按**控制器状态**轮询、循环内不 pump:实测全量并行下,"循环内逐次
    // pump + 查 widget"的写法会把 bySession 的完成推迟到轮询循环退出为止
    // (固定窗口 1.2s/4s/8s 先后被击穿;换成 30s 墙钟窗口后,完成时刻仍精确
    // 贴着循环退出)。改为状态先落地、出循环后再统一补帧渲染,绕开该调度
    // 病理;正常路径几十毫秒即命中退出。
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        final updated = container
            .read(chatControllerProvider)
            .messages
            .any((m) => m.content == '新的编辑内容');
        if (updated) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    // 编辑区关闭,气泡显示新内容。
    expect(find.text('编辑消息'), findsNothing);
    expect(find.text('新的编辑内容'), findsOneWidget);
    expect(find.text('原始内容'), findsNothing);
  });

  testWidgets('edit flow: assistant reply shows 编辑回复 title', (tester) async {
    late final AppDatabase db;
    late int sessionId;
    late int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(db).append(sessionId: sessionId, role: 'assistant', content: '回复');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sessionId, characterId: charId, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _settleChat(tester);

    await tester.tap(find.text('回复'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // 助手消息的编辑标题是"编辑回复"。
    expect(find.text('编辑回复'), findsOneWidget);
    // 取消即可关闭,不改动内容。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('编辑回复'), findsNothing);
    expect(find.text('回复'), findsOneWidget);
  });

  testWidgets('edit flow: saving whitespace-only text just cancels (no save)', (tester) async {
    late final AppDatabase db;
    late int sessionId;
    late int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(db).append(sessionId: sessionId, role: 'user', content: '内容');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sessionId, characterId: charId, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await _settleChat(tester);

    await tester.tap(find.text('内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // 编辑区确实打开。
    expect(find.text('编辑消息'), findsOneWidget);

    // 清空成纯空白 → 保存键置灰(不可保存)。
    await tester.enterText(find.byType(TextField).last, '   ');
    await tester.pump();
    // FilledButton.icon 构造返回私有 _FilledButtonWithIcon,须按子类型匹配。
    final save = tester.widget<FilledButton>(
      find.ancestor(of: find.text('保存'), matching: find.bySubtype<FilledButton>()).first,
    );
    expect(save.onPressed, isNull); // 置灰,不可保存

    // 点"取消"关闭,内容保持原样。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('编辑消息'), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });
}
