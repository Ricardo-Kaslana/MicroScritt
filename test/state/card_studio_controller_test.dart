// 制卡控制器测试:新卡/优化全流程、自动生图与失败降级、取消、多轮种子、
// 头像复用、应用事务与冲突、审阅校验。真库 + 脚本化 LLM/生图后端。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/upstream_error.dart';
import 'package:microscritt/data/card_studio_draft_file.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/engine/card_studio/card_diff.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/image_result.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/card_studio_controller.dart';
import 'package:microscritt/state/card_studio_draft_codec.dart';
import 'package:microscritt/state/card_studio_state.dart';
import 'package:microscritt/state/providers.dart';
import '../support/image_fixtures.dart';
import '../support/scripted_llm_backend.dart';
import '../support/test_database.dart';

class _CountingImageBackend implements ImageBackend {
  int calls = 0;
  final String base64;
  _CountingImageBackend(this.base64);

  @override
  String get id => 'fake';

  @override
  Future<ImageResult> generateImage(String prompt) async {
    calls++;
    return ImageResult.single(base64: base64);
  }
}

class _FailingImageBackend implements ImageBackend {
  @override
  String get id => 'failing';

  @override
  Future<ImageResult> generateImage(String prompt) async {
    throw Exception('provider down');
  }
}

class _GatedImageBackend implements ImageBackend {
  final Completer<void> gate = Completer<void>();
  final String base64;
  int calls = 0;
  _GatedImageBackend(this.base64);

  @override
  String get id => 'gated';

