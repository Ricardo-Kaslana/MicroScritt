// 审计 profile 测试(P4):工具面(无 setImagePrompts)、数据段同构、审计契约
// (合并/修剪/保守/权限/≤5/严格提案)、工具描述覆盖(维护字节不变)、软提醒无
// 生图计数、温度透传/缓存、暂存态复用。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/engine/agent/agent_runner.dart';
import 'package:microscritt/engine/background_agent.dart';
import 'package:microscritt/engine/background_prompt.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import '../support/scripted_llm_backend.dart';

void main() {
  const variables = {'hp': '10', 'loc': 'tavern', 'hp_max': '10'};
  const access = {
    'hp': VariableAccess.full,
    'loc': VariableAccess.protected,
    'hp_max': VariableAccess.readonly,
  };
  final history = [
    const Message(sessionId: 1, role: 'user', content: 'we rest at the inn', seq: 1),
    const Message(sessionId: 1, role: 'assistant', content: 'the fire dims', seq: 2),
  ];

  ({AgentSpec spec, MaintenanceStaging staging}) build({
    Map<String, String> vars = variables,
    Map<String, VariableAccess> acc = access,
    List<Message> hist = const [],
    HistorySearch? searchHistory,
    Future<Set<String>> Function()? pendingDeletions,
    double temperature = 1,
  }) => AuditProfile.build(
    backend: ScriptedLlmBackend([[const DoneEvent()]]),
    model: 'm',
    variables: vars,
    access: acc,
    history: hist,
    readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async => [],
    searchHistory: searchHistory ?? (query, {int limit = 5}) async => const [],
    pendingDeletions: pendingDeletions,
    temperature: temperature,
  );

  Future<String> exec(AgentSpec spec, String name, [Map<String, Object?> args = const {}]) =>
      spec.registry.lookup(name)!.execute(args);

  group('tool surface', () {
    test('registers read/set/remove/search/validate, never setImagePrompts', () {
      final b = build();
      expect(b.spec.registry.lookup('readVariables'), isNotNull);
      expect(b.spec.registry.lookup('setVariables'), isNotNull);
      expect(b.spec.registry.lookup('removeVariables'), isNotNull);
      expect(b.spec.registry.lookup('readHistory'), isNotNull);
      expect(b.spec.registry.lookup('searchHistory'), isNotNull);
      expect(b.spec.registry.lookup('validateStaged'), isNotNull);
      expect(b.spec.registry.lookup('setImagePrompts'), isNull);
      // finish 由内核 runner 追加,不在注册表(保留名拒收)。
      expect(b.spec.registry.lookup('finish'), isNull);
      expect(b.spec.registry.definitions.map((t) => t.name), isNot(contains('setImagePrompts')));
    });

    test('audit tool descriptions drop variable_delta, point at evidence', () {
      final b = build();
      final set = b.spec.registry.lookup('setVariables')!.tool.description;
      final remove = b.spec.registry.lookup('removeVariables')!.tool.description;
      expect(set, isNot(contains('variable_delta')));
      expect(remove, isNot(contains('variable_delta')));
      expect(set, contains('audit_history'));
      expect(remove, contains('audit_history'));
      expect(set, contains('Merge'));
      expect(remove, contains('conservative'));
    });

    test('maintenance descriptions keep variable_delta bytes (no regression)', () {
      final m = MaintenanceProfile.build(
        backend: ScriptedLlmBackend([[const DoneEvent()]]),
        model: 'm',
        variables: variables,
        access: access,
        history: const [],
        features: const BackgroundFeatures(variables: true),
        imageTools: false,
        readHistory: ({int? beforeSeq, int? afterSeq, required int limit}) async => [],
        searchHistory: (query, {int limit = 5}) async => const [],
      );
      expect(
        m.spec.registry.lookup('setVariables')!.tool.description,
        contains('CHANGED in variable_delta'),
      );
      expect(
        m.spec.registry.lookup('removeVariables')!.tool.description,
        contains('variable_delta shows the fact ended'),
      );
    });
  });

  group('prompt isomorphism (shared builders verbatim)', () {
    test('variable part = audit_history + variables + variable_access', () {
      final b = build(hist: history);
      final deletable = {'hp'};
      final readonly = {'hp_max'};
      final expected = [
        auditHistorySection(history),
        variablesSection(variables),
        variableAccessSection(deletable, readonly),
      ].join('\n\n');
      expect(b.spec.variableSystemPart, expected);
    });

    test('no variable_delta / image anchor / rerun sections', () {
      final b = build(hist: history);
      expect(b.spec.systemPrompt, isNot(contains('<variable_delta>')));
      expect(b.spec.systemPrompt, isNot(contains('<image_guide>')));
      expect(b.spec.systemPrompt, isNot(contains('<rerun_instruction>')));
      expect(b.spec.systemPrompt, contains('<audit_history>'));
      expect(b.spec.systemPrompt, contains('<background_audit>'));
    });

    test('constitution covers merge/prune/conservative/permissions/limit/strict', () {
      final b = build();
      final p = b.spec.stableSystemPart!;
      expect(p, contains('Merge near-duplicate'));
      expect(p, contains('Prune facts'));
      expect(p, contains('When unsure, DO NOT touch'));
      expect(p, contains('readonly'));
      expect(p, contains('At most 5 distinct removals'));
      expect(p, contains('strict confirmation mode'));
      expect(p, contains('last action wins'));
    });
  });

  group('spec wiring', () {
    test('cacheStableSystem true, temperature passed through untouched', () {
      expect(build().spec.cacheStableSystem, isTrue);
      expect(build(temperature: 0.9).spec.temperature, 0.9);
      expect(build(temperature: 0.2).spec.temperature, 0.2);
    });

    test('soft reminder counts updates/removals only, no image prompts', () async {
      final b = build();
      await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
      final r = b.spec.softReminder!(8, 1);
      expect(r, contains('1 update(s)'));
      expect(r, contains('0 removal(s)'));
      expect(r, isNot(contains('image prompt')));
      expect(r, contains('Call finish'));
    });

    test('initial user message is audit-worded', () {
      expect(build().spec.initialUserMessage, contains('Audit the state board'));
    });
  });

  group('staging reuse (same semantics as maintenance)', () {
    test('merge = set canonical + remove alias, maps disjoint', () async {
      final b = build(
        vars: {'hp': '10', 'hp_alias': '10'},
        acc: {'hp': VariableAccess.full, 'hp_alias': VariableAccess.full},
      );
      await exec(b.spec, 'setVariables', {'variables': {'hp': '12'}});
      await exec(b.spec, 'removeVariables', {'keys': ['hp_alias']});
      expect(b.staging.updates, {'hp': '12'});
      expect(b.staging.removals, ['hp_alias']);
      expect(b.staging.workingCopy.containsKey('hp_alias'), isFalse);
    });

    test('readonly removal rejected with feedback, nothing staged', () async {
      final b = build();
      final out = await exec(b.spec, 'removeVariables', {'keys': ['hp_max']});
      expect(out, contains('readonly'));
      expect(b.staging.removals, isEmpty);
    });

    test('cumulative removal cap still 5 distinct keys', () async {
      final b = build(
        vars: {for (var i = 0; i < 6; i++) 'k$i': 'v'},
        acc: {for (var i = 0; i < 6; i++) 'k$i': VariableAccess.full},
      );
      final out = await exec(b.spec, 'removeVariables', {
        'keys': ['k0', 'k1', 'k2', 'k3', 'k4', 'k5'],
      });
      expect(out, contains('removal limit reached'));
      expect(b.staging.everRemoved.length, 5);
    });

    test('imagePrompts stays null (audit never stages images)', () async {
      final b = build();
      await exec(b.spec, 'setVariables', {'variables': {'hp': '8'}});
      expect(b.staging.imagePrompts, isNull);
    });

    test('validateStaged surfaces near-duplicate keys for consolidation', () async {
      final b = build(
        vars: {
          'current location': 'inn',
          'current_location': 'inn',
          'hp': '10',
        },
        acc: {
          'current location': VariableAccess.full,
          'current_location': VariableAccess.full,
          'hp': VariableAccess.full,
        },
      );
      final out = await exec(b.spec, 'validateStaged');
      expect(out, contains('near-duplicate keys'));
      expect(out, contains('"current location" / "current_location"'));
    });
  });

  test('constants: interval 5, wide window 30', () {
    expect(AuditProfile.auditInterval, 5);
    expect(AuditProfile.maxAuditHistoryMessages, 30);
  });
}