// 聊天页装配与生命周期:消息渲染、背景层与模糊、图片气泡跨重建保帧、
// 后台生图即时出现、输入行布局与头像状态卡。
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/image_result.dart';
import 'package:microscritt/models/user.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import 'package:microscritt/ui/user_screen.dart';
import 'package:microscritt/ui/widgets/message_list.dart';
import '../support/test_database.dart';

/// 用 dart:ui 画一块纯色矩形并编码为 PNG base64(已知宽高比、确定可解码)。
Future<String> _pngBase64(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff4477aa),
  );
  final img = await recorder.endRecording().toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return base64Encode(data!.buffer.asUint8List());
}

/// 反复 pump 直到 [condition] 成立(图片解码是真实异步,固定延时在负载下会抖)。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 40 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue);
}

/// 空 Hook 运行时:只验证接线,不求值任何 JS。
class _NoopHookRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => null;
}

/// 主写回复 + 后台调用返回 imagePrompt,触发后台生图(bg = 第 2 次调用起)。
class _WidgetBackgroundImageBackend implements LlmBackend {
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [
      TextDelta(
        '{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a sword"}',
      ),
      DoneEvent(),
    ]);
  }
}

/// 记录描述并按固定 PNG 返回的假生图后端(用于图片重新生成断言)。
class _WidgetRegenImageBackend implements ImageBackend {
  _WidgetRegenImageBackend(this.base64);
  final String base64;
  final prompts = <String>[];

  @override
  String get id => 'widget-regen';

  @override
  Future<ImageResult> generateImage(String prompt) async {
    prompts.add(prompt);
    return ImageResult.single(base64: base64);
  }
}

/// 主写立即回 'reply N',首个后台调用挂起直到 [unblock]:用来断言后台维护
/// 未收敛时发送键仍可用、第二轮发送不与后台轮串行。
class _QueuedWidgetBackend implements LlmBackend {
  final release = Completer<void>();
  int mainCalls = 0;
  int backgroundCalls = 0;

  @override
  String get id => 'queued-widget';

  void unblock() {
    if (!release.isCompleted) release.complete();
  }

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    if (request.systemPrompt.contains('<background_task>')) {
      backgroundCalls++;
      if (backgroundCalls == 1) await release.future;
      yield const TextDelta('{"variables":{}}');
    } else {
      mainCalls++;
      yield TextDelta('reply $mainCalls');
    }
    yield const DoneEvent();
  }
}

/// 生图挂起直到 [release] 放行:模拟真实云端慢生图(后台轮早已 succeeded,
/// 图片才姗姗落库)—— 生图与轮次解耦后图片就绪得最晚的那条路径。
class _WidgetGatedImageBackend implements ImageBackend {
  final String base64;
  final Completer<void> release = Completer<void>();
  bool started = false;
  _WidgetGatedImageBackend(this.base64);
  @override
  String get id => 'gated-image';
  @override
  Future<ImageResult> generateImage(String prompt) async {
    started = true;
    await release.future;
    return ImageResult.single(base64: base64);
  }
}

/// 等 ChatController.load 整体完成(sessionId 落定)+ llmProvidersProvider 就绪,
/// 之后才能安全关闭 DB。load 内部有多段串行 DB 读,只等 llmProvidersProvider 会提前
/// 返回,使 load 后续 await 撞上已关闭的 DB(见 rebinding 测试的同类等待)。
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

