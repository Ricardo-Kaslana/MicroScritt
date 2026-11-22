// ChatController agentic 接线契约(P3):逐步用量行(无轮级行)、legacy 对照、
// 护栏失败行计次、模式切换次轮生效、/rerun 跟随、运行中步摘要。
// 事件脚本化后端 + 真实 FFI 库,usage_records 走 raw SQL 断言。
import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
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
      if (DateTime.now().isAfter(deadline)) {
        fail(message ?? 'condition not met within 10s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<List<Map<String, Object?>>> bgRows() => db.db.query(
    'usage_records',
    where: "session_id = ? AND kind = 'background'",
    whereArgs: [sessionId],
  );

  /// 逐步行是 unawaited 落库:轮询到齐后再静置片刻,确认没有多余的轮级行。
  Future<List<Map<String, Object?>>> waitRows(int count) async {
    late List<Map<String, Object?>> rows;
    for (var i = 0; i < 200; i++) {
      rows = await bgRows();
      if (rows.length >= count) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return bgRows();
  }

  List<LlmEvent> replyStep() => [const TextDelta('reply.'), const DoneEvent()];

  List<LlmEvent> toolStep(String name, Map<String, Object?> args, {String id = 'c1', TokenUsage? usage}) => [
    ToolCallsEvent([ToolCall(id: id, name: name, arguments: jsonEncode(args))]),
    if (usage != null) UsageEvent(usage),
    const DoneEvent(),
  ];

  List<LlmEvent> proseStep() => [const TextDelta('no tools here'), const DoneEvent()];

  test('agentic mode: one usage row per step, no round-level row', () async {
    final backend = ScriptedLlmBackend([
      replyStep(),
      toolStep('setVariables', {'variables': {'hp': '8'}}, usage: const TokenUsage(inputTokens: 10, outputTokens: 5)),
      toolStep('finish', const {}, id: 'c2', usage: const TokenUsage(inputTokens: 20, outputTokens: 7)),
    ]);
    final container = makeContainer(backend, settings: const AppSettings(backgroundMode: BackgroundMode.agentic));
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);

    final rows = await waitRows(2);
    expect(rows, hasLength(2)); // 恰两步行,无轮级行
    expect(rows[0]['input_tokens'], 10);
    expect(rows[0]['output_tokens'], 5);
    expect(rows[0]['reported'], 1);
    expect(rows[1]['input_tokens'], 20);
    expect(rows[1]['reported'], 1);

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
    expect(state.backgroundInputTokens, 30); // 桶 = 步求和(轮末 semantics 不变)
    expect(state.backgroundOutputTokens, 12);
    expect(state.backgroundSummary, contains('hp'));
    expect(state.backgroundVariableStats?.added, 1); // 新键
    expect(state.backgroundVariableStats?.updated, 0);
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '8'});
  });

  test('legacy mode keeps exactly one round-level row (contrast)', () async {
    final backend = ScriptedLlmBackend([
      replyStep(),
      [
        const TextDelta('{"variables":{}}'),
        const UsageEvent(TokenUsage(inputTokens: 120, outputTokens: 15, cachedInputTokens: 80)),
        const DoneEvent(),
      ],
    ]);
    final container = makeContainer(backend); // 默认 legacy
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);

    final rows = await waitRows(1);
    expect(rows, hasLength(1));
    expect(rows.single['input_tokens'], 120);
    expect(rows.single['reported'], 1);
    expect(container.read(chatControllerProvider).backgroundInputTokens, 120);
  });

  test('agentic guardrail failure: failed steps counted reported=0, no extra zero row', () async {
    final backend = ScriptedLlmBackend([
      replyStep(),
      toolStep('setVariables', {'variables': {'hp': '8'}}, usage: const TokenUsage(inputTokens: 10, outputTokens: 5)),
      proseStep(),
      proseStep(),
      proseStep(),
    ]);
    final container = makeContainer(backend, settings: const AppSettings(backgroundMode: BackgroundMode.agentic));
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);

    final rows = await waitRows(4);
    expect(rows, hasLength(4)); // 1 成功步 + 3 非法步,无额外零行
    expect(rows[0]['reported'], 1);
    expect(rows.sublist(1).every((r) => r['reported'] == 0), isTrue);

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.failed);
    expect(state.backgroundSummary, contains('工具调用')); // 诊断透出
    // 暂存原子性:护栏失败不落库。
    expect(await VariableRepository(db).bySession(sessionId), isEmpty);
  });

  test('mode switch takes effect on the next round', () async {
    final backend = ScriptedLlmBackend([
      replyStep(),
      toolStep('setVariables', {'variables': {'hp': '8'}}),
      toolStep('finish', const {}, id: 'c2'),
      replyStep(),
      [const TextDelta('{"variables":{"mp":"3"}}'), const DoneEvent()],
    ]);
    final container = makeContainer(backend, settings: const AppSettings(backgroundMode: BackgroundMode.agentic));
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);
    expect(await waitRows(2), hasLength(2));

    // 切回 legacy:次轮走单发,写一条轮级行。
    container.read(appSettingsProvider.notifier).state = const AppSettings();
    await controller.send('again');
    await awaitBackground(container);
    final rows = await waitRows(3);
    expect(rows, hasLength(3)); // 2 步行 + 1 轮级行
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '8', 'mp': '3'});
  });

  test('/rerun follows agentic mode with per-step rows', () async {
    final backend = ScriptedLlmBackend([
      replyStep(),
      toolStep('setVariables', {'variables': {'hp': '8'}}),
      toolStep('finish', const {}, id: 'c2'),
      toolStep('setVariables', {'variables': {'hp': '9'}}, id: 'c3'),
      toolStep('finish', const {}, id: 'c4'),
    ]);
    final container = makeContainer(backend, settings: const AppSettings(backgroundMode: BackgroundMode.agentic));
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);
    expect(await waitRows(2), hasLength(2));

    controller.rerunBackgroundMaintenance();
    await waitFor(() => container.read(chatControllerProvider).backgroundSummary.contains('重跑完成'));
    final rows = await waitRows(4);
    expect(rows, hasLength(4)); // 重跑同样逐步入账,无轮级行
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '9'});
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('running step summary shows progress before the round settles', () async {
    final step2Started = Completer<void>();
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        replyStep(),
        toolStep('setVariables', {'variables': {'hp': '8'}}),
        toolStep('finish', const {}, id: 'c2'),
      ],
      gates: {2: gate},
      onRequest: (i) {
        if (i == 2 && !step2Started.isCompleted) step2Started.complete();
      },
    );
    final container = makeContainer(backend, settings: const AppSettings(backgroundMode: BackgroundMode.agentic));
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    // 第二步请求发起时,第一步事件已更新摘要。
    await step2Started.future;
    final running = container.read(chatControllerProvider);
    expect(running.backgroundStatus, BackgroundStatus.running);
    expect(running.backgroundSummary, contains('步 1'));
    expect(running.backgroundSummary, contains('setVariables'));
    gate.complete();
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('agentic suggestions publish after the round and dismiss drops the batch', () async {
    final backend = ScriptedLlmBackend([
      replyStep(),
      toolStep('setNextSuggestions', {
        'suggestions': ['我环顾四周,寻找声音的来源。', '我后退半步,压低呼吸。'],
      }),
      toolStep('finish', const {}, id: 'c2'),
    ]);
    final container = makeContainer(
      backend,
      settings: const AppSettings(
        backgroundMode: BackgroundMode.agentic,
        backgroundNextSuggestions: true,
      ),
    );
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);

    final state = container.read(chatControllerProvider);
    expect(state.nextSuggestions, [
      '我环顾四周,寻找声音的来源。',
      '我后退半步,压低呼吸。',
    ]);
    expect(state.backgroundSummary, isNot(contains('建议')));

    controller.dismissNextSuggestions();
    expect(container.read(chatControllerProvider).nextSuggestions, isEmpty);
  });

  test('memory proposal surfaces for review; accept writes the library only', () async {
    final memory = MemoryRepository(db);
    await memory.set(sessionId, 'old fact');
    final backend = ScriptedLlmBackend([
      replyStep(),
      toolStep('proposeMemory', {'content': 'new fact'}),
      toolStep('finish', const {}, id: 'c2'),
    ]);
    final container = makeContainer(
      backend,
      settings: const AppSettings(backgroundMode: BackgroundMode.agentic),
    );
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);

    var state = container.read(chatControllerProvider);
    expect(state.memoryProposal, 'new fact');
    expect((await memory.bySession(sessionId)).single.content, 'old fact');
    expect(state.frozenMemory, 'old fact');

    await controller.acceptMemoryProposal();
    state = container.read(chatControllerProvider);
    expect(state.memoryProposal, isNull);
    expect((await memory.bySession(sessionId)).single.content, 'new fact');
    // 记忆库已更新,但上下文第 0 条仍冻结旧版,等待显式「应用到上下文」。
    expect(state.frozenMemory, 'old fact');
  });

  test('pending variable injection is written as an attachment before the next user message', () async {
    final backend = ScriptedLlmBackend([
      replyStep(),
      toolStep('setVariables', {'variables': {'hp': '8'}}),
      toolStep('setVariableInjection', {'keys': ['hp']}),
      toolStep('finish', const {}, id: 'c2'),
      replyStep(),
      toolStep('finish', const {}, id: 'c3'),
    ]);
    final container = makeContainer(
      backend,
      settings: const AppSettings(
        backgroundMode: BackgroundMode.agentic,
        backgroundVariableInjection: true,
      ),
    );
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundSummary, contains('注入变量 hp'));

    await controller.send('again');
    await awaitBackground(container);

    final rows = await MessageRepository(db).bySession(sessionId);
    final injectionIndex = rows.indexWhere(
      (m) => (m.refId ?? '').startsWith('notice:varinj:'),
    );
    expect(injectionIndex, greaterThanOrEqualTo(0));
    final injection = rows[injectionIndex];
    expect(injection.content, contains('- hp: 8'));
    expect(injection.content, contains('<system-reminder>'));
    final nextUserIndex = rows.indexWhere(
      (m) => m.role == 'user' && m.content == 'again',
    );
    expect(nextUserIndex, injectionIndex + 1);
  });
}