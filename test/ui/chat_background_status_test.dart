import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import '../support/test_database.dart';

/// 主写返回 reply.,后台调用返回一段状态 JSON —— 模拟真实双写引擎。
class _DualBackend implements LlmBackend {
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable([
        const TextDelta('reply.'),
        const DoneEvent(),
      ]);
    }
    return Stream.fromIterable([
      const TextDelta('{"variables":{"mood":"calm"},"memory":null}'),
      const DoneEvent(),
    ]);
  }
}

/// 主写流由测试驱动(TextDelta → 关闭),用于验证中断按钮。
class _ControllableBackend implements LlmBackend {
  final _controller = StreamController<LlmEvent>();
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    return _controller.stream;
  }

  void emit(LlmEvent e) => _controller.add(e);
  void close() => _controller.close();
  StreamController<LlmEvent> get stream => _controller;
}

/// 记忆初始化专用假后端:调用即返回一段初始记忆 JSON。
class _MemoryInitBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield const TextDelta('{"memory":"Alice is a silver-haired catgirl from Eldoria."}');
    yield const DoneEvent();
  }
}

Future<void> _pumpUntilLoaded(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      if (container.read(chatControllerProvider).sessionId != null) break;
    }
    await tester.pump();
  });
}

void main() {
  int sessionId = 1;
  testWidgets(
    'background-agent status strip appears and reports success after a turn',
    (tester) async {
      late final AppDatabase db;
      late final int charId;
      final backend = _DualBackend();
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's1');
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendConfigProvider.overrideWith(
              (ref) => const BackendConfig(
                provider: BackendProvider.openai,
                baseUrl: 'https://x',
                apiKey: 'k',
                model: 'm',
              ),
            ),
            backendProvider.overrideWith((ref) => backend),
          ],
          child: MaterialApp(
            home: ChatScreen(
              sessionId: sessionId,
              characterId: charId,
              character: const CharacterCard(name: 'Alice'),
            ),
          ),
        ),
      );
      await _pumpUntilLoaded(tester);

      // 尚未发消息:后台agent 状态条不显示(处于 idle)。
      expect(find.textContaining('后台agent'), findsNothing);

      // 发一条消息 → 主回复 + 后台维护都跑完(点击发送按钮触发;输入框为
      // TextInputAction.newline,Enter 不发送)。
      final field = find.byType(TextField);
      await tester.enterText(field, 'hi');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      await tester.runAsync(() async {
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ChatScreen)),
          );
          if (container.read(chatControllerProvider).backgroundStatus.name ==
              'succeeded') {
            break;
          }
        }
      });
      await tester.pumpAndSettle();

      // 状态闪示可见且带维护摘要(技能已迁出后台维护,不再出现在摘要里;
      // 后台返回的 variables 更新仍在)。闪示文案是富文本双段 span,
      // findRichText 才能匹配。
      expect(find.textContaining('后台agent', findRichText: true), findsOneWidget);
      expect(find.textContaining('变量 mood=calm', findRichText: true), findsOneWidget);

      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'interrupt button appears while streaming and stops the main write',
    (tester) async {
      late final AppDatabase db;
      late final int charId;
      final backend = _ControllableBackend();
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's1');
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendConfigProvider.overrideWith(
              (ref) => const BackendConfig(
                provider: BackendProvider.openai,
                baseUrl: 'https://x',
                apiKey: 'k',
                model: 'm',
              ),
            ),
            backendProvider.overrideWith((ref) => backend),
          ],
          child: MaterialApp(
            home: ChatScreen(
              sessionId: sessionId,
              characterId: charId,
              character: const CharacterCard(name: 'Alice'),
            ),
          ),
        ),
      );
      await _pumpUntilLoaded(tester);

      // 输入并发送;发送键在流式中变成中断键。
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.runAsync(() async {
        backend.emit(const TextDelta('partial-'));
        // 等草稿真正进入气泡且中断键就绪,再点停止 —— 否则可能停在
        // "已开始流式但 delta 尚未消费"的窗口,截断时草稿为空。
        for (var i = 0; i < 80; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          if (find.byIcon(Icons.stop_rounded).evaluate().isNotEmpty &&
              find
                  .textContaining('partial-', findRichText: true)
                  .evaluate()
                  .isNotEmpty) {
            break;
          }
        }
      });
      // 流式中发送键变为中断键。
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      expect(
        find.textContaining('partial-', findRichText: true),
        findsOneWidget,
      );

      // 点中断:主写被截断,已生成的部分文本落库保留。
      await tester.tap(find.byIcon(Icons.stop_rounded));
      await tester.runAsync(() async {
        backend.close(); // 让流结束,回合收敛。
        for (var i = 0; i < 80; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          final rows = await MessageRepository(db).bySession(sessionId);
          if (rows.length >= 2) break;
        }
      });
      await tester.pumpAndSettle();

      // 用户消息与部分回复都在(不想保留可自行删除)。
      await tester.runAsync(() async {
        final messages = await MessageRepository(db).bySession(sessionId);
        expect(messages.map((m) => m.role).toList(), ['user', 'assistant']);
        expect(messages.last.content, 'partial-');
        await db.db.close();
      });
    },
  );

  testWidgets(
    'memory-init strip appears for an empty-memory session, initializes memory on tap, then disappears',
    (tester) async {
      late final AppDatabase db;
      late final int charId;
      final backend = _MemoryInitBackend();
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's1');
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendConfigProvider.overrideWith(
              (ref) => const BackendConfig(
                provider: BackendProvider.openai,
                baseUrl: 'https://x',
                apiKey: 'k',
                model: 'm',
              ),
            ),
            backendProvider.overrideWith((ref) => backend),
          ],
          child: MaterialApp(
            home: ChatScreen(
              sessionId: sessionId,
              characterId: charId,
              character: const CharacterCard(name: 'Alice', description: 'a silver-haired catgirl'),
            ),
          ),
        ),
      );
      await _pumpUntilLoaded(tester);

      // 记忆为空 + 后台 memory 功能开启:初始化提示条出现。
      expect(find.textContaining('新会话记忆为空'), findsOneWidget);
      expect(find.text('初始化记忆'), findsOneWidget);

      // 触发初始化。初始化链路含真实数据库 I/O 与 LLM 流,必须整体在
      // runAsync(真实异步区)里驱动 —— 由控制器直接发起(tap 的 onPressed 只是
      // 转发到同一个入口,控制器级行为已由 chat_controller_test 覆盖)。
      await tester.runAsync(() async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ChatScreen)),
        );
        final controller = container.read(chatControllerProvider.notifier);
        await controller.initializeMemory();
        final task = controller.backgroundTask;
        if (task != null) await task;
      });
      await tester.pump();
      // 压过 action → 闪示的模式切换退场动画:旧提示胶囊在淡出期内仍挂在树上,
      // 单帧后 find 仍能找到「新会话记忆为空」。
      await tester.pumpAndSettle();

      // 落库了一条初始记忆;提示条消失(记忆非空);状态闪示展示初始化摘要。
      await tester.runAsync(() async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ChatScreen)),
        );
        final memories = await container.read(memoriesProvider(sessionId).future);
        expect(memories.single.content, 'Alice is a silver-haired catgirl from Eldoria.');
      });
      expect(find.textContaining('新会话记忆为空'), findsNothing);
      expect(find.textContaining('记忆已初始化', findRichText: true), findsOneWidget);

      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'memory-init strip can be dismissed without initializing',
    (tester) async {
      late final AppDatabase db;
      late final int charId;
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sessionId = await SessionRepository(db).create(charId, 's1');
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendConfigProvider.overrideWith(
              (ref) => const BackendConfig(
                provider: BackendProvider.openai,
                baseUrl: 'https://x',
                apiKey: 'k',
                model: 'm',
              ),
            ),
            backendProvider.overrideWith((ref) => _MemoryInitBackend()),
          ],
          child: MaterialApp(
            home: ChatScreen(
              sessionId: sessionId,
              characterId: charId,
              character: const CharacterCard(name: 'Alice'),
            ),
          ),
        ),
      );
      await _pumpUntilLoaded(tester);

      // 点关闭按钮:提示条消失,且不触发任何 LLM 调用(记忆仍为空)。
      expect(find.text('初始化记忆'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭初始化提示'));
      await tester.pump();
      expect(find.textContaining('新会话记忆为空'), findsNothing);

      await tester.runAsync(() async {
        expect(await MemoryRepository(db).bySession(sessionId), isEmpty);
        await db.db.close();
      });
    },
  );
}
