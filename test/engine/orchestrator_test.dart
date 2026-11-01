import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/image_guide_repository.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/engine/background_engine.dart';
import 'package:microscritt/engine/orchestrator.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/image_result.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/variable.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import '../support/test_database.dart';

class _JsonBackend implements LlmBackend {
  final String text;
  _JsonBackend([this.text = '{"variables":{"hp":"8"},"memory":"Met a dragon"}']);

  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield TextDelta(text);
    yield const DoneEvent();
  }
}

/// 按调用顺序回放响应文本(超出后重复最后一条),并记录全部请求 ——
/// 用于验证合并轮缺图像描述后的"仅图像"补调。
class _ScriptedBackend implements LlmBackend {
  _ScriptedBackend(this.texts);
  final List<String> texts;
  final requests = <LlmRequest>[];
  int _index = 0;

  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    requests.add(request);
    yield TextDelta(texts[_index < texts.length ? _index : texts.length - 1]);
    _index++;
    yield const DoneEvent();
  }
}

/// 捕获真实引擎的请求,核对编排器送入的分段上下文与重试次数。
class _CapturingBackend implements LlmBackend {
  final String text;
  final requests = <LlmRequest>[];
  String? lastPrompt;

  /// 捕获完整请求(v48:断言推理强度透传)。
  LlmRequest? lastRequest;
  _CapturingBackend([this.text = '{"variables":{},"memory":null}']);

  void _recordRequest(LlmRequest request) {
    requests.add(request);
    lastRequest = request;
    lastPrompt = request.systemPrompt;
  }

  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    _recordRequest(request);
    yield TextDelta(text);
    yield const DoneEvent();
  }
}

/// 请求已读取变量快照后停住,由测试显式放行,不依赖计时或 sleep。
class _GatedBackend extends _CapturingBackend {
  final started = Completer<LlmRequest>();
  final release = Completer<void>();
  final finished = Completer<void>();

  _GatedBackend(super.text);

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    _recordRequest(request);
    started.complete(request);
    try {
      await release.future;
      yield TextDelta(text);
      yield const DoneEvent();
    } finally {
      finished.complete();
    }
  }
}

class _RecordingImageBackend extends FakeImageBackend {
  final prompts = <String>[];

  _RecordingImageBackend() : super('aGVsbG8=');

  @override
  Future<ImageResult> generateImage(String prompt) {
    prompts.add(prompt);
    return super.generateImage(prompt);
  }
}

/// 只比较标签正文,不把任务说明中对标签的提及误算成实际转录。
String _sectionBody(String prompt, String tag) {
  final matches = RegExp('<$tag>[^\n]*\n(.*?)</$tag>', dotAll: true)
      .allMatches(prompt)
      .toList();
  expect(matches, hasLength(1), reason: 'Expected one <$tag> section');
  return matches.single.group(1)!;
}

