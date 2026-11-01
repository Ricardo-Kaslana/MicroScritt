// 后台引擎测试:LLM 响应解析与修复兜底、重试/取消语义、提示词分段与缓存前缀、
// 输出上限档位与截断规则。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/engine/background_engine.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/image_prompt_guide.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/models/worldbook_entry.dart';

class _JsonBackend implements LlmBackend {
  final String text;
  final TokenUsage? usage;
  _JsonBackend(this.text, {this.usage});

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield TextDelta(text);
    if (usage != null) yield UsageEvent(usage!);
    yield const DoneEvent();
  }
}

/// 记录收到的请求,供断言提示词形状。
class _RecordingBackend implements LlmBackend {
  final String text;
  LlmRequest? lastRequest;
  _RecordingBackend(this.text);

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    lastRequest = request;
    yield TextDelta(text);
    yield const DoneEvent();
  }
}

void main() {
  /// 便利:断言一轮结果成功并取出 [BackgroundResult]。
  BackgroundResult ok(BackgroundRunResult outcome) {
    expect(outcome, isA<BackgroundRunSuccess>(), reason: 'expected a successful turn');
    return (outcome as BackgroundRunSuccess).result;
  }

  test('parses variables; memory is dropped on fast-state turns; retired keys ignored', () async {
    final engine = BackgroundEngine(
      _JsonBackend('{"activeSkills":["combat"],"variables":{"hp":"8"},"memory":"Met a dragon"}'),
    );
    final result = ok(await engine.run(
      model: 'm',
      variables: const {'hp': '10'},
      history: const [Message(sessionId: 1, role: 'user', content: 'I draw my sword', seq: 0)],
    ));

    // v37 起技能是全局目录:LLM 仍可能回传 activeSkills 键,直接忽略。
    expect(result.variableUpdates, {'hp': '8'});
    // 记忆不经后台逐轮维护:快状态轮即便 LLM 回传 memory 也一律清空
    // (记忆只经 runMemoryInit/runMemoryRegenerate 主动路径产出)。
    expect(result.memoryUpdate, isNull);
  });

  test('tolerates markdown-wrapped JSON', () async {
    final engine = BackgroundEngine(_JsonBackend('```json\n{"activeSkills":[],"variables":{},"memory":null}\n```'));
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.memoryUpdate, isNull);
  });

  group('strict variable updates', () {
    // 任一字段类型非法即整批拒绝:半批落库会让玩家状态与模型输出各对一半。
    const invalidResponses = <String, String>{
      'missing field': '{}',
      'only image': '{"imagePrompt":"a cave"}',
      'string field': '{"variables":"bad"}',
      'numeric field': '{"variables":8}',
      'boolean field': '{"variables":false}',
      'null field': '{"variables":null}',
      'array field': '{"variables":[]}',
      'empty key': '{"variables":{"":"8"}}',
      'whitespace key': r'{"variables":{" \t\n":"8"}}',
      'null value': '{"variables":{"hp":null}}',
      'nested value': '{"variables":{"hp":{"value":8}}}',
      'list value': '{"variables":{"hp":[8]}}',
      'non-finite number': '{"variables":{"hp":1e400}}',
      'negative non-finite number': '{"variables":{"hp":-1e400}}',
      'mixed valid and invalid values': '{"variables":{"hp":"8","mp":null},"imagePrompt":"a cave"}',
      'invalid value before valid value': '{"variables":{"mp":[],"hp":"8"}}',
      'valid value and blank key': '{"variables":{"hp":"8"," ":"4"}}',
      'truncated nested object': '{"variables":{"hp":"8"',
      'unclosed root': '{"variables":{"hp":"8"}',
      'truncated string value': '{"variables":{"hp":"8',
      'truncated number value': '{"variables":{"hp":8',
      'truncated boolean value': '{"variables":{"hp":tru',
      'truncated second value': '{"variables":{"hp":"8","mp":',
      'truncated second key': '{"variables":{"hp":"8","mp',
      'truncated image after valid variables': '{"variables":{"hp":"8"},"imagePrompt":"a ca',
      'truncated removals': '{"variables":{},"removeVariables":["hp"',
      'unclosed parent around complete result': 'Result: {"result":{"variables":{"hp":"8"}}',
      'nested result is not the root': '{"result":{"variables":{"hp":"8"}}}',
      'outer array': '[{"variables":{"hp":"8"}}]',
      'wrapped outer array': 'Result: ```json\n[{"variables":{"hp":"8"}}]\n```',
      'unclosed outer array': '[{"variables":{"hp":"8"}}',
      'unquoted field': '{variables:{"hp":"8"}}',
      'trailing comma': '{"variables":{"hp":"8",}}',
      'unescaped newline': '{"variables":{"note":"line one\nline two"}}',
      'string root': r'"{\"variables\":{}}"',
    };
    for (final entry in invalidResponses.entries) {
      test('${entry.key} fails the whole batch after three attempts', () async {
        final backend = _ScriptedBackend([
          [TextDelta(entry.value), const DoneEvent()],
        ]);
        final outcome = await BackgroundEngine(backend).run(
          model: 'm',
          variables: const {'hp': '10'},
          history: const [],
        );
        expect(outcome, isA<BackgroundRunFailure>());
        expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.parseFailure);
        expect(backend.calls, 3);
      });
    }

    test('empty object is an explicit no-change success on the first attempt', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('{"variables":{}}'), const DoneEvent()],
      ]);
      final result = ok(await BackgroundEngine(backend).run(
        model: 'm', variables: const {'hp': '10'}, history: const [],
      ));
      expect(result.variableUpdates, isEmpty);
      expect(backend.calls, 1);
    });

    test('keeps strings and original keys while converting finite numbers and booleans', () async {
      const updates = {' hp ': '8', 'mp': 2.5, 'alive': true, 'hidden': false, 'empty': '', 'note': 'null'};
      final result = ok(await BackgroundEngine(_JsonBackend(jsonEncode({'variables': updates}))).run(
        model: 'm', variables: const {}, history: const [],
      ));
      expect(result.variableUpdates, {
        ' hp ': '8', 'mp': '2.5', 'alive': 'true', 'hidden': 'false', 'empty': '', 'note': 'null',
      });
      final numeric = ok(await BackgroundEngine(_JsonBackend('{"variables":{"hp":8,"debt":-2,"zero":0}}')).run(
        model: 'm', variables: const {}, history: const [],
      ));
      expect(numeric.variableUpdates, {'hp': '8', 'debt': '-2', 'zero': '0'});
    });

    test('ignores malformed image fields without discarding valid variables', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('{"variables":{"hp":"8"},"imagePrompt":{},"imagePrompts":"bad"}'), const DoneEvent()],
      ]);
      final result = ok(await BackgroundEngine(backend).run(model: 'm', variables: const {}, history: const []));
      expect(result.variableUpdates, {'hp': '8'});
      expect(result.imagePrompt, isNull);
      expect(result.imagePrompts, isNull);
      expect(backend.calls, 1);
    });

    test('strips thinking, fences and surrounding prose without changing string values', () async {
      const value = 'a "quoted" } [ value \\ end';
      final response = '<think>{"variables":{"hp":"stale"}}</think>\nResult:\n```json\n'
          '${jsonEncode({'variables': {'note': value}})}\n```\nDone }';
      final result = ok(await BackgroundEngine(_JsonBackend(response)).run(
        model: 'm', variables: const {}, history: const [],
      ));
      expect(result.variableUpdates, {'note': value});
    });

    test('validates every retry and accepts only the third complete batch', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('{"variables":"bad"}'), const DoneEvent()],
        [const TextDelta('{"variables":{"hp":"8"'), const DoneEvent()],
        [const TextDelta('{"variables":{"hp":7}}'), const DoneEvent()],
      ]);
      final result = ok(await BackgroundEngine(backend).run(
        model: 'm', variables: const {}, history: const [], maxTokens: 512,
      ));
      expect(result.variableUpdates, {'hp': '7'});
      expect(backend.calls, 3);
      expect(backend.requests.map((r) => r.maxTokens), [512, null, null]);
    });

    test('stops retrying when the second attempt explicitly reports no changes', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('{"variables":{"hp":"8","mp":null}}'), const DoneEvent()],
        [const TextDelta('{"variables":{}}'), const DoneEvent()],
        [const TextDelta('{"variables":{"hp":"7"}}'), const DoneEvent()],
      ]);
      final result = ok(await BackgroundEngine(backend).run(model: 'm', variables: const {}, history: const []));
      expect(result.variableUpdates, isEmpty);
      expect(backend.calls, 2);
    });

    test('image-only turns ignore missing or invalid variables', () async {
      for (final response in ['{"imagePrompt":"a cave"}', '{"variables":{"hp":null},"imagePrompt":"a cave"}']) {
        final backend = _ScriptedBackend([
          [TextDelta(response), const DoneEvent()],
        ]);
        final result = ok(await BackgroundEngine(backend).run(
          model: 'm',
          variables: const {},
          history: const [],
          features: const BackgroundFeatures(variables: false, image: true),
        ));
        expect(result.variableUpdates, isEmpty);
        expect(result.imagePrompt, 'a cave');
        expect(backend.calls, 1);
      }
    });

    test('active memory and guide turns retain repair despite invalid variables', () async {
      final engine = BackgroundEngine(_JsonBackend(
        '{"variables":"bad","memory":"line one\nline two","imageGuide":"fixed appearance',
      ));
      const card = CharacterCard(name: 'Alice');
      expect(ok(await engine.runMemoryInit(model: 'm', character: card)).memoryUpdate, 'line one\nline two');
      expect(ok(await engine.runMemoryRegenerate(model: 'm', character: card, history: const [])).memoryUpdate,
          'line one\nline two');
      expect(ok(await engine.runImageGuideInit(model: 'm', character: card)).imageGuide, 'fixed appearance');
    });
  });

  test('fails with parseFailure on malformed JSON', () async {
    final engine = BackgroundEngine(_JsonBackend('this is not json'));
    final outcome = await engine.run(model: 'm', variables: const {}, history: const []);
    expect(outcome, isA<BackgroundRunFailure>());
    expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.parseFailure);
  });

  test('fails with backendError when the backend emits an error event', () async {
    final engine = BackgroundEngine(_ErrorBackend());
    final outcome = await engine.run(model: 'm', variables: const {}, history: const []);
    expect(outcome, isA<BackgroundRunFailure>());
    expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.backendError);
  });

  test('parses imagePrompt from JSON', () async {
    final engine = BackgroundEngine(
      _JsonBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a sword in a cave"}'),
    );
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.imagePrompt, 'a sword in a cave');
  });

  test('treats a literal "null" imagePrompt string as absent', () async {
    final engine = BackgroundEngine(
      _JsonBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"null"}'),
    );
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.imagePrompt, isNull);
  });

  test('imageCount>1 demands N distinct scene descriptions via imagePrompts', () async {
    final backend = _RecordingBackend(
      '{"activeSkills":[],"variables":{},"memory":null,'
      '"imagePrompts":["wide shot of the cave","close-up of the sword","hero seen from behind"]}',
    );
    final engine = BackgroundEngine(backend);
    final result = ok(await engine.run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'I enter the cave', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: true),
      imageCount: 3,
    ));

    // 解析:三个描述按序保留。
    expect(result.imagePrompts, hasLength(3));
    expect(result.imagePrompts!.first, 'wide shot of the cave');
    expect(result.imagePrompts!.last, 'hero seen from behind');
    // 提示:JSON 形状换成数组,并明确要求「N 个不同描述」(不是复制同一描述)。
    final prompt = backend.lastRequest!.systemPrompt;
    expect(prompt, contains('"imagePrompts": ["<scene description 1>"'));
    expect(prompt, contains('DIFFERENT'));
    expect(prompt, contains('3 images'));
  });

  test('imageCount>1 with image disabled still drops imagePrompts (double insurance)', () async {
    final backend = _RecordingBackend(
      '{"activeSkills":[],"variables":{},"memory":null,"imagePrompts":["a","b"],"imagePrompt":"c"}',
    );
    final engine = BackgroundEngine(backend);
    final result = ok(await engine.run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: false),
      imageCount: 2,
    ));
    expect(result.imagePrompts, isNull);
    expect(result.imagePrompt, isNull);
    // 提示里也没有 image 字段。
    expect(backend.lastRequest!.systemPrompt, isNot(contains('imagePrompts')));
  });

  test('imagePrompts keeps only non-empty string entries (C2)', () async {
    final engine = BackgroundEngine(
      _JsonBackend(
        '{"activeSkills":[],"variables":{},"memory":null,"imagePrompts":["a", 42, "", "  ", "null", "b"]}',
      ),
    );
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.imagePrompts, ['a', 'b']);
  });

  test('malformed imagePrompts falls back to the single imagePrompt', () async {
    final engine = BackgroundEngine(
      _JsonBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompts":"oops","imagePrompt":"a cave"}'),
    );
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.imagePrompts, isNull);
    expect(result.imagePrompt, 'a cave');
  });

  test('accounts background usage separately from the main write', () async {
    final engine = BackgroundEngine(
      _JsonBackend(
        '{"activeSkills":[],"variables":{},"memory":null}',
        usage: const TokenUsage(inputTokens: 120, outputTokens: 15, cachedInputTokens: 80),
      ),
    );
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.usage.inputTokens, 120);
    expect(result.usage.outputTokens, 15);
    expect(result.usage.cachedInputTokens, 80);
    expect(result.usage.uncachedInputTokens, 40);
  });

  test('defaults usage to zero when the backend emits none', () async {
    final engine = BackgroundEngine(_JsonBackend('{"activeSkills":[],"variables":{},"memory":null}'));
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.usage.inputTokens, 0);
    expect(result.usage.outputTokens, 0);
  });

  group('variable delta prompt', () {
    String body(String prompt, String tag) {
      final start = prompt.indexOf('<$tag>');
      return prompt.substring(prompt.indexOf('\n', start) + 1, prompt.indexOf('</$tag>', start));
    }

    test('separates variable delta from image context and encodes current variables as JSON', () async {
      final backend = _RecordingBackend('{"variables":{}}');
      const variables = {' hp\n"quoted" ': '10\nmp = 99'};
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: variables,
        history: const [Message(sessionId: 1, role: 'assistant', content: 'Current scene at the tavern', seq: 5)],
        variableHistory: const [
          Message(sessionId: 1, role: 'user', content: 'Earlier unprocessed damage', seq: 2),
          Message(sessionId: 1, role: 'assistant', content: 'You lost two hit points', seq: 3),
        ],
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(body(prompt, 'recent_conversation'), 'assistant: Current scene at the tavern');
      expect(body(prompt, 'variable_delta'), 'user: Earlier unprocessed damage\nassistant: You lost two hit points');
      expect(jsonDecode(body(prompt, 'variables')), variables);
      expect(prompt, contains('Update variables ONLY from the variable_delta section'));
      expect(prompt, contains('Never replay old changes from the read-only recent_conversation'));
      expect(prompt, contains('Preserve existing keys exactly, including whitespace'));
      expect(prompt, contains('strings, finite numbers or booleans; never null, objects or arrays'));
      final imageRules = prompt.split('# image').last.split('</background_task>').first;
      expect(imageRules, contains('CURRENT scene read from the recent_conversation'));
      expect(imageRules, isNot(contains('variable_delta')));
    });

    test('authorizes creating new variable keys without losing dedupe guardrails', () async {
      final backend = _RecordingBackend('{"variables":{"location":"tavern"}}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {'hp': '10'},
        history: const [Message(sessionId: 1, role: 'user', content: 'We enter the tavern', seq: 0)],
        features: const BackgroundFeatures(variables: true, image: false),
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(prompt, contains('durable state board'));
      expect(prompt, contains('They are not a per-scene summary'));
      expect(prompt, contains('YOU MAY AND SHOULD CREATE NEW KEYS'));
      expect(prompt, contains('that no existing key covers'));
      expect(prompt, contains('Prefer updating an existing key over creating a near-duplicate'));
      expect(prompt, contains('do not track transient scene details'));
      expect(prompt, contains('New keys may always be created.'));
      expect(prompt, contains('a key you add that is not listed here creates a new variable'));
      expect(prompt, contains('New keys are always allowed and are not restricted here'));
    });

    test('omitted variableHistory falls back to history for variable-only turns', () async {
      final backend = _RecordingBackend('{"variables":{}}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [Message(sessionId: 1, role: 'user', content: 'Lose two hit points', seq: 0)],
        features: const BackgroundFeatures(variables: true, image: false),
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(body(prompt, 'variable_delta'), 'user: Lose two hit points');
      expect(body(prompt, 'variable_delta'), body(prompt, 'recent_conversation'));
      expect(body(prompt, 'variables'), '{}');
      expect(prompt, isNot(contains('# image')));
    });

    test('explicitly empty variableHistory does not replay readonly history', () async {
      final backend = _RecordingBackend('{"variables":{}}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [Message(sessionId: 1, role: 'user', content: 'Old damage already applied', seq: 0)],
        variableHistory: const [],
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(body(prompt, 'variable_delta'), isEmpty);
      expect(body(prompt, 'recent_conversation'), contains('Old damage already applied'));
    });

    test('disabled variables omit the delta and current variable blocks', () async {
      final backend = _RecordingBackend('{"imagePrompt":"a cave"}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {'hp': '10'},
        history: const [Message(sessionId: 1, role: 'assistant', content: 'Current cave scene', seq: 5)],
        variableHistory: const [Message(sessionId: 1, role: 'user', content: 'Unprocessed old damage', seq: 0)],
        features: const BackgroundFeatures(variables: false, image: true),
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(prompt, isNot(contains('<variable_delta>')));
      expect(prompt, isNot(contains('<variables>')));
      expect(prompt, isNot(contains('<variable_access>')));
      expect(prompt, isNot(contains('Unprocessed old damage')));
      expect(body(prompt, 'recent_conversation'), 'assistant: Current cave scene');
    });

    test('carries the removal contract and sorted access lists', () async {
      final backend = _RecordingBackend('{"variables":{},"removeVariables":[]}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {'a': '1', 'b': '2', 'c': '3'},
        history: const [Message(sessionId: 1, role: 'user', content: 'We leave the cave', seq: 0)],
        features: const BackgroundFeatures(variables: true, image: false),
        deletableVariables: const {'c', 'a'},
        readonlyVariables: const {'b'},
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(body(prompt, 'variable_access'), jsonEncode({
        'deletable': ['a', 'c'],
        'readonly': ['b'],
      }));
      expect(prompt, contains('"removeVariables"'));
      expect(prompt, contains('Only existing keys listed under variable_access.deletable'));
      expect(prompt, contains('At most 5 removals per run'));
      expect(prompt, contains('Never remove a key merely because it is absent from variable_delta'));
    });
  });

  group('rerun prompt', () {
    test('marks rerun runs and keeps the section out of normal runs', () async {
      const history = [
        Message(sessionId: 1, role: 'user', content: 'We enter the cave', seq: 0),
      ];
      final rerun = _RecordingBackend('{"variables":{}}');
      ok(await BackgroundEngine(rerun).run(
        model: 'm',
        variables: const {},
        history: history,
        features: const BackgroundFeatures(variables: true, image: false),
        rerunContext: const RerunContext(),
      ));
      final rerunPrompt = rerun.lastRequest!.systemPrompt;
      expect(rerunPrompt, contains('<rerun_instruction>'));
      expect(rerunPrompt, contains('RERUN of the previous background maintenance'));
      // 无方向时不出现方向块,但重跑标识仍在。
      expect(rerunPrompt, isNot(contains('The user requested this change in direction')));

      final normal = _RecordingBackend('{"variables":{}}');
      ok(await BackgroundEngine(normal).run(
        model: 'm',
        variables: const {},
        history: history,
        features: const BackgroundFeatures(variables: true, image: false),
      ));
      expect(normal.lastRequest!.systemPrompt, isNot(contains('<rerun_instruction>')));
    });

    test('carries the user direction and previous image descriptions', () async {
      final backend = _RecordingBackend('{"variables":{},"imagePrompt":"x"}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [
          Message(sessionId: 1, role: 'user', content: 'We enter the cave', seq: 0),
        ],
        rerunContext: const RerunContext(
          direction: 'make the night stormier',
          previousImagePrompts: ['wide shot of the street', 'close-up of her face'],
        ),
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(prompt, contains('make the night stormier'));
      expect(prompt, contains('1. wide shot of the street'));
      expect(prompt, contains('2. close-up of her face'));
      expect(prompt, contains('reference only'));
    });

    test('omits previous image descriptions when the image feature is off', () async {
      final backend = _RecordingBackend('{"variables":{}}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [
          Message(sessionId: 1, role: 'user', content: 'We enter the cave', seq: 0),
        ],
        features: const BackgroundFeatures(variables: true, image: false),
        rerunContext: const RerunContext(
          direction: 'set the weather to stormy',
          previousImagePrompts: ['wide shot of the street'],
        ),
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      // 方向仍作用于变量重跑;上一轮图片描述不注入。
      expect(prompt, contains('set the weather to stormy'));
      expect(prompt, isNot(contains('wide shot of the street')));
    });

    test('truncates overlong direction and previous image descriptions', () async {
      final longDirection = 'D' * (BackgroundEngine.maxRerunDirectionChars + 20);
      final longPrompt = 'P' * (BackgroundEngine.maxRerunPreviousImageChars + 20);
      final backend = _RecordingBackend('{"variables":{},"imagePrompt":"x"}');
      ok(await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [
          Message(sessionId: 1, role: 'user', content: 'We enter the cave', seq: 0),
        ],
        rerunContext: RerunContext(
          direction: longDirection,
          previousImagePrompts: [longPrompt],
        ),
      ));
      final prompt = backend.lastRequest!.systemPrompt;
      expect(prompt, contains('超长已截断'));
      expect(prompt, isNot(contains(longDirection)));
      expect(prompt, isNot(contains(longPrompt)));
    });
  });

  group('variable removals', () {
    test('parses explicit removals with exact keys and drops malformed entries', () async {
      final engine = BackgroundEngine(_JsonBackend(
        '{"variables":{},"removeVariables":["hp","hp","","  ","mp",7,null]}',
      ));
      final result = ok(await engine.run(
        model: 'm',
        variables: const {'hp': '1', 'mp': '2'},
        history: const [],
      ));
      expect(result.variableRemovals, ['hp', 'mp']);
    });

    test('a non-list removeVariables is ignored without dropping valid updates', () async {
      final engine = BackgroundEngine(_JsonBackend(
        '{"variables":{"hp":"8"},"removeVariables":"hp"}',
      ));
      final result = ok(await engine.run(
        model: 'm',
        variables: const {'hp': '1'},
        history: const [],
      ));
      expect(result.variableUpdates, {'hp': '8'});
      expect(result.variableRemovals, isEmpty);
    });

    test('image-only turns drop removals even when the model emits them', () async {
      final engine = BackgroundEngine(_JsonBackend(
        '{"variables":{},"removeVariables":["hp"],"imagePrompt":"a cave"}',
      ));
      final result = ok(await engine.run(
        model: 'm',
        variables: const {'hp': '1'},
        history: const [Message(sessionId: 1, role: 'user', content: 'a cave', seq: 0)],
        features: const BackgroundFeatures(variables: false, image: true),
      ));
      expect(result.variableRemovals, isEmpty);
      expect(result.imagePrompt, 'a cave');
    });
  });

  test('memory enters the fast-state prompt only as an explicit read-only anchor', () async {
    // 记忆/角色卡/世界书以只读锚定段进快状态轮(仅 image 开启时),
    // 让生图贴合剧情 —— 但不传就不注入,纯 variables 轮维持低成本。
    final plain = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    await BackgroundEngine(plain).run(
      model: 'm',
      variables: const {},
      history: const [],
      imageGuide: 'guide placeholder',
    );
    expect(plain.lastRequest!.systemPrompt, isNot(contains('</memory>')));

    // 传入记忆 + image 开启 → <memory> 锚定段(含内容)。
    final withImage = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a scene"}');
    await BackgroundEngine(withImage).run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: false, image: true),
      memory: 'Alice waits at the tavern.',
    );
    final imagePrompt = withImage.lastRequest!.systemPrompt;
    expect(imagePrompt, contains('<memory>'));
    expect(imagePrompt, contains('Alice waits at the tavern.'));
    expect(imagePrompt, contains('</memory>'));

    // 纯 variables 轮:即便传了记忆也不注入锚定段。
    final variablesOnly = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    await BackgroundEngine(variablesOnly).run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: true, image: false),
      memory: 'Alice waits at the tavern.',
    );
    expect(variablesOnly.lastRequest!.systemPrompt, isNot(contains('</memory>')));
  });

  group('结构化锚定段贴合剧情(ES 批;EU 批起世界书按选定而非常驻)', () {
    const card = CharacterCard(
      name: 'Alice',
      description: 'silver-haired knight',
      personality: 'calm',
      scenario: 'tavern at dusk',
    );
    const anchorEntry = WorldbookEntry(characterId: 1, background: true, content: 'The tavern sits by the river.');
    const constantOnlyEntry = WorldbookEntry(characterId: 1, constant: true, content: 'Resident but not picked.');
    const triggeredEntry = WorldbookEntry(characterId: 1, keys: ['sword'], content: 'Swords are forbidden.');
    const disabledAnchor = WorldbookEntry(characterId: 1, background: true, enabled: false, content: 'Hidden lore.');

    test('image 轮注入角色卡/记忆/世界书锚定段(只收选定且启用的条目)', () async {
      final backend = _RecordingBackend('{"imagePrompt":"a scene"}');
      await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
        features: const BackgroundFeatures(variables: false, image: true),
        memory: 'They met at the river tavern.',
        character: card,
        worldbook: const [triggeredEntry, anchorEntry, constantOnlyEntry, disabledAnchor],
      );
      final prompt = backend.lastRequest!.systemPrompt;
      expect(prompt, contains('<character>'));
      expect(prompt, contains('Name: Alice'));
      expect(prompt, contains('tavern at dusk'));
      expect(prompt, contains('<memory>'));
      expect(prompt, contains('They met at the river tavern.'));
      expect(prompt, contains('<worldbook_background>'));
      expect(prompt, contains('The tavern sits by the river.'));
      // 常驻但未选定不进;触发型与停用的也不进。
      expect(prompt, isNot(contains('Resident but not picked.')));
      expect(prompt, isNot(contains('Swords are forbidden.')));
      expect(prompt, isNot(contains('Hidden lore.')));
      // 生图指令要求画面源自最近对话、锚定于记忆。
      expect(prompt, contains('<recent_conversation>'));
      expect(prompt, contains('recent_conversation section is the ONLY source of truth'));
    });

    test('超长记忆/角色卡/世界书按各自上限截断保开头', () async {
      final longMemory = 'M' * (BackgroundEngine.maxBackgroundMemoryChars + 500);
      final longDescription = 'D' * (BackgroundEngine.maxBackgroundCharacterChars + 500);
      final longWorldbook = WorldbookEntry(
        characterId: 1,
        background: true,
        content: 'W' * (BackgroundEngine.maxBackgroundWorldbookEntryChars + 500),
      );
      final backend = _RecordingBackend('{"imagePrompt":"a scene"}');
      await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [],
        features: const BackgroundFeatures(variables: false, image: true),
        memory: longMemory,
        character: CharacterCard(name: 'Alice', description: longDescription),
        worldbook: [longWorldbook],
      );
      final prompt = backend.lastRequest!.systemPrompt;
      // 记忆整段截断到上限;世界书改为**逐条**截断,单条超长夹到单条上限
      // (不再是旧的总量 800 一刀切)。
      expect(prompt, contains('M' * BackgroundEngine.maxBackgroundMemoryChars));
      expect(prompt, isNot(contains('M' * (BackgroundEngine.maxBackgroundMemoryChars + 1))));
      expect(prompt, contains('W' * BackgroundEngine.maxBackgroundWorldbookEntryChars));
      expect(
        prompt,
        isNot(contains('W' * (BackgroundEngine.maxBackgroundWorldbookEntryChars + 1))),
      );
      // 角色卡含标签前缀,整体截断到上限:超长描述的尾巴被裁掉,并带截断标记。
      expect(prompt, isNot(contains(longDescription)));
      expect(prompt, contains('超长已截断'));
    });

    test('多条世界书逐条截断,position 靠后的外貌条目不被前面清零', () async {
      // 回归:此前只按总量截拼接后的整块,第一条吃光预算后靠后条目整段消失 ——
      // 用户勾选多条角色外貌设定时只有最前一条进上下文,生图丢了后面角色的定妆。
      // 现改为逐条截断(每条夹到 maxBackgroundWorldbookEntryChars),两条都完整存活。
      final a = 'A' * BackgroundEngine.maxBackgroundWorldbookEntryChars; // 恰好满额,不触发标记
      final b = 'B' * BackgroundEngine.maxBackgroundWorldbookEntryChars;
      final backend = _RecordingBackend('{"imagePrompt":"a scene"}');
      await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [],
        features: const BackgroundFeatures(variables: false, image: true),
        worldbook: [
          WorldbookEntry(characterId: 1, background: true, position: 0, content: a),
          WorldbookEntry(characterId: 1, background: true, position: 1, content: b),
        ],
      );
      final prompt = backend.lastRequest!.systemPrompt;
      // 两条各自满额进入(旧逻辑下第二条会被清零)。
      expect(prompt, contains(a));
      expect(prompt, contains(b));
      // 2000 字仍在总量 4000 以内,无截断标记。
      expect(prompt, isNot(contains('超长已截断')));
    });

    test('世界书逐条截断后仍受总量兜底', () async {
      // 单条超上限 → 各自夹到单条上限;拼合后若仍超总量 → 总量兜底再截一次。
      final big = 'C' * (BackgroundEngine.maxBackgroundWorldbookEntryChars + 400);
      final backend = _RecordingBackend('{"imagePrompt":"a scene"}');
      await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [],
        features: const BackgroundFeatures(variables: false, image: true),
        worldbook: [
          for (var i = 0; i < 5; i++)
            WorldbookEntry(characterId: 1, background: true, position: i, content: big),
        ],
      );
      final prompt = backend.lastRequest!.systemPrompt;
      // 5 × 1000 = 5000 > 总量 4000 → 尾部被总量截断,带标记。
      expect(prompt, contains('超长已截断'));
    });
  });

  test('carries the background reasoning level into the request; defaults to off', () async {
    // v48:后台推理强度是独立设置 —— 透传进 LlmRequest(openai 端点随后映射
    // reasoning_effort,anthropic 映射 thinking 预算,均有各自 wire 测试)。
    final recording = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    await BackgroundEngine(recording).run(
      model: 'm',
      variables: const {},
      history: const [],
      reasoningLevel: ReasoningLevel.high,
    );
    expect(recording.lastRequest!.reasoningLevel, ReasoningLevel.high);

    // 默认 off:不传时与历史行为一致(请求不带推理参数)。
    final plain = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    await BackgroundEngine(plain).run(
      model: 'm',
      variables: const {},
      history: const [],
    );
    expect(plain.lastRequest!.reasoningLevel, ReasoningLevel.off);
  });

  test('image turns carry the session image guide as the authoritative direction', () async {
    // 生图行为规范由会话级"生图指导"承载(与记忆分离)—— 开 image 时
    // 指导原文进提示,要求场景描述严格遵循其定妆与风格约束。
    final backend = _RecordingBackend(
      '{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a scene","imagePrompts":["a","b"]}',
    );
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'She draws her sword', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: true),
      imageCount: 2,
      imageGuide: '1girl, silver hair, violet eyes, black coat; POV only, never show the user.',
    );
    final prompt = backend.lastRequest!.systemPrompt;
    expect(prompt, contains('<image_guide>'));
    expect(prompt, contains('1girl, silver hair, violet eyes, black coat'));
    expect(prompt, contains('never alter what those'));
    // 多张时同样要求贴合指导。
    expect(prompt, contains('established appearance EXACTLY as pinned by the'));
    // 不传记忆时不出现记忆锚定段(锚定段是只读注入,不自行读库)。
    expect(prompt, isNot(contains('</memory>')));
  });

  test('image guide absent falls back to the built-in English tag guide', () async {
    final backend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a scene"}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'She enters the tavern', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: true),
    );
    final prompt = backend.lastRequest!.systemPrompt;
    // 指导为空时回退内置规范:tag 化输出 + kImageTagGuideEn 全文。
    expect(prompt, contains('<image_guide>'));
    expect(prompt, contains(kImageTagGuideEn));
    expect(prompt, isNot(contains('"memory"')));
  });

  test('prompt includes only enabled features and result drops disabled ones', () async {
    // 只开 variables:即便 LLM 仍返回了 memory/image,也要被丢弃。
    final backend = _RecordingBackend(
      '{"activeSkills":["combat"],"variables":{"hp":"8"},"memory":"Dragon cave",'
      '"panel":null,"imagePrompt":"a cave"}',
    );
    final engine = BackgroundEngine(backend);
    final result = ok(await engine.run(
      model: 'm',
      variables: const {'hp': '10'},
      history: const [Message(sessionId: 1, role: 'user', content: 'north', seq: 0)],
      features: const BackgroundFeatures(variables: true, image: false),
    ));

    // 提示里只有 variables 块,没有 memory/image 指令。
    final prompt = backend.lastRequest!.systemPrompt;
    expect(prompt, contains('<variables>'));
    expect(prompt, isNot(contains('Available skills')));
    expect(prompt, isNot(contains('# image')));
    expect(prompt, isNot(contains('<memory>')));

    // 只保留 variables 字段,其余即使 LLM 返回也被清空(记忆恒为 null)。
    expect(result.variableUpdates, {'hp': '8'});
    expect(result.memoryUpdate, isNull);
    expect(result.imagePrompt, isNull);
  });

  test('fails with cancelled when cancelled mid-stream', () async {
    var cancelled = false;
    final release = Completer<void>();
    final backend = _GateBackend('{"activeSkills":["combat"],"variables":{},"memory":null}', release.future);
    final engine = BackgroundEngine(backend);

    final future = engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      shouldCancel: () => cancelled,
    );
    // 等后台已发出一段文本。
    for (var i = 0; i < 40 && !backend.served; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(backend.served, isTrue);
    cancelled = true; // 中断。
    release.complete(); // 放行流结束 → 触发流结束后的取消检查。
    final outcome = await future;
    expect(outcome, isA<BackgroundRunFailure>());
    expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.cancelled);
  });

  test('when image is enabled the prompt REQUIRES imagePrompt instead of allowing null', () async {
    // 回归防护「后台生图不生效」:旧的 image 指令是"optional,否则 null",让后台
    // LLM 在纯文本 RP 里几乎总是返回 null → 自动生图从不触发。现在改为"always
    // provide 当前场景描述"。
    final backend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a torch-lit cave"}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'I enter the cave', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: true),
    );
    final prompt = backend.lastRequest!.systemPrompt;
    // 必须把 imagePrompt 作为必填、并明确要求始终提供场景描述(而非"否则 null")。
    expect(prompt, contains('"imagePrompt": "<'));
    expect(prompt, isNot(contains('or null')));
    expect(prompt, isNot(contains('only when a visual should be rendered')));
    expect(prompt.toLowerCase(), contains('always'));
  });

  test('image guidance embeds the NovelAI tag guide (tags, not prose)', () async {
    // 后台生图提示词从"自由自然语言画面描述"升级为"英文 NovelAI tag 串":
    // 无会话指导时回退 kImageTagGuideEn(八类组织/权重/画面限制/一致性)——
    // imagePrompt/imagePrompts 才可直接作生图后端的 tag。
    final backend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null,'
        '"imagePrompt":"1girl, silver hair, {{{{long hair}}}}, standing, bedroom, night, looking at viewer"}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'she enters the room', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: true),
    );
    final prompt = backend.lastRequest!.systemPrompt;
    // 指令要求严格遵循指导;指导本身(回退=内置规范)携带 tag 化要求与全文。
    expect(prompt, contains('EXACTLY as pinned by the'));
    expect(prompt, contains(kImageTagGuideEn));
    expect(prompt, contains('comma-separated English tags in NovelAI style'));
    // 关闭生图时 tag 规范不出现(只随 image 块下发,不污染其余后台请求)。
    final noImage = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    await BackgroundEngine(noImage).run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: false),
    );
    expect(noImage.lastRequest!.systemPrompt, isNot(contains(kImageTagGuideEn)));
  });

  test('image rounds cache only the stable background prefix', () async {
    final backend = _RecordingBackend('{"variables":{},"imagePrompt":"a scene"}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {'hp': '10'},
      history: const [Message(sessionId: 1, role: 'user', content: 'I draw my sword', seq: 0)],
      variableHistory: const [Message(sessionId: 1, role: 'user', content: 'I draw my sword', seq: 0)],
      imageGuide: 'fixed look',
      memory: 'met at the tavern',
      character: const CharacterCard(name: 'Alice'),
    );
    final request = backend.lastRequest!;
    // 稳定段 = 任务契约 + 生图锚定;易变的转录/变量留在可变尾部,不写入缓存。
    expect(request.cacheContext, isTrue);
    expect(request.cacheMessageBreakpoint, isFalse);
    final stable = request.stableSystemPart!;
    final variable = request.variableSystemPart!;
    expect(request.systemPrompt, '$stable\n\n$variable');
    expect(stable, contains('<background_task>'));
    expect(stable, contains('<image_guide>'));
    expect(stable, contains('<character>'));
    expect(stable, contains('<memory>'));
    expect(stable, isNot(contains('<recent_conversation>')));
    expect(stable, isNot(contains('<variable_delta>')));
    expect(variable, contains('<recent_conversation>'));
    expect(variable, contains('<variable_delta>'));
    expect(variable, contains('<variables>'));
    expect(variable, contains('<variable_access>'));
  });

  test('stable prefix stays byte-identical across image rounds', () async {
    final backend = _RecordingBackend('{"variables":{},"imagePrompt":"x"}');
    final engine = BackgroundEngine(backend);
    Future<({String stable, String variable})> runRound({
      required String reply,
      required int seq,
      required Map<String, String> variables,
    }) async {
      await engine.run(
        model: 'm',
        variables: variables,
        history: [
          const Message(sessionId: 1, role: 'user', content: 'hi', seq: 0),
          Message(sessionId: 1, role: 'assistant', content: reply, seq: seq),
        ],
        variableHistory: [Message(sessionId: 1, role: 'assistant', content: reply, seq: seq)],
        imageGuide: 'fixed look',
        memory: 'met at the tavern',
        character: const CharacterCard(name: 'Alice'),
      );
      return (
        stable: backend.lastRequest!.stableSystemPart!,
        variable: backend.lastRequest!.variableSystemPart!,
      );
    }

    final first = await runRound(reply: 'first reply', seq: 1, variables: const {'hp': '10'});
    final second = await runRound(reply: 'second reply', seq: 2, variables: const {'hp': '9'});
    // 转录与变量每轮变化,但稳定前缀逐字节一致,缓存断点才有意义。
    expect(second.stable, first.stable);
    expect(second.variable, isNot(first.variable));
  });

  test('variable-only rounds keep prompt caching off and send one plain system prompt', () async {
    final backend = _RecordingBackend('{"variables":{}}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {'hp': '10'},
      history: const [Message(sessionId: 1, role: 'user', content: 'I draw my sword', seq: 0)],
      features: const BackgroundFeatures(variables: true, image: false),
    );
    final request = backend.lastRequest!;
    // 变量轮稳定段只有任务契约,达不到 Anthropic 的最小缓存段长,继续整串发送。
    expect(request.cacheContext, isFalse);
    expect(request.cacheMessageBreakpoint, isFalse);
    expect(request.stableSystemPart, isNull);
    expect(request.variableSystemPart, isNull);
    // 整串提示为结构化标签分段:任务说明 + 转录 + 状态块。
    final prompt = request.systemPrompt;
    expect(prompt, contains('background state-maintenance agent'));
    expect(prompt, contains('<recent_conversation>'));
    expect(prompt, contains('user: I draw my sword'));
    // 技能已迁出后台维护(v37):提示不再包含 skills 状态块。
    expect(prompt, isNot(contains('Available skills')));
    expect(prompt, contains('<variables>'));
    expect(prompt, contains('{"hp":"10"}'));
    // 不传记忆时不注入记忆锚定段。
    expect(prompt, isNot(contains('</memory>')));
    expect(request.messages.single.content, isNot(contains('I draw my sword')));
  });

  test('rerun instruction stays in the volatile part to keep anchors cacheable', () async {
    final backend = _RecordingBackend('{"variables":{},"imagePrompt":"x"}');
    await BackgroundEngine(backend).run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
      rerunContext: const RerunContext(direction: 'darker'),
    );
    final request = backend.lastRequest!;
    expect(request.cacheContext, isTrue);
    expect(request.stableSystemPart, isNot(contains('<rerun_instruction>')));
    expect(request.variableSystemPart, contains('<rerun_instruction>'));
    // 重跑说明位于整段提示的最末,作为模型最后读到的指令。
    expect(request.variableSystemPart!.trimRight(), endsWith('</rerun_instruction>'));
  });

  test('omits the state block when no state features are enabled', () async {
    final backend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a cave"}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {},
      history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
      features: const BackgroundFeatures(variables: false, image: true),
    );
    final request = backend.lastRequest!;
    final prompt = request.systemPrompt;
    expect(prompt, contains('Always fill this field'));
    expect(prompt, isNot(contains('Available skills')));
    expect(prompt, isNot(contains('Current variables')));
    expect(prompt, isNot(contains('Current long-term memory')));
  });

  test('memory regenerate prompt carries full transcript + draft, capping the draft at maxMemoryChars', () async {
    // 全量重生成:角色卡 + 全部活跃对话 + 既有记忆草稿一并送入;既有记忆
    // 超长时截断保留开头(与记忆截断兜底同规格)。
    final backend = _RecordingBackend('{"memory":"new memory"}');
    final engine = BackgroundEngine(backend);
    final longDraft = '${'fact-'.padRight(BackgroundEngine.maxMemoryChars, 'x')}ZZTAILZZ';
    await engine.runMemoryRegenerate(
      model: 'm',
      character: const CharacterCard(name: 'Alice', description: 'knight'),
      history: [
        const Message(sessionId: 1, role: 'user', content: 'q1', seq: 0),
        const Message(sessionId: 1, role: 'assistant', content: 'a1', seq: 1),
        // 附件行不进重生成转录。
        Message(sessionId: 1, role: 'user', content: '<system-reminder>lore</system-reminder>', seq: 2, kind: MessageKind.attachment, refId: 'wb:1'),
        const Message(sessionId: 1, role: 'system', content: 'summary row', seq: 3),
      ],
      currentMemory: longDraft,
    );
    final prompt = backend.lastRequest!.systemPrompt;
    expect(prompt, contains('recomposing the long-term memory'));
    expect(prompt, contains('Full conversation transcript'));
    expect(prompt, contains('user: q1'));
    expect(prompt, contains('assistant: a1'));
    expect(prompt, isNot(contains('system-reminder')));
    expect(prompt, isNot(contains('summary row')));
    expect(prompt, contains('Existing memory'));
    expect(prompt, contains(longDraft.substring(0, 200)));
    expect(prompt, contains('已截断'));
    expect(prompt, isNot(contains('ZZTAILZZ')));
    final result = ok(await engine.runMemoryRegenerate(
      model: 'm',
      character: const CharacterCard(name: 'Alice'),
      history: const [],
    ));
    expect(result.memoryUpdate, 'new memory');
  });

  test('image guide init prompt asks for fixed-appearance tag guide from the card', () async {
    final backend = _RecordingBackend('{"imageGuide":"1girl, silver hair, {{{blue eyes}}}"}');
    final engine = BackgroundEngine(backend);
    final outcome = await engine.runImageGuideInit(
      model: 'm',
      character: const CharacterCard(name: 'Alice', description: 'silver-haired knight'),
      worldbook: const [WorldbookEntry(characterId: 1, keys: [], constant: true, content: 'She never removes her coat.')],
    );
    final prompt = backend.lastRequest!.systemPrompt;
    expect(prompt, contains('image direction guide'));
    expect(prompt, contains('FIXED appearance'));
    expect(prompt, contains('never drift'));
    expect(prompt, contains('Name: Alice'));
    expect(prompt, contains('She never removes her coat.'));
    final result = ok(outcome);
    expect(result.imageGuide, '1girl, silver hair, {{{blue eyes}}}');
    // 缺 imageGuide 字段 → parseFailure 细分(主动轮成功判据)。
    final missing = await BackgroundEngine(_JsonBackend('{"imagePrompt":"x"}')).runImageGuideInit(
      model: 'm',
      character: const CharacterCard(name: 'A'),
    );
    expect(missing, isA<BackgroundRunFailure>());
    expect((missing as BackgroundRunFailure).reason, BackgroundFailureReason.parseFailure);
  });

  test('applies valid fields even when another field is malformed (C2)', () async {
    // activeSkills 已是退役键(v37):即便 LLM 把它给成字符串也不影响其余字段;
    // memory 字段的容错经主动记忆轮(runMemoryInit)验证 —— 快状态轮恒清空。
    final engine = BackgroundEngine(
      _JsonBackend('{"activeSkills":"combat","variables":{"hp":"8"},"memory":"Dragon cave"}'),
    );
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.variableUpdates, {'hp': '8'}); // 其余字段不受影响
    expect(result.memoryUpdate, isNull); // 快状态轮记忆恒清空
    final active = ok(await engine.runMemoryInit(
      model: 'm',
      character: const CharacterCard(name: 'A'),
    ));
    expect(active.memoryUpdate, 'Dragon cave');
  });

  test('clamps background temperature and caps maxTokens by default', () async {
    final backend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    final engine = BackgroundEngine(backend);
    await engine.run(model: 'm', variables: const {}, history: const []);
    final request = backend.lastRequest!;
    expect(request.temperature, BackgroundEngine.maxTemperature);
    // 快状态轮统一 maxOutputTokens 防跑飞(记忆轮放宽档只属主动轮)。
    expect(request.maxTokens, BackgroundEngine.maxOutputTokens);
  });

  test('passes through lower temperature and maxTokens untouched', () async {
    final backend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      temperature: 0.2,
      maxTokens: 512,
    );
    final request = backend.lastRequest!;
    expect(request.temperature, 0.2);
    expect(request.maxTokens, 512);
  });

  test('clamps excessive temperature and maxTokens down to the caps', () async {
    final backend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    final engine = BackgroundEngine(backend);
    await engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      temperature: 0.9,
      maxTokens: 9999,
      features: const BackgroundFeatures(variables: true, image: false),
    );
    final request = backend.lastRequest!;
    expect(request.temperature, BackgroundEngine.maxTemperature);
    // 快状态轮统一 maxOutputTokens(用户给的 9999 也被掐到这);
    // 放宽档 maxOutputTokensMemory 只属于记忆主动轮(init/regenerate)。
    expect(request.maxTokens, BackgroundEngine.maxOutputTokens);
  });

  test('fast-state turns keep the 2048 cap; memory active rounds widen it', () async {
    // 快状态轮(变量/image)维持 maxOutputTokens 防跑飞;记忆主动轮
    // (初始化/全量重生成)产出全量记忆文本,上限放宽到 maxOutputTokensMemory。
    final fastBackend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a cave"}');
    await BackgroundEngine(fastBackend).run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: false, image: true),
    );
    expect(fastBackend.lastRequest!.maxTokens, BackgroundEngine.maxOutputTokens);

    final regenBackend = _RecordingBackend('{"memory":"m"}');
    await BackgroundEngine(regenBackend).runMemoryRegenerate(
      model: 'm',
      character: const CharacterCard(name: 'A'),
      history: const [],
    );
    expect(regenBackend.lastRequest!.maxTokens, BackgroundEngine.maxOutputTokensMemory);
  });

  test('output tier scales the first-attempt cap; unlimited sends none (EX 批)', () async {
    // 档位映射(v54):compact 半量 / standard 基准 / relaxed 倍量 / unlimited
    // 首试也不发送 max_tokens(与重试同待遇);快状态轮与记忆主动轮各按档位取值。
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.compact, memory: false), 1024);
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.compact, memory: true), 2048);
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.standard, memory: false), BackgroundEngine.maxOutputTokens);
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.standard, memory: true), BackgroundEngine.maxOutputTokensMemory);
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.relaxed, memory: false), 4096);
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.relaxed, memory: true), 8192);
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.unlimited, memory: false), isNull);
    expect(BackgroundEngine.outputCapFor(BackgroundOutputTier.unlimited, memory: true), isNull);

    // 请求形状:快状态轮 compact → 1024;unlimited → 请求不带 max_tokens。
    final compactBackend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    await BackgroundEngine(compactBackend).run(
      model: 'm',
      variables: const {},
      history: const [],
      tier: BackgroundOutputTier.compact,
    );
    expect(compactBackend.lastRequest!.maxTokens, 1024);

    final unlimitedBackend = _RecordingBackend('{"activeSkills":[],"variables":{},"memory":null}');
    await BackgroundEngine(unlimitedBackend).run(
      model: 'm',
      variables: const {},
      history: const [],
      tier: BackgroundOutputTier.unlimited,
    );
    expect(unlimitedBackend.lastRequest!.maxTokens, isNull);

    // 记忆主动轮 relaxed → 8192;unlimited → 不带 max_tokens。
    final memRelaxedBackend = _RecordingBackend('{"memory":"m"}');
    await BackgroundEngine(memRelaxedBackend).runMemoryInit(
      model: 'm',
      character: const CharacterCard(name: 'A'),
      tier: BackgroundOutputTier.relaxed,
    );
    expect(memRelaxedBackend.lastRequest!.maxTokens, 8192);

    final memUnlimitedBackend = _RecordingBackend('{"memory":"m"}');
    await BackgroundEngine(memUnlimitedBackend).runMemoryInit(
      model: 'm',
      character: const CharacterCard(name: 'A'),
      tier: BackgroundOutputTier.unlimited,
    );
    expect(memUnlimitedBackend.lastRequest!.maxTokens, isNull);
  });

  test('repairs a JSON value truncated by the output cap, keeping the leading fields', () async {
    // 输出到上限被截断(memory 值写到一半):修复兜底补上收尾引号与右括号,memory
    // 字段(JSON 形状排最前)整段存活;截断发生点之后的字段自然缺失,不再整轮
    // "解析失败"。
    final engine = BackgroundEngine(
      _JsonBackend('{"memory":"The sword is cursed. The dragon sleeps under the mountain, '
          'its hoard of silver untouched for a thousand years."'),
    );
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, contains('The sword is cursed.'));
    expect(result.imagePrompt, isNull);
  });

  test('repairs unescaped newlines inside a memory string value', () async {
    // 模型把多行记忆直接写进 JSON 字符串(未转义换行)→ 整串解码炸;修复按
    // 真实换行转义后成功解析,换行内容原样保留。
    final engine = BackgroundEngine(
      _JsonBackend('{"memory":"line one\nline two","imagePrompt":"a cave"}'),
    );
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, 'line one\nline two');
    final fast = ok(await engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: false, image: true),
    ));
    expect(fast.imagePrompt, 'a cave');
  });

  test('repairs truncation between fields, keeping the earlier field', () async {
    // 截断发生在 memory 完整落出之后、下一个键刚开始:memory 保留,尾部字段缺失,
    // 不再整轮解析失败。
    final engine = BackgroundEngine(
      _JsonBackend('{"memory":"Dragon cave","imageProm'),
    );
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, 'Dragon cave');
    expect(result.imagePrompt, isNull);
  });

  test('repairs an unquoted imagePrompt key', () async {
    // 裸键漏引号(模型常见笔误)→ 修复补引号,两个字段照常解出。
    final engine = BackgroundEngine(
      _JsonBackend('{"memory":"Dragon cave", imagePrompt: "a torch-lit cave"}'),
    );
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, 'Dragon cave');
    final fast = ok(await engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: false, image: true),
    ));
    expect(fast.imagePrompt, 'a torch-lit cave');
  });

  test('repairs a head-cut quoted key and does NOT crash with RangeError', () async {
    // 输出掐在「键已闭合、值未开始」的位置(`{"activeSkills"`):旧修复补不出
    // `:null`,修出的 `{"activeSkills"}` 无法解析;且 _repairJson 在 start==0
    // 时做 `lastIndexOf('{', -1)` 抛 RangeError,逃出 run() 变成整轮异常。
    // 现在补 `:null` 成 `{"activeSkills":null}`,键下的 null 被字段级容错吸收。
    final engine = BackgroundEngine(_JsonBackend('{"activeSkills"'));
    final result = ok(await engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: false, image: true),
    ));
    // 修复补 ":null" 成可解析对象;退役键被忽略,整轮不判解析失败。
    expect(result.memoryUpdate, isNull);
    expect(result.variableUpdates, isEmpty);
  });

  test('repairs a full object truncated right after a later key', () async {
    // 记忆在前已完整落出,截断停在第二个键 `"imagePrompt"` 之后:补 `:null`
    // 保住 memory 与整体可解析(不再整轮解析失败)。
    final engine = BackgroundEngine(_JsonBackend('{"memory":"Dragon cave","imagePrompt"'));
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, 'Dragon cave');
    expect(result.imagePrompt, isNull);
  });

  test('repairs array elements after a comma even when non-string', () async {
    // 旧代码 `afterColon = stack.last == '['` 在栈里永远遇不到 '['(栈存闭合
    // 括号),数组逗号后的裸值(null/数字)被当成键,修出 `["one","42":null]`
    // 无法解析 → 整轮解析失败。现在按 `stack.last == ']'` 判断数组内逗号,
    // 裸值照常落出;坏项仍由 _asPromptList 过滤。
    final engine = BackgroundEngine(_JsonBackend('{"memory":"abc","imagePrompts":["one",42,true,"two","t'));
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, 'abc');
    final fast = ok(await engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: false, image: true),
    ));
    // 只收字符串项:42/true 被丢弃,"t"(截断尾巴被补引号救回)保留。
    expect(fast.imagePrompts, ['one', 'two', 't']);
  });

  test('escapes control characters besides newline/tab inside string values', () async {
    // 旧修复只转义 \n\r\t;其它 C0 控制字符(\b\f\v\0…)原样写进字符串,
    // jsonDecode 一律拒绝 → 整轮解析失败。现在按 \uXXXX 转义救回整段。
    final engine = BackgroundEngine(
      _JsonBackend('{"memory":"la\u0008ne d\x0cw","imagePrompt":"x"}'),
    );
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, 'la\u0008ne d\x0cw');
  });

  test('a truncated key alone still parses instead of failing the turn', () async {
    // 输出在一开始(仅一个未闭合键)就被截断 → 修复救出空对象,内存/生图照旧
    // 无更新,但不误报"解析失败"。
    final engine = BackgroundEngine(_JsonBackend('{"memor'));
    final result = ok(await engine.run(
      model: 'm',
      variables: const {},
      history: const [],
      features: const BackgroundFeatures(variables: false, image: true),
    ));
    expect(result.memoryUpdate, isNull);
  });

  test('repair prefers the last JSON object over leading reasoning', () async {
    // 模型先输出思考(带花括号)再给目标对象,且目标对象被截断:整串/切片都救不回
    // 时,修复按"最后一个 {" 候选命中目标对象。
    final engine = BackgroundEngine(
      _JsonBackend('Let me think: {maybe} Final JSON: {"memory":"Dragon cave","imagePrompt'),
    );
    final result = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(result.memoryUpdate, 'Dragon cave');
  });

  test('parses a JSON object followed by trailing text containing a closing brace', () async {
    // 旧实现 first-{/last-} 切片会取到末尾的 },导致整轮解析失败。
    final engine = BackgroundEngine(_JsonBackend('{"activeSkills":[],"variables":{"hp":"7"},"memory":null} done }'));
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.variableUpdates, {'hp': '7'});
  });

  test('parses JSON whose string values contain braces', () async {
    final engine = BackgroundEngine(
      _JsonBackend('{"activeSkills":[],"variables":{"note":"a } b"},"memory":"met a {dragon}"}'),
    );
    final result = ok(await engine.run(model: 'm', variables: const {}, history: const []));
    expect(result.variableUpdates, {'note': 'a } b'});
    final active = ok(await engine.runMemoryInit(model: 'm', character: const CharacterCard(name: 'A')));
    expect(active.memoryUpdate, 'met a {dragon}');
  });

  test('rejects non-object top-level JSON', () async {
    final engine = BackgroundEngine(_JsonBackend('[1,2,3]'));
    final outcome = await engine.run(model: 'm', variables: const {}, history: const []);
    expect(outcome, isA<BackgroundRunFailure>());
    expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.parseFailure);
  });

  group('瞬态失败重试与诊断摘要(BK 批)', () {
    Future<BackgroundRunResult> turn(LlmBackend backend) => BackgroundEngine(backend).run(
          model: 'm',
          variables: const {},
          history: const [],
        );

    test('首试后端报错、重试成功 → 整轮成功(共两次调用)', () async {
      final backend = _ScriptedBackend([
        [const ErrorEvent('upstream reset')],
        [
          const TextDelta('{"memory":"ok"}'),
          const DoneEvent(),
        ],
      ]);
      // 记忆主动轮同样走"首试 + 瞬态重试":报错后重试拿到有效 memory。
      final init = ok(await BackgroundEngine(backend).runMemoryInit(
        model: 'm',
        character: const CharacterCard(name: 'A'),
      ));
      expect(init.memoryUpdate, 'ok');
      expect(backend.calls, 2);
    });

    test('两次都解析失败 → parseFailure,detail 带最后一次响应片段(BM 批:共三次尝试)', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('first garbage'), const DoneEvent()],
        [const TextDelta('second garbage'), const DoneEvent()],
      ]);
      final outcome = await turn(backend);
      expect(outcome, isA<BackgroundRunFailure>());
      final failure = outcome as BackgroundRunFailure;
      expect(failure.reason, BackgroundFailureReason.parseFailure);
      expect(failure.detail, contains('second garbage'));
      expect(backend.calls, BackgroundEngine.maxAttemptsPerRound);
    });

    test('空响应(只有 DONE)→ parseFailure,detail 注明模型未返回内容', () async {
      final backend = _ScriptedBackend([
        [const DoneEvent()],
        [const DoneEvent()],
      ]);
      final outcome = await turn(backend);
      expect(outcome, isA<BackgroundRunFailure>());
      final failure = outcome as BackgroundRunFailure;
      expect(failure.reason, BackgroundFailureReason.parseFailure);
      expect(failure.detail, contains('未返回任何内容'));
      expect(backend.calls, BackgroundEngine.maxAttemptsPerRound);
    });

    test('只有思考没有正文 → parseFailure,detail 注明只有思考内容', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('<think>budget burned here</think>'), const DoneEvent()],
        [const TextDelta('<think>again</think>'), const DoneEvent()],
      ]);
      final outcome = await turn(backend);
      expect(outcome, isA<BackgroundRunFailure>());
      expect((outcome as BackgroundRunFailure).detail, contains('思考'));
    });

    test('<think>…</think> 包裹的正文 JSON 正常解析', () async {
      final backend = _JsonBackend(
        '<think>The user wants a scene tag string. {drafting}</think>\n'
        '{"variables":{},"imagePrompt":"1girl, silver hair"}',
      );
      final result = ok(await turn(backend));
      expect(result.imagePrompt, '1girl, silver hair');
    });

    test('思考被截断、正文在最后一个 </think> 之后 → 取其后部分解析', () async {
      final backend = _JsonBackend(
        '<think>long reasoning {"partial": true} cut off by token limit</think>'
        '{"memory":"recovered"}',
      );
      final result = ok(await BackgroundEngine(backend).runMemoryInit(
        model: 'm',
        character: const CharacterCard(name: 'A'),
      ));
      expect(result.memoryUpdate, 'recovered');
    });

    test('取消不重试:首次命中 cancelled 即返回(只调用一次)', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('{"memory":"x"}'), const DoneEvent()],
      ]);
      final outcome = await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [],
        shouldCancel: () => true,
      );
      expect(outcome, isA<BackgroundRunFailure>());
      expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.cancelled);
      expect(backend.calls, 1);
    });
  });

  group('cancelSignal 即时唤醒(CR 批)', () {
    test('流挂起(零事件期)cancelSignal 触发即立刻返回 cancelled,不等流事件', () async {
      // 旧实现下 shouldCancel 只能在下个流事件到达时才命中,LLM 思考期
      // 0~30 秒不吐首块时中断按钮要等这么久才生效;cancelSignal
      // 镜像主写的中断令牌语义,令牌完成即解除等待。
      final release = Completer<void>();
      final backend = _HangingBackend(release.future);
      final engine = BackgroundEngine(backend);
      var cancelled = false;
      final cancelSignal = Completer<void>();

      // cancelSignal 尚未完成时:run 应在挂起态不返回。
      final future = engine.run(
        model: 'm',
        variables: const {},
        history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
        shouldCancel: () => cancelled,
        cancelSignal: cancelSignal.future,
      );
      // 给监听链一个微任务周期,确保订阅已挂上但流仍空。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // 此刻 future 仍未完成(流挂起,无事件可消费)。
      expect(future, isNot(completion));

      // 触发取消信号(模拟主写的中断令牌到达)。
      cancelled = true;
      cancelSignal.complete();

      // 应在远小于流自然结束的等待时间内收敛到 cancelled。
      final outcome = await future.timeout(const Duration(milliseconds: 500));
      expect(outcome, isA<BackgroundRunFailure>());
      expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.cancelled);
      // 流仍挂起 —— 显式释放避免后端 teardown 警告。
      release.complete();
    });

    test('cancelSignal 在引擎启动时已立即触发则进入即返回 cancelled', () async {
      // 已取消场景也要立即生效:cancelSignal 完成后启动 run,whenComplete
      // 同步回调直接 complete,future 不挂起。
      final backend = _HangingBackend(Completer<void>().future);
      final engine = BackgroundEngine(backend);
      final cancelSignal = Completer<void>()..complete();

      final outcome = await engine
          .run(
            model: 'm',
            variables: const {},
            history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
            shouldCancel: () => true,
            cancelSignal: cancelSignal.future,
          )
          .timeout(const Duration(milliseconds: 500));
      expect(outcome, isA<BackgroundRunFailure>());
      expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.cancelled);
    });
  });

  group('重试放开输出上限与结构化 memory 兜底(BL 批)', () {
    test('首试带档位上限、重试请求不带 max_tokens(推理模型思考计入预算的根治)', () async {
      // 首试空响应(预算被推理烧尽,正文为空)→ 重试放开上限后成功。
      final backend = _ScriptedBackend([
        [const DoneEvent()],
        [
          const TextDelta('{"memory":"recovered after uncapped retry"}'),
          const DoneEvent(),
        ],
      ]);
      final result = ok(await BackgroundEngine(backend).runMemoryInit(
        model: 'm',
        character: const CharacterCard(name: 'Alice'),
      ));
      expect(result.memoryUpdate, 'recovered after uncapped retry');
      expect(backend.calls, 2);
      // 首试:memory 主动轮档位上限;重试:null = 不发送 max_tokens,与主写同待遇。
      expect(backend.requests[0].maxTokens, BackgroundEngine.maxOutputTokensMemory);
      expect(backend.requests[1].maxTokens, isNull);
    });

    test('memory 字段为结构化对象时序列化为文本,不再判未产出有效记忆', () async {
      final engine = BackgroundEngine(_JsonBackend('{"memory":{"identity":"Alice","looks":"silver hair"}}'));
      final outcome = await engine.runMemoryInit(
        model: 'm',
        character: const CharacterCard(name: 'Alice'),
      );
      final result = ok(outcome);
      expect(result.memoryUpdate, '{"identity":"Alice","looks":"silver hair"}');
    });
  });

  group('初始化缺 memory 字段纳入重试(BM 批)', () {
    const card = CharacterCard(name: 'Alice');

    test('解析成功但缺 memory → 重试直至产出非空 memory(首试带档位、重试放开)', () async {
      // 前两次解析"成功"但没有有效 memory(推理模型偶发 {} / {"memory":null}),
      // 第三次产出 —— 旧实现直接判"未产出有效记忆"不重试。
      final backend = _ScriptedBackend([
        [const TextDelta('{}'), const DoneEvent()],
        [const TextDelta('{"memory":null}'), const DoneEvent()],
        [
          const TextDelta('{"memory":"third time produces"}'),
          const DoneEvent(),
        ],
      ]);
      final result = ok(await BackgroundEngine(backend).runMemoryInit(
        model: 'm',
        character: card,
      ));
      expect(result.memoryUpdate, 'third time produces');
      expect(backend.calls, 3);
      // 首试带 memory 档上限;重试放开(不发送 max_tokens)。
      expect(backend.requests[0].maxTokens, BackgroundEngine.maxOutputTokensMemory);
      expect(backend.requests[1].maxTokens, isNull);
      expect(backend.requests[2].maxTokens, isNull);
    });

    test('三次都缺 memory → parseFailure,detail 注明缺少 memory 字段', () async {
      final backend = _ScriptedBackend([
        [const TextDelta('{}'), const DoneEvent()],
      ]);
      final outcome = await BackgroundEngine(backend).runMemoryInit(
        model: 'm',
        character: card,
      );
      expect(outcome, isA<BackgroundRunFailure>());
      final failure = outcome as BackgroundRunFailure;
      expect(failure.reason, BackgroundFailureReason.parseFailure);
      expect(failure.detail, contains('memory'));
      expect(backend.calls, BackgroundEngine.maxAttemptsPerRound);
    });
  });

  group('重试彻底放开输出上限(BN 批)', () {
    const card = CharacterCard(name: 'Alice');

    test('调用方传模型级 maxTokens 时,重试请求也不带 max_tokens(用户上限不再泄漏)', () async {
      // 只放开档位上限时:用户给模型配置过「最大输出 tokens」时,该值仍
      // 原样发进每次重试 —— 三次尝试带同一个 max_tokens,推理模型把预算烧在
      // 不可见思考上时正文恒空,"模型未返回任何内容"三连败(偶发残留根因)。
      final backend = _ScriptedBackend([
        [const DoneEvent()],
        [
          const TextDelta('{"memory":"recovered without any cap"}'),
          const DoneEvent(),
        ],
      ]);
      final result = ok(await BackgroundEngine(backend).runMemoryInit(
        model: 'm',
        character: card,
        maxTokens: 2048, // 用户在模型配置里设置的「最大输出 tokens」
      ));
      expect(result.memoryUpdate, 'recovered without any cap');
      expect(backend.calls, 2);
      // 首试:用户值与 memory 档位的较小者;重试:完全不发(与用户配置无关)。
      expect(backend.requests[0].maxTokens, 2048);
      expect(backend.requests[1].maxTokens, isNull);
    });

    test('run 路径同理:重试不透传调用方的 maxTokens', () async {
      final backend = _ScriptedBackend([
        [const DoneEvent()],
        [const TextDelta('{"variables":{"hp":"9"}}'), const DoneEvent()],
      ]);
      await BackgroundEngine(backend).run(
        model: 'm',
        variables: const {},
        history: const [],
        features: const BackgroundFeatures(variables: true, image: false),
        maxTokens: 1500,
      );
      expect(backend.requests[0].maxTokens, 1500);
      expect(backend.requests[1].maxTokens, isNull);
    });
  });


  group('runMemoryInit (主动记忆初始化)', () {
    const card = CharacterCard(
      name: 'Alice',
      description: 'a silver-haired catgirl with green eyes',
      personality: 'gentle and curious',
    );
    const constantEntry = WorldbookEntry(
      characterId: 1,
      constant: true,
      content: 'The kingdom of Eldoria borders the Mistwood.',
    );
    const triggeredEntry = WorldbookEntry(
      characterId: 1,
      keys: ['sword'],
      content: 'Swords are forbidden in the capital.',
    );

    test('composes the initial memory from the character card and constant worldbook only', () async {
      final backend = _RecordingBackend('{"memory":"Alice is a silver-haired catgirl from Eldoria."}');
      final engine = BackgroundEngine(backend);
      final result = ok(await engine.runMemoryInit(
        model: 'm',
        character: card,
        worldbook: const [triggeredEntry, constantEntry],
      ));

      expect(result.memoryUpdate, 'Alice is a silver-haired catgirl from Eldoria.');
      // 非 memory 字段一律清空(双保险,防御 LLM 多给字段;activeSkills 键已退役被忽略)。
      expect(result.variableUpdates, isEmpty);
      expect(result.imagePrompt, isNull);

      // 提示词只含角色卡与常驻(恒定)世界书;触发型条目不进初始化。
      final prompt = backend.lastRequest!.systemPrompt;
      expect(prompt, contains('silver-haired catgirl'));
      expect(prompt, contains('Eldoria borders the Mistwood'));
      expect(prompt, isNot(contains('Swords are forbidden')));
      expect(prompt, contains('Standing worldbook facts'));
      // 系统消息为空对话形状:初始化不携带会话转录。
      expect(backend.lastRequest!.messages.single.role, ChatRole.user);
    });

    test('uses the memory-tier output cap for the initialization call', () async {
      final backend = _RecordingBackend('{"memory":"m"}');
      await BackgroundEngine(backend).runMemoryInit(model: 'm', character: card);
      expect(backend.lastRequest!.maxTokens, BackgroundEngine.maxOutputTokensMemory);
    });

    test('fails with parseFailure (after retries) when the LLM emits no valid memory', () async {
      // 缺 memory 字段也纳入重试:三次尝试都只有 {"memory":null} → 失败,
      // detail 注明缺少 memory(不再以"成功但无记忆"返回)。
      final engine = BackgroundEngine(_JsonBackend('{"memory":null}'));
      final outcome = await engine.runMemoryInit(model: 'm', character: card);
      expect(outcome, isA<BackgroundRunFailure>());
      final failure = outcome as BackgroundRunFailure;
      expect(failure.reason, BackgroundFailureReason.parseFailure);
      expect(failure.detail, contains('memory'));
    });

    test('fails with parseFailure on malformed JSON', () async {
      final engine = BackgroundEngine(_JsonBackend('not json'));
      final outcome = await engine.runMemoryInit(model: 'm', character: card);
      expect(outcome, isA<BackgroundRunFailure>());
      expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.parseFailure);
    });

    test('fails with backendError when the backend emits an error event', () async {
      final engine = BackgroundEngine(_ErrorBackend());
      final outcome = await engine.runMemoryInit(model: 'm', character: card);
      expect(outcome, isA<BackgroundRunFailure>());
      expect((outcome as BackgroundRunFailure).reason, BackgroundFailureReason.backendError);
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

/// 按脚本逐次服务:第 n 次调用吐 script[n](超出取最后一组),并计数 ——
/// 重试语义断言用(首试失败、重试成功 / 两次都失败 / 取消只调一次)。
class _ScriptedBackend implements LlmBackend {
  final List<List<LlmEvent>> script;
  int calls = 0;

  /// 每次调用收到的请求(重试时输出上限放开与否的形状断言用)。
  final List<LlmRequest> requests = [];
  _ScriptedBackend(this.script);

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    requests.add(request);
    final events = script[calls.clamp(0, script.length - 1)];
    calls++;
    yield* Stream.fromIterable(events);
  }
}

/// 先发一段文本再等 [release] 收流:测试可在流挂起时中断,
/// 覆盖流结束后的取消检查。
class _GateBackend implements LlmBackend {
  final String text;
  final Future<void> release;
  bool served = false;
  _GateBackend(this.text, this.release);

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    served = true;
    yield TextDelta(text);
    await release; // 流保持打开直至测试放行(模拟仍在排队的后台请求)。
  }
}

/// 模拟 LLM 思考期(零事件):订阅已挂上、HTTP 请求已发出,但生成器一直
/// 停在 `await release` 之前不吐任何事件,直到测试主动放行或取消。
/// 用来验证 cancelSignal 能在零事件期立即解除等待(LLM 思考时长无上限)。
class _HangingBackend implements LlmBackend {
  final Future<void> release;
  bool served = false;
  _HangingBackend(this.release);

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    served = true;
    // 不 yield 任何事件,直接等到测试放行;复现"首字节迟迟不到"的零事件期。
    await release;
    yield const DoneEvent();
  }
}