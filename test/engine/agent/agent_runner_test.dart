// agent 内核循环测试:happy/多调用顺序/自纠/非法连击/软提醒/步级重试/
// 4xx 快失败/取消/截断/逐步事件/thinking 回放。事件脚本化后端驱动。
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/upstream_error.dart';
import 'package:microscritt/engine/agent/agent_events.dart';
import 'package:microscritt/engine/agent/agent_runner.dart';
import 'package:microscritt/engine/agent/agent_tool.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/models/token_usage.dart';
import '../../support/scripted_llm_backend.dart';

void main() {
  const usage1 = TokenUsage(inputTokens: 10, outputTokens: 5);
  const usage2 = TokenUsage(inputTokens: 20, outputTokens: 7, cachedInputTokens: 3);

  ToolCall call(String name, [Map<String, Object?> args = const {}]) =>
      ToolCall(id: 'c_${name}_${args.hashCode}', name: name, arguments: jsonEncode(args));

  List<LlmEvent> toolStep(List<ToolCall> calls, {TokenUsage? usage}) => [
    ToolCallsEvent(calls),
    if (usage != null) UsageEvent(usage),
    const DoneEvent(),
  ];

  List<LlmEvent> finishStep([Map<String, Object?> args = const {}, TokenUsage? usage]) =>
      toolStep([call('finish', args)], usage: usage);

  /// 注册 setVariables/readVariables 记录型执行器;onSet 可定制行为。
  AgentToolRegistry registry({
    Future<String> Function(Map<String, Object?> args)? onSet,
    List<String>? log,
  }) {
    final reg = AgentToolRegistry();
    reg.register(AgentTool(
      tool: const LlmTool(name: 'setVariables', description: 'stage', parameters: {'type': 'object'}),
      execute: (args) async {
        log?.add('setVariables');
        return onSet != null ? onSet(args) : 'ok';
      },
    ));
    reg.register(AgentTool(
      tool: const LlmTool(name: 'readVariables', description: 'read', parameters: {'type': 'object'}),
      execute: (args) async {
        log?.add('readVariables');
        return '{}';
      },
    ));
    return reg;
  }

  AgentSpec spec(
    ScriptedLlmBackend backend, {
    AgentToolRegistry? reg,
    int? maxTokens,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    String Function(int, int)? softReminder,
    void Function(AgentStepEvent)? onStep,
    void Function(String)? onTextDelta,
  }) => AgentSpec(
    backend: backend,
    model: 'm',
    systemPrompt: 'sys',
    initialUserMessage: 'go',
    registry: reg ?? registry(),
    temperature: 1,
    maxTokens: maxTokens,
    shouldCancel: shouldCancel,
    cancelSignal: cancelSignal,
    softReminder: softReminder,
    onStep: onStep,
    onTextDelta: onTextDelta,
  );

  test('happy path: two steps, finishArgs + per-step usage + total', () async {
    final backend = ScriptedLlmBackend([
      toolStep([call('setVariables', {'variables': {'hp': '8'}})], usage: usage1),
      finishStep({'summary': 'done'}, usage2),
    ]);
    final events = <AgentStepEvent>[];
    final result = await AgentRunner.run(spec(backend, onStep: events.add));

    final ok = result as AgentRunSuccess;
    expect(ok.finishArgs, {'summary': 'done'});
    expect(
      ok.stepUsages.map((u) => (u.inputTokens, u.outputTokens, u.cachedInputTokens)),
      [(10, 5, 0), (20, 7, 3)],
    );
    expect(ok.totalUsage.inputTokens, 30);
    expect(ok.totalUsage.outputTokens, 12);
    expect(ok.totalUsage.cachedInputTokens, 3);
    expect(backend.requests, hasLength(2));
    // 工具面 = 注册工具 + 内核 finish;第二步转录含 assistant 调用轮 + tool 结果。
    expect(backend.requests.first.tools.map((t) => t.name), containsAll(['setVariables', 'finish']));
    final msgs = backend.requests[1].messages;
    expect(msgs[1].role, ChatRole.assistant);
    expect(msgs[1].toolCalls!.single.name, 'setVariables');
    expect(msgs[2].role, ChatRole.tool);
    expect(msgs[2].toolCallId, msgs[1].toolCalls!.single.id);
    expect(msgs[2].content, 'ok');
    // 逐步事件:两逻辑步,成功且上报。
    expect(events, hasLength(2));
    expect(events.map((e) => e.step), [1, 2]);
    expect(events.every((e) => e.success && e.reported), isTrue);
    expect(events.first.toolNames, ['setVariables']);
  });

  test('onTextDelta forwards deltas in order; step event carries final text', () async {
    final backend = ScriptedLlmBackend([
      [
        const TextDelta('Hel'),
        const TextDelta('lo'),
        ...toolStep([call('setVariables')], usage: usage1),
      ],
      finishStep({'summary': 'done'}, usage2),
    ]);
    final deltas = <String>[];
    final events = <AgentStepEvent>[];
    final result = await AgentRunner.run(
      spec(backend, onStep: events.add, onTextDelta: deltas.add),
    );

    expect(result, isA<AgentRunSuccess>());
    expect(deltas, ['Hel', 'lo']);
    // 成功步事件带上本步正文,供流式 UI 落定并清除残文。
    expect(events, hasLength(2));
    expect(events.first.text, 'Hello');
  });

  test('retry: deltas include failed attempt, step text is the successful attempt only', () async {
    final backend = ScriptedLlmBackend([
      [const TextDelta('partial '), const ErrorEvent('boom', kind: UpstreamErrorKind.transient)],
      [const TextDelta('final'), ...finishStep({}, usage1)],
    ]);
    final deltas = <String>[];
    final events = <AgentStepEvent>[];
    final result = await AgentRunner.run(
      spec(backend, onStep: events.add, onTextDelta: deltas.add),
    );

    expect(result, isA<AgentRunSuccess>());
    expect(deltas.join(), 'partial final');
    expect(events.single.text, 'final');
  });

  test('multiple calls execute in receive order; finish mixed with writes', () async {
    final log = <String>[];
    final backend = ScriptedLlmBackend([
      toolStep([
        call('setVariables', {'variables': {'a': '1'}}),
        call('readVariables'),
        call('finish'),
        call('setVariables', {'variables': {'ignored': '1'}}),
      ]),
    ]);
    final result = await AgentRunner.run(spec(backend, reg: registry(log: log)));

    expect(result, isA<AgentRunSuccess>());
    // finish 之前的调用照常执行,其后的忽略。
    expect(log, ['setVariables', 'readVariables']);
  });

  test('bad arguments are fed back as tool_result and self-correct next step', () async {
    final backend = ScriptedLlmBackend([
      [ToolCallsEvent([const ToolCall(id: 'c1', name: 'setVariables', arguments: 'not json')]), const DoneEvent()],
      finishStep(),
    ]);
    final result = await AgentRunner.run(spec(backend));

    expect(result, isA<AgentRunSuccess>());
    final feedback = backend.requests[1].messages.last;
    expect(feedback.role, ChatRole.tool);
    expect(feedback.toolCallId, 'c1');
    expect(feedback.content, contains('Error'));
  });

  test('unknown tool is fed back and does not kill the round', () async {
    final backend = ScriptedLlmBackend([
      toolStep([call('bogusTool')]),
      finishStep(),
    ]);
    final result = await AgentRunner.run(spec(backend));
    expect(result, isA<AgentRunSuccess>());
    expect(backend.requests[1].messages.last.content, contains('unknown tool'));
  });

  test('semantic rejection (returned error text) never counts toward the guardrail', () async {
    final backend = ScriptedLlmBackend([
      toolStep([call('setVariables')]),
      toolStep([call('setVariables')]),
      toolStep([call('setVariables')]),
      finishStep(),
    ]);
    final result = await AgentRunner.run(spec(
      backend,
      reg: registry(onSet: (_) async => 'Error: readonly keys cannot be updated.'),
    ));
    expect(result, isA<AgentRunSuccess>());
    expect(backend.calls, 4);
  });

  test('AgentToolFailure (schema violation) counts toward the guardrail', () async {
    final backend = ScriptedLlmBackend([
      toolStep([call('setVariables')]),
      toolStep([call('setVariables')]),
      toolStep([call('setVariables')]),
    ]);
    final result = await AgentRunner.run(spec(
      backend,
      reg: registry(onSet: (_) async => throw const AgentToolFailure('bad shape')),
    ));
    final fail = result as AgentRunFailure;
    expect(fail.reason, AgentFailureReason.guardrail);
    expect(fail.detail, contains('非法工具调用'));
    expect(backend.calls, 3);
  });

  test('prose-only x3 fails with the endpoint diagnostic', () async {
    final backend = ScriptedLlmBackend([
      [const TextDelta('sorry, I cannot help'), const DoneEvent()],
    ]);
    final events = <AgentStepEvent>[];
    final result = await AgentRunner.run(spec(backend, onStep: events.add));

    final fail = result as AgentRunFailure;
    expect(fail.reason, AgentFailureReason.guardrail);
    expect(fail.detail, '端点疑似不支持工具调用,请改用旧模式');
    expect(backend.calls, 3);
    expect(events.every((e) => !e.success && !e.reported), isTrue);
    // prose 回喂是 user 消息(无 tool_call_id 可挂);正文进 assistant 轮。
    final msgs = backend.requests[1].messages;
    expect(msgs[1].role, ChatRole.assistant);
    expect(msgs[1].content, 'sorry, I cannot help');
    expect(msgs[2].role, ChatRole.user);
  });

  test('empty response is an invalid step; no empty assistant message appended', () async {
    final backend = ScriptedLlmBackend([
      [const DoneEvent()],
    ]);
    final result = await AgentRunner.run(spec(backend));
    expect((result as AgentRunFailure).reason, AgentFailureReason.guardrail);
    // 空正文不追加 assistant(Anthropic 空块数组会 400):user 初始 + user 回喂。
    final msgs = backend.requests[1].messages;
    expect(msgs.every((m) => m.role == ChatRole.user), isTrue);
  });

  test('bad-args x3 fails with the generic guardrail diagnostic', () async {
    final backend = ScriptedLlmBackend([
      [ToolCallsEvent([const ToolCall(id: 'c1', name: 'setVariables', arguments: '[')]), const DoneEvent()],
    ]);
    final result = await AgentRunner.run(spec(backend));
    final fail = result as AgentRunFailure;
    expect(fail.reason, AgentFailureReason.guardrail);
    expect(fail.detail, contains('连续 3 步非法工具调用'));
  });

  test('soft reminder lands after step 8 tool results with staging summary', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 8; i++) toolStep([call('readVariables')]),
      finishStep(),
    ]);
    final result = await AgentRunner.run(spec(
      backend,
      softReminder: (step, count) => 'reminder $step/$count',
    ));
    expect(result, isA<AgentRunSuccess>());
    // 第 9 步请求的转录末尾 = 第 8 步 tool results 之后的提醒 user 消息。
    final msgs = backend.requests[8].messages;
    expect(msgs.last.role, ChatRole.user);
    expect(msgs.last.content, 'reminder 8/1');
    expect(msgs[msgs.length - 2].role, ChatRole.tool);
    // 第 8 步之前无提醒。
    expect(backend.requests[7].messages.any((m) => m.content.startsWith('reminder')), isFalse);
  });

  test('soft reminder escalates at step 16', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 16; i++) toolStep([call('readVariables')]),
      finishStep(),
    ]);
    await AgentRunner.run(spec(backend, softReminder: (step, count) => 'reminder $step/$count'));
    final msgs = backend.requests[16].messages;
    final reminders = msgs.where((m) => m.content.startsWith('reminder')).toList();
    expect(reminders.map((m) => m.content), ['reminder 8/1', 'reminder 16/2']);
  });

  test('transient error retries within the step; maxTokens stays the model-level value', () async {
    final backend = ScriptedLlmBackend([
      [
        const UsageEvent(TokenUsage(inputTokens: 900, outputTokens: 1)),
        const ErrorEvent('boom', kind: UpstreamErrorKind.transient),
      ],
      finishStep({}, usage1),
    ]);
    final events = <AgentStepEvent>[];
    final result = await AgentRunner.run(spec(backend, maxTokens: 4096, onStep: events.add));

    expect(result, isA<AgentRunSuccess>());
    expect(backend.calls, 2);
    // 输出上限与主写一致:模型配置值在每次尝试中原样透传。
    expect(backend.requests[0].maxTokens, 4096);
    expect(backend.requests[1].maxTokens, 4096);
    // 一个逻辑步一事件:重试用量求和并入(计费口径)。
    expect(events, hasLength(1));
    expect(events.single.step, 1);
    expect(events.single.usage.inputTokens, 910);
    expect(events.single.success, isTrue);
    // 上下文占用取单次请求口径:最后一次尝试,而非重试求和。
    expect(events.single.requestUsage.inputTokens, 10);
  });

  test('rateLimit is retryable', () async {
    final backend = ScriptedLlmBackend([
      [const ErrorEvent('slow down', kind: UpstreamErrorKind.rateLimit)],
      finishStep(),
    ]);
    expect(await AgentRunner.run(spec(backend)), isA<AgentRunSuccess>());
    expect(backend.calls, 2);
  });

  test('transient retry exhaustion fails with hint after 3 attempts', () async {
    final backend = ScriptedLlmBackend([
      [const ErrorEvent('boom', kind: UpstreamErrorKind.transient)],
    ]);
    final result = await AgentRunner.run(spec(backend));
    final fail = result as AgentRunFailure;
    expect(fail.reason, AgentFailureReason.backendError);
    expect(fail.detail, contains(UpstreamErrorKind.transient.hint));
    expect(backend.calls, 3);
  });

  test('auth error fast-fails with hint and zero retries', () async {
    final backend = ScriptedLlmBackend([
      [const ErrorEvent('401 unauthorized', kind: UpstreamErrorKind.auth)],
    ]);
    final result = await AgentRunner.run(spec(backend));
    final fail = result as AgentRunFailure;
    expect(fail.reason, AgentFailureReason.backendError);
    expect(fail.detail, contains(UpstreamErrorKind.auth.hint));
    expect(backend.calls, 1);
  });

  test('contractViolation fast-fails (endpoint without tool support)', () async {
    final backend = ScriptedLlmBackend([
      [const ErrorEvent('tool_calls without tools', kind: UpstreamErrorKind.contractViolation)],
    ]);
    final fail = (await AgentRunner.run(spec(backend))) as AgentRunFailure;
    expect(fail.reason, AgentFailureReason.backendError);
    expect(fail.detail, contains(UpstreamErrorKind.contractViolation.hint));
    expect(backend.calls, 1);
  });

  test('failed step emits reported=false even with burned usage', () async {
    final backend = ScriptedLlmBackend([
      [UsageEvent(usage1), const ErrorEvent('403', kind: UpstreamErrorKind.quota)],
    ]);
    final events = <AgentStepEvent>[];
    final fail = (await AgentRunner.run(spec(backend, onStep: events.add))) as AgentRunFailure;
    expect(fail.stepUsages.single.inputTokens, 10);
    expect(fail.totalUsage.inputTokens, 10);
    expect(events.single.reported, isFalse);
    expect(events.single.success, isFalse);
    expect(events.single.usage.inputTokens, 10);
  });

  test('cancel between steps: executor flips the flag, next step never fires', () async {
    var cancelled = false;
    final backend = ScriptedLlmBackend([
      toolStep([call('setVariables')]),
      finishStep(),
    ]);
    final result = await AgentRunner.run(spec(
      backend,
      reg: registry(onSet: (_) async {
        cancelled = true;
        return 'ok';
      }),
      shouldCancel: () => cancelled,
    ));
    expect((result as AgentRunFailure).reason, AgentFailureReason.cancelled);
    expect(backend.calls, 1);
  });

  test('cancel before run: zero requests', () async {
    final backend = ScriptedLlmBackend([finishStep()]);
    final result = await AgentRunner.run(spec(backend, shouldCancel: () => true));
    expect((result as AgentRunFailure).reason, AgentFailureReason.cancelled);
    expect(backend.calls, 0);
  });

  test('in-step cancel race: cancelSignal wakes the blocked stream', () async {
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend([
      toolStep([call('setVariables')]),
    ], gates: {0: gate});
    var cancelled = false;
    final signal = Completer<void>();
    final future = AgentRunner.run(spec(
      backend,
      shouldCancel: () => cancelled,
      cancelSignal: signal.future,
    ));
    // 让 generate 订阅建立并停在门控上,再触发取消。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    cancelled = true;
    signal.complete();
    final result = await future;
    expect((result as AgentRunFailure).reason, AgentFailureReason.cancelled);
    gate.complete(); // 释放悬停的生成器
  });

  test('tool results are truncated to 4000 chars', () async {
    final backend = ScriptedLlmBackend([
      toolStep([call('readVariables')]),
      finishStep(),
    ]);
    final reg = AgentToolRegistry();
    reg.register(AgentTool(
      tool: const LlmTool(name: 'readVariables', description: 'read', parameters: {'type': 'object'}),
      execute: (_) async => 'x' * 5000,
    ));
    await AgentRunner.run(spec(backend, reg: reg));
    final toolMsg = backend.requests[1].messages.last;
    expect(toolMsg.content.length, lessThanOrEqualTo(AgentRunner.maxToolResultChars + 20));
    expect(toolMsg.content, contains('…(truncated)'));
  });

  test('thinking replayBlocks round-trip into the next assistant turn', () async {
    final blocks = [
      {'type': 'thinking', 'thinking': 'hmm', 'signature': 'sig'},
    ];
    final backend = ScriptedLlmBackend([
      [ToolCallsEvent([call('readVariables')], replayBlocks: blocks), const DoneEvent()],
      finishStep(),
    ]);
    await AgentRunner.run(spec(backend));
    final assistant = backend.requests[1].messages[1];
    expect(assistant.opaqueBlocks, blocks);
  });

  test('agent requests only carry the model-level maxTokens when configured', () async {
    final unset = ScriptedLlmBackend([finishStep()]);
    await AgentRunner.run(spec(unset));
    expect(unset.requests.single.maxTokens, isNull);

    final configured = ScriptedLlmBackend([finishStep()]);
    await AgentRunner.run(spec(configured, maxTokens: 3000));
    expect(configured.requests.single.maxTokens, 3000);
  });

  test('finish with malformed arguments still ends the run (summary optional)', () async {
    final backend = ScriptedLlmBackend([
      [ToolCallsEvent([const ToolCall(id: 'c1', name: 'finish', arguments: 'oops')]), const DoneEvent()],
    ]);
    final ok = (await AgentRunner.run(spec(backend))) as AgentRunSuccess;
    expect(ok.finishArgs, isEmpty);
  });
}