void main() {
  // 编排器在无活跃对话时直接跳过;这些测试需要对话才能走到 LLM 调用。
  Future<void> seedMessage(MessageRepository repo, int sessionId) =>
      repo.append(sessionId: sessionId, role: 'user', content: 'north');

  test('applies background result to variables (memory no longer written per-turn)', () async {
    final db = await openTestDb();
    final characters = CharacterRepository(db);
    final sessions = SessionRepository(db);
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's');

    final varRepo = VariableRepository(db);
    final memRepo = MemoryRepository(db);
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    // 技能自 v37 起是全局目录、用户手动管理:编排器不再读取/写入技能状态;
    // 记忆自 CW 批起不经后台逐轮写入(LLM 回传的 memory 字段被丢弃)。
    final orch = Orchestrator(BackgroundEngine(_JsonBackend()), varRepo, memRepo, msgRepo, ImageGuideRepository(db));
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    expect(turn.skipped, isFalse);
    expect(turn.result, isNotNull);

    expect(await varRepo.bySession(sessionId), {'hp': '8'});
    // 空会话到首个后台轮:hp 是新建键,默认归后台托管(可改可删)。
    expect((await varRepo.snapshot(sessionId)).access['hp'], VariableAccess.full);
    expect(await memRepo.bySession(sessionId), isEmpty);
  });

  test('forwards the background reasoning level into the engine request', () async {
    // v48:编排器把后台推理强度原样透传给引擎(与 temperature/maxTokens 同待遇),
    // 落到 LlmRequest.reasoningLevel —— 链路某层漏传即在此失败。
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    final recording = _CapturingBackend('{"variables":{},"memory":null}');
    final orch = Orchestrator(BackgroundEngine(recording), VariableRepository(db), MemoryRepository(db), msgRepo, ImageGuideRepository(db));
    final turn = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      reasoningLevel: ReasoningLevel.medium,
    );
    expect(turn.skipped, isFalse);
    expect(recording.lastRequest!.reasoningLevel, ReasoningLevel.medium);
    await db.db.close();
  });

  test('skips application when the engine returns null (failed)', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');

    final varRepo = VariableRepository(db);
    final memRepo = MemoryRepository(db);
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    // A backend that errors → engine returns null.
    final engine = BackgroundEngine(_ErrorBackend());
    final orch = Orchestrator(engine, varRepo, memRepo, msgRepo, ImageGuideRepository(db));
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    // 有对话但引擎失败 → 非跳过(status 为 failed,result 为空)。
    expect(turn.skipped, isFalse);
    expect(turn.result, isNull);

    expect(await varRepo.bySession(sessionId), isEmpty);
    expect(await memRepo.bySession(sessionId), isEmpty);
  });

  test('generates and stores an image when imagePrompt is present', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    final engine = BackgroundEngine(
      _JsonBackend('{"variables":{},"memory":null,"imagePrompt":"a sword"}'),
    );
    final orch = Orchestrator(
      engine,
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: FakeImageBackend('aGVsbG8='),
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    expect(turn.result, isNotNull);
    // A3:生图任务与轮次解耦 —— 图片落库要等 imageTask 收敛。
    await turn.imageTask;
    final msgs = await MessageRepository(db).bySession(sessionId, includeImages: true);
    expect(msgs, hasLength(2)); // seed 消息 + 图片消息
    expect(msgs.last.imageBase64, 'aGVsbG8=');
    expect(msgs.last.imagePrompt, 'a sword', reason: '图片重新生成依赖落库的原始描述');
  });

  test('a throwing image backend skips the image but keeps state updates', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    final engine = BackgroundEngine(
      _JsonBackend('{"variables":{"hp":"8"},"memory":null,"imagePrompt":"a sword"}'),
    );
    String? failureDetail;
    final orch = Orchestrator(
      engine,
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _ThrowingImageBackend(),
      onImageFailed: (detail) => failureDetail = detail,
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    expect(turn.result, isNotNull);
    // 生图任务吞掉 provider 异常,正常收敛(失败经 onImageFailed 通知,不静默);
    // 失败原因一并带出,状态面板不再只说「失败」。
    await turn.imageTask;
    expect(failureDetail, contains('provider down'));

    // No image message was stored, but the non-image updates still applied.
    expect(await MessageRepository(db).bySession(sessionId), hasLength(1)); // 只有那条 seed 消息
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '8'});
  });

  test('multiple distinct scene descriptions append one message per prompt', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    // 一次多张 = 后台 LLM 产出同场景的多个不同描述(「每次生图数量」>1)。
    final engine = BackgroundEngine(
      _JsonBackend('{"variables":{},"memory":null,"imagePrompts":["shot a","shot b","shot c"]}'),
    );
    var appended = 0;
    final orch = Orchestrator(
      engine,
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _PromptKeyedImageBackend(),
      onImagePlaced: (_) => appended++,
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    expect(turn.result, isNotNull);
    await turn.imageTask;
    // 每张落库通知一次 —— 多张时图片逐张浮现,不必等全部生成完。
    expect(appended, 3);

    final msgs = await MessageRepository(db).bySession(sessionId, includeImages: true);
    expect(msgs, hasLength(4)); // seed 消息 + 3 张,按描述顺序落库
    expect(
      [for (final m in msgs.skip(1)) m.imageUrl],
      ['http://127.0.0.1:1/shot%20a', 'http://127.0.0.1:1/shot%20b', 'http://127.0.0.1:1/shot%20c'],
    );
    expect(
      [for (final m in msgs.skip(1)) m.imagePrompt],
      ['shot a', 'shot b', 'shot c'],
    );
  });

  test('no image prompt fields means the provider is never called', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    final engine = BackgroundEngine(
      _JsonBackend('{"variables":{},"memory":null,"imagePrompt":null,"imagePrompts":[]}'),
    );
    var imageFailed = false;
    final orch = Orchestrator(
      engine,
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      // 若被调用必抛 —— 没被调用则 imageFailed 保持 false、无消息落库。
      imageBackend: _ThrowingImageBackend(),
      onImageFailed: (_) => imageFailed = true,
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    expect(turn.result, isNotNull);
    expect(turn.imageTask, isNull);
    // 描述缺失不算"消费了生图机会":保留给后续轮次,而不是本轮作废。
    expect(turn.imageHandled, isFalse);
    expect(imageFailed, isFalse);
    expect(await MessageRepository(db).bySession(sessionId), hasLength(1));
  });

  test('combined turn retries image-only when the model omits the scene description', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    // 合并轮只回变量(复现"同时开变量和生图时偶尔只更新变量"),补调回图像描述。
    final backend = _ScriptedBackend([
      '{"variables":{"hp":"8"},"memory":null}',
      '{"imagePrompt":"retried scene"}',
    ]);
    final images = _RecordingImageBackend();
    final turn = await Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: images,
    ).runAfterTurn(sessionId: sessionId, model: 'm');

    expect(backend.requests, hasLength(2));
    // 第一次是变量+生图合并轮;第二次补调只带图像任务,不再重复变量块。
    expect(backend.requests.first.systemPrompt, contains('<variables>'));
    expect(backend.requests.first.systemPrompt, contains('# image'));
    expect(backend.requests.last.systemPrompt, isNot(contains('<variables>')));
    expect(backend.requests.last.systemPrompt, contains('# image'));
    expect(turn.result!.variableUpdates, {'hp': '8'});
    expect(turn.imageHandled, isTrue);
    expect(images.prompts, ['retried scene']);
    await turn.imageTask;
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '8'});
    final rows = await msgRepo.bySession(sessionId, includeImages: true);
    expect(rows.last.imageBase64, 'aGVsbG8=');
    expect(rows.last.imagePrompt, 'retried scene');
  });

  test('combined turn keeps the image chance when the retry also lacks a scene', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    // 两次都只有变量:变量照常落库,生图机会保留(imageHandled=false)。
    final backend = _ScriptedBackend(['{"variables":{"hp":"8"},"memory":null}']);
    final images = _RecordingImageBackend();
    final turn = await Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: images,
    ).runAfterTurn(sessionId: sessionId, model: 'm');

    expect(backend.requests, hasLength(2)); // 合并轮 + 一次仅图像补调
    expect(backend.requests.last.systemPrompt, isNot(contains('<variables>')));
    expect(turn.result!.variableUpdates, {'hp': '8'});
    expect(turn.imageHandled, isFalse);
    expect(turn.imageTask, isNull);
    expect(images.prompts, isEmpty);
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '8'});
    expect(await msgRepo.bySession(sessionId), hasLength(1));
  });

  test('rerun context reaches both the combined and image-only retry prompts', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    // 合并轮只回变量 → 编排器补一次仅图像调用;两次都必须带上重跑上下文。
    final backend = _ScriptedBackend([
      '{"variables":{"hp":"8"},"memory":null}',
      '{"imagePrompt":"retried scene"}',
    ]);
    final images = _RecordingImageBackend();
    final turn = await Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: images,
    ).runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      rerunContext: const RerunContext(
        direction: 'stormy night',
        previousImagePrompts: ['previous scene'],
      ),
    );

    expect(backend.requests, hasLength(2));
    for (final request in backend.requests) {
      expect(request.systemPrompt, contains('<rerun_instruction>'));
      expect(request.systemPrompt, contains('stormy night'));
      expect(request.systemPrompt, contains('previous scene'));
    }
    expect(images.prompts, ['retried scene']);
    await turn.imageTask;
  });

  test('imageReplaceTargets swaps the previous image row in place and rewrites its prompt', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);
    // 上一轮后台为这一轮落库的图(带描述)—— 重跑的替换目标。
    final previous = await msgRepo.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'b2xk',
      imagePrompt: 'old scene',
    );

    final placements = <BackgroundImagePlacement>[];
    final images = _RecordingImageBackend();
    final turn = await Orchestrator(
      BackgroundEngine(_JsonBackend('{"variables":{"hp":"8"},"imagePrompt":"new scene"}')),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: images,
      onImagePlaced: placements.add,
    ).runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      imageReplaceTargets: [(messageId: previous.id!, expectedPrompt: 'old scene')],
    );
    await turn.imageTask;

    expect(images.prompts, ['new scene']);
    expect(placements, [(messageId: previous.id!, prompt: 'new scene', replaced: true)]);
    // 原地替换:不追加新行;描述一并更新,该消息的「重新生成图片」按新描述重绘。
    final rows = await msgRepo.bySession(sessionId, includeImages: true);
    expect(rows, hasLength(2));
    expect(rows.last.id, previous.id);
    expect(rows.last.imagePrompt, 'new scene');
    expect(rows.last.imageBase64, 'aGVsbG8=');
  });

  test('a deleted replace target falls back to appending a new image row', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);
    final previous = await msgRepo.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'b2xk',
      imagePrompt: 'old scene',
    );
    await msgRepo.delete(previous.id!);

    final placements = <BackgroundImagePlacement>[];
    final turn = await Orchestrator(
      BackgroundEngine(_JsonBackend('{"variables":{},"imagePrompt":"new scene"}')),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _RecordingImageBackend(),
      onImagePlaced: placements.add,
    ).runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      imageReplaceTargets: [(messageId: previous.id!, expectedPrompt: 'old scene')],
    );
    await turn.imageTask;

    expect(placements.single.replaced, isFalse);
    expect(placements.single.messageId, isNot(previous.id));
    final rows = await msgRepo.bySession(sessionId);
    expect(rows, hasLength(2)); // seed + 追加的新图(旧行已被删)
    expect(rows.last.imagePrompt, 'new scene');
  });

  test('a hand-edited prompt invalidates the replace target and appends instead', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);
    final previous = await msgRepo.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageBase64: 'b2xk',
      imagePrompt: 'old scene',
    );
    // 期间这张图被「重新生成图片」换过描述:条件更新不再匹配,重跑不得覆盖它。
    await msgRepo.replaceImage(
      previous.id!,
      imageBase64: 'b2xk',
      imageUrl: null,
      expectedPrompt: 'old scene',
      newImagePrompt: 'edited by hand',
    );

    final placements = <BackgroundImagePlacement>[];
    final turn = await Orchestrator(
      BackgroundEngine(_JsonBackend('{"variables":{},"imagePrompt":"new scene"}')),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _RecordingImageBackend(),
      onImagePlaced: placements.add,
    ).runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      imageReplaceTargets: [(messageId: previous.id!, expectedPrompt: 'old scene')],
    );
    await turn.imageTask;

    expect(placements.single.replaced, isFalse);
    final rows = await msgRepo.bySession(sessionId);
    expect(rows, hasLength(3)); // seed + 未被覆盖的旧图 + 追加的新图
    expect(rows[1].imagePrompt, 'edited by hand');
    expect(rows.last.imagePrompt, 'new scene');
  });

  test('multi-image rerun replaces positionally and appends the surplus', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);
    final first = await msgRepo.append(
      sessionId: sessionId, role: 'assistant', content: '',
      imageBase64: 'b2xk', imagePrompt: 'scene one',
    );
    final second = await msgRepo.append(
      sessionId: sessionId, role: 'assistant', content: '',
      imageBase64: 'b2xk', imagePrompt: 'scene two',
    );

    final placements = <BackgroundImagePlacement>[];
    final turn = await Orchestrator(
      BackgroundEngine(_JsonBackend('{"variables":{},"imagePrompts":["a","b","c"]}')),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _RecordingImageBackend(),
      onImagePlaced: placements.add,
    ).runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      imageCount: 3,
      imageReplaceTargets: [
        (messageId: first.id!, expectedPrompt: 'scene one'),
        (messageId: second.id!, expectedPrompt: 'scene two'),
      ],
    );
    await turn.imageTask;

    // 按位置替换前两张,多出的第三张追加;不静默删除用户可见的行。
    expect(placements.map((p) => p.replaced), [true, true, false]);
    expect(placements.take(2).map((p) => p.messageId), [first.id, second.id]);
    final rows = await msgRepo.bySession(sessionId);
    expect(rows, hasLength(4)); // seed + 2 张原地换新 + 1 张追加
    expect([rows[1].imagePrompt, rows[2].imagePrompt, rows[3].imagePrompt], ['a', 'b', 'c']);
  });

  test('rerun keeps replace targets aligned when one scene fails to generate', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);
    final first = await msgRepo.append(
      sessionId: sessionId, role: 'assistant', content: '',
      imageBase64: 'b2xk', imagePrompt: 'scene one',
    );
    final second = await msgRepo.append(
      sessionId: sessionId, role: 'assistant', content: '',
      imageBase64: 'b2xk', imagePrompt: 'scene two',
    );

    final placements = <BackgroundImagePlacement>[];
    final turn = await Orchestrator(
      BackgroundEngine(_JsonBackend('{"variables":{},"imagePrompts":["a","b"]}')),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _SelectivelyFailingImageBackend({'a'}),
      onImagePlaced: placements.add,
    ).runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      imageCount: 2,
      imageReplaceTargets: [
        (messageId: first.id!, expectedPrompt: 'scene one'),
        (messageId: second.id!, expectedPrompt: 'scene two'),
      ],
    );
    await turn.imageTask;

    // 第一条描述失败不产条目:第二条的图必须仍落在第二个目标上,不能前移
    // 覆盖第一条的旧图。
    expect(placements, [(messageId: second.id!, prompt: 'b', replaced: true)]);
    final rows = await msgRepo.bySession(sessionId, includeImages: true);
    expect(rows, hasLength(3));
    expect(rows[1].id, first.id);
    expect(rows[1].imagePrompt, 'scene one');
    expect(rows[1].imageBase64, 'b2xk');
    expect(rows[2].id, second.id);
    expect(rows[2].imagePrompt, 'b');
    expect(rows[2].imageBase64, 'aGVsbG8=');
  });

  test('reports the processed variable window so a rerun can replay it', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    for (var i = 0; i < 6; i++) {
      await msgRepo.append(
        sessionId: sessionId,
        role: i.isEven ? 'user' : 'assistant',
        content: 'msg$i',
      );
    }

    final backend = _CapturingBackend('{"variables":{"hp":"8"},"imagePrompt":"a scene"}');
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
    );
    final turn = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      afterSeq: 1,
      throughSeq: 5,
    );
    expect(turn.cursorSeq, 5);
    expect(turn.processedAfterSeq, 1); // batch.first.seq - 1
    expect(turn.processedThroughSeq, 5);

    // 没跑变量的轮次不带窗口(重跑据此回退到最新一轮,而不是重放过旧批次)。
    final imageOnly = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
      throughSeq: 5,
    );
    expect(imageOnly.processedAfterSeq, isNull);
    expect(imageOnly.processedThroughSeq, isNull);
  });

  test('forwards imageCount into the background prompt', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    final backend = _CapturingBackend('{"variables":{},"memory":null,"imagePrompts":["a","b"]}');
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _PromptKeyedImageBackend(),
    );
    await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
      imageCount: 2,
    );
    expect(backend.lastPrompt, contains('"imagePrompts": ["<scene description 1>"'));
  });

  test('an empty image result notifies failure and stores nothing', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    final engine = BackgroundEngine(
      _JsonBackend('{"variables":{},"memory":null,"imagePrompt":"a sword"}'),
    );
    var imageFailed = false;
    final orch = Orchestrator(
      engine,
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: _EmptyImageBackend(),
      onImageFailed: (_) => imageFailed = true,
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    await turn.imageTask;
    expect(imageFailed, isTrue);
    expect(await MessageRepository(db).bySession(sessionId), hasLength(1)); // 只有那条 seed 消息
  });

  test('fast-state turns send a sliding window even when the cursor has advanced (ES)', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    // 5 条消息:cursor=2 之后还有 2 条新消息(增量判据非空 → 不跳过)。
    for (var i = 0; i < 5; i++) {
      await msgRepo.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'msg$i');
    }

    final backend = _CapturingBackend();
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: FakeImageBackend('aGVsbG8='),
    );
    final turn = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
      afterSeq: 2,
    );
    expect(turn.skipped, isFalse);
    // ES 批:增量游标只作跳过判据;送入的是 recent 末尾滑动窗口
    // (image 窗口 6 条 ≥ 全部 5 条)—— 生图轮看到完整最近场景而非
    // 仅游标后的 2 条新消息。
    expect(backend.lastPrompt, contains('msg0'));
    expect(backend.lastPrompt, contains('msg4'));
    expect(turn.cursorSeq, isNull); // image-only 不推进变量游标。
    expect(turn.hasMoreVariables, isFalse);
    // 模型没给图像描述:生图机会未被消费(保留给后续轮次),也不能凭空画图。
    expect(turn.imageHandled, isFalse);
    expect(turn.imageTask, isNull);
    expect(turn.variableConflict, isFalse);
  });

  test('skips the fast-state turn when there is no new transcript since the cursor (B4)', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);
    await msgRepo.append(sessionId: sessionId, role: 'assistant', content: 'reply');

    final backend = _CapturingBackend();
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: FakeImageBackend('aGVsbG8='),
    );
    // 游标已到最大 seq(1):快状态没有新消息可维护 → 跳过,不再调用 LLM。
    final turn = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
      afterSeq: 1,
    );
    expect(turn.skipped, isTrue);
    expect(backend.lastPrompt, isNull); // 没有发起 LLM 调用。
  });

  test('rolls back the first variable write when the second insert aborts', () async {
    final db = await openTestDb();
    addTearDown(db.db.close);
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final varRepo = VariableRepository(db);
    final memRepo = MemoryRepository(db);
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);
    await varRepo.upsert(sessionId, 'hp', '10');
    final before = await varRepo.snapshot(sessionId);

    // 真正经过 compareAndApply 的事务:只有第一条已写成 8 才让第二条
    // INSERT ABORT,防止测试退化成「第一条写入之前就抛异常」。
    await db.db.execute('''
      CREATE TEMP TRIGGER abort_second_variable
      BEFORE INSERT ON variables
      WHEN NEW.session_id = $sessionId AND NEW.key = 'second'
        AND EXISTS (
          SELECT 1 FROM variables
          WHERE session_id = $sessionId AND key = 'hp' AND value = '8'
        )
      BEGIN
        SELECT RAISE(ABORT, 'second variable write failed');
      END
    ''');
    final images = _RecordingImageBackend();
    final orch = Orchestrator(
      BackgroundEngine(_JsonBackend(
        '{"variables":{"hp":"8","second":"new"},"imagePrompt":"a scene"}',
      )),
      varRepo,
      memRepo,
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: images,
    );
    await expectLater(
      orch.runAfterTurn(sessionId: sessionId, model: 'm'),
      throwsA(predicate<Object>(
        (e) => e.toString().contains('second variable write failed'),
      )),
    );
    final after = await varRepo.snapshot(sessionId);
    expect(after.values, before.values);
    expect(after.revision, before.revision);
    expect(await memRepo.bySession(sessionId), isEmpty);
    expect(images.prompts, isEmpty);
    expect(await msgRepo.bySession(sessionId), hasLength(1));
  });

  test('image turns carry the image guide and the read-only memory anchor (ES)', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final memRepo = MemoryRepository(db);
    final guideRepo = ImageGuideRepository(db);
    final msgRepo = MessageRepository(db);
    await memRepo.set(sessionId, 'Old fact: the sword is cursed.');
    await guideRepo.set(sessionId, '1girl, silver hair, black coat');
    await seedMessage(msgRepo, sessionId);

    final backend = _CapturingBackend('{"variables":{},"imagePrompt":"a scene"}');
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      memRepo,
      msgRepo,
      guideRepo,
      imageBackend: FakeImageBackend('aGVsbG8='),
    );
    final turn = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
    );

    expect(turn.skipped, isFalse);
    expect(turn.result, isNotNull);
    expect(turn.result!.usage.inputTokens, 0);
    // 生图指导照常携带;ES 批起记忆以只读锚定段回喂(贴合剧情的场景锚点)。
    expect(backend.lastPrompt, contains('1girl, silver hair, black coat'));
    expect(backend.lastPrompt, contains('<memory>'));
    expect(backend.lastPrompt, contains('Old fact: the sword is cursed.'));
    // 未传角色卡/世界书时不产生对应锚定段。
    expect(backend.lastPrompt, isNot(contains('</character>')));
    expect(backend.lastPrompt, isNot(contains('</worldbook_background>')));
  });

  test('skips state writes for features disabled by selection', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');

    final varRepo = VariableRepository(db);
    final memRepo = MemoryRepository(db);
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    // 关掉 variables(后台仍会返回它们,但选择器关闭时应不落库);image 开着
    // 并接上生图后端,保证轮次可执行(全关/无后端会在 LLM 调用前直接跳过)。
    const features = BackgroundFeatures(variables: false, image: true);
    final orch = Orchestrator(
      BackgroundEngine(_JsonBackend()),
      varRepo,
      memRepo,
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: FakeImageBackend('aGVsbG8='),
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm', features: features);
    expect(turn.result, isNotNull);

    // variables 虽被 LLM 返回但被跳过(未落库);记忆不再有逐轮写入路径,
    // 即便 LLM 回传 memory 字段也恒为空(CW 批)。
    expect(await varRepo.bySession(sessionId), isEmpty);
    expect(await memRepo.bySession(sessionId), isEmpty);
  });

  test('skips the run when there is no active conversation', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');

    // 没有消息:后台应直接跳过,不触发任何 LLM 调用。
    final backend = _CapturingBackend();
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      MessageRepository(db),
      ImageGuideRepository(db),
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm');
    expect(turn.skipped, isTrue);
    expect(turn.result, isNull);
    expect(backend.lastPrompt, isNull); // 从未发起 LLM 调用。
  });

  test('skips the run when only image is on but no image backend is configured', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    const features = BackgroundFeatures(variables: false, image: true);
    final backend = _CapturingBackend();
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      // imageBackend 不配置 → image 不可执行 → 整轮应跳过。
    );
    final turn = await orch.runAfterTurn(sessionId: sessionId, model: 'm', features: features);
    expect(turn.skipped, isTrue);
    expect(turn.result, isNull);
    expect(backend.lastPrompt, isNull);
  });

  test('bootstraps only three variable messages without a cursor and keeps six image messages', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final msgRepo = MessageRepository(db);
    // 无游标不全量回放:变量 bootstrap 最近 3 条,生图独立取最近 6 条。
    for (var i = 0; i < 30; i++) {
      await msgRepo.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'msg$i');
    }

    final backend = _CapturingBackend();

    // 场景 A:只开 variables → 最近 3 条 delta + 之前 2 条只读前文。
    final orchVariables = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
    );
    final variableTurn = await orchVariables.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: true, image: false),
    );
    expect(
      _sectionBody(backend.lastPrompt!, 'variable_delta'),
      'assistant: msg27\nuser: msg28\nassistant: msg29',
    );
    expect(
      _sectionBody(backend.lastPrompt!, 'recent_conversation'),
      'assistant: msg25\nuser: msg26',
    );
    expect(backend.lastPrompt, isNot(contains('msg24')));
    expect(backend.lastPrompt, isNot(contains('msg0')));
    expect(variableTurn.cursorSeq, 29);
    expect(variableTurn.hasMoreVariables, isFalse);

    // 场景 B:只开 image → 窗口放宽到 6 条(生图需要最近完整场景,ES 批)。
    // 需给 image 接一个 backend 才会真正发起(否则按"不可执行"跳过)。
    backend.lastPrompt = null;
    final orchImage = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      MemoryRepository(db),
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: FakeImageBackend('aGVsbG8='),
    );
    await orchImage.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
    );
    expect(backend.lastPrompt, contains('msg29'));
    // image 窗口 6 条:msg24..msg29,msg23 及更早被截掉。
    expect(backend.lastPrompt, contains('msg24'));
    expect(backend.lastPrompt, isNot(contains('msg23')));
  });

  test('anchor switches gate character/memory injection into the background prompt (EV)', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final memRepo = MemoryRepository(db);
    await memRepo.set(sessionId, '锚定记忆文本');
    final msgRepo = MessageRepository(db);
    await seedMessage(msgRepo, sessionId);

    final backend = _CapturingBackend('{"variables":{},"memory":null,"imagePrompt":"a scene"}');
    final orch = Orchestrator(
      BackgroundEngine(backend),
      VariableRepository(db),
      memRepo,
      msgRepo,
      ImageGuideRepository(db),
      imageBackend: FakeImageBackend('aGVsbG8='),
    );
    const card = CharacterCard(name: 'Alice', description: 'silver hair');

    // 双开关都关:角色卡/记忆锚定段均不注入。
    var turn = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
      character: card,
      characterAnchor: false,
      memoryAnchor: false,
    );
    expect(turn.skipped, isFalse);
    expect(backend.lastPrompt, isNot(contains('</character>')));
    expect(backend.lastPrompt, isNot(contains('</memory>')));
    await turn.imageTask;

    // 只开记忆开关:记忆段注入、角色卡仍缺席。
    backend.lastPrompt = null;
    turn = await orch.runAfterTurn(
      sessionId: sessionId,
      model: 'm',
      features: const BackgroundFeatures(variables: false, image: true),
      character: card,
      characterAnchor: false,
      memoryAnchor: true,
    );
    expect(backend.lastPrompt, contains('<memory>'));
    expect(backend.lastPrompt, contains('锚定记忆文本'));
    expect(backend.lastPrompt, isNot(contains('</character>')));
    await turn.imageTask;
    await db.db.close();
  });

  group('incremental variable maintenance', () {
    late int sessionId;
    late VariableRepository variables;
    late MemoryRepository memories;
    late MessageRepository messages;
    late ImageGuideRepository guides;

    setUp(() async {
      final db = await openTestDb();
      addTearDown(db.db.close);
      final charId = await CharacterRepository(db).insert(
        const CharacterCard(name: 'A'),
      );
      sessionId = await SessionRepository(db).create(charId, 's');
      variables = VariableRepository(db);
      memories = MemoryRepository(db);
      messages = MessageRepository(db);
      guides = ImageGuideRepository(db);
    });

    Orchestrator orchestrator(LlmBackend backend, {ImageBackend? images}) =>
        Orchestrator(
          BackgroundEngine(backend),
          variables,
          memories,
          messages,
          guides,
          imageBackend: images,
        );

    Future<List<Message>> seedHistory(int count) async {
      final rows = <Message>[];
      for (var seq = 0; seq < count; seq++) {
        rows.add(await messages.append(
          sessionId: sessionId,
          role: seq.isEven ? 'user' : 'assistant',
          content: 'turn[$seq]',
        ));
      }
      return rows;
    }

    String transcript(int first, int last) => [
      for (var seq = first; seq <= last; seq++)
        '${seq.isEven ? 'user' : 'assistant'}: turn[$seq]',
    ].join('\n');

    void expectRejected(BackgroundTurnResult turn) {
      expect(turn.result, isNull);
      expect(turn.cursorSeq, isNull);
      expect(turn.hasMoreVariables, isFalse);
      expect(turn.imageHandled, isFalse);
      expect(turn.imageTask, isNull);
    }

    test('afterSeq zero includes seq one, even for an empty variable update', () async {
      await seedHistory(6);
      await variables.upsert(sessionId, 'hp', '10');
      final before = await variables.snapshot(sessionId);
      final backend = _CapturingBackend();
      final turn = await orchestrator(backend).runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        features: const BackgroundFeatures(variables: true, image: false),
        afterSeq: 0,
        throughSeq: 5,
      );

      expect(backend.requests, hasLength(1));
      expect(_sectionBody(backend.lastPrompt!, 'variable_delta'), transcript(1, 5));
      expect(_sectionBody(backend.lastPrompt!, 'recent_conversation'), transcript(0, 0));
      expect(turn.skipped, isFalse);
      expect(turn.failureReason, isNull);
      expect(turn.result!.variableUpdates, isEmpty);
      expect(turn.cursorSeq, 5);
      expect(turn.hasMoreVariables, isFalse);
      expect(turn.imageHandled, isFalse);
      expect(turn.variableConflict, isFalse);
      final after = await variables.snapshot(sessionId);
      expect(after.values, before.values);
      expect(after.revision, before.revision);
    });

    test('explicit removals are applied and reflected in the result and access prompt', () async {
      await seedHistory(2);
      await variables.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      await variables.upsert(sessionId, 'keep', '2', access: VariableAccess.protected);
      await variables.upsert(sessionId, 'constant', 'gold', access: VariableAccess.readonly);
      final backend = _CapturingBackend(
        '{"variables":{"keep":"3"},"removeVariables":["a","keep","constant"]}',
      );

      final turn = await orchestrator(backend).runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        features: const BackgroundFeatures(variables: true, image: false),
        afterSeq: 0,
        throughSeq: 1,
      );

      expect(
        _sectionBody(backend.lastPrompt!, 'variable_access'),
        jsonEncode({'deletable': ['a'], 'readonly': ['constant']}),
      );
      expect(turn.result!.variableUpdates, {'keep': '3'});
      expect(turn.result!.variableRemovals, ['a']);
      expect(await variables.bySession(sessionId), {'keep': '3', 'constant': 'gold'});
      expect((await variables.trash(sessionId)).single.key, 'a');
    });

    test('confirm mode stages proposals instead of deleting', () async {
      await seedHistory(2);
      await variables.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      final backend = _CapturingBackend('{"variables":{},"removeVariables":["a"]}');

      final turn = await orchestrator(backend).runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        features: const BackgroundFeatures(variables: true, image: false),
        confirmVariableDeletions: true,
        afterSeq: 0,
        throughSeq: 1,
      );

      expect(turn.result!.variableRemovals, isEmpty);
      expect(turn.result!.variableRemovalProposals, ['a']);
      expect(await variables.bySession(sessionId), {'a': '1'});
      expect((await variables.pendingDeletions(sessionId)).single.key, 'a');
      expect(await variables.trash(sessionId), isEmpty);
    });

    test('combined turn keeps applied removals when it retries only the image', () async {
      await seedHistory(2);
      await variables.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      final backend = _ScriptedBackend([
        '{"variables":{},"removeVariables":["a"]}',
        '{"imagePrompt":"a cave"}',
      ]);
      final images = _RecordingImageBackend();

      final turn = await orchestrator(backend, images: images).runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        features: const BackgroundFeatures(variables: true, image: true),
        afterSeq: 0,
        throughSeq: 1,
      );
      await turn.imageTask;

      expect(backend.requests, hasLength(2));
      expect(turn.result!.variableRemovals, ['a']);
      expect(await variables.bySession(sessionId), isEmpty);
      expect(images.prompts, ['a cave']);
    });

    test('drains oldest batches of twelve without gaps and images only the final scene', () async {
      await seedHistory(28);
      await variables.upsert(sessionId, 'hp', '10');
      await guides.set(sessionId, 'latest image direction');
      final backend = _CapturingBackend(
        '{"variables":{"hp":"8"},"imagePrompt":"latest scene"}',
      );
      final images = _RecordingImageBackend();
      final orch = orchestrator(backend, images: images);
      final processed = <String>[];
      var cursor = 0;
      expect(Orchestrator.maxVariableMessages, 12);

      for (final batch in const [
        (first: 1, last: 12, more: true),
        (first: 13, last: 24, more: true),
        (first: 25, last: 27, more: false),
      ]) {
        final turn = await orch.runAfterTurn(
          sessionId: sessionId,
          model: 'm',
          afterSeq: cursor,
          throughSeq: 27,
        );
        await turn.imageTask;
        final prompt = backend.lastPrompt!;
        final delta = _sectionBody(prompt, 'variable_delta');
        expect(delta, transcript(batch.first, batch.last));
        processed.addAll(delta.split('\n'));
        expect(turn.skipped, isFalse);
        expect(turn.failureReason, isNull);
        expect(turn.variableConflict, isFalse);
        expect(turn.cursorSeq, batch.last);
        expect(turn.hasMoreVariables, batch.more);
        expect(turn.imageHandled, !batch.more);
        expect(
          _sectionBody(prompt, 'variables'),
          batch.first == 1 ? '{"hp":"10"}' : '{"hp":"8"}',
        );
        if (batch.more) {
          // 中间批次只读其之前两条,不能把尚未处理的后文当成变量 delta。
          expect(
            _sectionBody(prompt, 'recent_conversation'),
            transcript(batch.first == 1 ? 0 : batch.first - 2, batch.first - 1),
          );
          expect(prompt, isNot(contains('<image_guide>')));
          expect(prompt, isNot(contains('"imagePrompt":')));
          expect(turn.result!.imagePrompt, isNull);
          expect(turn.imageTask, isNull);
          expect(images.prompts, isEmpty);
          expect(await messages.bySession(sessionId), hasLength(28));
        } else {
          // 末批变量只处理 25..27,生图却需要活跃场景 22..27。
          expect(_sectionBody(prompt, 'recent_conversation'), transcript(22, 27));
          expect(prompt, contains('latest image direction'));
          expect(turn.imageTask, isNotNull);
          expect(images.prompts, ['latest scene']);
          final rows = await messages.bySession(sessionId, includeImages: true);
          expect(rows, hasLength(29));
          expect(rows.last.imageBase64, 'aGVsbG8=');
        }
        cursor = turn.cursorSeq!;
      }
      expect(processed, transcript(1, 27).split('\n'));
      expect(backend.requests, hasLength(3));
      expect(await variables.bySession(sessionId), {'hp': '8'});

      final exhausted = await orch.runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        features: const BackgroundFeatures(variables: true, image: false),
        afterSeq: cursor,
        throughSeq: 27,
      );
      expect(exhausted.skipped, isTrue);
      expectRejected(exhausted);
      expect(backend.requests, hasLength(3));
      expect(images.prompts, hasLength(1));
    });

    test('throughSeq excludes a later unfinished input from both text segments', () async {
      await seedHistory(6);
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'unfinished later input',
      );
      final backend = _CapturingBackend(
        '{"variables":{},"imagePrompt":"completed scene"}',
      );
      final images = _RecordingImageBackend();
      final orch = orchestrator(backend, images: images);
      final turn = await orch.runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        afterSeq: 0,
        throughSeq: 5,
      );
      await turn.imageTask;
      expect(_sectionBody(backend.lastPrompt!, 'variable_delta'), transcript(1, 5));
      expect(_sectionBody(backend.lastPrompt!, 'recent_conversation'), transcript(0, 5));
      expect(backend.lastPrompt, isNot(contains('unfinished later input')));
      expect(turn.cursorSeq, 5);
      expect(turn.hasMoreVariables, isFalse);
      expect(turn.imageHandled, isTrue);
      expect(images.prompts, ['completed scene']);

      // 界外的新输入也不能绕过 image-only 原有的 afterSeq 跳过判据。
      final imageOnly = await orch.runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        features: const BackgroundFeatures(variables: false, image: true),
        afterSeq: 5,
        throughSeq: 5,
      );
      expect(imageOnly.skipped, isTrue);
      expectRejected(imageOnly);
      expect(backend.requests, hasLength(1));
      expect(images.prompts, hasLength(1));
    });

    test('keeps compacted delta but excludes it from images and filters non-chat rows', () async {
      final history = await seedHistory(6);
      await messages.insertSystemAndCompact(
        sessionId: sessionId,
        content: 'system summary must not be replayed',
        compactIds: [history[1].id!, history[4].id!],
      );
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        kind: MessageKind.attachment,
        content: 'attachment must not be replayed',
      );
      final empty = await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageBase64: 'aW1hZ2U=',
      );
      final backend = _CapturingBackend(
        '{"variables":{"hp":"8"},"imagePrompt":"active scene"}',
      );
      final images = _RecordingImageBackend();
      final turn = await orchestrator(backend, images: images).runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        afterSeq: 0,
        throughSeq: empty.seq,
      );
      await turn.imageTask;
      expect(_sectionBody(backend.lastPrompt!, 'variable_delta'), transcript(1, 5));
      expect(
        _sectionBody(backend.lastPrompt!, 'recent_conversation'),
        [transcript(0, 0), transcript(2, 3), transcript(5, 5)].join('\n'),
      );
      expect(backend.lastPrompt, isNot(contains('system summary must not be replayed')));
      expect(backend.lastPrompt, isNot(contains('attachment must not be replayed')));
      expect(backend.lastPrompt, isNot(contains('aW1hZ2U=')));
      expect(turn.cursorSeq, 5); // 不能推进到 seq 6/7/8 的系统/附件/空行。
      expect(turn.hasMoreVariables, isFalse);
      expect(turn.imageHandled, isTrue);
      expect(await variables.bySession(sessionId), {'hp': '8'});
      expect(images.prompts, ['active scene']);
    });

    test('processes variable delta even when every chat row is compacted', () async {
      final history = await seedHistory(6);
      await messages.insertSystemAndCompact(
        sessionId: sessionId,
        content: 'summary only',
        compactIds: history.map((m) => m.id!).toList(),
      );
      final backend = _CapturingBackend('{"variables":{"hp":"8"}}');
      final turn = await orchestrator(backend).runAfterTurn(
        sessionId: sessionId,
        model: 'm',
        features: const BackgroundFeatures(variables: true, image: false),
        afterSeq: 0,
        throughSeq: 6,
      );
      expect(turn.skipped, isFalse);
      expect(turn.cursorSeq, 5);
      expect(_sectionBody(backend.lastPrompt!, 'variable_delta'), transcript(1, 5));
      expect(_sectionBody(backend.lastPrompt!, 'recent_conversation'), transcript(0, 0));
      expect(await variables.bySession(sessionId), {'hp': '8'});
    });

    for (final operation in ['upsert', 'rename', 'delete', 'clear', 'ABA']) {
      for (final emptyUpdate in [false, true]) {
        test('$operation during LLM rejects ${emptyUpdate ? 'empty' : 'stale'} updates and images', () async {
          await seedHistory(6);
          await variables.upsert(sessionId, 'hp', '10');
          await variables.upsert(sessionId, 'place', 'tavern');
          final before = await variables.snapshot(sessionId);
          final backend = _GatedBackend(emptyUpdate
              ? '{"variables":{},"imagePrompt":"stale scene"}'
              : '{"variables":{"hp":"8","place":"dungeon"},"imagePrompt":"stale scene"}');
          final images = _RecordingImageBackend();
          final pending = orchestrator(backend, images: images).runAfterTurn(
            sessionId: sessionId,
            model: 'm',
            afterSeq: 0,
            throughSeq: 5,
          );
          final request = await backend.started.future;
          expect(_sectionBody(request.systemPrompt, 'variables'), contains('"hp":"10"'));
          expect(_sectionBody(request.systemPrompt, 'variable_delta'), transcript(1, 5));

          // 独立仓库实例模拟状态面板写入,修订号必须跨实例共享。
          final manual = VariableRepository(variables.db);
          switch (operation) {
            case 'upsert':
              await manual.upsert(sessionId, 'hp', '99');
            case 'rename':
              await manual.update(sessionId, oldKey: 'hp', newKey: 'health', value: '99');
            case 'delete':
              await manual.delete(sessionId, 'hp');
            case 'clear':
              await manual.clear(sessionId);
            case 'ABA':
              await manual.upsert(sessionId, 'hp', '99');
              await manual.upsert(sessionId, 'hp', '10');
          }
          final expected = switch (operation) {
            'upsert' => {'hp': '99', 'place': 'tavern'},
            'rename' => {'health': '99', 'place': 'tavern'},
            'delete' => {'place': 'tavern'},
            'clear' => <String, String>{},
            _ => {'hp': '10', 'place': 'tavern'},
          };
          final edited = await manual.snapshot(sessionId);
          expect(edited.values, expected);
          expect(edited.revision, greaterThan(before.revision));
          backend.release.complete();
          final turn = await pending;
          await backend.finished.future;
          await turn.imageTask;

          expect(turn.skipped, isTrue);
          expect(turn.variableConflict, isTrue);
          expect(turn.skippedReason, isNotEmpty);
          expect(turn.failureReason, isNull);
          expectRejected(turn);
          final after = await variables.snapshot(sessionId);
          expect(after.values, expected); // 不覆盖人工值,不恢复删除或改名的旧键。
          expect(after.revision, edited.revision);
          expect(backend.requests, hasLength(1));
          expect(images.prompts, isEmpty);
          expect(await messages.bySession(sessionId), hasLength(6));
        });
      }
    }

    const invalidResponses = {
      'missing variables': '{"imagePrompt":"bad scene"}',
      'null variables': '{"variables":null,"imagePrompt":"bad scene"}',
      'array variables': '{"variables":[],"imagePrompt":"bad scene"}',
      'string variables': '{"variables":"hp=8","imagePrompt":"bad scene"}',
      'null value': '{"variables":{"hp":"8","bad":null},"imagePrompt":"bad scene"}',
      'object value': '{"variables":{"hp":"8","bad":{}},"imagePrompt":"bad scene"}',
      'array value': '{"variables":{"hp":"8","bad":[]},"imagePrompt":"bad scene"}',
      'blank key': '{"variables":{"hp":"8"," ":"bad"},"imagePrompt":"bad scene"}',
      'truncated root': '{"variables":{"hp":"8"},"imagePrompt":"bad scene"',
      'truncated value': '{"variables":{"hp":"8',
    };
    for (final invalid in invalidResponses.entries) {
      test('${invalid.key} fails after three attempts without writes or cursor progress', () async {
        await seedHistory(6);
        await variables.upsert(sessionId, 'hp', '10');
        final before = await variables.snapshot(sessionId);
        final backend = _CapturingBackend(invalid.value);
        final images = _RecordingImageBackend();
        final turn = await orchestrator(backend, images: images).runAfterTurn(
          sessionId: sessionId,
          model: 'm',
          afterSeq: 0,
          throughSeq: 5,
        );
        await turn.imageTask;
        expect(backend.requests, hasLength(3));
        for (final request in backend.requests) {
          expect(_sectionBody(request.systemPrompt, 'variable_delta'), transcript(1, 5));
        }
        expect(turn.skipped, isFalse);
        expect(turn.variableConflict, isFalse);
        expect(turn.failureReason, BackgroundFailureReason.parseFailure);
        expect(turn.failureDetail, isNotEmpty);
        expectRejected(turn);
        final after = await variables.snapshot(sessionId);
        expect(after.values, before.values);
        expect(after.revision, before.revision);
        expect(images.prompts, isEmpty);
        expect(await messages.bySession(sessionId), hasLength(6));
      });
    }

    for (final useSignal in [false, true]) {
      test('cancellation ${useSignal ? 'wakes a pending LLM' : 'rejects a late valid result'} without writes', () async {
        await seedHistory(6);
        await variables.upsert(sessionId, 'hp', '10');
        final before = await variables.snapshot(sessionId);
        final backend = _GatedBackend(
          '{"variables":{"hp":"8"},"imagePrompt":"cancelled scene"}',
        );
        final images = _RecordingImageBackend();
        var cancelled = false;
        final signal = Completer<void>();
        final pending = orchestrator(backend, images: images).runAfterTurn(
          sessionId: sessionId,
          model: 'm',
          afterSeq: 0,
          throughSeq: 5,
          shouldCancel: () => cancelled,
          cancelSignal: useSignal ? signal.future : null,
        );
        await backend.started.future;
        cancelled = true;
        late BackgroundTurnResult turn;
        try {
          if (useSignal) {
            signal.complete();
            turn = await pending;
            expect(backend.release.isCompleted, isFalse);
          } else {
            backend.release.complete();
            turn = await pending;
          }
        } finally {
          if (!backend.release.isCompleted) backend.release.complete();
          await backend.finished.future;
        }
        await turn.imageTask;
        expect(turn.skipped, isFalse);
        expect(turn.variableConflict, isFalse);
        expect(turn.failureReason, BackgroundFailureReason.cancelled);
        expectRejected(turn);
        final after = await variables.snapshot(sessionId);
        expect(after.values, before.values);
        expect(after.revision, before.revision);
        expect(backend.requests, hasLength(1));
        expect(images.prompts, isEmpty);
        expect(await messages.bySession(sessionId), hasLength(6));
      });
    }
  });

  group('initializeMemory (主动记忆初始化)', () {
    const card = CharacterCard(name: 'Alice', description: 'a silver-haired catgirl');
    const constantEntry = WorldbookEntry(
      characterId: 1,
      constant: true,
      content: 'Eldoria borders the Mistwood.',
    );

    test('writes the initial memory generated from character + constant worldbook', () async {
      final db = await openTestDb();
      final charId = await CharacterRepository(db).insert(card);
      final sessionId = await SessionRepository(db).create(charId, 's');

      final memRepo = MemoryRepository(db);
      final orch = Orchestrator(
        BackgroundEngine(_JsonBackend('{"memory":"Alice is a silver-haired catgirl from Eldoria."}')),
        VariableRepository(db),
        memRepo,
        MessageRepository(db),
        ImageGuideRepository(db),
      );
      final turn = await orch.initializeMemory(
        sessionId: sessionId,
        model: 'm',
        character: card,
        worldbook: const [constantEntry],
      );

      expect(turn.skipped, isFalse);
      expect(turn.result, isNotNull);
      expect(
        (await memRepo.bySession(sessionId)).single.content,
        'Alice is a silver-haired catgirl from Eldoria.',
      );
    });

    test('fails without writing when the LLM produces no valid memory (retries exhausted)', () async {
      // BM 批:缺 memory 字段在引擎层纳入重试;三次尝试耗尽后引擎返回
      // parseFailure,编排器不再落库(旧的"成功但无记忆 → skipped"路径已不可达)。
      final db = await openTestDb();
      final charId = await CharacterRepository(db).insert(card);
      final sessionId = await SessionRepository(db).create(charId, 's');

      final memRepo = MemoryRepository(db);
      final orch = Orchestrator(
        BackgroundEngine(_JsonBackend('{"memory":null}')),
        VariableRepository(db),
        memRepo,
        MessageRepository(db),
        ImageGuideRepository(db),
      );
      final turn = await orch.initializeMemory(sessionId: sessionId, model: 'm', character: card);

      expect(turn.skipped, isFalse);
      expect(turn.result, isNull);
      expect(turn.failureReason, BackgroundFailureReason.parseFailure);
      expect(turn.failureDetail, contains('memory'));
      expect(await memRepo.bySession(sessionId), isEmpty);
    });

    test('fails without writing when the backend errors', () async {
      final db = await openTestDb();
      final charId = await CharacterRepository(db).insert(card);
      final sessionId = await SessionRepository(db).create(charId, 's');

      final memRepo = MemoryRepository(db);
      final orch = Orchestrator(
        BackgroundEngine(_ErrorBackend()),
        VariableRepository(db),
        memRepo,
        MessageRepository(db),
        ImageGuideRepository(db),
      );
      final turn = await orch.initializeMemory(sessionId: sessionId, model: 'm', character: card);

      expect(turn.skipped, isFalse);
      expect(turn.result, isNull);
      expect(turn.failureReason, BackgroundFailureReason.backendError);
      // 引擎的诊断摘要(后端错误消息)透传到轮次结果,供状态面板披露。
      expect(turn.failureDetail, contains('boom'));
      expect(await memRepo.bySession(sessionId), isEmpty);
    });
  });
}

