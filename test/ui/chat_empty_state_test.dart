// 聊天空态:角色引导、开场白候选(主开场白 + 备用开场白,限 3 条),
// 点击后作为助手首条消息落库并直接显示;桌面端无开场白的新会话把输入区
// 抬离底部(内容高 25% 的留白),发出消息后回到底部;移动端始终贴底。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import 'package:microscritt/ui/widgets/chat_composer.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

const _card = CharacterCard(
  name: 'Alice',
  firstMessage: '主开场白:欢迎来到酒馆。',
  alternateGreetings: ['备用开场白一', '备用开场白二', '备用开场白三', '备用开场白四'],
);

const _blankCard = CharacterCard(name: 'Bob');

class _FakeBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield const TextDelta('回复。');
    yield const DoneEvent();
  }
}

Widget _harness({
  required AppDatabase db,
  required int characterId,
  required int sessionId,
  required CharacterCard character,
}) => ProviderScope(
  overrides: [
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
  ],
  child: MaterialApp(
    home: ChatScreen(
      sessionId: sessionId,
      characterId: characterId,
      character: character,
    ),
  ),
);

void main() {
  testWidgets('empty session offers opening lines and inserts the picked one', (
    tester,
  ) async {
    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(_card);
      sessionId = await SessionRepository(db).create(charId, 'new');
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: _card,
          ),
        ),
      ),
    );

    await waitUntilOrFail(
      tester,
      () => find.text('与 Alice 开始对话').evaluate().isNotEmpty,
      reason: '空会话未渲染角色引导',
    );
    // 主开场白 + 前两条备用开场白;第 4 条超出单屏上限不展示。
    expect(find.text('主开场白:欢迎来到酒馆。'), findsOneWidget);
    expect(find.text('备用开场白一'), findsOneWidget);
    expect(find.text('备用开场白二'), findsOneWidget);
    expect(find.text('备用开场白三'), findsNothing);
    expect(find.text('备用开场白四'), findsNothing);
    expect(find.textContaining('发一条消息开始对话'), findsOneWidget);

    await tester.tap(find.text('备用开场白一'));
    await waitUntilOrFail(
      tester,
      () => find.text('与 Alice 开始对话').evaluate().isEmpty,
      reason: '选择开场白后空态未退出',
    );
    // 空态在消息刷新后即退出,但 startWithGreeting 还要重算一次上下文;
    // 不等它落定就关库,后台查询会撞上 database_closed。
    await waitUntilOrFail(tester, () {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      return container
              .read(chatControllerProvider)
              .lastContext
              ?.messages
              .any((m) => m.content == '备用开场白一') ??
          false;
    }, reason: '开场白未完成上下文重算');
    expect(find.textContaining('备用开场白一'), findsOneWidget);
    final rows = await tester.runAsync(
      () => db.db.query(
        'messages',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      ),
    );
    expect(rows, hasLength(1));
    expect(rows!.single['role'], 'assistant');
    expect(rows.single['content'], '备用开场白一');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('超出首屏的开场白仍可经「查看全部」选择', (tester) async {
    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(_card);
      sessionId = await SessionRepository(db).create(charId, 'new');
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: _card,
          ),
        ),
      ),
    );

    await waitUntilOrFail(
      tester,
      () => find.text('与 Alice 开始对话').evaluate().isNotEmpty,
      reason: '空会话未渲染角色引导',
    );
    // 首屏只铺前三条,其余收在「查看全部」底单里。
    expect(find.text('备用开场白三'), findsNothing);
    expect(find.text('查看全部开场白(共 5 条)'), findsOneWidget);
    await tester.tap(find.text('查看全部开场白(共 5 条)'));
    await tester.pumpAndSettle();
    expect(find.text('全部开场白'), findsOneWidget);
    expect(find.text('备用开场白三'), findsOneWidget);
    expect(find.text('备用开场白四'), findsOneWidget);

    await tester.tap(find.text('备用开场白四'));
    await waitUntilOrFail(
      tester,
      () => find.text('与 Alice 开始对话').evaluate().isEmpty,
      reason: '选择第四条开场白后空态未退出',
    );
    await waitUntilOrFail(tester, () {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      return container
              .read(chatControllerProvider)
              .lastContext
              ?.messages
              .any((m) => m.content == '备用开场白四') ??
          false;
    }, reason: '第四条开场白未完成上下文重算');
    final rows = await tester.runAsync(
      () => db.db.query(
        'messages',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      ),
    );
    expect(rows, hasLength(1));
    expect(rows!.single['content'], '备用开场白四');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('桌面端无开场白的新会话:输入区抬高,发出消息后回到底部', (tester) async {
    // widget 测试默认平台是 Android;抬升仅桌面端生效,这里显式切到桌面。
    // 覆盖值须在测试体内复位:framework 的不变量检查先于 addTearDown 执行。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view
      ..physicalSize = const Size(1100, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(_blankCard);
      sessionId = await SessionRepository(db).create(charId, 'new');
    });
    await tester.pumpWidget(
      _harness(
        db: db,
        characterId: charId,
        sessionId: sessionId,
        character: _blankCard,
      ),
    );

    await waitUntilOrFail(
      tester,
      () => find.text('与 Bob 开始对话').evaluate().isNotEmpty,
      reason: '空会话未渲染角色引导',
    );

    // 空会话且角色没有开场白:底部留白(内容高 25%)把输入区抬离底部
    // (常规贴底位置的中心在 800 以上)。
    final lifted = tester.getRect(find.byType(ChatComposer));
    expect(lifted.center.dy, greaterThan(300));
    expect(lifted.center.dy, lessThan(680));
    expect(lifted.bottom, lessThan(750));

    // 发出第一条消息:留白收回,输入区回到底部。
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    for (var i = 0; i < 240; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ChatScreen)),
      );
      if (container.read(chatControllerProvider).messages.isNotEmpty) break;
    }
    // 收起过渡 240ms。
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    final settled = tester.getRect(find.byType(ChatComposer));
    expect(settled.bottom, closeTo(900, 1));
    expect(settled.center.dy, greaterThan(700));

    // 收尾:卸载并让在途 DB future 落定后再关库。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.runAsync(() => db.db.close());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('移动端无开场白的新会话:输入区始终贴底', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(400, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(_blankCard);
      sessionId = await SessionRepository(db).create(charId, 'new');
    });
    await tester.pumpWidget(
      _harness(
        db: db,
        characterId: charId,
        sessionId: sessionId,
        character: _blankCard,
      ),
    );

    await waitUntilOrFail(
      tester,
      () => find.text('与 Bob 开始对话').evaluate().isNotEmpty,
      reason: '空会话未渲染角色引导',
    );

    // 移动端即使无开场白也不抬升:输入区始终贴底,符合移动输入习惯。
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    final composer = tester.getRect(find.byType(ChatComposer));
    expect(composer.bottom, closeTo(900, 1));
    expect(composer.center.dy, greaterThan(700));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.runAsync(() => db.db.close());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('移动端状态栏顶部内边距不会在输入卡上方留空白带', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(400, 900)
      ..devicePixelRatio = 1.0
      // 物理像素,DPR=1 时即逻辑 44:模拟手机状态栏。
      ..padding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(_blankCard);
      sessionId = await SessionRepository(db).create(charId, 'new');
    });
    await tester.pumpWidget(
      _harness(
        db: db,
        characterId: charId,
        sessionId: sessionId,
        character: _blankCard,
      ),
    );

    await waitUntilOrFail(
      tester,
      () => find.text('与 Bob 开始对话').evaluate().isNotEmpty,
      reason: '空会话未渲染角色引导',
    );
    // 先确认环境里确实带着状态栏内边距(否则本用例无意义)。
    expect(
      MediaQuery.of(tester.element(find.byType(ChatComposer))).padding.top,
      44,
    );

    // composer 只需左右/底部安全区:输入框相对 composer 顶部只隔 4px 顶
    // 内边距与输入框自身的内容留白,不再叠加 44 的状态栏高度。
    final composerTop = tester.getTopLeft(find.byType(ChatComposer)).dy;
    final fieldTop = tester.getTopLeft(find.byType(TextField)).dy;
    expect(fieldTop - composerTop, lessThan(44));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.runAsync(() => db.db.close());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('有开场白的空会话:输入区保持贴底', (tester) async {
    tester.view
      ..physicalSize = const Size(1100, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int charId;
    late final int sessionId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(_card);
      sessionId = await SessionRepository(db).create(charId, 'new');
    });
    await tester.pumpWidget(
      _harness(
        db: db,
        characterId: charId,
        sessionId: sessionId,
        character: _card,
      ),
    );

    await waitUntilOrFail(
      tester,
      () => find.text('与 Alice 开始对话').evaluate().isNotEmpty,
      reason: '空会话未渲染角色引导',
    );
    // 空态本身有开场白可点,输入区不抬升:贴底且全高由消息区占据。
    final composer = tester.getRect(find.byType(ChatComposer));
    expect(composer.bottom, closeTo(900, 1));
    expect(composer.center.dy, greaterThan(700));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.runAsync(() => db.db.close());
  });
}
