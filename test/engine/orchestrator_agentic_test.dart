// 编排器 agentic 路径测试(真实 sqflite FFI 仓库):端到端原子提交、暂存
// 原子性(失败零写)、revision 冲突、严格提案、readHistory clamp、生图任务、
// rerun 替换、无 image-only 补调、逐步用量事件、hybrid/默认走 legacy。
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/upstream_error.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_guide_repository.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/engine/agent/agent_events.dart';
import 'package:microscritt/engine/background_engine.dart';
import 'package:microscritt/engine/orchestrator.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/image_result.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/models/variable.dart';
import '../support/scripted_llm_backend.dart';
import '../support/test_database.dart';

class _RecordingImageBackend extends FakeImageBackend {
  final prompts = <String>[];
  _RecordingImageBackend() : super('aGVsbG8=');

  @override
  Future<ImageResult> generateImage(String prompt) {
    prompts.add(prompt);
    return super.generateImage(prompt);
  }
}

void main() {
  const usage1 = TokenUsage(inputTokens: 10, outputTokens: 5);
  const usage2 = TokenUsage(inputTokens: 20, outputTokens: 7);

  List<LlmEvent> toolStep(String name, Map<String, Object?> args, {String id = 'c1', TokenUsage? usage}) => [
    ToolCallsEvent([ToolCall(id: id, name: name, arguments: jsonEncode(args))]),
    if (usage != null) UsageEvent(usage),
    const DoneEvent(),
  ];

  List<LlmEvent> finishStep({TokenUsage? usage}) =>
      toolStep('finish', const {}, id: 'cf', usage: usage);

  Future<({AppDatabase db, int sessionId, VariableRepository vars, MessageRepository msgs})> seed({
    int turns = 3,
  }) async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgs = MessageRepository(db);
    for (var i = 0; i < turns; i++) {
      await msgs.append(
        sessionId: sessionId,
        role: i.isEven ? 'user' : 'assistant',
        content: 'turn $i',
      );
    }
    return (db: db, sessionId: sessionId, vars: VariableRepository(db), msgs: msgs);
  }

  Orchestrator orchOf(
    ScriptedLlmBackend backend,
    ({AppDatabase db, int sessionId, VariableRepository vars, MessageRepository msgs}) s, {
    ImageBackend? imageBackend,
    void Function(BackgroundImagePlacement)? onImagePlaced,
  }) => Orchestrator(
    BackgroundEngine(backend),
    s.vars,
    MemoryRepository(s.db),
    s.msgs,
    ImageGuideRepository(s.db),
    imageBackend: imageBackend,
    onImagePlaced: onImagePlaced,
  );

  test('end-to-end: staged updates commit atomically with per-step usage events', () async {
    final s = await seed();
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '8'}}, usage: usage1),
      finishStep(usage: usage2),
    ]);
    final events = <AgentStepEvent>[];
    final turn = await orchOf(backend, s).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
      onAgentStep: events.add,
    );

    expect(turn.skipped, isFalse);
    expect(turn.result, isNotNull);
    expect(await s.vars.bySession(s.sessionId), {'hp': '8'});
    expect((await s.vars.snapshot(s.sessionId)).revision, greaterThan(0));
    final all = await s.msgs.bySession(s.sessionId);
    expect(turn.cursorSeq, all.last.seq);
    expect(turn.hasMoreVariables, isFalse);
    // 逐步入账数据:两逻辑步,用量与上报标记齐备;轮级用量 = 步求和。
    expect(events.map((e) => e.step), [1, 2]);
    expect(events.every((e) => e.success && e.reported), isTrue);
    expect(events[0].usage.inputTokens, 10);
    expect(turn.result!.usage.inputTokens, 30);
    expect(turn.result!.usage.outputTokens, 12);
    // 无 image-only 补调:恰好两请求。
    expect(backend.calls, 2);
    await s.db.db.close();
  });

  test('guardrail failure discards staging: zero writes, revision untouched', () async {
    final s = await seed();
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '8'}}),
      [const TextDelta('prose'), const DoneEvent()],
    ]);
    final turn = await orchOf(backend, s).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
    );
    expect(turn.result, isNull);
    expect(turn.failureReason, BackgroundFailureReason.parseFailure);
    expect(turn.failureDetail, contains('工具调用'));
    expect(turn.cursorSeq, isNull);
    expect(await s.vars.bySession(s.sessionId), isEmpty);
    expect((await s.vars.snapshot(s.sessionId)).revision, 0);
    await s.db.db.close();
  });

  test('backend fast-failure discards staging alike', () async {
    final s = await seed();
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '8'}}),
      [const ErrorEvent('401', kind: UpstreamErrorKind.auth)],
    ]);
    final turn = await orchOf(backend, s).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
    );
    expect(turn.failureReason, BackgroundFailureReason.backendError);
    expect(await s.vars.bySession(s.sessionId), isEmpty);
    await s.db.db.close();
  });

  test('human edit during the loop invalidates the commit (revision conflict)', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final step2Started = Completer<void>();
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        toolStep('setVariables', {'variables': {'hp': '8'}}),
        finishStep(),
      ],
      gates: {1: gate},
      onRequest: (i) {
        if (i == 1) step2Started.complete();
      },
    );
    final future = orchOf(backend, s).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
    );
    await step2Started.future;
    // 循环期间人工改变量:revision 推进,finish 后的 CAS 必须失败。
    await s.vars.upsert(s.sessionId, 'hp', 'human');
    gate.complete();
    final turn = await future;
    expect(turn.skipped, isTrue);
    expect(turn.variableConflict, isTrue);
    expect(turn.result, isNull);
    expect(await s.vars.bySession(s.sessionId), {'hp': 'human'});
    await s.db.db.close();
  });

  test('strict mode: removals become proposals, active board untouched', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final backend = ScriptedLlmBackend([
      toolStep('removeVariables', {'keys': ['hp']}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
      confirmVariableDeletions: true,
    );
    expect(turn.result!.variableRemovals, isEmpty);
    expect(turn.result!.variableRemovalProposals, ['hp']);
    expect(await s.vars.bySession(s.sessionId), {'hp': '10'});
    await s.db.db.close();
  });

  test('readHistory is clamped to the round throughSeq', () async {
    final s = await seed(turns: 6);
    final all = await s.msgs.bySession(s.sessionId);
    final throughSeq = all[2].seq; // 只允许读到第 3 条
    final backend = ScriptedLlmBackend([
      toolStep('readHistory', {'beforeSeq': 9999}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
      throughSeq: throughSeq,
    );
    expect(turn.skipped, isFalse);
    // 第二步请求转录里的 tool_result 只含 clamp 内的消息。
    final toolResult = backend.requests[1].messages.last.content;
    expect(toolResult, contains('[#${all[0].seq}'));
    expect(toolResult, contains('[#$throughSeq'));
    expect(toolResult, isNot(contains('[#${all[3].seq}')));
    await s.db.db.close();
  });

  test('staged image prompts drive the existing generate/persist task', () async {
    final s = await seed();
    final imageBackend = _RecordingImageBackend();
    final placed = <BackgroundImagePlacement>[];
    final backend = ScriptedLlmBackend([
      toolStep('setImagePrompts', {'prompts': ['1girl, tavern']}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s, imageBackend: imageBackend, onImagePlaced: placed.add)
        .runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
    );
    expect(turn.imageHandled, isTrue);
    await turn.imageTask;
    expect(imageBackend.prompts, ['1girl, tavern']);
    expect(placed, hasLength(1));
    final all = await s.msgs.bySession(s.sessionId);
    expect(all.last.hasImage, isTrue);
    expect(all.last.imagePrompt, '1girl, tavern');
    await s.db.db.close();
  });

  test('finish without image prompts: no supplementary single-shot call', () async {
    final s = await seed();
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '8'}}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s, imageBackend: _RecordingImageBackend()).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
    );
    // legacy 会补一次仅图像调用;agentic 不补:机会保留后续轮。
    expect(backend.calls, 2);
    expect(turn.imageHandled, isFalse);
    expect(turn.result!.variableUpdates, {'hp': '8'});
    await s.db.db.close();
  });

  test('rerun: tool-worded tail + in-place image replacement', () async {
    final s = await seed();
    final oldImage = await s.msgs.append(
      sessionId: s.sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'aGVsbG8=',
      imagePrompt: 'old scene',
    );
    final backend = ScriptedLlmBackend([
      toolStep('setImagePrompts', {'prompts': ['new scene']}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s, imageBackend: _RecordingImageBackend()).runAfterTurn(
      sessionId: s.sessionId,
      model: 'm',
      mode: BackgroundMode.agentic,
      rerunContext: const RerunContext(
        direction: 'stormier night',
        previousImagePrompts: ['old scene'],
      ),
      imageReplaceTargets: [(messageId: oldImage.id!, expectedPrompt: 'old scene')],
    );
    final prompt = backend.requests.first.systemPrompt;
    expect(prompt, contains('<rerun_instruction>'));
    expect(prompt, contains('stormier night'));
    expect(prompt, contains('stage'));
    await turn.imageTask;
    final all = await s.msgs.bySession(s.sessionId);
    // 原地替换:不新增图片行,描述更新。
    expect(all.where((m) => m.hasImage), hasLength(1));
    expect(all.firstWhere((m) => m.hasImage).imagePrompt, 'new scene');
    await s.db.db.close();
  });

  test('hybrid and default mode run the legacy single-shot path (no tools)', () async {
    for (final mode in [BackgroundMode.hybrid, BackgroundMode.legacy]) {
      final s = await seed();
      final backend = ScriptedLlmBackend([
        [const TextDelta('{"variables":{"hp":"8"}}'), const DoneEvent()],
      ]);
      final turn = await orchOf(backend, s).runAfterTurn(
        sessionId: s.sessionId,
        model: 'm',
        mode: mode,
      );
      expect(turn.result, isNotNull);
      expect(await s.vars.bySession(s.sessionId), {'hp': '8'});
      expect(backend.requests.single.tools, isEmpty);
      await s.db.db.close();
    }
  });
}