class _ErrorBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield const ErrorEvent('boom');
  }
}

class _ThrowingImageBackend implements ImageBackend {
  @override
  String get id => 'throwing';
  @override
  Future<ImageResult> generateImage(String prompt) async => throw Exception('provider down');
}

/// 按描述回显 URL 的单图后端:多张 = 多个不同描述,每个请求各画一张
/// (回环地址保证下载立即失败,走 URL 回退落库,不依赖外网)。
class _PromptKeyedImageBackend implements ImageBackend {
  @override
  String get id => 'keyed';
  @override
  Future<ImageResult> generateImage(String prompt) async =>
      ImageResult.single(url: 'http://127.0.0.1:1/${Uri.encodeComponent(prompt)}');
}

/// 指定描述必失败、其余回显固定 base64:验证部分失败时的落点对齐。
class _SelectivelyFailingImageBackend implements ImageBackend {
  _SelectivelyFailingImageBackend(this.failing);
  final Set<String> failing;
  final prompts = <String>[];

  @override
  String get id => 'selective';
  @override
  Future<ImageResult> generateImage(String prompt) async {
    prompts.add(prompt);
    if (failing.contains(prompt)) throw Exception('rejected: $prompt');
    return ImageResult.single(base64: 'aGVsbG8=');
  }
}

/// 返回空结果(极端 provider 行为):编排器按失败处理,不落任何消息。
class _EmptyImageBackend implements ImageBackend {
  @override
  String get id => 'empty';
  @override
  Future<ImageResult> generateImage(String prompt) async => const ImageResult([]);
}
