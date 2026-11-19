// 编排器 runAudit 测试(P4,真实 sqflite FFI):端到端原子提交(cursorSeq 恒
// null、无生图)、宽历史窗 30、readHistory clamp、revision 冲突、护栏原子性、
// 严格提案、空板/空对话良性跳过(零 LLM 调用)、取消。审计是独立入口,不经
// runAfterTurn 的 mode 分流(hybrid 维护仍 legacy,由 orchestrator_agentic_test 钉死)。
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/llm_backend.dart';
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
  List<LlmEvent> finishStep({TokenUsage? usage}) => toolStep('finish', const {}, id: 'cf', usage: usage);

  Future<({AppDatabase db, int sessionId, VariableRepository vars, MessageRepository msgs})> seed({
    int turns = 3,
  }) async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgs = MessageRepository(db);
    for (var i = 0; i < turns; i++) {
      await msgs.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'turn $i');
    }
    return (db: db, sessionId: sessionId, vars: VariableRepository(db), msgs: msgs);
  }

  Orchestrator orchOf(
    ScriptedLlmBackend backend,
    ({AppDatabase db, int sessionId, VariableRepository vars, MessageRepository msgs}) s, {
    ImageBackend? imageBackend,
  }) => Orchestrator(
    BackgroundEngine(backend),
    s.vars,
    MemoryRepository(s.db),
    s.msgs,
    ImageGuideRepository(s.db),
    imageBackend: imageBackend,
  );

  test('end-to-end: corrections commit atomically, cursorSeq null, per-step usage', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '12'}}, usage: usage1),
      finishStep(usage: usage2),
    ]);
    final events = <AgentStepEvent>[];
    final turn = await orchOf(backend, s).runAudit(
      sessionId: s.sessionId,
      model: 'm',
      onAgentStep: events.add,
    );
    expect(turn.skipped, isFalse);
    expect(turn.result, isNotNull);
    expect(await s.vars.bySession(s.sessionId), {'hp': '12'});
    // 审计永不推进 delta 游标、不标生图。
    expect(turn.cursorSeq, isNull);
    expect(turn.hasMoreVariables, isFalse);
    expect(turn.imageHandled, isFalse);
    expect(turn.imageTask, isNull);
    expect(events.map((e) => e.step), [1, 2]);
    expect(turn.result!.usage.inputTokens, 30);
    expect(turn.result!.usage.outputTokens, 12);
    expect(backend.calls, 2);
    await s.db.db.close();
  });

  test('wide history window keeps the newest 30 turns', () async {
    final s = await seed(turns: 40);
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '12'}}),
      finishStep(),
    ]);
    await orchOf(backend, s).runAudit(sessionId: s.sessionId, model: 'm');
    final prompt = backend.requests.first.systemPrompt;
    expect(prompt, contains('<audit_history>'));
    expect(prompt, contains('turn 39')); // 最新在窗内
    expect(prompt, contains('turn 10')); // 第 30 条边界
    expect(prompt, isNot(contains('turn 9'))); // 更旧的被裁掉
    expect(prompt, isNot(contains('turn 0')));
    await s.db.db.close();
  });

  test('readHistory is clamped to the audit throughSeq', () async {
    final s = await seed(turns: 6);
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final all = await s.msgs.bySession(s.sessionId);
    final throughSeq = all[2].seq;
    final backend = ScriptedLlmBackend([
      toolStep('readHistory', {'beforeSeq': 9999}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s).runAudit(
      sessionId: s.sessionId,
      model: 'm',
      throughSeq: throughSeq,
    );
    expect(turn.skipped, isFalse);
    final toolResult = backend.requests[1].messages.last.content;
    expect(toolResult, contains('[#${all[0].seq}'));
    expect(toolResult, contains('[#$throughSeq'));
    expect(toolResult, isNot(contains('[#${all[3].seq}')));
    await s.db.db.close();
  });

  test('human edit during the audit invalidates the commit (revision conflict)', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final step2Started = Completer<void>();
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend(
      [toolStep('setVariables', {'variables': {'hp': '12'}}), finishStep()],
      gates: {1: gate},
      onRequest: (i) { if (i == 1) step2Started.complete(); },
    );
    final future = orchOf(backend, s).runAudit(sessionId: s.sessionId, model: 'm');
    await step2Started.future;
    await s.vars.upsert(s.sessionId, 'hp', 'human');
    gate.complete();
    final turn = await future;
    expect(turn.skipped, isTrue);
    expect(turn.variableConflict, isTrue);
    expect(turn.result, isNull);
    expect(turn.cursorSeq, isNull);
    expect(await s.vars.bySession(s.sessionId), {'hp': 'human'});
    await s.db.db.close();
  });

  test('guardrail failure discards staging: zero writes', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '12'}}),
      [const TextDelta('prose'), const DoneEvent()],
    ]);
    final turn = await orchOf(backend, s).runAudit(sessionId: s.sessionId, model: 'm');
    expect(turn.result, isNull);
    expect(turn.failureReason, BackgroundFailureReason.parseFailure);
    expect(turn.failureDetail, contains('工具调用'));
    expect(await s.vars.bySession(s.sessionId), {'hp': '10'}); // 未写
    await s.db.db.close();
  });

  test('strict mode: removals become proposals, board untouched', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final backend = ScriptedLlmBackend([
      toolStep('removeVariables', {'keys': ['hp']}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s).runAudit(
      sessionId: s.sessionId,
      model: 'm',
      confirmVariableDeletions: true,
    );
    expect(turn.result!.variableRemovals, isEmpty);
    expect(turn.result!.variableRemovalProposals, ['hp']);
    expect(await s.vars.bySession(s.sessionId), {'hp': '10'});
    await s.db.db.close();
  });

  test('empty board skips without any LLM call', () async {
    final s = await seed();
    final backend = ScriptedLlmBackend([finishStep()]);
    final turn = await orchOf(backend, s).runAudit(sessionId: s.sessionId, model: 'm');
    expect(turn.skipped, isTrue);
    expect(turn.variableConflict, isFalse);
    expect(turn.skippedReason, contains('变量板为空'));
    expect(backend.calls, 0);
    await s.db.db.close();
  });

  test('empty conversation skips without any LLM call', () async {
    final s = await seed(turns: 0);
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final backend = ScriptedLlmBackend([finishStep()]);
    final turn = await orchOf(backend, s).runAudit(sessionId: s.sessionId, model: 'm');
    expect(turn.skipped, isTrue);
    expect(turn.skippedReason, contains('无对话'));
    expect(backend.calls, 0);
    await s.db.db.close();
  });

  test('audit never generates images even with an image backend present', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final imageBackend = _RecordingImageBackend();
    final backend = ScriptedLlmBackend([
      toolStep('setVariables', {'variables': {'hp': '12'}}),
      finishStep(),
    ]);
    final turn = await orchOf(backend, s, imageBackend: imageBackend)
        .runAudit(sessionId: s.sessionId, model: 'm');
    expect(turn.imageHandled, isFalse);
    expect(turn.imageTask, isNull);
    expect(imageBackend.prompts, isEmpty);
    await s.db.db.close();
  });

  test('pre-cancelled audit returns cancelled without calling the backend', () async {
    final s = await seed();
    await s.vars.upsert(s.sessionId, 'hp', '10', access: VariableAccess.full);
    final backend = ScriptedLlmBackend([finishStep()]);
    final turn = await orchOf(backend, s).runAudit(
      sessionId: s.sessionId,
      model: 'm',
      shouldCancel: () => true,
    );
    expect(turn.failureReason, BackgroundFailureReason.cancelled);
    expect(backend.calls, 0);
    await s.db.db.close();
  });
}