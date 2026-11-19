// ChatController hybrid 周期审计接线契约(P4):N=5 计数触发 + 计数器重置、
// 让位 delta 优先(审计取消/暂存丢弃/计数器不重置/稍后重试)、审计失败/冲突重置、
// legacy/agentic 不审计、切会话清零、rerun 不计数、interrupt 取消不重置。
// 事件脚本化后端 + 真实 FFI 库;hybrid 维护走 legacy 单发(每轮一条轮级行),
// 审计走 agent 逐步行(无轮级行)。usage_records 走 raw SQL 断言。
import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/engine/background_status.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import '../support/scripted_llm_backend.dart';
import '../support/test_database.dart';

class _NoopRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => null;
}

void main() {
  late AppDatabase db;
  late int sessionId;

  setUp(() async {
    db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    sessionId = await SessionRepository(db).create(charId, 's1');
  });

  ProviderContainer makeContainer(LlmBackend backend, {AppSettings settings = const AppSettings()}) =>
      ProviderContainer(
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
          hookRuntimeProvider.overrideWith((ref) => _NoopRuntime()),
          appSettingsProvider.overrideWith((ref) => settings),
        ],
      );

  Future<void> awaitBackground(ProviderContainer container) async {
    final task = container.read(chatControllerProvider.notifier).backgroundTask;
    if (task != null) await task;
  }

  Future<void> waitFor(bool Function() condition, {String? message}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail(message ?? 'condition not met within 10s');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<List<Map<String, Object?>>> bgRows() => db.db.query(
    'usage_records',
    where: "session_id = ? AND kind = 'background'",
    whereArgs: [sessionId],
  );

  Future<List<Map<String, Object?>>> waitRows(int count) async {
    for (var i = 0; i < 300; i++) {
      if ((await bgRows()).length >= count) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return bgRows();
  }

  List<LlmEvent> replyStep() => [const TextDelta('reply.'), const DoneEvent()];
  List<LlmEvent> jsonRound(String key, String value) => [
    TextDelta('{"variables":{"$key":"$value"}}'),
    const UsageEvent(TokenUsage(inputTokens: 1, outputTokens: 1)),
    const DoneEvent(),
  ];
  List<LlmEvent> toolStep(String name, Map<String, Object?> args, {String id = 'c1', TokenUsage? usage}) => [
    ToolCallsEvent([ToolCall(id: id, name: name, arguments: jsonEncode(args))]),
    if (usage != null) UsageEvent(usage),
    const DoneEvent(),
  ];
  List<LlmEvent> proseStep() => [const TextDelta('no tools here'), const DoneEvent()];

  const hybrid = AppSettings(backgroundMode: BackgroundMode.hybrid);

  /// 驱动 n 次发送,每次等后台维护收敛(hybrid 维护 = legacy 单发)。
  Future<void> sendRounds(ProviderContainer container, ChatController controller, int n, {String prefix = 'hi'}) async {
    for (var i = 0; i < n; i++) {
      await controller.send('$prefix $i');
      await awaitBackground(container);
    }
  }

  test('hybrid: 5 successful variable rounds trigger an audit, then counter resets', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 5; i++) ...[replyStep(), jsonRound('hp', '$i')],
      // 第 5 轮维护收敛后触发审计:两逻辑步。
      toolStep('setVariables', {'variables': {'hp': 'audited'}}, usage: const TokenUsage(inputTokens: 10, outputTokens: 5)),
      toolStep('finish', const {}, id: 'c2', usage: const TokenUsage(inputTokens: 20, outputTokens: 7)),
      // 第 6 轮:计数器已重置,只维护不审计。
      replyStep(), jsonRound('hp', '6'),
    ]);
    final container = makeContainer(backend, settings: hybrid);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await sendRounds(container, controller, 5);
    await waitFor(() => container.read(chatControllerProvider).backgroundSummary.contains('审计完成'));
    await awaitBackground(container);

    final rows = await waitRows(7);
    expect(rows, hasLength(7)); // 5 维护轮级行 + 2 审计步行,无审计轮级行
    expect(rows[5]['input_tokens'], 10);
    expect(rows[6]['input_tokens'], 20);
    expect(rows[5]['reported'], 1);
    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
    expect(state.backgroundSummary, contains('审计完成'));
    expect(state.backgroundSummary, contains('更新 1 键'));
    expect(state.backgroundInputTokens, 31); // 维护桶 1 + 审计 30(累加)
    expect(await VariableRepository(db).bySession(sessionId), {'hp': 'audited'});

    // 计数器重置:第 6 轮只维护,不再审计。
    await controller.send('hi 6');
    await awaitBackground(container);
    expect(await waitRows(8), hasLength(8));
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('审计')));
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '6'});
  });

  test('yield: new input during audit cancels it, delta runs first, counter kept (retry later)', () async {
    final gateA = Completer<void>(); // 审计1 finish
    final gateB = Completer<void>(); // 审计2 finish(让位后稍后重试)
    final audit1AtFinish = Completer<void>();
    final audit2AtFinish = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        for (var i = 0; i < 5; i++) ...[replyStep(), jsonRound('hp', '$i')],
        toolStep('setVariables', {'variables': {'hp': 'audited'}}), // call10 审计1
        toolStep('finish', const {}, id: 'c2'), // call11 gated
        replyStep(), // call12 第6次发送主写
        jsonRound('hp', '6'), // call13 让位后 delta 维护
        toolStep('setVariables', {'variables': {'hp': 'audited2'}}, id: 'c3'), // call14 审计2
        toolStep('finish', const {}, id: 'c4'), // call15 gated
      ],
      gates: {11: gateA, 15: gateB},
      onRequest: (i) {
        if (i == 11 && !audit1AtFinish.isCompleted) audit1AtFinish.complete();
        if (i == 15 && !audit2AtFinish.isCompleted) audit2AtFinish.complete();
      },
    );
    final container = makeContainer(backend, settings: hybrid);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await sendRounds(container, controller, 5);
    await audit1AtFinish.future; // 审计1 在飞,暂存 audited 未提交
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '4'});

    // 新对话到达 → 让位:取消审计1,先跑 delta。
    await controller.send('interrupting');
    gateA.complete();
    await audit2AtFinish.future; // 维护6 已提交、审计2 已发起(证明计数器未重置)

    // delta 优先:审计1 暂存丢弃,maintenance6 落库 hp=6;审计2 尚未提交。
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '6'});
    final running = container.read(chatControllerProvider);
    expect(running.backgroundStatus, BackgroundStatus.running);
    expect(running.backgroundSummary, contains('审计')); // 审计2 在飞 = 稍后重试

    controller.interrupt(); // 收尾:取消审计2
    gateB.complete();
    await awaitBackground(container);
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '6'});
  });

  test('audit guardrail failure resets counter; delta maintenance unaffected', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 5; i++) ...[replyStep(), jsonRound('hp', '$i')],
      toolStep('setVariables', {'variables': {'hp': 'audited'}}),
      proseStep(), proseStep(), proseStep(), // 护栏失败
      replyStep(), jsonRound('hp', '6'), // 第6轮:计数器已重置,只维护
    ]);
    final container = makeContainer(backend, settings: hybrid);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await sendRounds(container, controller, 5);
    await waitFor(() => container.read(chatControllerProvider).backgroundStatus == BackgroundStatus.failed);
    await awaitBackground(container);
    final state = container.read(chatControllerProvider);
    expect(state.backgroundSummary, contains('审计失败'));
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '4'}); // 暂存丢弃

    await controller.send('hi 6');
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('审计')));
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '6'});
    expect(await waitRows(10), hasLength(10)); // 5 维护 + 4 审计步 + 1 维护
  });

  test('audit revision conflict resets counter and reports skipped', () async {
    final gate = Completer<void>();
    final auditAtFinish = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        for (var i = 0; i < 5; i++) ...[replyStep(), jsonRound('hp', '$i')],
        toolStep('setVariables', {'variables': {'hp': 'audited'}}),
        toolStep('finish', const {}, id: 'c2'),
      ],
      gates: {11: gate},
      onRequest: (i) { if (i == 11 && !auditAtFinish.isCompleted) auditAtFinish.complete(); },
    );
    final container = makeContainer(backend, settings: hybrid);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await sendRounds(container, controller, 5);
    await auditAtFinish.future;
    await VariableRepository(db).upsert(sessionId, 'hp', 'human'); // 循环期间人工改
    gate.complete();
    await waitFor(() => container.read(chatControllerProvider).backgroundStatus == BackgroundStatus.skipped);
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundSummary, contains('变量板已被修改'));
    expect(await VariableRepository(db).bySession(sessionId), {'hp': 'human'});
  });

  test('legacy mode never audits (5 rounds, 5 round-level rows)', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 5; i++) ...[replyStep(), jsonRound('hp', '$i')],
    ]);
    final container = makeContainer(backend); // 默认 legacy
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await sendRounds(container, controller, 5);
    expect(await waitRows(5), hasLength(5));
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('审计')));
  });

  test('agentic mode never audits (per-round steps only, no extra audit)', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 5; i++) ...[
        replyStep(),
        toolStep('setVariables', {'variables': {'hp': '$i'}}),
        toolStep('finish', const {}, id: 'c$i'),
      ],
    ]);
    final container = makeContainer(backend, settings: const AppSettings(backgroundMode: BackgroundMode.agentic));
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await sendRounds(container, controller, 5);
    expect(await waitRows(10), hasLength(10)); // 5 轮 × 2 步,无审计
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('审计')));
  });

  test('session switch clears the counter (new session needs a full 5 rounds)', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 4; i++) ...[replyStep(), jsonRound('hp', '$i')], // 会话A 计到4
      replyStep(), jsonRound('hp', 'b0'), // 会话B 第1轮
    ]);
    final container = makeContainer(backend, settings: hybrid);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await sendRounds(container, controller, 4);
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('审计')));

    final charId2 = await CharacterRepository(db).insert(const CharacterCard(name: 'Bob'));
    final sid2 = await SessionRepository(db).create(charId2, 's2');
    await controller.load(sessionId: sid2, character: const CharacterCard(name: 'Bob'));
    await controller.send('b0');
    await awaitBackground(container);
    // 若计数器未清零(4+1=5)此刻会触发审计;清零后仅计到1,不审计。
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('审计')));
    expect(await bgRows(), hasLength(4)); // 会话A 的4行,B 的行属 sid2 不计入
  });

  test('rerun does not count toward the audit interval', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 4; i++) ...[replyStep(), jsonRound('hp', '$i')], // 计到4
      jsonRound('hp', 'rerun'), // rerun 重放(hybrid→legacy 单发)
    ]);
    final container = makeContainer(backend, settings: hybrid);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await sendRounds(container, controller, 4);

    expect(controller.rerunBackgroundMaintenance(), isNull); // 已启动
    await waitFor(() => container.read(chatControllerProvider).backgroundSummary.contains('重跑完成'));
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('审计')));
    expect(await VariableRepository(db).bySession(sessionId), {'hp': 'rerun'});
    expect(await waitRows(5), hasLength(5)); // 4 维护 + 1 rerun,无审计
  });

  test('interrupt during audit cancels it without resetting counter or restarting delta', () async {
    final gate = Completer<void>();
    final auditAtFinish = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        for (var i = 0; i < 5; i++) ...[replyStep(), jsonRound('hp', '$i')],
        toolStep('setVariables', {'variables': {'hp': 'audited'}}),
        toolStep('finish', const {}, id: 'c2'),
      ],
      gates: {11: gate},
      onRequest: (i) { if (i == 11 && !auditAtFinish.isCompleted) auditAtFinish.complete(); },
    );
    final container = makeContainer(backend, settings: hybrid);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await sendRounds(container, controller, 5);
    await auditAtFinish.future;

    controller.interrupt();
    gate.complete();
    await waitFor(() => container.read(chatControllerProvider).backgroundStatus == BackgroundStatus.interrupted);
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundSummary, contains('审计已中断'));
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '4'}); // 暂存丢弃
    // interrupt 清 pending:finally 不补跑 delta(无第6轮维护行)。
    // 5 维护轮级行 + 2 审计步行(setVariables 无脚本用量 reported=0、被取消的
    // finish 步 reported=0);取消步仍计次,不另写零行。
    final rows = await waitRows(7);
    expect(rows, hasLength(7));
    expect(rows.sublist(5).every((r) => r['reported'] == 0), isTrue);
  });
}