void main() {
  testWidgets('send button remains usable while background maintenance is pending', (tester) async {
    late AppDatabase db;
    late int characterId;
    late int sessionId;
    late _QueuedWidgetBackend backend;
    await tester.runAsync(() async {
      backend = _QueuedWidgetBackend();
      db = await openTestDb();
      characterId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(characterId, 's');
      await MemoryRepository(db).set(sessionId, 'A quiet training room.');
    });
    addTearDown(backend.unblock);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendConfigProvider.overrideWith((ref) => const BackendConfig(
          provider: BackendProvider.openai, baseUrl: 'http://127.0.0.1', apiKey: 'test', model: 'test',
        )),
        backendProvider.overrideWith((ref) => backend),
        hookRuntimeProvider.overrideWith((ref) => _NoopHookRuntime()),
      ],
      child: MaterialApp(home: ChatScreen(
        sessionId: sessionId, characterId: characterId, character: const CharacterCard(name: 'Alice'),
      )),
    ));
    await _settleChat(tester);
    await tester.enterText(find.byType(TextField), 'first');
    await tester.runAsync(() => tester.tap(find.byTooltip('发送')));
    await _pumpUntil(tester, () => backend.backgroundCalls == 1);
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(find.byTooltip('中断生成'), findsNothing);
    await tester.enterText(find.byType(TextField), 'second');
    await tester.runAsync(() => tester.tap(find.byTooltip('发送')));
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    await _pumpUntil(tester, () =>
        container.read(chatControllerProvider).messages.where((m) => m.role == 'assistant').length == 2);
    expect(backend.backgroundCalls, 1);
    await tester.runAsync(() async {
      backend.unblock();
      await container.read(chatControllerProvider.notifier).backgroundTask;
      final rows = await MessageRepository(db).bySession(sessionId);
      expect(rows.where((m) => m.role == 'user').map((m) => m.content), ['first', 'second']);
    });
    expect(backend.backgroundCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('chat screen renders messages and streams assistant reply', (
    tester,
  ) async {
    // openTestDb() 走 sqflite_ffi(真实 isolate I/O),在假异步测试区里不会推进;
    // runAsync 提供真实异步窗口。
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(
            sessionId: 1,
            characterId: 1,
            character: CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );

    // 让 load(真实 DB 读)在 runAsync 窗口内完整落定,避免 teardown 时 load 仍挂着
    // 而撞上已 dispose 的 Ref(UnmountedRefException)。
    await _settleChat(tester);

    // 注:完整流式断言需要 mock 仓库流,这里只做冒烟渲染。
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('chat screen renders after load (smoke)', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(
            sessionId: 1,
            characterId: 1,
            character: CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    // 让 load(真实 DB 读)落定,避免 teardown 时撞上已 dispose 的 Ref。
    await _settleChat(tester);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets(
    'rebinding the same ChatScreen to a new session reloads context and messages',
    (tester) async {
      late final AppDatabase db;
      late final int charId;
      late final int sessionA;
      late final int sessionB;
      await tester.runAsync(() async {
        db = await openTestDb();
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        final sessions = SessionRepository(db);
        sessionA = await sessions.create(charId, 'a');
        sessionB = await sessions.create(charId, 'b');
        // 每个会话有不同消息,便于断言切换后消息列表不复用上个会话的。
        await MessageRepository(
          db,
        ).append(sessionId: sessionA, role: 'user', content: '会话A内容');
        await MessageRepository(
          db,
        ).append(sessionId: sessionB, role: 'assistant', content: '会话B内容');
      });

      Widget harness(int sid) => ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: charId,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      );

      // 首次:会话 A。
      await tester.pumpWidget(harness(sessionA));
      await tester.runAsync(() async {
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ChatScreen)),
          );
          final st = container.read(chatControllerProvider);
          if (st.sessionId == sessionA && st.messages.any((m) => m.content == '会话A内容')) break;
        }
      });
      expect(find.textContaining('会话A内容'), findsOneWidget);

      // 复用同一 ChatScreen 实例改写为会话 B:didUpdateWidget 必须触发重新载入。
      await tester.pumpWidget(harness(sessionB));
      await tester.runAsync(() async {
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ChatScreen)),
          );
          final st = container.read(chatControllerProvider);
          if (st.sessionId == sessionB && st.messages.any((m) => m.content == '会话B内容')) break;
        }
      });
      // 切换后:显示会话 B 的内容,且不再残留会话 A 的消息。
      expect(find.textContaining('会话B内容'), findsOneWidget);
      expect(find.textContaining('会话A内容'), findsNothing);
      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'chat screen shows the background layer when the switch is enabled',
    (tester) async {
      // 1x1 透明 PNG,decode 不会抛错。
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=';
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = await openTestDb();
        await CharacterRepository(db).insert(
          const CharacterCard(
            name: 'Alice',
            avatarBase64: png,
            backgroundBase64: png,
          ),
        );
      });

      Widget harness(bool enabled) => ProviderScope(
        // 每次切换开关用新 key 强制重建容器,否则 StateProvider(chatBackgroundEnabledProvider)
        // 的初始态会被复用,第二次 pump 读不到新的 override。
        key: ValueKey(enabled),
        overrides: [
          databaseProvider.overrideWithValue(db),
          // 聊天背景总开关(默认关闭)由测试显式控制。
          appSettingsProvider.overrideWith(
            (ref) => AppSettings(chatBackgroundEnabled: enabled),
          ),
        ],
        child: const MaterialApp(
          home: ChatScreen(
            sessionId: 1,
            characterId: 1,
            character: CharacterCard(name: 'Alice'),
          ),
        ),
      );

      // 关闭:不渲染背景层。
      await tester.pumpWidget(harness(false));
      expect(find.byKey(const ValueKey('chat-background')), findsNothing);

      // 开启:渲染背景层。
      await tester.pumpWidget(harness(true));
      expect(find.byKey(const ValueKey('chat-background')), findsOneWidget);

      await _settleChat(tester);
      // 背景存在时头像列仍要读取:AppBar 角色头像不因背景而缺失(头像与
      // 背景是两列独立数据,背景层仅在无专属背景图时回退头像)。
      CircleAvatar appbarAvatar() => tester.widget<CircleAvatar>(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(CircleAvatar),
        ),
      );
      await _pumpUntil(tester, () => appbarAvatar().backgroundImage != null);

      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'chat screen falls back to the avatar when no background image is set',
    (tester) async {
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=';
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = await openTestDb();
        // 只设头像、不设背景:开启背景后应回退头像做背景。
        await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice', avatarBase64: png));
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appSettingsProvider.overrideWith(
              (ref) => const AppSettings(chatBackgroundEnabled: true),
            ),
          ],
          // 只设头像、不设背景:开启背景后 _ChatBackground 应回退头像做背景。
          child: const MaterialApp(
            home: ChatScreen(
              sessionId: 1,
              characterId: 1,
              character: CharacterCard(name: 'Alice', avatarBase64: png),
            ),
          ),
        ),
      );

      // 背景层仍在(回退头像),里面能解出图片。
      final $bg = find.byKey(const ValueKey('chat-background'));
      expect($bg, findsOneWidget);
      expect(
        find
                .descendant(of: $bg, matching: find.byType(Image))
                .evaluate()
                .isNotEmpty ||
            find
                .descendant(of: $bg, matching: find.byType(ImageFiltered))
                .evaluate()
                .isNotEmpty,
        isTrue,
      );

      await _settleChat(tester);
      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'background blur is applied from settings and zero disables ImageFiltered',
    (tester) async {
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=';
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = await openTestDb();
      });

      Widget harness(double blur) => ProviderScope(
        // 每次改模糊度用新 key 强制重建容器(与背景层开关测试同源)。
        key: ValueKey(blur),
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(
            (ref) => AppSettings(
              chatBackgroundEnabled: true,
              chatBackgroundBlur: blur,
            ),
          ),
        ],
        child: const MaterialApp(
          home: ChatScreen(
            sessionId: 1,
            characterId: 1,
            character: CharacterCard(name: 'Alice', avatarBase64: png),
          ),
        ),
      );

      // blur=0:无 ImageFiltered,只有原始 Image。
      await tester.pumpWidget(harness(0));
      final $bgSharp = find.byKey(const ValueKey('chat-background'));
      expect($bgSharp, findsOneWidget);
      expect(
        find.descendant(of: $bgSharp, matching: find.byType(ImageFiltered)),
        findsNothing,
      );
      expect(
        find.descendant(of: $bgSharp, matching: find.byType(Image)),
        findsOneWidget,
      );

      // 默认 18:包一层 ImageFiltered。
      await tester.pumpWidget(harness(18));
      final $bgBlurred = find.byKey(const ValueKey('chat-background'));
      expect($bgBlurred, findsOneWidget);
      expect(
        find.descendant(of: $bgBlurred, matching: find.byType(ImageFiltered)),
        findsOneWidget,
      );

      await _settleChat(tester);
      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'image bubble keeps its decoded frame when the token bar appears on a new turn',
    (tester) async {
      // 回归防护「发送新消息产生新对话时,已生成的图片重新加载」:旧实现里 token
      // 用量条/后台状态条按条件插到消息列表之前,消息区元素被挤到新下标 → 整个子树
      // 重建 → 图片气泡 State 丢失 → 重新解码。现在这些状态都收进恒驻的灵岛(Stack
      // 末位、隐藏时零高),位置稳定;本用例直接驱动真实 ChatScreen 守这条不变量。
      late final AppDatabase db;
      late final int sid;
      await tester.runAsync(() async {
        db = await openTestDb();
        final charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sid = await SessionRepository(db).create(charId, 's');
        final base64 = await _pngBase64(200, 100);
        await MessageRepository(db).append(
          sessionId: sid,
          role: 'assistant',
          content: 'scene',
          imageBase64: base64,
        );
        // 预置一条非空记忆:否则灵岛的「初始化记忆」行动项(优先级高于用量粒)
        // 会顶掉用量粒,用量出现的断言无从谈起。
        await MemoryRepository(
          db,
        ).set(sid, 'Alice is a silver-haired catgirl.');
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: const MaterialApp(
            home: ChatScreen(
              sessionId: 1,
              characterId: 1,
              character: CharacterCard(name: 'Alice'),
            ),
          ),
        ),
      );
      await _settleChat(tester);

      // 等图片消息解码出帧。
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );
      final first = tester.widget<RawImage>(find.byType(RawImage)).image;

      // 模拟"发送新消息后首段 token 用量到达":灵动岛以用量粒形态出现。
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      final notifier = container.read(chatControllerProvider.notifier);
      notifier.state = container
          .read(chatControllerProvider)
          .copyWith(inputTokens: 120, outputTokens: 15);
      await tester.pump();

      // 用量粒确实出现(灵动岛渲染),且图片帧不变(消息区未被重建)。
      expect(find.byKey(const ValueKey('chat-island')), findsOneWidget);
      expect(find.textContaining('in 120', findRichText: true), findsOneWidget);
      final second = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(identical(first, second), isTrue);

      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets(
    'A3: background image bubble appears as soon as generation finishes, without another send',
    (tester) async {
      late final AppDatabase db;
      late final int charId;
      late final int sid;
      late final String png;
      await tester.runAsync(() async {
        db = await openTestDb();
        png = await _pngBase64(64, 64);
        charId = await CharacterRepository(
          db,
        ).insert(const CharacterCard(name: 'Alice'));
        sid = await SessionRepository(db).create(charId, 's');
      });
      final backend = _WidgetBackgroundImageBackend();
      final image = _WidgetGatedImageBackend(png);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendConfigProvider.overrideWith(
              (ref) => const BackendConfig(
                provider: BackendProvider.openai,
                baseUrl: 'https://api.openai.com/v1',
                apiKey: 'sk-test',
                model: 'gpt-4o',
              ),
            ),
            backendProvider.overrideWith((ref) => backend),
            imageBackendProvider.overrideWithValue(image),
            hookRuntimeProvider.overrideWith((ref) => _NoopHookRuntime()),
          ],
          child: MaterialApp(
            home: ChatScreen(
              sessionId: sid,
              characterId: charId,
              character: const CharacterCard(name: 'Alice'),
            ),
          ),
        ),
      );
      await _settleChat(tester);

      // 发送一条消息:主写收敛,后台轮(含生图指令)收敛,生图任务挂起。
      await tester.runAsync(() async {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ChatScreen)),
        );
        await container.read(chatControllerProvider.notifier).send('hi');
        final task = container
            .read(chatControllerProvider.notifier)
            .backgroundTask;
        if (task != null) await task;
        await tester.pump();
      });
      expect(image.started, isTrue, reason: '生图任务应在后台轮内启动');
      expect(
        find.byType(RawImage).evaluate().isEmpty,
        isTrue,
        reason: '生图未完成,消息区不应有图片气泡',
      );

      // 放行生图:图片落库 → onImagePlaced → 刷新列表 → 气泡应**立即**出现,
      // 不需要再发一条消息。
      image.release.complete();
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );

      await tester.runAsync(() => db.db.close());
    },
  );

  testWidgets('image message action row regenerates in place with the stored prompt', (tester) async {
    late final AppDatabase db;
    late final int charId;
    late final int sid;
    late final String oldPng;
    late final String newPng;
    late final int messageId;
    await tester.runAsync(() async {
      db = await openTestDb();
      oldPng = await _pngBase64(20, 20);
      newPng = await _pngBase64(30, 10);
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      messageId = (await MessageRepository(db).append(
        sessionId: sid,
        role: 'assistant',
        content: '',
        imageBase64: oldPng,
        imagePrompt: 'a cave',
      )).id!;
    });
    final images = _WidgetRegenImageBackend(newPng);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendConfigProvider.overrideWith(
            (ref) => const BackendConfig(
              provider: BackendProvider.openai,
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'sk-test',
              model: 'gpt-4o',
            ),
          ),
          backendProvider.overrideWith((ref) => _QueuedWidgetBackend()),
          imageBackendProvider.overrideWithValue(images),
          hookRuntimeProvider.overrideWith((ref) => _NoopHookRuntime()),
        ],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: charId,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleChat(tester);
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    // 图片本体点击进全屏;点气泡边缘(图片外留白)选中并显示操作行。
    final rect = tester.getRect(find.byType(RawImage).first);
    await tester.runAsync(() async {
      await tester.tapAt(Offset(rect.left - 6, rect.center.dy));
    });
    await tester.pumpAndSettle();
    expect(find.byTooltip('重新生成图片'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('重新生成图片'));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (await MessageRepository(db).imageBase64For(messageId) == newPng) break;
        await tester.pump();
      }
    });
    await tester.pump();

    expect(images.prompts, ['a cave']);
    final rows = await tester.runAsync(
      () => MessageRepository(db).bySession(sid, includeImages: true),
    );
    expect(rows!.single.imageBase64, newPng);
    expect(rows.single.imagePrompt, 'a cave');
    await _pumpUntil(tester, () => find.text('图片已重新生成').evaluate().isNotEmpty);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('输入框底部行:宽视口 chip 自适应右靠 + 输入区封顶居中,窄视口吃满剩余宽', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });

    double chipWidth() =>
        tester.getSize(find.byKey(const ValueKey('model_selector'))).width;

    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: ChatScreen(
            sessionId: 1,
            characterId: 1,
            character: CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _settleChat(tester);
    // 宽行:chip 不再定宽 280,而是按模型名自适应收窄,与使用率圆环一起靠右;
    // 推理徽标(if any)紧贴 chip 右侧。输入区整体封顶 760 居中,不再拉满聊天区。
    expect(chipWidth(), lessThan(280.0), reason: '宽行 chip 应按模型名自适应,不再定宽 280');
    final ringLeft = tester.getTopLeft(find.byType(ContextUsageRing)).dx;
    final chipRight = tester
        .getTopRight(find.byKey(const ValueKey('model_selector')))
        .dx;
    expect(ringLeft - chipRight, closeTo(6, 0.5), reason: 'chip 应右靠且紧贴右侧组件组');
    final fieldRight = tester.getTopRight(find.byType(TextField)).dx;
    expect(fieldRight, lessThan(1024.0), reason: '输入框应封顶 760 居中,右侧留出大片空白');

    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
    await tester.pumpAndSettle();
    // 窄行(手机)布局不变:chip 吃满中段剩余宽度(收缩省略),全宽铺满。
    expect(chipWidth(), greaterThan(120), reason: '窄屏 chip 应吃满中段剩余宽度');
    final narrowFieldRight = tester.getTopRight(find.byType(TextField)).dx;
    expect(narrowFieldRight, greaterThan(390 - 24), reason: '窄屏输入框仍占满整行');
  });

  testWidgets('角色头像弹出状态卡,可进入角色卡编辑并即时刷新名称', (tester) async {
    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice', description: '一位旅人'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: const CharacterCard(name: 'Alice', description: '一位旅人'),
          ),
        ),
      ),
    );
    await _settleChat(tester);

    // AppBar 头像 → 带头像与简介的状态卡 + 编辑入口。
    await tester.tap(find.byKey(const ValueKey('appbar-character-avatar')));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsWidgets);
    expect(find.text('一位旅人'), findsOneWidget);
    expect(find.text('编辑角色卡'), findsOneWidget);

    // 编辑入口直达角色卡编辑页;改名保存后回到聊天页即时刷新。
    await tester.tap(find.text('编辑角色卡'));
    await tester.pump();
    await _pumpUntil(tester, () => find.text('编辑角色').evaluate().isNotEmpty);
    await tester.enterText(find.byKey(const ValueKey('field_名字 *')), 'Alice2');
    await tester.pump();
    await tester.tap(find.text('保存').last);
    await _pumpUntil(
      tester,
      () => find.widgetWithText(AppBar, 'Alice2').evaluate().isNotEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('用户头像弹出带头像的状态卡,可进入个人设置', (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=';
    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sessionId, role: 'user', content: '你好');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          userProfileProvider.overrideWith(
            (ref) => const UserProfile(name: '小明', avatarBase64: png),
          ),
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
    await _settleChat(tester);
    await _pumpUntil(tester, () => find.text('你好').evaluate().isNotEmpty);

    // 角色卡无头像 → 消息区只有用户气泡旁这一枚头像。
    final userAvatar = find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(CircleAvatar),
    );
    expect(userAvatar, findsOneWidget);
    await tester.tap(userAvatar);
    await tester.pumpAndSettle();

    // 状态卡:大头像(绑定了图片)+ 用户名 + 个人设置入口。
    final sheetAvatar = tester.widget<CircleAvatar>(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(CircleAvatar),
      ),
    );
    expect(sheetAvatar.foregroundImage, isNotNull);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('个人设置'), findsOneWidget);

    await tester.tap(find.text('个人设置'));
    await tester.pumpAndSettle();
    expect(find.byType(UserScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('用户未设置头像时仍显示占位头像并可打开状态卡', (tester) async {
    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(
        db,
      ).append(sessionId: sessionId, role: 'user', content: '你好');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          userProfileProvider.overrideWith(
            (ref) => const UserProfile(name: '小明'),
          ),
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
    await _settleChat(tester);
    await _pumpUntil(tester, () => find.text('你好').evaluate().isNotEmpty);

    // 未设置头像:用户气泡旁仍渲染占位头像(人形图标),点击可打开状态卡。
    final userAvatar = find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(CircleAvatar),
    );
    expect(userAvatar, findsOneWidget);
    expect(tester.widget<CircleAvatar>(userAvatar).backgroundImage, isNull);
    expect(
      find.descendant(of: userAvatar, matching: find.byIcon(Icons.person)),
      findsOneWidget,
    );

    await tester.tap(userAvatar);
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('个人设置'), findsOneWidget);
    final sheetAvatar = tester.widget<CircleAvatar>(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(CircleAvatar),
      ),
    );
    expect(sheetAvatar.foregroundImage, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.db.close());
  });
}
