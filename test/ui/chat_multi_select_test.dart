// 聊天消息多选:快捷选择、批量删除与撤销。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../support/image_fixture.dart';
import '../support/test_database.dart';

/// 等 ChatController.load 落定,之后才能安全关闭 DB。
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

/// 对话框/菜单动画只需推进有限帧;图片占位转圈会让 pumpAndSettle 永不收敛。
Future<void> _pumpFrames(WidgetTester tester, [int frames = 4]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 等真实 DB 写入完成:每次给一个真实异步窗口再 pump,直到条件成立。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 60 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  testWidgets('多选快捷选择、批量删除与撤销', (tester) async {
    late AppDatabase db;
    late int characterId;
    late int sessionId;
    late int lastMessageId;
    await tester.runAsync(() async {
      db = await openTestDb();
      characterId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(characterId, 's');
      final repo = MessageRepository(db);
      final hash = await putTestImage(db);
      await repo.append(sessionId: sessionId, role: 'user', content: '文本一');
      await repo.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: hash,
      );
      await repo.append(sessionId: sessionId, role: 'user', content: '文本二');
      final last = await repo.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: hash,
      );
      lastMessageId = last.id!;
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
    await _pumpFrames(tester);

    // 会话菜单 → 多选消息。
    await tester.tap(find.byTooltip('会话操作'));
    await _pumpFrames(tester);
    await tester.tap(find.text('多选消息'));
    await _pumpFrames(tester);
    expect(find.text('已选 0 条'), findsOneWidget);

    // 删除/导出固定在右上角 AppBar,空选择时禁用。
    final appBarDelete = find.descendant(
      of: find.byType(AppBar),
      matching: find.byKey(const ValueKey('message_selection_delete')),
    );
    final appBarExport = find.descendant(
      of: find.byType(AppBar),
      matching: find.byKey(const ValueKey('message_selection_export')),
    );
    expect(appBarDelete, findsOneWidget);
    expect(appBarExport, findsOneWidget);
    expect(tester.widget<IconButton>(appBarDelete).onPressed, isNull);
    expect(tester.widget<IconButton>(appBarExport).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('message_selection_images')));
    await tester.pump();
    expect(find.text('已选 2 条'), findsOneWidget);
    expect(tester.widget<IconButton>(appBarDelete).onPressed, isNotNull);
    expect(tester.widget<IconButton>(appBarExport).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('message_selection_text')));
    await tester.pump();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('message_selection_all')));
    await tester.pump();
    expect(find.text('已选 4 条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('message_selection_none')));
    await tester.pump();
    expect(find.text('已选 0 条'), findsOneWidget);

    // 点击气泡也可切换选中(富文本正文不是 Text,用底部可见条目的稳定 key)。
    await tester.tap(find.byKey(ValueKey('msg-$lastMessageId')));
    await tester.pump();
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('message_selection_all')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('message_selection_delete')));
    await _pumpFrames(tester);
    expect(find.text('删除 4 条消息?'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await _pumpUntil(
      tester,
      () => find.textContaining('已删除 4 条消息').evaluate().isNotEmpty,
    );
    await tester.runAsync(() async {
      expect(await MessageRepository(db).bySession(sessionId), isEmpty);
    });

    // 等 SnackBar 滑入完成再点撤销,否则动作按钮还在屏幕下缘之外。
    await _pumpFrames(tester, 4);
    await tester.tap(find.text('撤销'));
    await tester.pump();
    final restoredRows = await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        final rows = await MessageRepository(db).bySession(sessionId);
        if (rows.length == 4) return rows;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return MessageRepository(db).bySession(sessionId);
    });
    expect(restoredRows, hasLength(4));
    await _pumpFrames(tester, 4);
    // 撤销按新插入行重建,id 会重新分配;按控制器消息数断言完整恢复。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatScreen)),
    );
    expect(container.read(chatControllerProvider).messages, hasLength(4));
    await tester.runAsync(() async {
      final restored = await MessageRepository(db).bySession(sessionId);
      expect(restored, hasLength(4));
      expect(restored.map((message) => message.content).toList(), [
        '文本一',
        '',
        '文本二',
        '',
      ]);
    });

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('安卓返回键与 Esc 先退出多选,不离开会话', (tester) async {
    late AppDatabase db;
    late int characterId;
    late int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      characterId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(characterId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sessionId, role: 'user', content: '文本一');
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
    await _pumpFrames(tester);

    Future<void> enterSelection() async {
      await tester.tap(find.byTooltip('会话操作'));
      await _pumpFrames(tester);
      await tester.tap(find.text('多选消息'));
      await _pumpFrames(tester);
      expect(find.text('已选 0 条'), findsOneWidget);
    }

    await enterSelection();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('已选 0 条'), findsNothing, reason: '返回键应只退出多选');

    await enterSelection();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('已选 0 条'), findsNothing, reason: 'Esc 应只退出多选');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });
}
