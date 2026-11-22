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
    bool? imageTools,
    List<Message> history = const [],
    List<Message>? variableHistory,
    String? imageGuide,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    RerunContext? rerunContext,
    bool variableInjection = false,
    bool nextSuggestions = false,
    bool memoryTools = false,
    Future<List<Message>> Function({
      int? beforeSeq,
      int? afterSeq,
      required int limit,
    })?
    readHistory,
    HistorySearch? searchHistory,
    Future<Set<String>> Function()? pendingDeletions,
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
    imageTools: imageTools ?? features.image,
    imageGuide: imageGuide,
    memory: memory,
    character: character,
    worldbook: worldbook,
    rerunContext: rerunContext,
    variableInjection: variableInjection,
    nextSuggestions: nextSuggestions,
    memoryTools: memoryTools,
    readHistory:
        readHistory ??
        ({int? beforeSeq, int? afterSeq, required int limit}) async => [],
    searchHistory: searchHistory ?? (query, {int limit = 5}) async => const [],
    pendingDeletions: pendingDeletions,
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

    test('removeVariables keys must be strings; prompt types are schema-checked', () async {
      final b = build(imageCount: 2);
      expect(
        () => exec(b.spec, 'removeVariables', {'keys': [7]}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'setImagePrompts', {'prompts': 'a'}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'setImagePrompts', {'prompts': ['a', 7]}),
        throwsA(isA<AgentToolFailure>()),
      );
      // 数量不符是语义拒绝(模型可补足),不占非法连击。
      expect(await exec(b.spec, 'setImagePrompts', {'prompts': []}), contains('exactly 2'));
      expect(await exec(b.spec, 'setImagePrompts', {'prompts': ['a']}), contains('exactly 2'));
      expect(b.staging.imagePrompts, isNull);

      final blank = build(imageCount: 1);
      expect(
        () => exec(blank.spec, 'setImagePrompts', {'prompts': ['  ']}),
        throwsA(isA<AgentToolFailure>()),
      );
    });
  });

  test('setImagePrompts requires exactly imageCount; wrong counts keep the top-up chance', () async {
    final b = build(imageCount: 2);
    // 少于目标:不能静默消费本轮生图机会,也不动已有暂存。
    expect(await exec(b.spec, 'setImagePrompts', {'prompts': ['a']}), contains('exactly 2'));
    expect(b.staging.imagePrompts, isNull);

    await exec(b.spec, 'setImagePrompts', {'prompts': ['a', 'b']});
    expect(b.staging.imagePrompts, ['a', 'b']);

    // 多于目标同样拒绝,已有两条保持不变。
    expect(
      await exec(b.spec, 'setImagePrompts', {'prompts': ['a', 'b', 'c']}),
      contains('exactly 2'),
    );
    expect(b.staging.imagePrompts, ['a', 'b']);

    await exec(b.spec, 'setImagePrompts', {'prompts': [' c ', ' d ']});
    expect(b.staging.imagePrompts, ['c', 'd']);
  });

  test('repeated wrong-count prompt calls never trip the guardrail', () async {
    final backend = ScriptedLlmBackend([
      for (var i = 0; i < 3; i++)
        [
          ToolCallsEvent([
            ToolCall(
              id: 'p$i',
              name: 'setImagePrompts',
              arguments: jsonEncode({
                'prompts': ['only one'],
              }),
            ),
          ]),
          const DoneEvent(),
        ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'ok',
            name: 'setImagePrompts',
            arguments: jsonEncode({
              'prompts': ['first', 'second'],
            }),
          ),
          const ToolCall(id: 'f', name: 'finish', arguments: '{}'),
        ]),
        const DoneEvent(),
      ],
    ]);
    final b = build(backend: backend, imageCount: 2);
    final result = await AgentRunner.run(b.spec);
    expect(result, isA<AgentRunSuccess>());
    expect(b.staging.imagePrompts, ['first', 'second']);
  });

  group('agentic enhancements', () {
    test(
      'tools are registered only when enabled; audit never registers them',
      () {
        final off = build();
        expect(off.spec.registry.lookup('setVariableInjection'), isNull);
        expect(off.spec.registry.lookup('setNextSuggestions'), isNull);

        final on = build(variableInjection: true, nextSuggestions: true);
        expect(on.spec.registry.lookup('setVariableInjection'), isNotNull);
        expect(on.spec.registry.lookup('setNextSuggestions'), isNotNull);

        // 注入必须有变量维护;建议不依赖变量功能。
        final imageOnly = build(
          features: const BackgroundFeatures(variables: false, image: true),
          variableInjection: true,
          nextSuggestions: true,
        );
        expect(imageOnly.spec.registry.lookup('setVariableInjection'), isNull);
        expect(imageOnly.spec.registry.lookup('setNextSuggestions'), isNotNull);

        final audit = AuditProfile.build(
          backend: ScriptedLlmBackend([
            [const DoneEvent()],
          ]),
          model: 'm',
          variables: defaultVariables,
          access: defaultAccess,
          history: const [],
          readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async => [],
          searchHistory: (query, {int limit = 5}) async => const [],
        );
        expect(audit.spec.registry.lookup('setVariableInjection'), isNull);
        expect(audit.spec.registry.lookup('setNextSuggestions'), isNull);
      },
    );

    test(
      'setVariableInjection validates the working copy and stages nothing on error',
      () async {
        final b = build(variableInjection: true);
        final out = await exec(b.spec, 'setVariableInjection', {
          'keys': ['hp', 'ghost'],
        });
        expect(out, contains('not an existing key'));
        expect(b.staging.injectionKeys, isNull);

        // 本轮新增键可注入;暂存删除的键不可注入。
        await exec(b.spec, 'setVariables', {
          'variables': {'mood': 'calm'},
        });
        await exec(b.spec, 'removeVariables', {
          'keys': ['hp'],
        });
        expect(
          await exec(b.spec, 'setVariableInjection', {
            'keys': ['mood', 'hp'],
          }),
          contains('not an existing key'),
        );
        expect(b.staging.injectionKeys, isNull);
        await exec(b.spec, 'setVariableInjection', {
          'keys': ['mood', 'loc', 'loc'],
        });
        expect(b.staging.injectionKeys, ['mood', 'loc']);
      },
    );

    test('setVariableInjection replaces, clears, and caps at 8 keys', () async {
      final many = {for (var i = 0; i < 9; i++) 'k$i': '$i'};
      final b = build(
        variables: many,
        access: {for (var i = 0; i < 9; i++) 'k$i': VariableAccess.full},
        variableInjection: true,
      );
      expect(
        await exec(b.spec, 'setVariableInjection', {
          'keys': [for (var i = 0; i < 9; i++) 'k$i'],
        }),
        contains('at most 8'),
      );
      expect(b.staging.injectionKeys, isNull);

      await exec(b.spec, 'setVariableInjection', {
        'keys': ['k0', 'k1'],
      });
      await exec(b.spec, 'setVariableInjection', {
        'keys': ['k2'],
      });
      expect(b.staging.injectionKeys, ['k2']);
      await exec(b.spec, 'setVariableInjection', {'keys': []});
      expect(b.staging.injectionKeys, isEmpty);

      expect(
        () => exec(b.spec, 'setVariableInjection', {
          'keys': ['k0', 3],
        }),
        throwsA(isA<AgentToolFailure>()),
      );
    });

    test(
      'setNextSuggestions validates length, uniqueness and slash prefix',
      () async {
        final b = build(nextSuggestions: true);
        expect(
          await exec(b.spec, 'setNextSuggestions', {
            'suggestions': ['a', 'b'],
          }),
          contains('Staged 2'),
        );
        await exec(b.spec, 'setNextSuggestions', {
          'suggestions': [' c '],
        });
        expect(b.staging.nextSuggestions, ['c']);

        for (final bad in [
          ['a', 'b', 'c', 'd'],
          [''],
          ['/clear'],
          ['a', 'a'],
          ['x' * (MaintenanceProfile.maxNextSuggestionChars + 1)],
        ]) {
          expect(
            () => exec(b.spec, 'setNextSuggestions', {'suggestions': bad}),
            throwsA(isA<AgentToolFailure>()),
            reason: '$bad should be rejected',
          );
        }
        expect(b.staging.nextSuggestions, ['c']);
      },
    );

    test('empty suggestion list clears; repeated clears never trip the guardrail', () async {
      final b = build(nextSuggestions: true, variableInjection: true);
      await exec(b.spec, 'setNextSuggestions', {
        'suggestions': ['a'],
      });
      expect(
        await exec(b.spec, 'setNextSuggestions', {'suggestions': []}),
        contains('Cleared'),
      );
      expect(b.staging.nextSuggestions, isEmpty);

      // 三次清空都是合法步:后续 finish 提交,整轮暂存不被护栏丢弃。
      final backend = ScriptedLlmBackend([
        [
          ToolCallsEvent([
            ToolCall(
              id: 'set',
              name: 'setVariables',
              arguments: jsonEncode({
                'variables': {'hp': '8'},
              }),
            ),
          ]),
          const DoneEvent(),
        ],
        for (var i = 0; i < 3; i++)
          [
            ToolCallsEvent([
              ToolCall(
                id: 's$i',
                name: 'setNextSuggestions',
                arguments: jsonEncode({'suggestions': <String>[]}),
              ),
            ]),
            const DoneEvent(),
          ],
        [
          ToolCallsEvent([
            const ToolCall(id: 'f', name: 'finish', arguments: '{}'),
          ]),
          const DoneEvent(),
        ],
      ]);
      final loop = build(backend: backend, nextSuggestions: true);
      final result = await AgentRunner.run(loop.spec);
      expect(result, isA<AgentRunSuccess>());
      expect(loop.staging.nextSuggestions, isEmpty);
      expect(loop.staging.updates, {'hp': '8'});
    });

    test('prompt sections appear only when the tools are enabled', () {
      final off = build();
      expect(off.spec.systemPrompt, isNot(contains('# variable injection')));
      expect(off.spec.systemPrompt, isNot(contains('# next-step suggestions')));
      expect(off.spec.systemPrompt, isNot(contains('setNextSuggestions')));

      final on = build(variableInjection: true, nextSuggestions: true);
      expect(on.spec.systemPrompt, contains('# variable injection'));
      expect(on.spec.systemPrompt, contains('# next-step suggestions'));
      expect(on.spec.systemPrompt, contains('setVariableInjection'));
      expect(on.spec.systemPrompt, contains('setNextSuggestions'));
      expect(on.spec.systemPrompt, contains('first person'));
    });

    test('soft reminder includes enhancement staging counts', () async {
      final backend = ScriptedLlmBackend([
        [
          ToolCallsEvent([
            ToolCall(
              id: 'c1',
              name: 'setNextSuggestions',
              arguments: jsonEncode({
                'suggestions': ['look around'],
              }),
            ),
          ]),
          const DoneEvent(),
        ],
        for (var i = 0; i < 7; i++)
          [
            ToolCallsEvent([
              ToolCall(id: 'r$i', name: 'readVariables', arguments: '{}'),
            ]),
            const DoneEvent(),
          ],
        [
          ToolCallsEvent([
            const ToolCall(id: 'f', name: 'finish', arguments: '{}'),
          ]),
          const DoneEvent(),
        ],
      ]);
      final b = build(
        backend: backend,
        variableInjection: true,
        nextSuggestions: true,
      );
      await AgentRunner.run(b.spec);
      final reminder = backend.requests[8].messages.last;
      expect(reminder.content, contains('1 suggestion(s)'));
      expect(reminder.content, contains('0 injection key(s)'));
    });
  });

  group('readHistory paging', () {
    Message msg(int seq, String content) =>
        Message(sessionId: 1, role: seq.isEven ? 'assistant' : 'user', content: content, seq: seq);

    test('page is ascending, ≤2000 chars, with next-page hint', () async {
      final seen = <int?>[];
      final b = build(
        readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async {
          seen.add(beforeSeq);
          return [for (var i = 1; i <= 5; i++) msg(i, 'msg $i')];
        },
      );
      final out = await exec(b.spec, 'readHistory', {'beforeSeq': 99});
      expect(seen, [99]);
      expect(out, contains('[#1 user] msg 1'));
      expect(out, contains('[#5 user] msg 5'));
      expect(out.indexOf('[#1'), lessThan(out.indexOf('[#5')));
      expect(out, contains('beforeSeq=1'));
      expect(out.length, lessThanOrEqualTo(MaintenanceProfile.readHistoryPageChars));
    });

    test('char budget keeps the newest rows that fit', () async {
      final b = build(
        readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async =>
            [for (var i = 1; i <= 5; i++) msg(i, 'x' * 800)],
      );
      final out = await exec(b.spec, 'readHistory');
      expect(out, contains('[#5'));
      expect(out, contains('[#4'));
      expect(out, isNot(contains('[#3')));
      expect(out, contains('beforeSeq=4'));
      expect(out.length, lessThanOrEqualTo(MaintenanceProfile.readHistoryPageChars));
    });

    test('single over-long message is truncated, page still bounded', () async {
      final b = build(
        readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async =>
            [msg(9, 'y' * 3000)],
      );
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

  group('readHistory around window', () {
    Message msg(int seq, String content) =>
        Message(sessionId: 1, role: seq.isEven ? 'assistant' : 'user', content: content, seq: seq);

    test('aroundSeq returns a compact window with the target marked', () async {
      final b = build(
        readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async {
          if (afterSeq != null) {
            return [msg(8, 'after one'), msg(9, 'after two')];
          }
          return [for (var i = 3; i <= 7; i++) msg(i, 'm$i')];
        },
      );
      final out = await exec(b.spec, 'readHistory', {'aroundSeq': 5});
      expect(out, contains('[#3 user] m3'));
      expect(out, contains('[#4 assistant] m4'));
      expect(out, contains('[#5 user] m5 (around target)'));
      expect(out, contains('[#6 assistant] m6'));
      expect(out, contains('[#7 user] m7'));
      expect(out, isNot(contains('[#8')));
      expect(out, contains('Window around seq 5'));
    });

    test('newest page fully covered by the prompt is short-circuited', () async {
      final rows = [msg(4, 'a'), msg(5, 'b')];
      final b = build(
        history: rows,
        readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async => rows,
      );
      final out = await exec(b.spec, 'readHistory');
      expect(out, contains('already included in your context'));
      expect(out, isNot(contains('[#4')));
      expect(out, contains('beforeSeq=4'));
    });

    test('beforeSeq and aroundSeq together are rejected; bad types throw', () async {
      final b = build();
      expect(
        () => exec(b.spec, 'readHistory', {'beforeSeq': 5, 'aroundSeq': 5}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'readHistory', {'aroundSeq': 'x'}),
        throwsA(isA<AgentToolFailure>()),
      );
    });
  });

  group('searchHistory', () {
    test('bounds snippets, collapses whitespace, and rejects bad queries', () async {
      final seen = <String>[];
      final b = build(
        searchHistory: (query, {int limit = 5}) async {
          seen.add('$query/$limit');
          return [
            (seq: 9, role: 'assistant', content: 'the dragon\nwakes  at dawn'),
            (seq: 4, role: 'user', content: 'x' * 300),
          ];
        },
      );
      final out = await exec(b.spec, 'searchHistory', {'query': ' dragon '});
      expect(seen, ['dragon/5']);
      expect(out, contains('[#9 assistant] the dragon wakes at dawn'));
      expect(out, contains('…'));
      expect(out, isNot(contains('wakes  at')));
      expect(
        () => exec(b.spec, 'searchHistory', {'query': '  '}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'searchHistory', {'query': 7}),
        throwsA(isA<AgentToolFailure>()),
      );
    });

    test('no match suggests refining; five hits add the refine hint', () async {
      final empty = build();
      expect(
        await exec(empty.spec, 'searchHistory', {'query': 'ghost'}),
        contains('No messages match'),
      );

      final full = build(
        searchHistory: (query, {int limit = 5}) async => [
          for (var i = 0; i < MaintenanceProfile.searchHistoryMaxHits; i++)
            (seq: i, role: 'user', content: 'hit $i'),
        ],
      );
      final out = await exec(full.spec, 'searchHistory', {'query': 'hit'});
      expect(out, contains('5 newest matches'));
    });
  });

  group('validateStaged', () {
    test('reports a clean dry run with staged counts', () async {
      final b = build();
      await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
      final out = await exec(b.spec, 'validateStaged');
      expect(out, contains('Dry run (nothing committed)'));
      expect(out, contains('1 update(s)'));
      expect(out, contains('Ready to commit'));
    });

    test('flags dropped injection keys, image count, duplicates, pending proposals', () async {
      const vars = {
        'HP': '10',
        'hp': '10',
        'loc': 'tavern',
        'mood': 'calm',
        'temp': 'cold',
      };
      const acc = {
        'HP': VariableAccess.full,
        'hp': VariableAccess.full,
        'loc': VariableAccess.full,
        'mood': VariableAccess.full,
        'temp': VariableAccess.full,
      };
      final b = build(
        variables: vars,
        access: acc,
        imageCount: 2,
        variableInjection: true,
        pendingDeletions: () async => {'loc'},
      );
      await exec(b.spec, 'setVariables', {
        'variables': {'temp': 'warm', 'hp': '11'},
      });
      // 工具层已拒绝数量不符;这里直接改暂存以覆盖 validateStaged 的终裁护栏。
      b.staging.imagePrompts = ['a'];
      await exec(b.spec, 'setVariableInjection', {'keys': ['mood']});
      await exec(b.spec, 'removeVariables', {'keys': ['mood', 'loc']});

      final out = await exec(b.spec, 'validateStaged');
      // 严格模式:暂存删除只是待确认提案,mood 仍会注入 —— 不得报成将丢弃。
      expect(out, isNot(contains('injection key(s) missing')));
      expect(out, contains('will still be injected'));
      expect(out, contains('mood'));
      expect(out, contains('staged 1'));
      expect(out, contains('expects exactly 2'));
      expect(out, contains('near-duplicate keys'));
      expect(out, contains('"HP" / "hp"'));
      expect(out, contains('pending user confirmation: loc'));
      expect(out, contains('already pending confirmation'));
    });

    test('non-strict: a staged removal really drops the injection key', () async {
      final b = build(variableInjection: true);
      await exec(b.spec, 'setVariableInjection', {'keys': ['hp']});
      await exec(b.spec, 'removeVariables', {'keys': ['hp']});
      final out = await exec(b.spec, 'validateStaged');
      expect(out, contains('injection key(s) missing'));
      expect(out, isNot(contains('will still be injected')));
    });

    test('empty staging is a valid empty commit', () async {
      final b = build();
      final out = await exec(b.spec, 'validateStaged');
      expect(out, contains('0 update(s), 0 removal(s)'));
      expect(out, contains('Ready to commit'));
    });
  });

  group('reference lookups and memory proposal', () {
    const selected = WorldbookEntry(
      characterId: 1,
      name: 'River',
      keys: ['river'],
      background: true,
      content: 'the river marks the northern border',
    );
    const notSelected = WorldbookEntry(
      characterId: 1,
      name: 'Sea',
      background: false,
      content: 'the sea is far away',
    );

    test('reference tools follow data and settings, not the round type', () {
      // image 轮与变量轮同集:稳定前缀的工具面不随轮次摇摆。image 轮里
      // 世界书/记忆已在锚定段,但纯读工具不会被自动调用,不增加轮次成本。
      for (final features in const [
        BackgroundFeatures(variables: true, image: true),
        BackgroundFeatures(variables: true, image: false),
      ]) {
        final b = build(
          features: features,
          memory: 'old fact',
          memoryTools: true,
          worldbook: const [selected],
        );
        expect(b.spec.registry.lookup('searchWorldbook'), isNotNull);
        expect(b.spec.registry.lookup('readMemory'), isNotNull);
        expect(b.spec.registry.lookup('proposeMemory'), isNotNull);
      }

      final off = build(
        features: const BackgroundFeatures(variables: true, image: false),
        memory: 'old fact',
        memoryTools: false,
        worldbook: const [selected],
      );
      expect(off.spec.registry.lookup('readMemory'), isNull);
      expect(off.spec.registry.lookup('proposeMemory'), isNull);
      expect(off.spec.registry.lookup('searchWorldbook'), isNotNull);
    });

    test('searchWorldbook matches selected entries only, with bounded excerpts', () async {
      final b = build(
        features: const BackgroundFeatures(variables: true, image: false),
        worldbook: const [selected, notSelected],
      );
      final out = await exec(b.spec, 'searchWorldbook', {'query': 'RIVER'});
      expect(out, contains('[River]'));
      expect(out, contains('northern border'));
      expect(out, isNot(contains('sea is far')));
      expect(
        await exec(b.spec, 'searchWorldbook', {'query': 'sea'}),
        contains('No selected'),
      );
    });

    test('readMemory returns the truncated memory', () async {
      final b = build(
        features: const BackgroundFeatures(variables: true, image: false),
        memory: 'x' * 5000,
        memoryTools: true,
      );
      final out = await exec(b.spec, 'readMemory');
      expect(
        out.length,
        lessThanOrEqualTo(BackgroundEngine.maxBackgroundMemoryChars + 20),
      );
      expect(out, startsWith('x'));
    });

    test('proposeMemory stages a trimmed proposal and rejects invalid input', () async {
      final b = build(memory: 'old fact', memoryTools: true);
      final out = await exec(b.spec, 'proposeMemory', {
        'content': '  new facts  ',
      });
      expect(out, contains('not applied automatically'));
      expect(b.staging.memoryProposal, 'new facts');

      // 与当前记忆相同 → 语义拒绝,不覆盖已有暂存。
      final same = await exec(b.spec, 'proposeMemory', {
        'content': 'old fact',
      });
      expect(same, contains('matches the current memory'));
      expect(b.staging.memoryProposal, 'new facts');

      expect(
        () => exec(b.spec, 'proposeMemory', {'content': ''}),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'proposeMemory', {
          'content': 'x' * (MaintenanceProfile.maxProposedMemoryChars + 1),
        }),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(
        () => exec(b.spec, 'proposeMemory', {'content': 7}),
        throwsA(isA<AgentToolFailure>()),
      );
    });
  });

  group('round-stable cached prefix', () {
    const entry = WorldbookEntry(
      characterId: 1,
      name: 'River',
      background: true,
      content: 'the river marks the northern border',
    );
    String toolWire(AgentSpec spec) => spec.registry.definitions
        .map(
          (t) => jsonEncode({
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          }),
        )
        .join('\n');

    test('image and variable rounds share tool and contract bytes', () {
      final image = build(
        memory: 'they met',
        memoryTools: true,
        worldbook: const [entry],
      );
      final vars = build(
        features: const BackgroundFeatures(variables: true, image: false),
        imageTools: true,
        memory: 'they met',
        memoryTools: true,
        worldbook: const [entry],
      );
      expect(toolWire(image.spec), toolWire(vars.spec));
      // 变量轮的稳定段就是共享契约;image 轮在契约后追加锚定段。
      final contract = vars.spec.stableSystemPart;
      expect(contract, isNotNull);
      expect(image.spec.stableSystemPart, startsWith(contract!));
      expect(contract, isNot(contains('<image_guide>')));
      expect(image.spec.stableSystemPart, contains('<image_guide>'));
    });

    test('images per round stay out of the cached prefix', () {
      final one = build(imageCount: 1);
      final three = build(imageCount: 3);
      expect(one.spec.stableSystemPart, three.spec.stableSystemPart);
      expect(toolWire(one.spec), toolWire(three.spec));
      expect(one.spec.initialUserMessage, contains('1 image(s)'));
      expect(three.spec.initialUserMessage, contains('3 image(s)'));
    });

    test('non-image round keeps the image tool but rejects staging', () async {
      final b = build(
        features: const BackgroundFeatures(variables: true, image: false),
        imageTools: true,
      );
      expect(
        b.spec.initialUserMessage,
        contains('do not call setImagePrompts'),
      );
      final out = await exec(b.spec, 'setImagePrompts', {
        'prompts': ['tavern'],
      });
      expect(out, contains('does not generate images'));
      expect(b.staging.imagePrompts, isNull);
    });
  });

  test('readVariables returns only the staged diff', () async {
    final b = build(
      access: {'hp': VariableAccess.full, 'loc': VariableAccess.full},
    );
    await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
    await exec(b.spec, 'removeVariables', {'keys': ['loc']});
    final decoded = jsonDecode(await exec(b.spec, 'readVariables')) as Map<String, dynamic>;
    expect(decoded['stagedUpdates'], {'hp': '8'});
    expect(decoded['stagedRemovals'], ['loc']);
    expect(decoded['removalsUsedThisRun'], 1);
    expect(decoded['stagedUpdateCount'], 1);
    expect(decoded['updatePage']['nextOffset'], isNull);
    expect(decoded.containsKey('values'), isFalse);
    expect(decoded.containsKey('access'), isFalse);
  });

  group('readVariables result budget', () {
    test('large staging is paged, abbreviated and stays valid JSON under 4000', () async {
      final vars = {for (var i = 0; i < 30; i++) 'key$i': 'v' * 500};
      final b = build(
        variables: vars,
        access: {for (var i = 0; i < 30; i++) 'key$i': VariableAccess.full},
      );
      await exec(b.spec, 'setVariables', {'variables': vars});

      final seen = <String>{};
      int? offset;
      var pages = 0;
      while (true) {
        final raw = await exec(
          b.spec,
          'readVariables',
          offset == null ? const {} : {'offset': offset},
        );
        expect(raw.length, lessThan(kToolResultBudget));
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        expect(decoded['stagedUpdateCount'], 30);
        expect(decoded['abbreviated'], isTrue);
        final updates = decoded['stagedUpdates'] as Map<String, dynamic>;
        for (final entry in updates.entries) {
          expect(entry.value as String, endsWith('…'));
          expect((entry.value as String).length, lessThanOrEqualTo(
            MaintenanceProfile.readVariableValueChars + 1,
          ));
          seen.add(entry.key);
        }
        pages++;
        offset = (decoded['updatePage'] as Map<String, dynamic>)['nextOffset'] as int?;
        if (offset == null) break;
        expect(pages, lessThan(10));
      }
      expect(seen, hasLength(30));
      expect(pages, greaterThan(1));
    });

    test('over-long keys are abbreviated without breaking the JSON', () async {
      final longKey = 'k' * 500;
      final b = build();
      await exec(b.spec, 'setVariables', {
        'variables': {longKey: 'v' * 500, 'short': 'ok'},
      });
      final raw = await exec(b.spec, 'readVariables');
      expect(raw.length, lessThan(kToolResultBudget));
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['abbreviated'], isTrue);
      final updates = decoded['stagedUpdates'] as Map<String, dynamic>;
      expect(updates['short'], 'ok');
      for (final key in updates.keys) {
        expect(key.length, lessThanOrEqualTo(MaintenanceProfile.readVariableKeyChars + 1));
      }
      expect(raw, contains('…'));
    });
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
      expect(names, {'readHistory', 'searchHistory', 'validateStaged', 'setImagePrompts'});
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
      expect(names, {
        'readVariables',
        'setVariables',
        'removeVariables',
        'readHistory',
        'searchHistory',
        'validateStaged',
      });
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