// 制卡 profile 测试:工具面裁剪、字段护栏、条目 upsert/remove 原子性、
// 头像提示词、提示词契约、整轮循环写暂存。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/engine/agent/agent_runner.dart';
import 'package:microscritt/engine/agent/agent_tool.dart';
import 'package:microscritt/engine/card_studio/card_agent.dart';
import 'package:microscritt/engine/card_studio/card_staging.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import '../../support/scripted_llm_backend.dart';

void main() {
  ({AgentSpec spec, CardStaging staging}) build({
    CardStaging? staging,
    bool avatarEnabled = true,
    String instruction = '写一个机械师角色',
    List<String> sessionLog = const [],
    ScriptedLlmBackend? backend,
  }) =>
      CardProfile.build(
        backend: backend ?? ScriptedLlmBackend([[const DoneEvent()]]),
        model: 'm',
        instruction: instruction,
        staging: staging ?? CardStaging(characterId: 7),
        avatarEnabled: avatarEnabled,
        sessionLog: sessionLog,
        temperature: 1,
      );

  Future<String> exec(
    AgentSpec spec,
    String name, [
    Map<String, Object?> args = const {},
  ]) =>
      spec.registry.lookup(name)!.execute(args);

  WorldbookEntry entry(
    int id, {
    String name = 'Entry',
    String content = 'lore',
    int position = 0,
    Map<String, dynamic> extra = const {},
  }) =>
      WorldbookEntry(
        id: id,
        characterId: 7,
        name: name,
        keys: const ['key'],
        content: content,
        position: position,
        extra: extra,
      );

  test('tool surface: avatar tool only registered when generation is available', () {
    final withAvatar = build();
    expect(
      withAvatar.spec.registry.definitions.map((t) => t.name).toSet(),
      {
        'readDraft',
        'setCardFields',
        'upsertWorldbookEntries',
        'removeWorldbookEntries',
        'setAvatarPrompt',
      },
    );
    final noAvatar = build(avatarEnabled: false);
    expect(noAvatar.spec.registry.lookup('setAvatarPrompt'), isNull);
  });

  group('setCardFields', () {
    test('stages partial updates, trims name, last action wins', () async {
      final b = build();
      final out = await exec(b.spec, 'setCardFields', {
        'fields': {
          'name': '  艾莉 ',
          'description': '机械师',
          'tags': [' 蒸汽 ', '朋克', ''],
        },
      });
      expect(out, contains('Staged 3'));
      expect(b.staging.workingCard.name, '艾莉');
      expect(b.staging.workingCard.description, '机械师');
      expect(b.staging.workingCard.tags, ['蒸汽', '朋克']);

      await exec(b.spec, 'setCardFields', {
        'fields': {'name': '新名字'},
      });
      expect(b.staging.workingCard.name, '新名字');
    });

    test('unknown field rejects the whole call atomically', () async {
      final b = build(staging: CardStaging(baseCard: const CharacterCard(name: 'A')));
      final out = await exec(b.spec, 'setCardFields', {
        'fields': {'name': 'B', 'avatar': 'x'},
      });
      expect(out, startsWith('Error'));
      expect(out, contains('avatar'));
      expect(b.staging.workingCard.name, 'A');
    });

    test('empty name, over-cap field and over-cap list are rejected', () async {
      final b = build();
      expect(
        await exec(b.spec, 'setCardFields', {
          'fields': {'name': '   '},
        }),
        contains('name must not be empty'),
      );
      expect(
        await exec(b.spec, 'setCardFields', {
          'fields': {'description': 'x' * (CardProfile.maxDescriptionChars + 1)},
        }),
        contains('<= ${CardProfile.maxDescriptionChars}'),
      );
      expect(
        await exec(b.spec, 'setCardFields', {
          'fields': {
            'tags': List.generate(CardProfile.maxTags + 1, (i) => 't$i'),
          },
        }),
        contains('at most'),
      );
      expect(b.staging.overriddenFieldCount, 0);
    });

    test('wrong value type throws AgentToolFailure', () async {
      final b = build();
      await expectLater(
        exec(b.spec, 'setCardFields', {
          'fields': {'description': 42},
        }),
        throwsA(isA<AgentToolFailure>()),
      );
      await expectLater(
        exec(b.spec, 'setCardFields', {
          'fields': {
            'tags': 'not-a-list',
          },
        }),
        throwsA(isA<AgentToolFailure>()),
      );
      expect(b.staging.overriddenFieldCount, 0);
    });
  });

  group('upsertWorldbookEntries', () {
    test('creates an entry with a negative temporary id and appended position', () async {
      final b = build(
        staging: CardStaging(
          baseCard: const CharacterCard(name: 'A'),
          baseEntries: [entry(1, position: 0)],
          characterId: 7,
        ),
      );
      final out = await exec(b.spec, 'upsertWorldbookEntries', {
        'entries': [
          {'name': '新条目', 'keys': ['蒸汽'], 'content': '城市背景'},
        ],
      });
      expect(out, contains('+1 new'));
      final created = b.staging.workingEntries.last;
      expect(created.id, lessThan(0));
      expect(created.name, '新条目');
      expect(created.position, 1);
    });

    test('updates by id preserving extra/position/untouched fields', () async {
      final base = entry(
        3,
        name: '旧条目',
        content: 'old',
        position: 5,
        extra: {'probability': 100},
      );
      final b = build(staging: CardStaging(baseEntries: [base], characterId: 7));
      await exec(b.spec, 'upsertWorldbookEntries', {
        'entries': [
          {'id': 3, 'content': 'new'},
        ],
      });
      final updated = b.staging.workingEntryById(3)!;
      expect(updated.content, 'new');
      expect(updated.name, '旧条目');
      expect(updated.position, 5);
      expect(updated.extra, {'probability': 100});
    });

    test('existing staged-new entries are updated, not duplicated', () async {
      const seed = WorldbookEntry(
        id: -1,
        characterId: 7,
        name: '上轮新增',
        keys: ['s'],
        content: 'old',
      );
      final b = build(
        staging: CardStaging(baseEntries: const [seed], characterId: 7),
      );
      final out = await exec(b.spec, 'upsertWorldbookEntries', {
        'entries': [
          {'id': -1, 'content': 'updated'},
        ],
      });
      expect(out, contains('~1 existing'));
      expect(b.staging.workingEntries, hasLength(1));
      expect(b.staging.workingEntries.single.content, 'updated');
      expect(b.staging.stagedNewCount, 1);
    });

    test('updates by unique case-insensitive name', () async {
      final b = build(
        staging: CardStaging(
          baseEntries: [entry(3, name: 'Steam City')],
          characterId: 7,
        ),
      );
      await exec(b.spec, 'upsertWorldbookEntries', {
        'entries': [
          {'name': ' steam city ', 'content': 'updated'},
        ],
      });
      expect(b.staging.workingEntryById(3)!.content, 'updated');
      expect(b.staging.workingEntries.length, 1);
    });

    test('ambiguous names, unknown ids and extra fields reject atomically', () async {
      final b = build(
        staging: CardStaging(
          baseEntries: [entry(1, name: 'Same'), entry(2, name: 'Same')],
          characterId: 7,
        ),
      );
      expect(
        await exec(b.spec, 'upsertWorldbookEntries', {
          'entries': [
            {'name': 'Same', 'content': 'x'},
          ],
        }),
        contains('matches multiple'),
      );
      expect(
        await exec(b.spec, 'upsertWorldbookEntries', {
          'entries': [
            {'id': 999, 'content': 'x'},
          ],
        }),
        contains('not found'),
      );
      expect(
        await exec(b.spec, 'upsertWorldbookEntries', {
          'entries': [
            {'id': 1, 'extra': {'x': 1}},
          ],
        }),
        contains('unknown field'),
      );

      // 同一批中第一条合法、第二条非法 → 整批不落暂存。
      final atomic = await exec(b.spec, 'upsertWorldbookEntries', {
        'entries': [
          {'name': 'Good', 'keys': ['g'], 'content': 'ok'},
          {'id': 404, 'content': 'bad'},
        ],
      });
      expect(atomic, startsWith('Error'));
      expect(b.staging.workingEntries.length, 2);
    });

    test('new entries need name+content and keys-or-constant', () async {
      final b = build();
      expect(
        await exec(b.spec, 'upsertWorldbookEntries', {
          'entries': [
            {'name': 'X', 'keys': ['x']},
          ],
        }),
        contains('needs content'),
      );
      expect(
        await exec(b.spec, 'upsertWorldbookEntries', {
          'entries': [
            {'content': 'x'},
          ],
        }),
        contains('needs a name'),
      );
      expect(
        await exec(b.spec, 'upsertWorldbookEntries', {
          'entries': [
            {'name': 'X', 'content': 'x'},
          ],
        }),
        contains('needs keys or constant'),
      );
      expect(b.staging.workingEntries, isEmpty);
    });

    test('per-run upsert cap rejects the whole batch', () async {
      final b = build();
      final out = await exec(b.spec, 'upsertWorldbookEntries', {
        'entries': [
          for (var i = 0; i < CardProfile.maxUpsertsPerRun + 1; i++)
            {'name': 'E$i', 'keys': ['k'], 'content': 'c'},
        ],
      });
      expect(out, contains('at most'));
      expect(b.staging.workingEntries, isEmpty);
    });

    test('total entry cap is enforced', () async {
      final b = build(
        staging: CardStaging(
          baseEntries: [
            for (var i = 0; i < CardProfile.maxEntriesTotal; i++)
              entry(i + 1, name: 'E$i', position: i),
          ],
          characterId: 7,
        ),
      );
      final out = await exec(b.spec, 'upsertWorldbookEntries', {
        'entries': [
          {'name': 'OneMore', 'keys': ['x'], 'content': 'c'},
        ],
      });
      expect(out, contains('max ${CardProfile.maxEntriesTotal}'));
    });
  });

  group('removeWorldbookEntries', () {
    test('removes by id and name; staged-new removals do not count toward cap', () async {
      final b = build(
        staging: CardStaging(
          baseEntries: [
            entry(1, name: 'A'),
            entry(2, name: 'B'),
            entry(3, name: 'C'),
          ],
          characterId: 7,
        ),
      );
      final addedId = b.staging.addEntry(WorldbookEntry(
        characterId: 7,
        name: 'Temp',
        keys: const ['t'],
        content: 'x',
      ));
      final out = await exec(b.spec, 'removeWorldbookEntries', {
        'ids': [1, addedId],
        'names': ['B'],
      });
      expect(out, contains('3'));
      expect(b.staging.workingEntries.map((e) => e.id), [3]);
      expect(b.staging.everRemoved, {1, 2});
    });

    test('unknown/ambiguous targets reject atomically', () async {
      final b = build(
        staging: CardStaging(
          baseEntries: [entry(1, name: 'Same'), entry(2, name: 'Same')],
          characterId: 7,
        ),
      );
      expect(
        await exec(b.spec, 'removeWorldbookEntries', {
          'ids': [999],
        }),
        contains('not found'),
      );
      expect(
        await exec(b.spec, 'removeWorldbookEntries', {
          'names': ['Same'],
        }),
        contains('matches multiple'),
      );
      expect(b.staging.workingEntries.length, 2);
      expect(b.staging.everRemoved, isEmpty);
    });

    test('base deletion cap is cumulative across calls', () async {
      final b = build(
        staging: CardStaging(
          baseEntries: [
            for (var i = 1; i <= CardProfile.maxRemovalsPerRun + 1; i++)
              entry(i, name: 'E$i', position: i),
          ],
          characterId: 7,
        ),
      );
      final out = await exec(b.spec, 'removeWorldbookEntries', {
        'ids': [
          for (var i = 1; i <= CardProfile.maxRemovalsPerRun + 1; i++) i,
        ],
      });
      expect(out, contains('at most'));
      expect(b.staging.workingEntries.length, CardProfile.maxRemovalsPerRun + 1);
      expect(b.staging.everRemoved, isEmpty);
    });
  });

  group('setAvatarPrompt', () {
    test('stages, replaces and clears; changing prompt drops the stale image', () async {
      final b = build();
      await exec(b.spec, 'setAvatarPrompt', {'prompt': '1girl, red hair'});
      expect(b.staging.avatarPrompt, '1girl, red hair');
      b.staging.avatarBase64 = 'OLD';
      b.staging.generatedPrompt = '1girl, red hair';

      await exec(b.spec, 'setAvatarPrompt', {'prompt': '1girl, blue hair'});
      expect(b.staging.avatarPrompt, '1girl, blue hair');
      expect(b.staging.avatarBase64, isNull);

      await exec(b.spec, 'setAvatarPrompt', {'prompt': '   '});
      expect(b.staging.avatarPrompt, isNull);
    });

    test('over-cap prompt is rejected without staging', () async {
      final b = build();
      final out = await exec(b.spec, 'setAvatarPrompt', {
        'prompt': 'x' * (CardProfile.maxAvatarPromptChars + 1),
      });
      expect(out, startsWith('Error'));
      expect(b.staging.avatarPrompt, isNull);
    });
  });

  test('prompt carries contract, current draft and session log; avatar guide is conditional', () {
    final b = build(
      staging: CardStaging(baseCard: const CharacterCard(name: '旧卡'), characterId: 7),
      sessionLog: ['第一轮：加一个机械师'],
    );
    final stable = b.spec.stableSystemPart!;
    final variable = b.spec.variableSystemPart!;
    expect(stable, contains('<card_task>'));
    expect(stable, contains('setCardFields'));
    expect(stable, contains('avatar_tag_guide'));
    expect(variable, contains('旧卡'));
    expect(variable, contains('第一轮：加一个机械师'));
    expect(variable, contains('target="existing"'));

    final noAvatar = build(avatarEnabled: false);
    expect(noAvatar.spec.stableSystemPart, isNot(contains('avatar_tag_guide')));
    expect(noAvatar.spec.stableSystemPart, contains('not configured'));
  });

  test('readDraft summary lists ids and entry content can be read by id', () async {
    final b = build(
      staging: CardStaging(
        baseEntries: [entry(4, name: '蒸汽城', content: '长内容')],
        characterId: 7,
      ),
    );
    final summary = jsonDecode(await exec(b.spec, 'readDraft')) as Map<String, dynamic>;
    expect((summary['entries'] as List).single['id'], 4);
    expect(summary['target'], 'new');

    final detail = jsonDecode(
      await exec(b.spec, 'readDraft', {'entryId': 4}),
    ) as Map<String, dynamic>;
    expect(detail['content'], '长内容');
    expect(
      await exec(b.spec, 'readDraft', {'entryId': 99}),
      contains('not found'),
    );
    await expectLater(
      exec(b.spec, 'readDraft', {'entryId': '4'}),
      throwsA(isA<AgentToolFailure>()),
    );
  });

  test('readDraft pages entries so the summary stays under the result cap', () async {
    final b = build(
      staging: CardStaging(
        baseEntries: [
          for (var i = 1; i <= 25; i++)
            entry(i, name: 'E$i', position: i),
        ],
        characterId: 7,
      ),
    );
    final first = jsonDecode(await exec(b.spec, 'readDraft')) as Map<String, dynamic>;
    expect(first['entryPage']['total'], 25);
    expect(first['entries'] as List, hasLength(20));
    expect(first['entryPage']['nextOffset'], 20);

    final second = jsonDecode(
      await exec(b.spec, 'readDraft', {'offset': 20}),
    ) as Map<String, dynamic>;
    expect(second['entries'] as List, hasLength(5));
    expect(second['entryPage']['nextOffset'], isNull);

    expect(
      await exec(b.spec, 'readDraft', {'offset': -1}),
      contains('offset'),
    );
  });

  test('readDraft reads one card field in pages within the result cap', () async {
    final description =
        List.generate(120, (i) => '第$i行 "quoted" text').join('\n');
    final b = build(
      staging: CardStaging(
        baseCard: CharacterCard(name: '长卡', description: description),
        characterId: 7,
      ),
    );
    final firstRaw = await exec(b.spec, 'readDraft', {'field': 'description'});
    expect(firstRaw.length, lessThanOrEqualTo(4000));
    final first = jsonDecode(firstRaw) as Map<String, dynamic>;
    expect(first['field'], 'description');
    expect(first['totalChars'], description.length);
    expect(first['offset'], 0);
    expect(first['limit'], lessThanOrEqualTo(CardProfile.readFieldCharsDefault));
    expect(first['nextOffset'], isNotNull);
    expect(first['text'], description.substring(0, first['limit'] as int));

    final parts = <String>[first['text'] as String];
    int? offset = first['nextOffset'] as int?;
    while (offset != null) {
      final page = jsonDecode(await exec(b.spec, 'readDraft', {
        'field': 'description',
        'fieldOffset': offset,
      })) as Map<String, dynamic>;
      expect(page['offset'], offset);
      parts.add(page['text'] as String);
      offset = page['nextOffset'] as int?;
    }
    expect(parts.join(), description);

    final clamped = jsonDecode(await exec(b.spec, 'readDraft', {
      'field': 'description',
      'fieldLimit': 99999,
    })) as Map<String, dynamic>;
    expect(clamped['limit'], lessThanOrEqualTo(CardProfile.readFieldCharsMax));
  });

  test('readDraft field errors are semantic and never stage', () async {
    final b = build();
    expect(
      await exec(b.spec, 'readDraft', {'field': 'nope'}),
      startsWith('Error'),
    );
    expect(
      await exec(b.spec, 'readDraft', {
        'field': 'description',
        'entryId': 1,
      }),
      startsWith('Error'),
    );
    expect(
      await exec(b.spec, 'readDraft', {
        'field': 'description',
        'fieldOffset': -1,
      }),
      startsWith('Error'),
    );
    await expectLater(
      exec(b.spec, 'readDraft', {'field': 'description', 'fieldOffset': '0'}),
      throwsA(isA<AgentToolFailure>()),
    );
    expect(b.staging.overriddenFieldCount, 0);
  });

  test('prompt flags truncated fields with a readDraft hint', () {
    final long = 'x' * (CardProfile.promptCardFieldChars + 50);
    final b = build(
      staging: CardStaging(
        baseCard: CharacterCard(name: '长卡', description: long),
        characterId: 7,
      ),
    );
    expect(b.spec.stableSystemPart, contains('read its full text with readDraft'));
    expect(b.spec.variableSystemPart, contains('readDraft field="description"'));
    expect(b.spec.variableSystemPart, contains('truncated at 2000'));
  });

  test('full loop: tool calls stage the draft and finish ends the run', () async {
    ToolCall call(String name, [Map<String, Object?> args = const {}]) =>
        ToolCall(id: 'c_$name', name: name, arguments: jsonEncode(args));
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          call('setCardFields', {
            'fields': {'name': '循环卡'},
          }),
          call('upsertWorldbookEntries', {
            'entries': [
              {'name': 'W', 'keys': ['w'], 'content': 'lore'},
            ],
          }),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([call('finish', {'summary': 'done'})]),
        const DoneEvent(),
      ],
    ]);
    final b = build(backend: backend);
    final result = await AgentRunner.run(b.spec);
    expect(result, isA<AgentRunSuccess>());
    expect(b.staging.workingCard.name, '循环卡');
    expect(b.staging.workingEntries.single.name, 'W');
    expect((result as AgentRunSuccess).finishArgs['summary'], 'done');
  });
}
