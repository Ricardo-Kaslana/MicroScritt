// 维护 profile 测试:暂存语义(last-action-wins/累计删除帽/权限回喂)、
// 工具校验、readHistory 分页、提示词同构与 features 裁剪、档位缩放。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/engine/agent/agent_runner.dart';
import 'package:microscritt/engine/agent/agent_tool.dart';
import 'package:microscritt/engine/background_agent.dart';
import 'package:microscritt/engine/background_engine.dart';
import 'package:microscritt/engine/background_prompt.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import '../support/scripted_llm_backend.dart';

void main() {
  const defaultVariables = {'hp': '10', 'loc': 'tavern'};
  const defaultAccess = {'hp': VariableAccess.full, 'loc': VariableAccess.protected};

  ({AgentSpec spec, MaintenanceStaging staging}) build({
    Map<String, String> variables = defaultVariables,
    Map<String, VariableAccess> access = defaultAccess,
    BackgroundFeatures features = const BackgroundFeatures(),
    int imageCount = 1,
    List<Message> history = const [],
    List<Message>? variableHistory,
    String? imageGuide,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    RerunContext? rerunContext,
    Future<List<Message>> Function({int? beforeSeq, required int limit})? readHistory,
    double temperature = 1,
    ScriptedLlmBackend? backend,
  }) => MaintenanceProfile.build(
    backend: backend ?? ScriptedLlmBackend([[const DoneEvent()]]),
    model: 'm',
    variables: variables,
    access: access,
    history: history,
    variableHistory: variableHistory,
    features: features,
    imageCount: imageCount,
    imageGuide: imageGuide,
    memory: memory,
    character: character,
    worldbook: worldbook,
    rerunContext: rerunContext,
    readHistory: readHistory ?? ({int? beforeSeq, required int limit}) async => [],
    temperature: temperature,
  );

  Future<String> exec(AgentSpec spec, String name, [Map<String, Object?> args = const {}]) =>
      spec.registry.lookup(name)!.execute(args);

  group('staging semantics', () {
    test('setVariables stages scalars as strings; working copy reflects them', () async {
      final b = build();
      final out = await exec(b.spec, 'setVariables', {
        'variables': {'hp': 8, 'flag': true, 'note': 'ok'},
      });
      expect(out, contains('Staged 3'));
      expect(b.staging.updates, {'hp': '8', 'flag': 'true', 'note': 'ok'});
      expect(b.staging.workingCopy['hp'], '8');
      expect(b.staging.workingCopy['loc'], 'tavern'); // 基线未动键保留
    });

    test('set then remove: removal wins, maps disjoint', () async {
      final b = build();
      await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
      await exec(b.spec, 'removeVariables', {'keys': ['hp']});
      expect(b.staging.updates, isEmpty);
      expect(b.staging.removals, ['hp']);
      expect(b.staging.workingCopy.containsKey('hp'), isFalse);
    });

    test('remove then set: update wins, maps disjoint', () async {
      final b = build();
      await exec(b.spec, 'removeVariables', {'keys': ['hp']});
      await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
      expect(b.staging.removals, isEmpty);
      expect(b.staging.updates, {'hp': '8'});
    });

    test('remove→set→remove does not double-charge the cumulative cap', () async {
      final b = build();
      await exec(b.spec, 'removeVariables', {'keys': ['hp']});
      await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
      final out = await exec(b.spec, 'removeVariables', {'keys': ['hp']});
      expect(out, contains('Staged'));
      expect(b.staging.everRemoved, {'hp'});
      expect(b.staging.removals, ['hp']);
      expect(b.staging.updates, isEmpty);
    });

    test('cumulative cap: sixth distinct key rejected, five staged', () async {
      final b = build(
        variables: {for (var i = 0; i < 6; i++) 'k$i': 'v'},
        access: {for (var i = 0; i < 6; i++) 'k$i': VariableAccess.full},
      );
      final out = await exec(b.spec, 'removeVariables', {
        'keys': ['k0', 'k1', 'k2', 'k3', 'k4', 'k5'],
      });
      expect(out, contains('removal limit reached'));
      expect(b.staging.everRemoved.length, 5);
      expect(b.staging.removals, ['k0', 'k1', 'k2', 'k3', 'k4']);
    });

    test('re-remove of an already staged key is a free no-op', () async {
      final b = build();
      await exec(b.spec, 'removeVariables', {'keys': ['hp', 'hp']});
      expect(b.staging.removals, ['hp']);
      expect(b.staging.everRemoved, {'hp'});
    });

    test('staged new keys are removable (default full)', () async {
      final b = build();
      await exec(b.spec, 'setVariables', {'variables': {'newKey': 'v'}});
      final out = await exec(b.spec, 'removeVariables', {'keys': ['newKey']});
      expect(out, contains('Staged'));
      expect(b.staging.updates, isEmpty);
      expect(b.staging.removals, ['newKey']);
    });
  });

  group('permission feedback (semantic rejections are valid steps)', () {
    test('readonly update returns error text and stages nothing', () async {
      final b = build(access: {'hp': VariableAccess.readonly});
      final out = await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
      expect(out, contains('readonly'));
      expect(b.staging.updates, isEmpty);
    });

    test('protected/readonly removal returns error text', () async {
      final b = build(access: {'hp': VariableAccess.protected, 'loc': VariableAccess.readonly});
      final out = await exec(b.spec, 'removeVariables', {'keys': ['hp', 'loc']});
      expect(out, contains('protected'));
      expect(out, contains('readonly'));
      expect(b.staging.removals, isEmpty);
    });

    test('nonexistent key removal errors; valid keys in the same call still stage', () async {
      final b = build();
      final out = await exec(b.spec, 'removeVariables', {'keys': ['ghost', 'hp']});
      expect(out, contains('not an existing key'));
      expect(b.staging.removals, ['hp']);
    });
  });

  group('schema violations throw AgentToolFailure (invalid steps)', () {
    test('non-scalar value / empty key / non-object variables', () async {
      final b = build();
      expect(
        () => exec(b.spec, 'setVariables', {'variables': {'hp': {'nested': 1}}}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'setVariables', {'variables': {'': 'v'}}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'setVariables', {'variables': 'bad'}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(b.staging.updates, isEmpty);
    });

    test('schema violation wins over readonly in a mixed call', () async {
      final b = build(access: {'hp': VariableAccess.readonly});
      expect(
        () => exec(b.spec, 'setVariables', {'variables': {'hp': '8', 'x': []}}),
        throwsA(isA<AgentToolFailure>()),
      );
    });

    test('removeVariables keys must be strings; setImagePrompts bounds', () async {
      final b = build(imageCount: 2);
      expect(
        () => exec(b.spec, 'removeVariables', {'keys': [7]}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'setImagePrompts', {'prompts': []}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'setImagePrompts', {'prompts': ['a', 'b', 'c']}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'setImagePrompts', {'prompts': ['  ']}),
        throwsA(isA<AgentToolFailure>()),
      );
    });
  });

  test('setImagePrompts replaces prior staging and trims', () async {
    final b = build(imageCount: 2);
    await exec(b.spec, 'setImagePrompts', {'prompts': ['a', 'b']});
    await exec(b.spec, 'setImagePrompts', {'prompts': [' c ']});
    expect(b.staging.imagePrompts, ['c']);
  });

  group('readHistory paging', () {
    Message msg(int seq, String content) =>
        Message(sessionId: 1, role: seq.isEven ? 'assistant' : 'user', content: content, seq: seq);

    test('page is ascending, ≤2000 chars, with next-page hint', () async {
      final seen = <int?>[];
      final b = build(readHistory: ({int? beforeSeq, required int limit}) async {
        seen.add(beforeSeq);
        return [for (var i = 1; i <= 5; i++) msg(i, 'msg $i')];
      });
      final out = await exec(b.spec, 'readHistory', {'beforeSeq': 99});
      expect(seen, [99]);
      expect(out, contains('[#1 user] msg 1'));
      expect(out, contains('[#5 user] msg 5'));
      expect(out.indexOf('[#1'), lessThan(out.indexOf('[#5')));
      expect(out, contains('beforeSeq=1'));
      expect(out.length, lessThanOrEqualTo(MaintenanceProfile.readHistoryPageChars));
    });

    test('char budget keeps the newest rows that fit', () async {
      final b = build(readHistory: ({int? beforeSeq, required int limit}) async =>
          [for (var i = 1; i <= 5; i++) msg(i, 'x' * 800)]);
      final out = await exec(b.spec, 'readHistory');
      expect(out, contains('[#5'));
      expect(out, contains('[#4'));
      expect(out, isNot(contains('[#3')));
      expect(out, contains('beforeSeq=4'));
      expect(out.length, lessThanOrEqualTo(MaintenanceProfile.readHistoryPageChars));
    });

    test('single over-long message is truncated, page still bounded', () async {
      final b = build(readHistory: ({int? beforeSeq, required int limit}) async =>
          [msg(9, 'y' * 3000)]);
      final out = await exec(b.spec, 'readHistory');
      expect(out.length, lessThanOrEqualTo(MaintenanceProfile.readHistoryPageChars));
      expect(out, contains('[#9'));
    });

    test('empty page reports no messages; bad beforeSeq type throws', () async {
      final b = build();
      expect(await exec(b.spec, 'readHistory'), contains('No chat messages'));
      expect(
        () => exec(b.spec, 'readHistory', {'beforeSeq': 'abc'}),
        throwsA(isA<AgentToolFailure>()),
      );
    });
  });

  test('readVariables returns working copy + sorted access tiers', () async {
    final b = build(access: {'hp': VariableAccess.full, 'loc': VariableAccess.readonly});
    await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
    final decoded = jsonDecode(await exec(b.spec, 'readVariables')) as Map<String, dynamic>;
    expect(decoded['values'], {'hp': '8', 'loc': 'tavern'});
    expect(decoded['access'], {'deletable': ['hp'], 'readonly': ['loc']});
  });

  group('prompt isomorphism with legacy data sections', () {
    const card = CharacterCard(name: 'Alice', description: 'knight', personality: 'calm', scenario: 'tavern');
    const entry = WorldbookEntry(characterId: 1, background: true, content: 'river lore');
    final history = [
      const Message(sessionId: 1, role: 'user', content: 'hello', seq: 4),
      const Message(sessionId: 1, role: 'assistant', content: 'hi', seq: 5),
    ];
    final delta = [const Message(sessionId: 1, role: 'user', content: 'I order ale', seq: 6)];

    test('shared sections appear verbatim; rerun tail last; cache split on', () {
      final b = build(
        history: history,
        variableHistory: delta,
        imageGuide: '1girl',
        memory: 'they met',
        character: card,
        worldbook: const [entry],
        rerunContext: const RerunContext(
          direction: 'stormier',
          previousImagePrompts: ['wide shot'],
        ),
        temperature: 0.9,
      );
      final prompt = b.spec.systemPrompt;
      expect(prompt, contains(transcriptSection(history)));
      expect(prompt, contains(variableDeltaSection(delta)));
      expect(prompt, contains(variablesSection(defaultVariables)));
      expect(prompt, contains(variableAccessSection({'hp'}, const {})));
      expect(
        b.spec.stableSystemPart,
        contains(imageAnchorSections(
          imageGuide: '1girl',
          character: card,
          memory: 'they met',
          worldbook: const [entry],
          memoryChars: BackgroundEngine.maxBackgroundMemoryChars,
          characterChars: BackgroundEngine.maxBackgroundCharacterChars,
          worldbookChars: BackgroundEngine.maxBackgroundWorldbookChars,
          worldbookEntryChars: BackgroundEngine.maxBackgroundWorldbookEntryChars,
        ).join('\n\n')),
      );
      expect(prompt, contains('<background_task>'));
      expect(prompt, contains('CALLING TOOLS'));
      expect(prompt, endsWith('</rerun_instruction>'));
      expect(prompt, contains('stormier'));
      expect(prompt, contains('wide shot'));
      expect(b.spec.cacheStableSystem, isTrue);
      expect(b.spec.temperature, 0.9); // 模型配置原样透传,不再夹取
    });

    test('image-only round trims variable tools and sections', () {
      final b = build(
        features: const BackgroundFeatures(variables: false, image: true),
        history: history,
      );
      final names = b.spec.registry.definitions.map((t) => t.name).toSet();
      expect(names, {'readHistory', 'setImagePrompts'});
      expect(b.spec.systemPrompt, isNot(contains('<variable_delta>')));
      expect(b.spec.systemPrompt, isNot(contains('setVariables')));
      expect(b.spec.systemPrompt, contains('<image_guide>'));
    });

    test('variables-only round trims image tool and anchors', () {
      final b = build(
        features: const BackgroundFeatures(variables: true, image: false),
        history: history,
        memory: 'they met',
      );
      final names = b.spec.registry.definitions.map((t) => t.name).toSet();
      expect(names, {'readVariables', 'setVariables', 'removeVariables', 'readHistory'});
      expect(b.spec.systemPrompt, isNot(contains('<image_guide>')));
      expect(b.spec.systemPrompt, isNot(contains('setImagePrompts')));
    });
  });

  test('full loop: staged updates survive to finish for the orchestrator commit', () async {
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(id: 'c1', name: 'setVariables', arguments: jsonEncode({'variables': {'hp': '8'}})),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(id: 'c2', name: 'finish', arguments: jsonEncode({'summary': 'hp updated'})),
        ]),
        const DoneEvent(),
      ],
    ]);
    final b = build(backend: backend);
    final result = await AgentRunner.run(b.spec);
    final ok = result as AgentRunSuccess;
    expect(ok.finishArgs, {'summary': 'hp updated'});
    expect(b.staging.updates, {'hp': '8'});
    expect(b.staging.removals, isEmpty);
  });

  test('soft reminder carries the staging summary', () async {
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(id: 'c1', name: 'setVariables', arguments: jsonEncode({'variables': {'hp': '8'}})),
        ]),
        const DoneEvent(),
      ],
      for (var i = 0; i < 7; i++)
        [ToolCallsEvent([ToolCall(id: 'r$i', name: 'readVariables', arguments: '{}')]), const DoneEvent()],
      [ToolCallsEvent([const ToolCall(id: 'f', name: 'finish', arguments: '{}')]), const DoneEvent()],
    ]);
    final b = build(backend: backend);
    await AgentRunner.run(b.spec);
    // 第 9 步请求转录末尾 = 第 8 步后的提醒,含暂存计数。
    final reminder = backend.requests[8].messages.last;
    expect(reminder.role.name, 'user');
    expect(reminder.content, contains('1 update(s)'));
    expect(reminder.content, contains('finish'));
  });

  group('BackgroundMode', () {
    test('fromWire round-trips known values and fails safe to legacy', () {
      expect(BackgroundMode.fromWire('agentic'), BackgroundMode.agentic);
      expect(BackgroundMode.fromWire('hybrid'), BackgroundMode.hybrid);
      expect(BackgroundMode.fromWire('legacy'), BackgroundMode.legacy);
      expect(BackgroundMode.fromWire('bogus'), BackgroundMode.legacy);
      expect(BackgroundMode.fromWire(''), BackgroundMode.legacy);
    });
  });
}