  @override
  Future<ImageResult> generateImage(String prompt) async {
    calls++;
    await gate.future;
    return ImageResult.single(base64: base64);
  }
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await openTestDb();
  });

  tearDown(() => db.db.close());

  TestWidgetsFlutterBinding.ensureInitialized();
  const fakeImageBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
      'hKmMIQAAAABJRU5ErkJggg==';
  final fakeImageHash = sha256
      .convert(base64Decode(fakeImageBase64))
      .toString();

  ProviderContainer makeContainer({
    required LlmBackend backend,
    ImageBackend? imageBackend,
    CardStudioDraftFile? draftFile,
  }) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      backendConfigProvider.overrideWith(
        (ref) => const BackendConfig(
          provider: BackendProvider.openai,
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-test',
          model: 'test-model',
          temperature: 0.8,
        ),
      ),
      backendProvider.overrideWith((ref) => backend),
      imageBackendProvider.overrideWith((ref) => imageBackend),
      appSettingsProvider.overrideWith((ref) => const AppSettings()),
      if (draftFile != null)
        cardStudioDraftFileProvider.overrideWithValue(draftFile),
    ],
  );

  Future<CardStudioDraftFile> openDraftFile() async {
    final dir = await Directory.systemTemp.createTemp(
      'card-studio-controller-',
    );
    final file = CardStudioDraftFile(dir.path);
    addTearDown(() async {
      // 控制器 dispose/apply 里的草稿写删可能是 unawaited 的排队任务;先读一次
      // 等队列落定,否则 Windows 递归删除会与在途 rename/delete 撞成
      // PathNotFoundException。清目录是尽力而为,句柄短暂占用不影响断言。
      await file.read(null);
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // 临时目录清理失败不改变用例结论。
      }
    });
    return file;
  }

  ToolCall call(String name, [Map<String, Object?> args = const {}]) =>
      ToolCall(id: 'c_$name', name: name, arguments: jsonEncode(args));

  List<LlmEvent> step(List<ToolCall> calls, {String text = ''}) => [
    if (text.isNotEmpty) TextDelta(text),
    ToolCallsEvent(calls),
    const UsageEvent(TokenUsage(inputTokens: 10, outputTokens: 5)),
    const DoneEvent(),
  ];

  List<LlmEvent> finishStep([String summary = 'done']) => step([
    call('finish', {'summary': summary}),
  ]);

  Future<void> waitFor(bool Function() condition, {String? message}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(message ?? 'condition not met within 10s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<List<Map<String, Object?>>> waitUsage(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final rows = await db.db.query('usage_records', orderBy: 'id');
      if (rows.length >= count || DateTime.now().isAfter(deadline)) {
        return rows;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'new card: agent stages card/worldbook/avatar, apply writes once',
    () async {
      final image = _CountingImageBackend(fakeImageBase64);
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {
              'name': '艾莉',
              'description': '机械师',
              'firstMessage': '你好，旅行者。',
            },
          }),
          call('upsertWorldbookEntries', {
            'entries': [
              {
                'name': '蒸汽城',
                'keys': ['蒸汽'],
                'content': '城市设定',
              },
            ],
          }),
          call('setAvatarPrompt', {'prompt': '1girl, red hair'}),
        ], text: '我先写人设'),
        finishStep('完成'),
      ]);
      final container = makeContainer(backend: backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);

      await controller.start(null);
      expect(
        container.read(cardStudioControllerProvider).phase,
        CardStudioPhase.idle,
      );
      await controller.run('写一个机械师');

      final state = container.read(cardStudioControllerProvider);
      expect(state.phase, CardStudioPhase.review);
      expect(state.draftCard!.name, '艾莉');
      expect(state.draftEntries!.single.content, '城市设定');
      expect(state.diff!.fields.any((f) => f.key == 'name'), isTrue);
      expect(state.avatarStatus, CardStudioAvatarStatus.ready);
      expect(state.draftCard!.avatarHash, fakeImageHash);
      expect(image.calls, 1);
      expect(
        state.entries.any(
          (e) => e.kind == CardStudioEntryKind.agent && e.text == '我先写人设',
        ),
        isTrue,
      );
      expect(
        state.entries.any((e) => e.kind == CardStudioEntryKind.toolStep),
        isTrue,
      );
      expect(state.canApply, isTrue);

      expect(await controller.apply(), isTrue);
      final after = container.read(cardStudioControllerProvider);
      expect(after.phase, CardStudioPhase.done);
      final id = after.appliedCharacterId!;

      final repo = CharacterRepository(db);
      final saved = await repo.get(id);
      expect(saved!.name, '艾莉');
      expect(saved.description, '机械师');
      expect(saved.firstMessage, '你好，旅行者。');
      expect(saved.avatarHash, fakeImageHash);
      expect((await db.db.query('image_assets')).single['ref_count'], 1);
      final entries = await WorldbookRepository(db).byCharacter(id);
      expect(entries.single.content, '城市设定');
    },
  );

  test('step usage anchors the context ring and cache hit rate', () async {
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          call('setCardFields', {
            'fields': {'name': '用量角色'},
          }),
        ]),
        const UsageEvent(
          TokenUsage(
            inputTokens: 1200,
            outputTokens: 30,
            cachedInputTokens: 900,
          ),
        ),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          call('finish', {'summary': 'ok'}),
        ]),
        const UsageEvent(
          TokenUsage(
            inputTokens: 1800,
            outputTokens: 20,
            cachedInputTokens: 1500,
          ),
        ),
        const DoneEvent(),
      ],
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);

    await controller.start(null);
    await controller.run('写一个角色');

    final state = container.read(cardStudioControllerProvider);
    expect(state.phase, CardStudioPhase.review);
    // 末步重发完整系统提示 + 转录,实际输入即本轮占用锚点。
    expect(state.lastRequestInputTokens, 1800);
    expect(state.lastRequestCachedInputTokens, 1500);
    expect(state.contextEstimateTokens, greaterThan(0));
  });

  test(
    'existing card: diff is against baseline and raw survives apply',
    () async {
      final repo = CharacterRepository(db);
      final charId = await repo.insert(
        const CharacterCard(
          name: '旧名',
          description: '旧描述',
          raw: {
            'spec': 'chara_card_v2',
            'data': {
              'name': '旧名',
              'character_book': {'entries': []},
            },
          },
        ),
      );
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(
          characterId: 0,
          name: '条目',
          keys: ['k'],
          content: '旧内容',
          position: 0,
        ),
      ]);
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'description': '新描述'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);

      await controller.start(charId);
      await controller.run('优化描述');

      final state = container.read(cardStudioControllerProvider);
      expect(state.diff!.fields.single.key, 'description');
      expect(state.diff!.entries, isEmpty);
      // 新一轮提示词里带既有卡内容。
      expect(backend.requests.first.variableSystemPart, contains('旧名'));

      expect(await controller.apply(), isTrue);
      final saved = await repo.get(charId);
      expect(saved!.name, '旧名');
      expect(saved.description, '新描述');
      expect(saved.raw['spec'], 'chara_card_v2');
      expect(saved.raw['data']['character_book'], isNotNull);
      final entries = await WorldbookRepository(db).byCharacter(charId);
      expect(entries.single.content, '旧内容', reason: '未改动条目原样保留');
    },
  );

  test('avatar failure degrades to review and does not block apply', () async {
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'name': '无头图'},
        }),
        call('setAvatarPrompt', {'prompt': '1girl'}),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(
      backend: backend,
      imageBackend: _FailingImageBackend(),
    );
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);

    await controller.start(null);
    await controller.run('做一个角色');

    final state = container.read(cardStudioControllerProvider);
    expect(state.avatarStatus, CardStudioAvatarStatus.failed);
    expect(state.avatarError, contains('失败'));
    expect(state.canApply, isTrue);
    expect(await controller.apply(), isTrue);
    final id = container.read(cardStudioControllerProvider).appliedCharacterId!;
    expect((await CharacterRepository(db).get(id))!.avatarHash, isNull);
  });

  test('missing LLM backend fails fast without calling the model', () async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendConfigProvider.overrideWith((ref) => null),
        backendProvider.overrideWith((ref) => null),
        imageBackendProvider.overrideWith((ref) => null),
        appSettingsProvider.overrideWith((ref) => const AppSettings()),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);
    await controller.run('brief');

    final state = container.read(cardStudioControllerProvider);
    expect(state.phase, CardStudioPhase.failed);
    expect(state.error, contains('未配置 LLM'));
    expect(state.entries.last.kind, CardStudioEntryKind.error);
  });

  test('cancel returns to idle without a proposal', () async {
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        [const TextDelta('partial'), const DoneEvent()],
      ],
      gates: {0: gate},
    );
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);

    final runFuture = controller.run('brief');
    await waitFor(() => backend.calls == 1);
    controller.cancel();
    await runFuture;
    gate.complete();

    final state = container.read(cardStudioControllerProvider);
    expect(state.phase, CardStudioPhase.idle);
    expect(state.diff, isNull);
    expect(state.entries.last.text, contains('已取消'));
  });

  test(
    'continueAdjust seeds the next run with accepted changes only',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': 'A'},
          }),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'name': 'B'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);

      await controller.run('第一轮');
      expect(container.read(cardStudioControllerProvider).draftCard!.name, 'A');

      await controller.continueAdjust('改成 B');
      final state = container.read(cardStudioControllerProvider);
      expect(state.draftCard!.name, 'B');
      // 第二轮请求的 current_draft 是上一轮已接受的种子。
      expect(backend.requests[2].variableSystemPart, contains('A'));

      expect(await controller.apply(), isTrue);
      final id = container
          .read(cardStudioControllerProvider)
          .appliedCharacterId!;
      expect((await CharacterRepository(db).get(id))!.name, 'B');
    },
  );

  test('rejected decisions are dropped from the refinement seed', () async {
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'name': 'A'},
        }),
      ]),
      finishStep(),
      step([
        call('setCardFields', {
          'fields': {'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);
    await controller.run('第一轮');

    controller.toggleField('name', false);
    await controller.continueAdjust('继续');
    expect(
      backend.requests[2].variableSystemPart,
      isNot(contains('A')),
      reason: '被拒绝的字段不得进入下一轮种子',
    );
  });

  test(
    'unchanged avatar prompt reuses the generated image (no double billing)',
    () async {
      final image = _CountingImageBackend(fakeImageBase64);
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': 'A'},
          }),
          call('setAvatarPrompt', {'prompt': '1girl, red hair'}),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'description': 'D'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('第一轮');
      expect(image.calls, 1);

      await controller.continueAdjust('继续');
      expect(image.calls, 1);
      expect(
        container.read(cardStudioControllerProvider).avatarStatus,
        CardStudioAvatarStatus.ready,
      );
    },
  );

  test(
    'apply rejects invalid edited entries; conflict requires force',
    () async {
      final repo = CharacterRepository(db);
      final charId = await repo.insert(const CharacterCard(name: '原名'));
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'description': '新描述'},
          }),
          call('upsertWorldbookEntries', {
            'entries': [
              {
                'name': 'W',
                'keys': ['w'],
                'content': '内容',
              },
            ],
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(charId);
      await controller.run('改');
      final state = container.read(cardStudioControllerProvider);
      final entryDiff = state.diff!.entries.first;

      controller.editEntry(
        entryDiff.reviewKey,
        entryDiff.newEntry!.copyWith(content: ''),
      );
      expect(await controller.apply(), isFalse);
      expect(
        container.read(cardStudioControllerProvider).applyErrors.join(),
        contains('内容不能为空'),
      );

      // 恢复后,模拟其他页面改了角色名 → 冲突,需 force 覆盖。
      controller.editEntry(entryDiff.reviewKey, entryDiff.newEntry!);
      await repo.update(charId, const CharacterCard(name: '被改名'));
      expect(await controller.apply(), isFalse);
      expect(
        container.read(cardStudioControllerProvider).conflictWarning,
        isNotNull,
      );
      expect(await controller.apply(force: true), isTrue);
      final saved = await repo.get(charId);
      expect(saved!.name, '原名', reason: '强制覆盖使用制卡基线的名字');
      expect(saved.description, '新描述');
    },
  );

  test('records per-step usage as card kind without a session', () async {
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'name': 'A'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);
    await controller.run('brief');

    final rows = await waitUsage(2);
    expect(rows, hasLength(2));
    expect(rows.map((r) => r['kind']), everyElement('card'));
    expect(rows.map((r) => r['session_id']), everyElement(isNull));
    expect(rows.map((r) => r['reported']), everyElement(1));
    expect(rows.fold<int>(0, (s, r) => s + (r['input_tokens'] as int)), 20);
  });

  test('failed steps still count as unreported card requests', () async {
    final backend = ScriptedLlmBackend([
      [const ErrorEvent('boom'), const DoneEvent()],
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);
    await controller.run('brief');

    final rows = await waitUsage(1);
    expect(rows, hasLength(1));
    expect(rows.single['kind'], 'card');
    expect(rows.single['reported'], 0);
    expect(rows.single['input_tokens'], 0);
  });

  test('rejecting every change blocks apply until one is accepted', () async {
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'name': 'A', 'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);
    await controller.run('brief');

    final diff = container.read(cardStudioControllerProvider).diff!;
    for (final field in diff.fields) {
      controller.toggleField(field.key, false);
    }
    var state = container.read(cardStudioControllerProvider);
    expect(state.changeCount, 2);
    expect(state.acceptedChangeCount, 0);
    expect(state.canApply, isFalse);
    expect(await controller.apply(), isFalse);

    controller.toggleField(diff.fields.first.key, true);
    state = container.read(cardStudioControllerProvider);
    expect(state.acceptedChangeCount, 1);
    expect(state.canApply, isTrue);
  });

  test(
    'editing a field back to baseline drops it from the accepted count',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': 'A'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('brief');

      final field = container
          .read(cardStudioControllerProvider)
          .diff!
          .fields
          .single;
      controller.editField(field.key, field.oldText);
      final state = container.read(cardStudioControllerProvider);
      expect(state.acceptedChangeCount, 0);
      expect(state.canApply, isFalse);
    },
  );

  test(
    'continueAfterApply keeps the applied card as the next baseline',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': 'A', 'description': 'D'},
          }),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'description': 'D2'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('first');
      expect(await controller.apply(), isTrue);

      controller.continueAfterApply();
      var state = container.read(cardStudioControllerProvider);
      expect(state.phase, CardStudioPhase.idle);
      expect(state.draftCard, isNull);
      expect(state.baseCard.name, 'A');
      expect(state.baseCard.description, 'D');
      expect(state.entries, isNotEmpty);

      await controller.run('second');
      state = container.read(cardStudioControllerProvider);
      final field = state.diff!.fields.single;
      expect(field.key, 'description');
      expect(field.oldText, 'D');
      expect(await controller.apply(), isTrue);

      final doneState = container.read(cardStudioControllerProvider);
      final saved = await CharacterRepository(
        db,
      ).get(doneState.appliedCharacterId!);
      expect(saved!.name, 'A');
      expect(saved.description, 'D2');
    },
  );

  test(
    'applied avatar prompt is reused after continue (no double billing)',
    () async {
      final image = _CountingImageBackend(fakeImageBase64);
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': 'A'},
          }),
          call('setAvatarPrompt', {'prompt': '1girl, red hair'}),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'description': 'D'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('first');
      expect(image.calls, 1);
      expect(await controller.apply(), isTrue);

      controller.continueAfterApply();
      await controller.run('second');
      expect(image.calls, 1);
    },
  );

  test('card conflict covers non-description fields', () async {
    final repo = CharacterRepository(db);
    final charId = await repo.insert(
      const CharacterCard(name: 'A', personality: 'P'),
    );
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(charId);
    await controller.run('改');

    await repo.update(
      charId,
      const CharacterCard(name: 'A', personality: 'P2'),
    );
    expect(await controller.apply(), isFalse);
    expect(
      container.read(cardStudioControllerProvider).conflictWarning,
      contains('角色卡'),
    );
  });

  test('external worldbook edits trigger conflict; force overwrites', () async {
    final repo = CharacterRepository(db);
    final wbRepo = WorldbookRepository(db);
    final charId = await repo.insertWithWorldbook(
      const CharacterCard(name: 'A'),
      const [
        WorldbookEntry(characterId: 0, name: 'W', keys: ['w'], content: 'old'),
      ],
    );
    final stored = await wbRepo.byCharacter(charId);
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(charId);
    await controller.run('改');

    await wbRepo.replaceForCharacter(charId, [
      stored.single.copyWith(content: 'external'),
    ]);
    expect(await controller.apply(), isFalse);
    expect(
      container.read(cardStudioControllerProvider).conflictWarning,
      contains('世界书'),
    );
    expect(await controller.apply(force: true), isTrue);
    final saved = await wbRepo.byCharacter(charId);
    expect(saved.single.content, 'old');
  });

  test(
    'draft saves on detach, restores in a new controller, apply clears it',
    () async {
      final draftFile = await openDraftFile();
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': '草稿名', 'description': '草稿描述'},
          }),
        ]),
        finishStep(),
      ]);
      final c1 = makeContainer(backend: backend, draftFile: draftFile);
      final controller1 = c1.read(cardStudioControllerProvider.notifier);
      await controller1.start(null);
      await controller1.run('写一个草稿');
      final field = c1.read(cardStudioControllerProvider).diff!.fields.first;
      controller1.editField(field.key, '草稿编辑');
      controller1.detach();
      c1.dispose();

      CardStudioDraftSnapshot? saved;
      for (var i = 0; i < 100 && saved == null; i++) {
        final payload = await draftFile.read(null);
        if (payload != null) saved = decodeCardStudioDraft(payload);
        if (saved == null) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(saved, isNotNull);
      expect(saved!.decisions.field(field.key).editedText, '草稿编辑');

      final c2 = makeContainer(
        backend: ScriptedLlmBackend([
          [const DoneEvent()],
        ]),
        draftFile: draftFile,
      );
      addTearDown(c2.dispose);
      final controller2 = c2.read(cardStudioControllerProvider.notifier);
      await controller2.start(null);
      final restored = c2.read(cardStudioControllerProvider);
      expect(restored.phase, CardStudioPhase.review);
      expect(restored.draftCard?.name, '草稿名');
      expect(restored.draftCard?.description, '草稿描述');
      expect(restored.decisions.field(field.key).editedText, '草稿编辑');
      expect(
        restored.entries.any(
          (e) => e.kind == CardStudioEntryKind.notice && e.text.contains('已恢复'),
        ),
        isTrue,
      );

      expect(await controller2.apply(), isTrue);
      expect(await draftFile.read(null), isNull);
    },
  );

  test(
    'multi-round new entries get distinct temp ids and both apply',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': '多轮卡'},
          }),
          call('upsertWorldbookEntries', {
            'entries': [
              {
                'name': 'A',
                'keys': ['a'],
                'content': 'A',
              },
            ],
          }),
        ]),
        finishStep(),
        step([
          call('upsertWorldbookEntries', {
            'entries': [
              {
                'name': 'B',
                'keys': ['b'],
                'content': 'B',
              },
            ],
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('第一轮');
      await controller.continueAdjust('第二轮');

      final diff = container.read(cardStudioControllerProvider).diff!;
      expect(
        diff.entries.map((e) => e.reviewKey),
        containsAll(['new:-1', 'new:-2']),
      );
      expect(diff.entries, hasLength(2));
      expect(await controller.apply(), isTrue);

      final state = container.read(cardStudioControllerProvider);
      final entries = await WorldbookRepository(
        db,
      ).byCharacter(state.appliedCharacterId!);
      expect(entries.map((e) => e.name), containsAll(['A', 'B']));
    },
  );

  test(
    'discard clears the draft and a late debounce cannot resurrect it',
    () async {
      final draftFile = await openDraftFile();
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': '丢弃卡'},
          }),
          call('setAvatarPrompt', {'prompt': '1girl'}),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(
        backend: backend,
        imageBackend: _CountingImageBackend(fakeImageBase64),
        draftFile: draftFile,
      );
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('brief');

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await draftFile.read(null), isNotNull);
      expect(await testImageRefCount(db, fakeImageHash), 1);

      final field = container
          .read(cardStudioControllerProvider)
          .diff!
          .fields
          .first;
      controller.editField(field.key, '迟到编辑');
      controller.discardDraft();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(await draftFile.read(null), isNull);
      expect(await testImageRefCount(db, fakeImageHash), 0);
      final state = container.read(cardStudioControllerProvider);
      expect(state.phase, CardStudioPhase.idle);
      expect(state.draftCard, isNull);
      expect(state.entries.single.text, contains('已丢弃'));
    },
  );

  test('context usage anchors survive draft detach and restore', () async {
    final draftFile = await openDraftFile();
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          call('setCardFields', {
            'fields': {'name': '用量卡'},
          }),
        ]),
        const UsageEvent(
          TokenUsage(
            inputTokens: 1200,
            outputTokens: 20,
            cachedInputTokens: 900,
          ),
        ),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          call('finish', {'summary': '完成'}),
        ]),
        const UsageEvent(
          TokenUsage(
            inputTokens: 1800,
            outputTokens: 10,
            cachedInputTokens: 1500,
          ),
        ),
        const DoneEvent(),
      ],
    ]);
    final c1 = makeContainer(backend: backend, draftFile: draftFile);
    final controller1 = c1.read(cardStudioControllerProvider.notifier);
    await controller1.start(null);
    await controller1.run('写一张卡');

    final before = c1.read(cardStudioControllerProvider);
    expect(before.lastRequestInputTokens, 1800);
    expect(before.lastRequestCachedInputTokens, 1500);
    expect(before.contextEstimateTokens, greaterThan(0));
    controller1.detach();
    c1.dispose();

    CardStudioDraftSnapshot? saved;
    for (var i = 0; i < 100 && saved == null; i++) {
      final payload = await draftFile.read(null);
      if (payload != null) saved = decodeCardStudioDraft(payload);
      if (saved == null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(saved, isNotNull);
    expect(saved!.lastRequestInputTokens, 1800);
    expect(saved.lastRequestCachedInputTokens, 1500);
    expect(saved.contextEstimateTokens, before.contextEstimateTokens);

    final c2 = makeContainer(
      backend: ScriptedLlmBackend([
        [const DoneEvent()],
      ]),
      draftFile: draftFile,
    );
    addTearDown(c2.dispose);
    await c2.read(cardStudioControllerProvider.notifier).start(null);
    final restored = c2.read(cardStudioControllerProvider);
    expect(restored.lastRequestInputTokens, 1800);
    expect(restored.lastRequestCachedInputTokens, 1500);
    expect(restored.contextEstimateTokens, before.contextEstimateTokens);
  });

  test('restored avatar prompt reuses the generated image', () async {
    final draftFile = await openDraftFile();
    final image = _CountingImageBackend(fakeImageBase64);
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'name': '头像卡'},
        }),
        call('setAvatarPrompt', {'prompt': '1girl'}),
      ]),
      finishStep(),
      step([
        call('setCardFields', {
          'fields': {'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final c1 = makeContainer(
      backend: backend,
      imageBackend: image,
      draftFile: draftFile,
    );
    final controller1 = c1.read(cardStudioControllerProvider.notifier);
    await controller1.start(null);
    await controller1.run('第一轮');
    expect(image.calls, 1);
    controller1.detach();
    c1.dispose();

    final c2 = makeContainer(
      backend: backend,
      imageBackend: image,
      draftFile: draftFile,
    );
    addTearDown(c2.dispose);
    final controller2 = c2.read(cardStudioControllerProvider.notifier);
    await controller2.start(null);
    expect(
      c2.read(cardStudioControllerProvider).draftCard?.avatarHash,
      fakeImageHash,
    );

    await controller2.run('第二轮');
    expect(image.calls, 1, reason: '恢复的提示词/生成凭据应复用头像');
  });

  test('restored draft reports external baseline changes on apply', () async {
    final repo = CharacterRepository(db);
    final charId = await repo.insert(
      const CharacterCard(name: '原名', personality: '旧'),
    );
    final draftFile = await openDraftFile();
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'description': '新描述'},
        }),
      ]),
      finishStep(),
    ]);
    final c1 = makeContainer(backend: backend, draftFile: draftFile);
    final controller1 = c1.read(cardStudioControllerProvider.notifier);
    await controller1.start(charId);
    await controller1.run('改');
    controller1.detach();
    c1.dispose();

    await repo.update(
      charId,
      const CharacterCard(name: '原名', personality: '外部改'),
    );

    final c2 = makeContainer(
      backend: ScriptedLlmBackend([
        [const DoneEvent()],
      ]),
      draftFile: draftFile,
    );
    addTearDown(c2.dispose);
    final controller2 = c2.read(cardStudioControllerProvider.notifier);
    await controller2.start(charId);
    expect(
      c2
          .read(cardStudioControllerProvider)
          .entries
          .any((e) => e.text.contains('应用时会提示冲突')),
      isTrue,
    );

    expect(await controller2.apply(), isFalse);
    expect(
      c2.read(cardStudioControllerProvider).conflictWarning,
      contains('角色卡'),
    );
    expect(await controller2.apply(force: true), isTrue);
    final saved = await repo.get(charId);
    expect(saved!.personality, '旧', reason: 'force 用草稿基线覆盖外部修改');
    expect(saved.description, '新描述');
  });

  test('session after apply + continue survives detach and restores', () async {
    final repo = CharacterRepository(db);
    final charId = await repo.insert(
      const CharacterCard(name: '原名', description: '旧描述'),
    );
    final draftFile = await openDraftFile();
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'description': '新描述'},
        }),
      ]),
      finishStep(),
    ]);
    final c1 = makeContainer(backend: backend, draftFile: draftFile);
    final controller1 = c1.read(cardStudioControllerProvider.notifier);
    await controller1.start(charId);
    await controller1.run('第一轮');
    expect(await controller1.apply(), isTrue);
    controller1.continueAfterApply();
    controller1.detach();
    c1.dispose();

    final payload = await draftFile.read(charId);
    expect(payload, isNotNull, reason: '继续打磨的会话也要落盘');

    final c2 = makeContainer(
      backend: ScriptedLlmBackend([
        [const DoneEvent()],
      ]),
      draftFile: draftFile,
    );
    addTearDown(c2.dispose);
    final controller2 = c2.read(cardStudioControllerProvider.notifier);
    await controller2.start(charId);
    final restored = c2.read(cardStudioControllerProvider);
    expect(restored.phase, CardStudioPhase.idle);
    expect(restored.hasProposal, isFalse);
    expect(restored.hasSession, isTrue);
    expect(restored.baseCard.description, '新描述');
    expect(
      restored.entries.any(
        (e) => e.kind == CardStudioEntryKind.user && e.text == '第一轮',
      ),
      isTrue,
      reason: '恢复制卡对话',
    );
    expect(restored.entries.any((e) => e.text.contains('已恢复上次制卡对话')), isTrue);
    expect(
      restored.entries.any((e) => e.text.contains('应用时会提示冲突')),
      isFalse,
      reason: '无提案的会话恢复不提示冲突',
    );
  });

  test(
    'restored session adopts the current DB baseline after external edits',
    () async {
      final repo = CharacterRepository(db);
      final charId = await repo.insert(
        const CharacterCard(name: '原名', description: '旧描述'),
      );
      final draftFile = await openDraftFile();
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'description': '新描述'},
          }),
        ]),
        finishStep(),
      ]);
      final c1 = makeContainer(backend: backend, draftFile: draftFile);
      final controller1 = c1.read(cardStudioControllerProvider.notifier);
      await controller1.start(charId);
      await controller1.run('第一轮');
      expect(await controller1.apply(), isTrue);
      controller1.continueAfterApply();
      controller1.detach();
      c1.dispose();

      await repo.update(
        charId,
        const CharacterCard(name: '原名', description: '新描述', personality: '外部改'),
      );

      final c2 = makeContainer(
        backend: ScriptedLlmBackend([
          step([
            call('setCardFields', {
              'fields': {'scenario': 'S'},
            }),
          ]),
          finishStep(),
        ]),
        draftFile: draftFile,
      );
      addTearDown(c2.dispose);
      final controller2 = c2.read(cardStudioControllerProvider.notifier);
      await controller2.start(charId);
      expect(
        c2.read(cardStudioControllerProvider).baseCard.personality,
        '外部改',
        reason: '会话恢复以当前库为基线',
      );

      await controller2.run('第二轮');
      expect(await controller2.apply(), isTrue);
      final saved = await repo.get(charId);
      expect(saved!.personality, '外部改');
      expect(saved.scenario, 'S');
    },
  );

  test('discard clears a restored session-only draft', () async {
    final repo = CharacterRepository(db);
    final charId = await repo.insert(const CharacterCard(name: 'A'));
    final draftFile = await openDraftFile();
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final c1 = makeContainer(backend: backend, draftFile: draftFile);
    final controller1 = c1.read(cardStudioControllerProvider.notifier);
    await controller1.start(charId);
    await controller1.run('第一轮');
    expect(await controller1.apply(), isTrue);
    controller1.continueAfterApply();
    controller1.detach();
    c1.dispose();

    final c2 = makeContainer(
      backend: ScriptedLlmBackend([
        [const DoneEvent()],
      ]),
      draftFile: draftFile,
    );
    addTearDown(c2.dispose);
    final controller2 = c2.read(cardStudioControllerProvider.notifier);
    await controller2.start(charId);
    expect(c2.read(cardStudioControllerProvider).hasSession, isTrue);

    controller2.discardDraft();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await draftFile.read(charId), isNull);
    final state = c2.read(cardStudioControllerProvider);
    expect(state.hasSession, isFalse);
    expect(state.entries.single.text, contains('已丢弃'));
  });

  test(
    'applied entries adopt DB ids so the next round has no phantom diff',
    () async {
      final repo = CharacterRepository(db);
      final wbRepo = WorldbookRepository(db);
      final charId = await repo.insert(
        const CharacterCard(name: '原名', description: '旧描述'),
      );
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'description': '新描述'},
          }),
          call('upsertWorldbookEntries', {
            'entries': [
              {
                'name': 'W1',
                'keys': ['w1'],
                'content': '内容一',
              },
            ],
          }),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'scenario': '场景'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(charId);
      await controller.run('第一轮');
      expect(await controller.apply(), isTrue);
      final stored = await wbRepo.byCharacter(charId);
      expect(stored.single.id, greaterThan(0));

      controller.continueAfterApply();
      var state = container.read(cardStudioControllerProvider);
      expect(
        state.baseEntries.single.id,
        stored.single.id,
        reason: '应用后基线应换成库里的真实 id,而不是负临时 id',
      );

      await controller.run('第二轮');
      state = container.read(cardStudioControllerProvider);
      expect(state.diff!.entries, isEmpty, reason: '已应用条目不应再次以删除+新增出现');
      expect(state.diff!.fields.map((f) => f.key), ['scenario']);
      expect(await controller.apply(), isTrue);
      final after = await wbRepo.byCharacter(charId);
      expect(after.single.id, stored.single.id, reason: '再次应用不应让条目 id 漂移');
      expect(after.single.content, '内容一');
    },
  );

  test(
    'legacy session draft with temp entry ids restores without phantom diff',
    () async {
      final repo = CharacterRepository(db);
      final wbRepo = WorldbookRepository(db);
      final charId = await repo.insertWithWorldbook(
        const CharacterCard(name: '旧卡'),
        const [
          WorldbookEntry(characterId: 0, name: 'W', keys: ['w'], content: 'c'),
        ],
      );
      final stored = (await wbRepo.byCharacter(charId)).single;
      final legacy = stored.copyWith(id: -1);
      final card = (await repo.get(charId))!;
      final draftFile = await openDraftFile();
      await draftFile.write(
        charId,
        encodeCardStudioDraft(
          CardStudioDraftSnapshot(
            targetCharacterId: charId,
            baseCard: card,
            baseEntries: [legacy],
            draftCard: card,
            draftEntries: [legacy],
            decisions: ReviewDecisions.acceptAll,
            entries: const [
              CardStudioEntry.user('上次的调整'),
              CardStudioEntry.notice('已应用，可继续描述要调整的内容。'),
            ],
            sessionLog: const ['用户：上次的调整'],
          ),
        ),
      );

      final c = makeContainer(
        backend: ScriptedLlmBackend([
          [const DoneEvent()],
        ]),
        draftFile: draftFile,
      );
      addTearDown(c.dispose);
      final controller = c.read(cardStudioControllerProvider.notifier);
      await controller.start(charId);
      final restored = c.read(cardStudioControllerProvider);
      expect(restored.phase, CardStudioPhase.idle);
      expect(restored.hasProposal, isFalse);
      expect(restored.diff, isNull);
      expect(restored.baseEntries.single.id, stored.id);
    },
  );

  test(
    'legacy proposal with temp entry ids remaps to DB ids on apply',
    () async {
      final repo = CharacterRepository(db);
      final wbRepo = WorldbookRepository(db);
      final charId = await repo.insertWithWorldbook(
        const CharacterCard(name: '旧卡'),
        const [
          WorldbookEntry(
            characterId: 0,
            name: 'W',
            keys: ['w'],
            content: 'old',
          ),
        ],
      );
      final stored = (await wbRepo.byCharacter(charId)).single;
      final base = stored.copyWith(id: -1);
      final draft = stored.copyWith(id: -1, content: 'new');
      final card = (await repo.get(charId))!;
      final draftFile = await openDraftFile();
      await draftFile.write(
        charId,
        encodeCardStudioDraft(
          CardStudioDraftSnapshot(
            targetCharacterId: charId,
            baseCard: card,
            baseEntries: [base],
            draftCard: card,
            draftEntries: [draft],
            decisions: ReviewDecisions.acceptAll,
            entries: const [CardStudioEntry.user('改条目')],
            sessionLog: const ['用户：改条目'],
          ),
        ),
      );

      final c = makeContainer(
        backend: ScriptedLlmBackend([
          [const DoneEvent()],
        ]),
        draftFile: draftFile,
      );
      addTearDown(c.dispose);
      final controller = c.read(cardStudioControllerProvider.notifier);
      await controller.start(charId);
      final restored = c.read(cardStudioControllerProvider);
      expect(restored.phase, CardStudioPhase.review);
      final entryDiff = restored.diff!.entries.single;
      expect(entryDiff.kind, WorldbookChangeKind.modified);
      expect(entryDiff.baseId, stored.id);
      expect(entryDiff.oldEntry!.content, 'old');
      expect(entryDiff.newEntry!.content, 'new');
      expect(restored.conflictWarning, isNull);

      expect(await controller.apply(), isTrue);
      final saved = await wbRepo.byCharacter(charId);
      expect(saved.single.id, stored.id, reason: '旧草稿的临时 id 不应导致重新插入');
      expect(saved.single.content, 'new');
    },
  );

  test('re-entering after leaving mid-run recovers from the stale busy phase',
      () async {
    final repo = CharacterRepository(db);
    final charId = await repo.insert(const CharacterCard(name: 'A'));
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final c = makeContainer(backend: backend);
    addTearDown(c.dispose);
    final controller = c.read(cardStudioControllerProvider.notifier);
    await controller.start(charId);

    final running = controller.run('改');
    controller.detach();
    await running;
    // 旧页面退出时 phase 可能停在 running/preparing;再次进入必须能接管。
    await controller.start(charId);
    final state = c.read(cardStudioControllerProvider);
    expect(state.busy, isFalse);
    expect(state.loaded, isTrue);
    expect(state.phase, CardStudioPhase.idle);
  });

  test('leaving during apply still clears the persisted proposal', () async {    final repo = CharacterRepository(db);
    final charId = await repo.insert(const CharacterCard(name: 'A'));
    final draftFile = await openDraftFile();
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'description': 'D'},
        }),
      ]),
      finishStep(),
    ]);
    final c1 = makeContainer(backend: backend, draftFile: draftFile);
    addTearDown(c1.dispose);
    final controller1 = c1.read(cardStudioControllerProvider.notifier);
    await controller1.start(charId);
    await controller1.run('改');
    for (var i = 0; i < 100 && await draftFile.read(charId) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await draftFile.read(charId), isNotNull, reason: '提案应已防抖落盘');

    // 写库期间退出页面:detach 会置空控制器的草稿文件引用,但写库继续完成。
    final applying = controller1.apply();
    controller1.detach();
    expect(await applying, isTrue);
    expect(await draftFile.read(charId), isNull, reason: '应用成功后必须清理已捕获的草稿文件');

    final c2 = makeContainer(
      backend: ScriptedLlmBackend([
        [const DoneEvent()],
      ]),
      draftFile: draftFile,
    );
    addTearDown(c2.dispose);
    final controller2 = c2.read(cardStudioControllerProvider.notifier);
    await controller2.start(charId);
    final restored = c2.read(cardStudioControllerProvider);
    expect(restored.hasProposal, isFalse);
    expect(restored.entries, isEmpty);
  });

  test('disposeStudio resets conversation and draft', () async {
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'name': 'A'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);
    await controller.run('brief');
    expect(container.read(cardStudioControllerProvider).entries, isNotEmpty);

    controller.disposeStudio();
    final state = container.read(cardStudioControllerProvider);
    expect(state.phase, CardStudioPhase.idle);
    expect(state.entries, isEmpty);
    expect(state.draftCard, isNull);
  });

  test(
    'editing the latest instruction rewinds and reruns from the pre-turn seed',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'description': '旧轮描述'},
          }),
        ]),
        finishStep('第一轮完成'),
        step([
          call('setCardFields', {
            'fields': {'name': '新名'},
          }),
        ]),
        finishStep('重跑完成'),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('第一轮指令');

      var state = container.read(cardStudioControllerProvider);
      expect(state.draftCard!.description, '旧轮描述');
      expect(controller.latestUserInstructionIndex, 0);
      expect(controller.instructionEditBlockedReasonFor(0), isNull);
      expect(
        controller.latestTurnProducedChanges,
        isTrue,
        reason: '成功轮有实际修改,编辑需提示撤回',
      );

      expect(await controller.editLastInstruction('修改后的指令'), isNull);

      state = container.read(cardStudioControllerProvider);
      expect(state.phase, CardStudioPhase.review);
      expect(state.draftCard!.description, isEmpty, reason: '撤回后种子回到轮前基线');
      expect(state.draftCard!.name, '新名');
      expect(
        state.entries
            .where((e) => e.kind == CardStudioEntryKind.user)
            .map((e) => e.text),
        ['修改后的指令'],
      );
      expect(state.entries.any((e) => e.text.contains('第一轮完成')), isFalse);
      final rerunRequest = backend.requests[2];
      expect(rerunRequest.messages.first.content, contains('修改后的指令'));
      expect(rerunRequest.variableSystemPart, isNot(contains('第一轮指令')));
      expect(rerunRequest.variableSystemPart, isNot(contains('第一轮完成')));
      expect(await CharacterRepository(db).all(), isEmpty, reason: '编辑重跑不触碰库');
    },
  );

  test(
    'editing only withdraws the latest turn; earlier accepted changes stay',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'description': '第一轮描述'},
          }),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'name': 'B名'},
          }),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'personality': '新性格'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('第一轮');
      await controller.continueAdjust('第二轮');

      final latest = controller.latestUserInstructionIndex!;
      expect(controller.instructionEditBlockedReasonFor(0), '仅最近一条指令可修改');
      expect(controller.instructionEditBlockedReasonFor(latest), isNull);

      expect(await controller.editLastInstruction('第二轮改'), isNull);

      final state = container.read(cardStudioControllerProvider);
      expect(state.draftCard!.description, '第一轮描述', reason: '第一轮已接纳内容保留在种子');
      expect(state.draftCard!.name, isEmpty, reason: '第二轮结果被撤回');
      expect(state.draftCard!.personality, '新性格');
      expect(
        state.entries
            .where((e) => e.kind == CardStudioEntryKind.user)
            .map((e) => e.text),
        ['第一轮', '第二轮改'],
      );
      final rerun = backend.requests[4];
      expect(rerun.variableSystemPart, contains('第一轮描述'));
      expect(rerun.variableSystemPart, isNot(contains('B名')));
    },
  );

  test(
    'a failed turn can be edited and its stale error entries are removed',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': 'A'},
          }),
        ]),
        finishStep(),
        const [ErrorEvent('boom', kind: UpstreamErrorKind.contractViolation)],
        step([
          call('setCardFields', {
            'fields': {'description': 'D'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('第一轮');
      await controller.continueAdjust('第二轮');

      var state = container.read(cardStudioControllerProvider);
      expect(state.phase, CardStudioPhase.failed);
      final latest = controller.latestUserInstructionIndex!;
      expect(controller.instructionEditBlockedReasonFor(latest), isNull);
      expect(
        state.entries.any((e) => e.kind == CardStudioEntryKind.error),
        isTrue,
      );
      expect(
        controller.latestTurnProducedChanges,
        isFalse,
        reason: '失败轮没有实际修改,编辑不应提示撤回',
      );

      expect(await controller.editLastInstruction('第二轮改'), isNull);

      state = container.read(cardStudioControllerProvider);
      expect(state.phase, CardStudioPhase.review);
      expect(
        state.entries.any((e) => e.kind == CardStudioEntryKind.error),
        isFalse,
      );
      expect(
        state.entries
            .where((e) => e.kind == CardStudioEntryKind.user)
            .map((e) => e.text),
        ['第一轮', '第二轮改'],
      );
      expect(state.draftCard!.name, 'A');
      expect(state.draftCard!.description, 'D');
    },
  );

  test('a cancelled turn is consequence-free to edit', () async {
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        [const TextDelta('partial'), const DoneEvent()],
        step([
          call('setCardFields', {
            'fields': {'name': '重跑名'},
          }),
        ]),
        finishStep(),
      ],
      gates: {0: gate},
    );
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);

    final runFuture = controller.run('会取消的指令');
    await waitFor(() => backend.calls == 1);
    controller.cancel();
    await runFuture;
    gate.complete();

    var state = container.read(cardStudioControllerProvider);
    expect(state.phase, CardStudioPhase.idle);
    expect(state.draftCard, isNull);
    expect(
      controller.latestTurnProducedChanges,
      isFalse,
      reason: '取消轮没有实际修改,编辑不应提示撤回',
    );
    final index = controller.latestUserInstructionIndex!;
    expect(controller.instructionEditBlockedReasonFor(index), isNull);

    expect(await controller.editLastInstruction('改后的指令'), isNull);

    state = container.read(cardStudioControllerProvider);
    expect(state.phase, CardStudioPhase.review);
    expect(state.draftCard!.name, '重跑名');
    expect(
      state.entries.any((e) => e.text.contains('已取消')),
      isFalse,
      reason: '取消通知随该轮一起截断',
    );
    expect(
      state.entries
          .where((e) => e.kind == CardStudioEntryKind.user)
          .map((e) => e.text),
      ['改后的指令'],
    );
    expect(backend.requests.last.messages.first.content, contains('改后的指令'));
    expect(await CharacterRepository(db).all(), isEmpty, reason: '全程不触碰库');
  });

  test('a turn producing no changes is consequence-free to edit', () async {
    final backend = ScriptedLlmBackend([
      finishStep('无需修改'),
      step([
        call('setCardFields', {
          'fields': {'name': 'A'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);

    await controller.run('先看看');
    var state = container.read(cardStudioControllerProvider);
    expect(state.phase, CardStudioPhase.review);
    expect(state.diff!.hasChanges, isFalse);
    expect(controller.latestTurnProducedChanges, isFalse, reason: '空结果轮编辑没有后果');

    expect(await controller.editLastInstruction('真的改一下'), isNull);
    state = container.read(cardStudioControllerProvider);
    expect(state.draftCard!.name, 'A');
    expect(
      state.entries
          .where((e) => e.kind == CardStudioEntryKind.user)
          .map((e) => e.text),
      ['真的改一下'],
    );
  });

  test('a generated avatar counts as turn results for edit warnings', () async {
    final image = _CountingImageBackend(fakeImageBase64);
    final backend = ScriptedLlmBackend([
      step([
        call('setAvatarPrompt', {'prompt': '1girl, silver hair'}),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend, imageBackend: image);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);

    await controller.run('只换头像');
    final state = container.read(cardStudioControllerProvider);
    expect(state.draftCard!.avatarHash, fakeImageHash);
    expect(image.calls, 1);
    expect(
      controller.latestTurnProducedChanges,
      isTrue,
      reason: '新生成的头像属于本轮产出,编辑撤回会丢弃,需提示',
    );
  });

  test('editing is rejected while a run is in flight', () async {
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        [const TextDelta('partial'), const DoneEvent()],
      ],
      gates: {0: gate},
    );
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);

    final running = controller.run('慢指令');
    await waitFor(() => backend.calls == 1);
    final index = controller.latestUserInstructionIndex!;
    expect(controller.instructionEditBlockedReasonFor(index), '正在生成或应用中');
    expect(await controller.editLastInstruction('改'), '正在生成或应用中');
    expect(backend.calls, 1);

    controller.cancel();
    await running;
    gate.complete();
    expect(
      container.read(cardStudioControllerProvider).phase,
      CardStudioPhase.idle,
    );
  });

  test(
    'applied instructions stay read-only until a new instruction is sent',
    () async {
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': 'A'},
          }),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'description': 'D'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('第一轮');
      expect(await controller.apply(), isTrue);
      controller.continueAfterApply();

      var state = container.read(cardStudioControllerProvider);
      final oldIndex = controller.latestUserInstructionIndex!;
      expect(state.phase, CardStudioPhase.idle);
      expect(
        controller.instructionEditBlockedReasonFor(oldIndex),
        '该指令已应用或会话已恢复，仅可复制',
      );
      expect(await controller.editLastInstruction('改第一轮'), isNotNull);

      await controller.run('新指令');
      final newIndex = controller.latestUserInstructionIndex!;
      expect(newIndex, greaterThan(oldIndex));
      expect(
        controller.instructionEditBlockedReasonFor(oldIndex),
        '仅最近一条指令可修改',
      );
      expect(controller.instructionEditBlockedReasonFor(newIndex), isNull);
      state = container.read(cardStudioControllerProvider);
      expect(state.draftCard!.name, 'A');
      expect(state.draftCard!.description, 'D');
    },
  );

  test(
    'a restored draft is read-only until a new instruction is sent',
    () async {
      final draftFile = await openDraftFile();
      final backend1 = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': '草稿名'},
          }),
        ]),
        finishStep(),
      ]);
      final c1 = makeContainer(backend: backend1, draftFile: draftFile);
      final controller1 = c1.read(cardStudioControllerProvider.notifier);
      await controller1.start(null);
      await controller1.run('草稿指令');
      controller1.detach();
      c1.dispose();
      for (var i = 0; i < 100 && await draftFile.read(null) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await draftFile.read(null), isNotNull);

      final backend2 = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'description': '续写'},
          }),
        ]),
        finishStep(),
      ]);
      final c2 = makeContainer(backend: backend2, draftFile: draftFile);
      addTearDown(c2.dispose);
      final controller2 = c2.read(cardStudioControllerProvider.notifier);
      await controller2.start(null);
      final restored = c2.read(cardStudioControllerProvider);
      expect(restored.phase, CardStudioPhase.review);
      final index = controller2.latestUserInstructionIndex!;
      expect(
        controller2.instructionEditBlockedReasonFor(index),
        '该指令已应用或会话已恢复，仅可复制',
      );
      expect(await controller2.editLastInstruction('改'), isNotNull);

      await controller2.continueAdjust('继续调整');
      final newIndex = controller2.latestUserInstructionIndex!;
      expect(controller2.instructionEditBlockedReasonFor(newIndex), isNull);
    },
  );

  test(
    'rewinding invalidates the persisted draft before the rerun completes',
    () async {
      final draftFile = await openDraftFile();
      final gate = Completer<void>();
      final backend = ScriptedLlmBackend(
        [
          step([
            call('setCardFields', {
              'fields': {'name': '旧名'},
            }),
          ]),
          finishStep(),
          step([
            call('setCardFields', {
              'fields': {'name': '新名'},
            }),
          ]),
          finishStep(),
        ],
        gates: {2: gate},
      );
      final container = makeContainer(backend: backend, draftFile: draftFile);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      await controller.run('第一轮');
      for (var i = 0; i < 100 && await draftFile.read(null) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await draftFile.read(null), isNotNull);

      final editing = controller.editLastInstruction('改');
      await waitFor(() => backend.calls == 3);
      expect(await draftFile.read(null), isNull, reason: '撤回后旧提案不得复活');
      gate.complete();
      expect(await editing, isNull);
      for (var i = 0; i < 100 && await draftFile.read(null) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await draftFile.read(null), isNotNull, reason: '重跑结果重新落盘');
    },
  );

  test(
    'editing while the old avatar is generating drops the late image',
    () async {
      final image = _GatedImageBackend('QUJD');
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': '旧名'},
          }),
          call('setAvatarPrompt', {'prompt': '1girl'}),
        ]),
        finishStep(),
        step([
          call('setCardFields', {
            'fields': {'name': '新名'},
          }),
        ]),
        finishStep(),
      ]);
      final container = makeContainer(backend: backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(cardStudioControllerProvider.notifier);
      await controller.start(null);
      final firstRun = controller.run('第一轮');
      await waitFor(
        () =>
            container.read(cardStudioControllerProvider).avatarStatus ==
            CardStudioAvatarStatus.generating,
      );
      expect(
        controller.instructionEditBlockedReasonFor(
          controller.latestUserInstructionIndex!,
        ),
        isNull,
        reason: '生图在飞不影响编辑(忙态只看阶段)',
      );

      final editing = controller.editLastInstruction('改');
      await waitFor(
        () =>
            container.read(cardStudioControllerProvider).phase ==
                CardStudioPhase.review &&
            container.read(cardStudioControllerProvider).draftCard?.name ==
                '新名',
      );
      await editing;

      // 旧一轮的生图此刻才返回:不得覆盖撤回后的头像状态。
      image.gate.complete();
      await firstRun;
      final state = container.read(cardStudioControllerProvider);
      expect(state.avatarStatus, CardStudioAvatarStatus.idle);
      expect(state.draftCard!.avatarHash, isNull);
    },
  );

  test(
    'draft avatar survives grace period and restart without duplicate refs',
    () async {
      final draftFile = await openDraftFile();
      final image = _CountingImageBackend(fakeImageBase64);
      final backend = ScriptedLlmBackend([
        step([
          call('setCardFields', {
            'fields': {'name': '长期草稿'},
          }),
          call('setAvatarPrompt', {'prompt': '1girl'}),
        ]),
        finishStep(),
      ]);
      final c1 = makeContainer(
        backend: backend,
        imageBackend: image,
        draftFile: draftFile,
      );
      final controller1 = c1.read(cardStudioControllerProvider.notifier);
      await controller1.start(null);
      await controller1.run('生成长期草稿');
      for (var i = 0; i < 100 && await draftFile.read(null) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await draftFile.read(null), isNotNull);
      expect(await testImageRefCount(db, fakeImageHash), 1);

      final field = c1.read(cardStudioControllerProvider).diff!.fields.first;
      controller1.editField(field.key, '再次保存');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await draftFile.read(null);
      expect(
        await testImageRefCount(db, fakeImageHash),
        1,
        reason: '重写同一份草稿不得重复 acquire',
      );
      expect(
        await db.images.deleteIfUnreferenced(
          now: DateTime.now().add(const Duration(hours: 25)),
        ),
        0,
      );
      expect(await db.images.exists(fakeImageHash), isTrue);
      controller1.detach();
      c1.dispose();

      final c2 = makeContainer(
        backend: ScriptedLlmBackend([
          [const DoneEvent()],
        ]),
        draftFile: draftFile,
      );
      addTearDown(c2.dispose);
      final controller2 = c2.read(cardStudioControllerProvider.notifier);
      await controller2.start(null);
      expect(
        await testImageRefCount(db, fakeImageHash),
        1,
        reason: '恢复直接接管草稿清单,不能重复增加持久化引用',
      );
      expect(
        await db.images.deleteIfUnreferenced(
          now: DateTime.now().add(const Duration(hours: 72)),
        ),
        0,
      );

      expect(await controller2.apply(), isTrue);
      expect(await draftFile.read(null), isNull);
      expect(
        await testImageRefCount(db, fakeImageHash),
        1,
        reason: '应用后只剩角色业务引用,草稿引用已释放',
      );
      expect(await db.images.exists(fakeImageHash), isTrue);
    },
  );

  test('editing with unchanged text is a no-op', () async {
    final backend = ScriptedLlmBackend([
      step([
        call('setCardFields', {
          'fields': {'name': 'A'},
        }),
      ]),
      finishStep(),
    ]);
    final container = makeContainer(backend: backend);
    addTearDown(container.dispose);
    final controller = container.read(cardStudioControllerProvider.notifier);
    await controller.start(null);
    await controller.run('第一轮');
    expect(await controller.editLastInstruction('  第一轮  '), isNull);
    expect(backend.calls, 2);
    expect(container.read(cardStudioControllerProvider).draftCard!.name, 'A');
  });
}
