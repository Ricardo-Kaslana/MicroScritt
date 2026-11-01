// ChatController 行为契约:主写发送/重生成/重发送、后台维护编排、压缩与
// Hook 改写、生图落库与错误分类;用假后端钉住时序与落库副作用。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/upstream_error.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/context/context_assembler.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/engine/background_status.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/variable.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/models/image_result.dart';
import 'package:microscritt/models/hook_seeds.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/state/slash_commands.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/models/user.dart';
import '../support/test_database.dart';

/// A backend whose stream is driven by the test, so we can hold it open while
/// exercising the streaming guard.
class _FakeBackend implements LlmBackend {
  final _controller = StreamController<LlmEvent>();
  _FakeBackend();

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) => _controller.stream;

  void emit(LlmEvent event) => _controller.add(event);
  void close() => _controller.close();
}

/// 贴近真实后端的形状:generate 是 async* 生成器,启动即停在漫长的 await 上
/// (如 `await client.send()` 等首字节)。对此类流,订阅的取消 Future 要等生成
/// 器本体收敛才算完成 —— 消费端若 await 取消,打断会被拖回"等请求自然结束"。
class _HangingStartBackend implements LlmBackend {
  final gate = Completer<void>();
  @override
  String get id => 'hanging';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    await gate.future; // 永不主动完成:请求悬挂在首字节之前。
  }
}

/// A backend that emits the main reply on the first call and a summary on the
/// second (the compaction call).
class _CountingBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [TextDelta('summary.'), DoneEvent()]);
  }
}

class _BackgroundBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"activeSkills":["combat"],"variables":{},"memory":null}'),
      UsageEvent(TokenUsage(inputTokens: 120, outputTokens: 15, cachedInputTokens: 80)),
      DoneEvent(),
    ]);
  }
}

/// 生图假后端:记录收到的全部描述并返回固定图 URL。
///
/// URL 用回环地址而非真实 CDN —— 生成路径会立即下载 URL 字节做本地化落库
/// (下载失败回退 URL 渲染);真实域名在无外网环境会挂起 30s 拖爆测试,回环
/// 未监听端口则立即「连接拒绝」失败 → 走 URL 回退落库,测试完全离线可跑。
class _FakeImageBackend implements ImageBackend {
  String? lastPrompt;
  final prompts = <String>[];
  @override
  String get id => 'fake-image';
  @override
  Future<ImageResult> generateImage(String prompt) async {
    lastPrompt = prompt;
    prompts.add(prompt);
    return ImageResult.single(url: 'http://127.0.0.1:1/image');
  }
}

/// 生图后端在 [release] 放行前一直挂起:模拟真实云端生图耗时远超后台轮
/// (后台状态早已 succeeded,图片才姗姗落库)的场景 —— 生图与轮次解耦后的
/// 关键路径。
class _GatedImageBackend implements ImageBackend {
  final Completer<void> release = Completer<void>();
  bool started = false;
  String? lastPrompt;
  @override
  String get id => 'gated-image';
  @override
  Future<ImageResult> generateImage(String prompt) async {
    started = true;
    lastPrompt = prompt;
    await release.future;
    // 回环未监听端口:下载立即"连接拒绝"失败 → 走 URL 回退落库。
    // (真实 CDN 域名在无外网环境会挂起 30s,把轮询窗口拖爆,测试偶发红。)
    return ImageResult.single(url: 'http://127.0.0.1:1/image');
  }
}

/// 生图后端直接抛异常:生图失败是 best-effort(不落图片消息),但状态文案
/// 必须如实标注失败,不能静默装作"生图完成"。
class _ThrowingImageBackend implements ImageBackend {
  @override
  String get id => 'throwing-image';
  @override
  Future<ImageResult> generateImage(String prompt) async => throw Exception('provider down');
}

/// 主写回复 + 后台调用返回 imagePrompt,触发后台生图落库。
class _BackgroundImageBackend implements LlmBackend {
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"activeSkills":[],"variables":{},"memory":null,"imagePrompt":"a sword in the mist"}'),
      DoneEvent(),
    ]);
  }
}

/// 主写回复一次;后台调用返回同场景的两个不同描述(「每次生图数量」>1)。
class _BackgroundImagesBackend implements LlmBackend {
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"activeSkills":[],"variables":{},"memory":null,'
          '"imagePrompts":["wide shot of the misty street","close-up of her face"]}'),
      DoneEvent(),
    ]);
  }
}

/// 主写回复一次;后台变量+生图合并轮只回变量、把图像描述漏掉,仅图像的补调
/// 才回描述 —— 复现"同时开启变量与生图时偶发只更新变量"的模型输出。
class _BackgroundCombinedRetryBackend implements LlmBackend {
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    if (calls == 2) {
      return Stream.fromIterable(const [
        TextDelta('{"activeSkills":[],"variables":{"mood":"calm"},"memory":null}'),
        DoneEvent(),
      ]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"imagePrompt":"a quiet inn at night"}'),
      DoneEvent(),
    ]);
  }
}

/// 主写回复一次;后台轮回传 memory 字段,验证该字段不落库(记忆仅由用户维护)。
class _BackgroundMemoryBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"activeSkills":[],"variables":{},"memory":"Alice met a dragon"}'),
      UsageEvent(TokenUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 50)),
      DoneEvent(),
    ]);
  }
}

/// A backend that replies on the first call (main write) and then errors on
/// the background call (second), exercising the failure path.
class _BackgroundThenError implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [ErrorEvent('bg failed')]);
  }
}

/// A backend that replies on the first call (main write) and then blocks on the
/// background call (second) until the test closes the stream, so the test can
/// interrupt the background agent mid-run. Later calls (e.g. a second send's
/// main write) get a fresh reply stream — only one bg stream is ever handed out.
class _BackgroundThenHang implements LlmBackend {
  int calls = 0;
  final _bgController = StreamController<LlmEvent>();
  bool _bgHandedOut = false;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (!request.systemPrompt.contains('<background_task>') || _bgHandedOut) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    // 后台先吐一段**无法解析**的文本(无任何 JSON 对象,宽容修复兜底也救不回),
    // 让 BackgroundEngine 停在"等待下一事件"的循环顶部,随后测试可中断并关闭流
    // 以触发解析失败路径。
    _bgHandedOut = true;
    _bgController.add(const TextDelta('this is not a JSON object'));
    return _bgController.stream;
  }

  void closeBg() => _bgController.close();
}

/// 受控后台后端:主写恒回 'reply.';后台轮按请求序回放 [firstResponse]/[response],
/// 第 1 次后台调用挂起直到 [unblock](用 [started] 观测),便于编排合并/失败用例。
class _ControlledBackgroundBackend implements LlmBackend {
  _ControlledBackgroundBackend({
    this.firstResponse = '{"variables":{"hp":"8"}}',
    this.response = '{"variables":{}}',
    this.failingCalls = 0,
  });

  final String firstResponse;
  final String response;
  final int failingCalls;
  final started = Completer<void>();
  final _release = Completer<void>();
  final requests = <LlmRequest>[];

  @override
  String get id => 'controlled';

  void unblock() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    if (!request.systemPrompt.contains('<background_task>') &&
        !request.systemPrompt.contains('initial long-term memory')) {
      yield const TextDelta('reply.');
      yield const DoneEvent();
      return;
    }
    requests.add(request);
    final index = requests.length;
    if (index == 1) {
      started.complete();
      await _release.future;
    }
    yield TextDelta(index <= failingCalls ? 'invalid response' : (index == 1 ? firstResponse : response));
    yield const DoneEvent();
  }
}

/// 生图假后端:记录描述,按 [failure]('throw'/'empty')或 [gate] 模拟失败/挂起。
class _TrackingImageBackend implements ImageBackend {
  _TrackingImageBackend({this.base64 = 'bmV3', this.failure, this.gate});

  final String base64;
  final String? failure;
  final Completer<void>? gate;
  final prompts = <String>[];

  @override
  String get id => 'tracking-image';

  @override
  Future<ImageResult> generateImage(String prompt) async {
    prompts.add(prompt);
    if (gate != null) await gate!.future;
    if (failure == 'throw') throw Exception('image provider down');
    if (failure == 'empty') return const ImageResult([]);
    return ImageResult.single(base64: base64);
  }
}

/// 中断回归专用:第 1 次调用 = 第一轮主写(自动完成);第 2 次 = 后台维护
/// (挂起,closeBg 放行);第 3 次 = 第二轮主写(挂起,closeMain2 放行)。
/// 两处挂起都可观测,让"中断落在第二轮主写期间、后台仍挂起"成为确定时序。
class _BgHangThenMainHang implements LlmBackend {
  int calls = 0;
  final _bg = StreamController<LlmEvent>();
  final _main2 = StreamController<LlmEvent>();

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) return Stream.fromIterable(const [TextDelta('first.'), DoneEvent()]);
    if (calls == 2) {
      // 后台先吐一段无法解析的文本,停在同一循环顶部等测试动作。
      _bg.add(const TextDelta('this is not a JSON object'));
      return _bg.stream;
    }
    _main2.add(const TextDelta('partial-'));
    return _main2.stream;
  }

  void closeBg() => _bg.close();
  void closeMain2() => _main2.close();
}

/// `/rerun` 专用:后台请求按 `<background_task>` 识别并按序回放不同 JSON,
/// 主写恒回 'reply.'。[gateCall] 非 0 时第 N 次后台调用挂起,直到 [unblock]
/// (用于"运行中拒绝"与"中断重跑"用例)。
class _RerunBackend implements LlmBackend {
  _RerunBackend(this.responses, {this.gateCall = 0});

  final List<String> responses;
  final int gateCall;
  final bgRequests = <LlmRequest>[];
  final started = Completer<void>();
  Completer<void>? _release;

  @override
  String get id => 'rerun';

  void unblock() {
    if (_release != null && !_release!.isCompleted) _release!.complete();
  }

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    if (!request.systemPrompt.contains('<background_task>')) {
      yield const TextDelta('reply.');
      yield const DoneEvent();
      return;
    }
    bgRequests.add(request);
    final index = bgRequests.length;
    if (index == gateCall) {
      _release = Completer<void>();
      if (!started.isCompleted) started.complete();
      await _release!.future;
    }
    final text = responses[index - 1 < responses.length ? index - 1 : responses.length - 1];
    yield TextDelta(text);
    yield const DoneEvent();
  }
}

/// A backend that emits an error event, exercising the error path.
class _ErrorBackend implements LlmBackend {
  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) => Stream.fromIterable(const [ErrorEvent('boom'), DoneEvent()]);
}

/// 契约漂移回归:前 3 轮以 contractViolation 失败(触发阈值),之后恒成功。
class _DriftSequenceBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    // calls==5 是第 4 轮成功后触发的后台维护轮(静默失败不可见),主写第 5 轮是 calls>=6。
    if (calls <= 3 || calls >= 5) {
      // 第 5 轮再次失败:验证第 4 轮成功已把连击归零(原文不带导语)。
      return Stream.fromIterable([
        const ErrorEvent('bad SSE payload: {oops}', kind: UpstreamErrorKind.contractViolation),
        DoneEvent(),
      ]);
    }
    return Stream.fromIterable(const [TextDelta('恢复.'), DoneEvent()]);
  }
}

/// 分类错误回归:主写直接失败并携带稳定分类(备用模型建议的判据输入)。
class _ClassifiedErrorBackend implements LlmBackend {
  final String message;
  final UpstreamErrorKind kind;
  _ClassifiedErrorBackend(this.message, this.kind);

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) =>
      Stream.fromIterable([ErrorEvent(message, kind: kind), DoneEvent()]);
}

/// A backend that emits a distinct reply on every call, letting tests confirm a
/// re-generation actually re-ran the pipeline.
class _VaryingBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    return Stream.fromIterable([TextDelta('reply#$calls'), DoneEvent()]);
  }
}

/// A runtime that evaluates nothing: exercises the hook wiring without any JS.
class _NoopRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => null;
}

/// 接线用 runtime:识别 beforeContextAssembly 的用户输入改写脚本,按
/// HookEngine 的脚本包络解析嵌入的 ctx JSON,把指令块前插到 userText 之前
/// (真实 JS 语义已由 hook_seeds_test 的 QuickJS 组合用例覆盖,这里只钉
/// "快捷指令路径会跑 hook")。
class _NotePrependWiringRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async {
    if (!js.contains('userText')) return null;
    final wrap = RegExp(r"JSON\.parse\((.*?)\);", dotAll: true).firstMatch(js);
    if (wrap == null) return null;
    final ctx = jsonDecode(jsonDecode(wrap.group(1)!)) as Map<String, dynamic>;
    final input = ctx['userText'] as String? ?? '';
    ctx['userText'] = '<note_hook>测试指令块\n(前插内容)</note_hook>\n\n$input';
    return jsonEncode(ctx);
  }
}

/// A runtime that rewrites the context's `text` field.
class _ModifyingRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => '{"text": "MODIFIED"}';
}

/// A runtime that rewrites the context's `userText` field.
class _UserTextRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => '{"userText": "REWRITTEN"}';
}

/// Verifies the `userName` injected into the hook context reached the script,
/// then rewrites `userText` to a fixed value so the test can assert persistence.
///
/// Uses a plain-ASCII marker name so it appears verbatim (un-escaped) in the
/// generated HookEngine script, avoiding fragile CJK/JSON decoding. The ctx is
/// double-JSON-encoded, so keys/values appear with `\"` escapes — hence we only
/// check that the `userName` key and the marker value are both present.
class _UserNameMarkerRuntime implements HookRuntime {
  static const marker = 'USERNAME_MARKER';
  bool sawUserName = false;

  @override
  Future<String?> evaluate(String js) async {
    sawUserName = sawUserName || (js.contains('userName') && js.contains(marker));
    return '{"userText": "REWRITTEN"}';
  }
}

/// Like [_UserNameMarkerRuntime] but rewrites the **reply** (`text`) field, to
/// verify the injected username also reaches the afterStream reply hooks and
/// that a reply rewrite is what gets persisted.
class _ReplyUserNameMarkerRuntime implements HookRuntime {
  static const marker = 'USERNAME_MARKER';
  bool sawUserName = false;

  @override
  Future<String?> evaluate(String js) async {
    sawUserName = sawUserName || (js.contains('userName') && js.contains(marker));
    return '{"text": "REPLY_REWRITTEN"}';
  }
}

/// A runtime that rewrites the request's systemPrompt and params.
class _RequestRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => '{"systemPrompt": "SP2", "temperature": 0.2, "maxTokens": 77}';
}

/// Records every request it serves so tests can assert what reached the LLM.
class _RecordingBackend implements LlmBackend {
  final List<LlmRequest> requests = [];

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    requests.add(request);
    return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
  }
}

/// 记忆初始化专用假后端:每次调用返回一段初始记忆 JSON(初始化只有一次后台
/// 调用,无主写回复),带 token 用量供记账断言。
class _MemoryInitBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    return Stream.fromIterable(const [
      TextDelta('{"memory":"Alice is a silver-haired catgirl from Eldoria."}'),
      UsageEvent(TokenUsage(inputTokens: 60, outputTokens: 25, cachedInputTokens: 0)),
      DoneEvent(),
    ]);
  }
}

/// 记忆初始化后端直接报错:初始化应失败且不落库。
class _MemoryInitErrorBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) => Stream.fromIterable(const [ErrorEvent('bg down')]);
}

/// 主写回复 + 每次后台调用都记录请求并返回技能 JSON。
/// 偶数次调用是后台轮,奇数次是主写 —— 主写/后台交替(请求形状断言用)。
class _MainBgRecordingBackend implements LlmBackend {
  final List<LlmRequest> bgRequests = [];
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls.isEven) {
      bgRequests.add(request);
      return Stream.fromIterable(const [
        // 带图像描述:同开变量+生图的合规输出,避免触发"仅图像补调"多一轮调用。
        TextDelta('{"activeSkills":["combat"],"variables":{},"memory":null,'
            '"imagePrompt":"a quiet scene"}'),
        UsageEvent(TokenUsage(inputTokens: 120, outputTokens: 15, cachedInputTokens: 80)),
        DoneEvent(),
      ]);
    }
    return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
  }
}

/// 主写正常回复,后台轮显式要求删除 hp。
class _RemovalBgBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"variables":{},"removeVariables":["hp"]}'),
      DoneEvent(),
    ]);
  }
}

/// 主写 / 压缩摘要(带用量)/ 后台 三合一:验证 compact 用量单独记账。
class _CompactUsageBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    if (calls == 2) {
      // 压缩摘要调用:带 token 用量。
      return Stream.fromIterable(const [
        TextDelta('summary.'),
        UsageEvent(TokenUsage(inputTokens: 120, outputTokens: 15, cachedInputTokens: 80)),
        DoneEvent(),
      ]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"activeSkills":[],"variables":{},"memory":null}'),
      DoneEvent(),
    ]);
  }
}

/// 硬挡预算检测路径:第一次调用是**发送前**的压缩摘要(先压缩再发),
/// 第二次才是主写回复 —— 与轮次结束后的旧顺序相反。
class _PreSendCompactBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls == 1) {
      return Stream.fromIterable(const [TextDelta('SUMMARY-PRESEND'), DoneEvent()]);
    }
    return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
  }
}

/// 按 systemPrompt 区分压缩摘要与主写请求:摘要提示词固定含「会话摘要助手」。
/// 前 [summaryFailures] 次摘要调用报错(验证重试耗尽/机械兜底),主写恒返回回复。
class _SummaryAwareBackend implements LlmBackend {
  _SummaryAwareBackend({this.summaryFailures = 0});
  final int summaryFailures;
  int summaryCalls = 0;
  int mainCalls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    if (request.systemPrompt.contains('会话摘要助手')) {
      summaryCalls++;
      if (summaryCalls <= summaryFailures) {
        return Stream.fromIterable(const [ErrorEvent('summary down')]);
      }
      return Stream.fromIterable(const [TextDelta('SOFT-SUMMARY'), DoneEvent()]);
    }
    mainCalls++;
    return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
  }
}

void main() {
  late AppDatabase db;
  late int sessionId;

  setUp(() async {
    db = await openTestDb();
    final characters = CharacterRepository(db);
    final sessions = SessionRepository(db);
    final charId = await characters.insert(const CharacterCard(name: 'Alice'));
    sessionId = await sessions.create(charId, 's1');
  });

  ProviderContainer makeContainer(
    LlmBackend backend, {
    ImageBackend? imageBackend,
    ImageConfig? imageConfig,
    int? maxTokens,
    HookRuntime? hookRuntime,
  }) =>
      ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      backendConfigProvider.overrideWith(
        (ref) => BackendConfig(
          provider: BackendProvider.openai,
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
          model: 'gpt-4o',
          maxTokens: maxTokens,
        ),
      ),
      backendProvider.overrideWith((ref) => backend),
      if (imageBackend != null) imageBackendProvider.overrideWithValue(imageBackend),
      if (imageConfig != null) imageConfigProvider.overrideWith((ref) => imageConfig),
      hookRuntimeProvider.overrideWith((ref) => hookRuntime ?? _NoopRuntime()),
    ],
  );

  /// 种入当前在用的 provider+模型(带上下文容量)。容量是占用率驱动压缩
  /// (60%/80%/20% 三挡)的输入;不种时按兜底容量 16384 估算。
  Future<void> seedCapacityModel(int contextCapacity) async {
    final repo = LlmProviderRepository(db);
    await repo.saveProvider(LlmProviderConfig(
      id: 0,
      providerId: 'prov-a',
      displayName: 'Prov A',
      baseUrl: 'https://api.example.com',
      protocol: LlmProtocol.openaiCompat,
      apiKey: 'k',
      isActive: true,
      models: [
        LlmModelEntry(
          id: 0,
          providerId: 0,
          modelId: 'model-a',
          displayName: 'Model A',
          contextCapacity: contextCapacity,
          isActive: true,
        ),
      ],
    ));
  }

  /// 禁用默认种入的预设提示词:预算测试的占用数字只由种子历史与角色卡决定,
  /// 不让预设文本长度参与推算(否则 system 段不可控,挡位判定漂移)。
  Future<void> disablePresetItems() async {
    await db.db.update('prompt_items', {'enabled': 0});
  }

  /// 解耦后 `send` 返回时后台轮可能仍在运行:等待最近一轮后台任务收敛,
  /// 让测试在确定的后台终态上断言。
  Future<void> awaitBackground(ProviderContainer container) async {
    final task = container.read(chatControllerProvider.notifier).backgroundTask;
    if (task != null) await task;
  }

  /// 轮询等待 [condition] 成立,替代固定毫秒延时 —— 全量并行跑时 CPU 竞争
  /// 会把真实调度延迟推到 20ms 级窗口之外(偶发红,单跑必绿);条件轮询对
  /// 负载不敏感。超时仍未成立即失败,避免真回归时挂死整个套件。
  Future<void> waitFor(
    bool Function() condition, {
    String? message,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(message ?? 'condition not met within ${timeout.inMilliseconds}ms');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('session load clears a stale draft (EF: draft lives in its own provider)', () async {
    // 草稿自 ChatState 拆出后,会话切换的"元数据立即清空"语义要
    // 覆盖到新家:上一会话的生成中气泡绝不能闪进下一会话。
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    container.read(chatDraftProvider.notifier).set('上一会话残留');
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    expect(container.read(chatDraftProvider), '');
  });

  test('appends user and assistant rows and transitions state', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('Hello from the fake.'));
    backend.emit(const DoneEvent());
    backend.close();

    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    await controller.send('hi');

    final state = container.read(chatControllerProvider);
    expect(state.streaming, isFalse);
    expect(container.read(chatDraftProvider), '');

    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.role).toList(), ['user', 'assistant']);
    expect(messages[0].content, 'hi');
    expect(messages[0].seq, 0);
    expect(messages[1].content, 'Hello from the fake.');
    expect(messages[1].seq, 1);
  });

  test('send keeps @skill tokens in the stored user message and still attaches the skill (DA)', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('Hello from the fake.'));
    backend.emit(const DoneEvent());
    backend.close();

    final skillId = await SkillRepository(db).insert(const Skill(name: '剑术', content: '# 剑术'));
    // 本文件各用例共享同一内存库:技能行不清理会泄漏进后续断言 skills 表的用例。
    addTearDown(() => db.db.delete('skills'));
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    await controller.send('  @剑术 我拔剑了');
    await awaitBackground(container);

    final messages = await MessageRepository(db).bySession(sessionId);
    // 附件行在前,真实对话行在后;@记号**保留在转录里**(气泡/编辑所见即所得),
    // 剥离发生在组装出口(见 context_assembler_test 的 stripSkillNames 用例)。
    final attachments = messages.where((m) => !m.isChat).toList();
    final chatRows = messages.where((m) => m.isChat).toList();
    expect(attachments, hasLength(1));
    expect(attachments.single.refId, 'skill:$skillId');
    // 原样落库(含前后空白与 @记号)—— 转录即用户所输入。
    expect(chatRows[0].content, '  @剑术 我拔剑了');

    // 纯函数边界(委托 ContextAssembler.withoutSkillTokens):剥离后只剩空白 →
    // 空串;多次提及全剥,各记号后原有空白不收缩。
    const skills = [Skill(name: '剑术', content: 'x')];
    expect(ChatController.stripSkillTokens('@剑术 ', skills), '');
    expect(ChatController.stripSkillTokens('普通文本', skills), '普通文本');
    expect(ChatController.stripSkillTokens('@剑术 冲 @剑术 跳', skills), '冲  跳');
  });

  test('worldbook attachments beyond the single-turn budget are dropped tail-first (DG)', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('ok'));
    backend.emit(const DoneEvent());
    backend.close();

    final charId = (await SessionRepository(db).get(sessionId))!.characterId;
    await WorldbookRepository(db).replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, name: 'E1', keys: ['kwone'], content: 'c1'),
      WorldbookEntry(characterId: 0, name: 'E2', keys: ['kwtwo'], content: 'c2'),
      WorldbookEntry(characterId: 0, name: 'E3', keys: ['kwthree'], content: 'c3'),
      WorldbookEntry(characterId: 0, name: 'E4', keys: ['kwfour'], content: 'c4'),
    ]);

    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state =
        const AppSettings(backgroundEnabled: false, maxAutoAttachments: 2);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await controller.send('kwone kwtwo kwthree kwfour');

    final rows = await MessageRepository(db).bySession(sessionId);
    final wb = rows.where((m) => m.refId?.startsWith('wb:') ?? false).toList();
    // 限额 2:按命中(库序)取前两条,尾部两条丢弃。
    expect(wb, hasLength(2));
    expect(wb[0].content, contains('E1'));
    expect(wb[1].content, contains('E2'));
  });

  test('budget 0 disables worldbook auto attachments but @skill stays exempt (DG)', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('ok'));
    backend.emit(const DoneEvent());
    backend.close();

    final skillId = await SkillRepository(db).insert(const Skill(name: '剑术', content: '# 剑术'));
    addTearDown(() => db.db.delete('skills'));
    final charId = (await SessionRepository(db).get(sessionId))!.characterId;
    await WorldbookRepository(db).replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, name: 'E1', keys: ['kwone'], content: 'c1'),
      WorldbookEntry(characterId: 0, name: 'E2', keys: ['kwtwo'], content: 'c2'),
    ]);

    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state =
        const AppSettings(backgroundEnabled: false, maxAutoAttachments: 0);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await controller.send('@剑术 kwone kwtwo');

    final rows = await MessageRepository(db).bySession(sessionId);
    // 限额 0:世界书自动附件全部不注入;用户主动 @ 的技能豁免,照常注入。
    expect(rows.where((m) => m.refId?.startsWith('wb:') ?? false), isEmpty);
    final skillRows = rows.where((m) => m.refId == 'skill:$skillId').toList();
    expect(skillRows, hasLength(1));
  });

  test('compact notice persists as attachment row before the next user message (DG)', () async {
    final backend = _SummaryAwareBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    final messageRepo = MessageRepository(db);
    for (var i = 0; i < 8; i++) {
      await messageRepo.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'seed$i');
    }
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await controller.runCommand(SlashCommand.compact); // 置压缩通知待发标志

    await controller.send('next');
    var rows = await messageRepo.bySession(sessionId);
    final notices = rows.where((m) => m.refId?.startsWith('notice:compact:') ?? false).toList();
    expect(notices, hasLength(1));
    expect(notices.single.content, ContextAssembler.compactNoticeText);
    // 落库在用户消息之前(发送管线收口),标志已复位。
    final nextUser = rows.firstWhere((m) => m.isChat && m.content == 'next');
    expect(notices.single.seq, lessThan(nextUser.seq));

    // 再次发送不产生第二份压缩通知(一次性)。
    await controller.send('third');
    rows = await messageRepo.bySession(sessionId);
    expect(rows.where((m) => m.refId?.startsWith('notice:compact:') ?? false), hasLength(1));
  });

  test('memory diff notice persists once per memory version (DG)', () async {
    final backend = _SummaryAwareBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    await MemoryRepository(db).set(sessionId, 'frozen fact');
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    // 修改记忆后发送:差异落库为附件行,位于用户消息之前。
    await MemoryRepository(db).set(sessionId, 'frozen fact\nnew fact');
    await controller.send('hi');
    var rows = await MessageRepository(db).bySession(sessionId);
    var diffs = rows.where((m) => m.refId?.startsWith('notice:memdiff:') ?? false).toList();
    expect(diffs, hasLength(1));
    expect(diffs.single.content, contains('【新增】new fact'));
    final hiRow = rows.firstWhere((m) => m.isChat && m.content == 'hi');
    expect(diffs.single.seq, lessThan(hiRow.seq));

    // 同一记忆版本不再重发。
    await controller.send('again');
    rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.where((m) => m.refId?.startsWith('notice:memdiff:') ?? false), hasLength(1));

    // 记忆再变(新版本)→ 下一次发送再通知一次。
    await MemoryRepository(db).set(sessionId, 'changed');
    await controller.send('and again');
    rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.where((m) => m.refId?.startsWith('notice:memdiff:') ?? false), hasLength(2));
  });

  test('hard-budget mid-turn compact persists notice after user message; assembly corrects before it (DG)', () async {
    await seedCapacityModel(6000);
    await disablePresetItems();
    // 本文件各用例共享同一内存库:预设禁用不清理会泄漏进后续断言首段为
    // preset 的用例,用完还原。
    addTearDown(() => db.db.update('prompt_items', {'enabled': 1}));
    final backend = _PreSendCompactBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    final messages = MessageRepository(db);
    for (var i = 0; i < 40; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 400);
    }
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');

    final all = await messages.bySession(sessionId);
    final notice = all.where((m) => m.refId?.startsWith('notice:compact:') ?? false).toList();
    expect(notice, hasLength(1));
    // 中途压缩:用户消息已先落库 → 通知行 seq 在用户消息之后。
    final hiRow = all.firstWhere((m) => m.isChat && m.content == 'hi');
    expect(notice.single.seq, greaterThan(hiRow.seq));
    // 组装期位置校正:当轮请求数组里通知排在用户输入之前(字节对齐旧合成位置)。
    final ctx = container.read(chatControllerProvider).lastContext;
    expect(ctx, isNotNull);
    final idxNotice = ctx!.messages.indexWhere((m) => m.content == ContextAssembler.compactNoticeText);
    final idxHi = ctx.messages.indexWhere((m) => m.content == 'hi');
    expect(idxNotice, greaterThanOrEqualTo(0));
    expect(idxHi, greaterThanOrEqualTo(0));
    expect(idxNotice, lessThan(idxHi));
    // 面板附件段可见该通知(需求:所有类型附件在面板展示)。
    final attSeg = ctx.segments.firstWhere((s) => s.key == 'attachments');
    expect(attSeg.subEntries.any((s) => s.label.startsWith('压缩通知')), isTrue);
  });

  test('deleteMessage removes the row and refreshes state', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('reply.'));
    backend.emit(const DoneEvent());
    backend.close();

    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    final rows = await MessageRepository(db).bySession(sessionId);
    expect(rows, hasLength(2));
    await controller.deleteMessage(rows.first.id!);

    final state = container.read(chatControllerProvider);
    expect(state.messages.single.content, 'reply.');
    expect(await MessageRepository(db).bySession(sessionId), hasLength(1));
  });

  test('editMessage rewrites the content and refreshes state', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('reply.'));
    backend.emit(const DoneEvent());
    backend.close();

    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    final user = (await MessageRepository(db).bySession(sessionId)).first;
    await controller.editMessage(user.id!, ' edited ');

    final state = container.read(chatControllerProvider);
    expect(state.messages.first.content, 'edited');
    expect((await MessageRepository(db).bySession(sessionId)).first.content, 'edited');
  });

  test('deleteMessageImage drops the whole row for captionless image messages only', () async {
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final repo = MessageRepository(db);
    // 两条带图消息:一条纯图无正文,一条图文都有。
    await repo.append(sessionId: sessionId, role: 'assistant', content: '', imageBase64: 'AAAA');
    await repo.append(sessionId: sessionId, role: 'assistant', content: '看这张图', imageBase64: 'AAAA');
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    var rows = await repo.bySession(sessionId);
    // 纯图无正文:删图后什么都不剩 → 整条移除,不留空白气泡。
    await controller.deleteMessageImage(rows[0].id!);
    rows = await repo.bySession(sessionId);
    expect(rows.map((m) => m.content), ['看这张图']);
    expect(container.read(chatControllerProvider).messages, hasLength(1));

    // 图文都有:只清空图片字段,文字保留、图片标志归零。
    await controller.deleteMessageImage(rows.single.id!);
    final left = await repo.bySession(sessionId);
    expect(left.single.content, '看这张图');
    expect(left.single.imageBase64, isNull);
    expect(left.single.hasImage, isFalse);
  });

  group('regenerateImage', () {
    Future<int> seedImage(MessageRepository repo, {String? prompt = 'a cave'}) async {
      final row = await repo.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageBase64: 'b2xk',
        imagePrompt: prompt,
      );
      return row.id!;
    }

    Future<void> waitForPrompts(_TrackingImageBackend backend, int count) async {
      for (var i = 0; i < 200 && backend.prompts.length < count; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(backend.prompts, hasLength(count));
    }

    test('replaces the message image with the stored prompt', () async {
      final repo = MessageRepository(db);
      final id = await seedImage(repo);
      final images = _TrackingImageBackend(base64: 'bmV3');
      final container = makeContainer(_FakeBackend(), imageBackend: images);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

      expect(await controller.regenerateImage(id), isNull);

      expect(images.prompts, ['a cave']);
      expect(await repo.imageBase64For(id), 'bmV3');
      expect(await repo.imagePromptFor(id), 'a cave');
      final state = container.read(chatControllerProvider);
      expect(state.imageRevisions[id], 1);
      expect(state.regeneratingImageId, isNull);
      expect(state.messages.single.hasImage, isTrue);
    });

    test('trimmed prompt is sent to the provider but matched verbatim for the update', () async {
      final repo = MessageRepository(db);
      final id = await seedImage(repo, prompt: '  a cave  ');
      final images = _TrackingImageBackend(base64: 'bmV3');
      final container = makeContainer(_FakeBackend(), imageBackend: images);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

      expect(await controller.regenerateImage(id), isNull);
      expect(images.prompts, ['a cave']);
      expect(await repo.imageBase64For(id), 'bmV3');
      expect(await repo.imagePromptFor(id), '  a cave  ');
    });

    test('rejects images without an original prompt without calling the provider', () async {
      final repo = MessageRepository(db);
      final id = await seedImage(repo, prompt: null);
      final images = _TrackingImageBackend();
      final container = makeContainer(_FakeBackend(), imageBackend: images);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

      expect(await controller.regenerateImage(id), contains('原始描述'));
      expect(images.prompts, isEmpty);
      expect(await repo.imageBase64For(id), 'b2xk');
    });

    test('reports a missing image provider and keeps the old image', () async {
      final repo = MessageRepository(db);
      final id = await seedImage(repo);
      final container = makeContainer(_FakeBackend());
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

      expect(await controller.regenerateImage(id), contains('生图服务'));
      expect(await repo.imageBase64For(id), 'b2xk');
    });

    for (final mode in ['throw', 'empty']) {
      test('$mode failure keeps the old image and clears the busy state', () async {
        final repo = MessageRepository(db);
        final id = await seedImage(repo);
        final images = _TrackingImageBackend(failure: mode);
        final container = makeContainer(_FakeBackend(), imageBackend: images);
        addTearDown(container.dispose);
        final controller = container.read(chatControllerProvider.notifier);
        await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

        final error = await controller.regenerateImage(id);

        expect(error, isNotNull);
        expect(await repo.imageBase64For(id), 'b2xk');
        expect(container.read(chatControllerProvider).regeneratingImageId, isNull);
        expect(container.read(chatControllerProvider).imageRevisions[id], isNull);
      });
    }

    test('rejects a concurrent second request while one image is generating', () async {
      final repo = MessageRepository(db);
      final id = await seedImage(repo);
      final gate = Completer<void>();
      final images = _TrackingImageBackend(gate: gate);
      final container = makeContainer(_FakeBackend(), imageBackend: images);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

      final first = controller.regenerateImage(id);
      await waitForPrompts(images, 1);
      expect(container.read(chatControllerProvider).regeneratingImageId, id);
      expect(await controller.regenerateImage(id), contains('正在重新生成'));
      gate.complete();
      expect(await first, isNull);
      expect(images.prompts, ['a cave']);
    });

    test('does not resurrect an image deleted while generating', () async {
      final repo = MessageRepository(db);
      final id = await seedImage(repo);
      final gate = Completer<void>();
      final images = _TrackingImageBackend(gate: gate);
      final container = makeContainer(_FakeBackend(), imageBackend: images);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

      final pending = controller.regenerateImage(id);
      await waitForPrompts(images, 1);
      await controller.deleteMessageImage(id);
      expect(await repo.bySession(sessionId), isEmpty);
      gate.complete();

      expect(await pending, contains('已被删除或修改'));
      expect(await repo.bySession(sessionId), isEmpty);
    });

    test('does not write back after switching sessions', () async {
      final repo = MessageRepository(db);
      final id = await seedImage(repo);
      final otherId = await SessionRepository(db).create(
        await CharacterRepository(db).insert(const CharacterCard(name: 'Bob')),
        'other',
      );
      final gate = Completer<void>();
      final images = _TrackingImageBackend(gate: gate);
      final container = makeContainer(_FakeBackend(), imageBackend: images);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

      final pending = controller.regenerateImage(id);
      await waitForPrompts(images, 1);
      await controller.load(sessionId: otherId, character: const CharacterCard(name: 'Bob'));
      gate.complete();

      expect(await pending, isNull);
      expect(await repo.imageBase64For(id), 'b2xk');
      expect(container.read(chatControllerProvider).sessionId, otherId);
      expect(container.read(chatControllerProvider).imageRevisions, isEmpty);
    });
  });

  test('regenerate re-runs the pipeline and swaps the reply', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    var rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.map((m) => m.role).toList(), ['user', 'assistant']);
    final before = rows.last.content;

    await controller.regenerate(rows.last.id!);

    rows = await MessageRepository(db).bySession(sessionId);
    // 仍然是 user + assistant 各一条,但助手回复已重新生成(文本不同)。
    expect(rows.map((m) => m.role).toList(), ['user', 'assistant']);
    expect(rows.last.content, isNot(before));
  });

  test('regenerate of a leading assistant without a prior user trims and stops', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi'); // user + assistant
    // 解耦后 send 返回时后台轮可能仍在跑:等它收敛再计数,否则其 LLM 调用
    // 会异步污染下面的 calls 断言。
    await awaitBackground(container);

    final before = backend.calls;
    final rows = await MessageRepository(db).bySession(sessionId);
    await controller.regenerate(rows.first.id!); // 删除 user 及其后所有 → 无 user 可回应

    final after = await MessageRepository(db).bySession(sessionId);
    expect(after, isEmpty);
    expect(backend.calls, before); // 没有再次生成
  });

  test('resend trims from the user message and sends the same text again', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await controller.send('again');

    var rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.map((m) => m.role).toList(), ['user', 'assistant', 'user', 'assistant']);
    final tailReply = rows.last.content;

    // 重发第二条用户消息:剪掉它及其后的助手回复,再以同文本重走发送管线。
    await controller.resend(rows[2].id!);

    rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.map((m) => m.role).toList(), ['user', 'assistant', 'user', 'assistant']);
    // 前一轮对话原样保留。
    expect(rows[0].content, 'hi');
    // 同文本重新落库为新的用户消息。
    expect(rows[2].content, 'again');
    // 助手回复重新生成(每次调用文本不同)。
    expect(rows[3].content, isNot(tailReply));
  });

  test('runCommand test appends a user message and generates a reply', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    await controller.runCommand(SlashCommand.test);

    final rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.map((m) => m.role).toList(), ['user', 'assistant']);
  });

  test('runCommand continue appends a user message and generates a reply', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    await controller.runCommand(SlashCommand.continueStory);

    final rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.map((m) => m.role).toList(), ['user', 'assistant']);
  });

  test('runCommand continue runs input-rewrite hooks: note block lands before the injected text', () async {
    // 回归:/test /continue 走 _appendAndGenerate,此前该路径不过
    // beforeContextAssembly —— 输入改写 hook(main/jump)在这两个快捷指令
    // 上会静默失效。种入一条启用态输入改写 hook,runtime 按 HookEngine
    // 同款脚本包络解析 ctx 并前插指令块。
    final seed = kDefaultHookSeeds.firstWhere((s) => s.name == '主导模式(main)');
    await db.db.insert('hooks', {
      'name': seed.name,
      'trigger_point': seed.triggerPointWire,
      'js_code': seed.jsCode,
      'enabled': 1,
    });
    final container = makeContainer(
      _VaryingBackend(),
      hookRuntime: _NotePrependWiringRuntime(),
    );
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    await controller.runCommand(SlashCommand.continueStory);

    final rows = await MessageRepository(db).bySession(sessionId);
    expect(rows.first.role, 'user');
    // 改写后的文本落库:指令块在前,命令注入的原话垫底(气泡里块折叠为 chip)。
    expect(rows.first.content, startsWith('<note_hook>'));
    expect(rows.first.content, contains('测试指令块'));
    // 空会话走 /continue 的开场分支,命令注入的原话垫底。
    expect(rows.first.content, endsWith('（请以角色的视角自然展开一段剧情开场）'));
    expect(rows.map((m) => m.role).toList(), ['user', 'assistant']);
  });

  test('runCommand clear updates context-panel history count and session-list counts', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    final charId = (await SessionRepository(db).get(sessionId))!.characterId;

    // 造一段较长的历史,让"清空前后"的历史条数有明显差异。
    final msgRepo = MessageRepository(db);
    for (var i = 0; i < 8; i++) {
      await msgRepo.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'seed$i');
    }
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // 先把会话列表的消息计数缓存下来(模拟列表已被查看)。
    expect((await container.read(sessionInfosProvider(charId).future)).single.messageCount, 8);

    // 清空会重放开场白(角色未配 firstMessage → 为空),历史归零。
    await controller.runCommand(SlashCommand.clearHistory);

    // 上下文面板的历史消息数应反映清空后的历史(而非陈旧快照)。
    final ctx = container.read(chatControllerProvider).lastContext;
    expect(ctx, isNotNull);
    expect(ctx!.messages, isEmpty);

    // 会话列表的消息计数被失效并已刷新为"0"。
    final refreshed = await container.read(sessionInfosProvider(charId).future);
    expect(refreshed.single.messageCount, 0);
  });

  test('runCommand clear empties the session history', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    expect(await MessageRepository(db).bySession(sessionId), isNotEmpty);

    await controller.runCommand(SlashCommand.clearHistory);

    expect(await MessageRepository(db).bySession(sessionId), isEmpty);
    expect(container.read(chatControllerProvider).messages, isEmpty);
  });

  test('runCommand clear preserves the character opening message when non-empty', () async {
    final backend = _VaryingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    // 角色配了开场白:会话新建时会被自动写入。
    const card = CharacterCard(name: 'Alice', firstMessage: '欢迎来到酒馆。');
    final c = container.read(chatControllerProvider.notifier);
    await c.load(sessionId: sessionId, character: card);

    // 模拟会话创建时的开场白,再追加历史后清空。
    await MessageRepository(db).append(sessionId: sessionId, role: 'assistant', content: card.firstMessage);
    await MessageRepository(db).append(sessionId: sessionId, role: 'user', content: '你好');
    await c.load(sessionId: sessionId, character: card); // 刷新,载入开场 + user
    expect(container.read(chatControllerProvider).messages, isNotEmpty);

    await c.runCommand(SlashCommand.clearHistory);

    final rest = await MessageRepository(db).bySession(sessionId);
    // 只剩开场白,其余全被清掉。
    expect(rest.map((m) => m.content).toList(), ['欢迎来到酒馆。']);
    expect(container.read(chatControllerProvider).messages.single.content, '欢迎来到酒馆。');
  });

  test('runCommand compact summarizes when there is enough history', () async {
    // 本用例只发 /compact:首次调用即压缩摘要请求,返回 'reply.'。
    final backend = _CountingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // 造历史使 active > keep(6),/compact 会把超出的历史摘要成 system 行。
    final messageRepo = MessageRepository(db);
    for (var i = 0; i < 8; i++) {
      await messageRepo.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'seed$i');
    }
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    await controller.runCommand(SlashCommand.compact);

    final rows = await MessageRepository(db).bySession(sessionId);
    // /compact 把超出的历史摘要成 system 行,并把原文标记压缩。
    final summaries = rows.where((m) => m.role == 'system').map((m) => m.content).toList();
    expect(summaries, isNotEmpty);
    expect(summaries.first, isNotEmpty);
    expect(rows.where((m) => m.isCompacted).length, greaterThan(0));

    // 压缩后上下文快照被重算:摘要段出现在 lastContext 里(否则上下文面板
    // 不会立即反映"历史变短 + 摘要",观感上"没有效果")。
    // _CountingBackend 首次调用(即本次压缩的摘要请求)返回 'reply.'。
    final ctx = container.read(chatControllerProvider).lastContext;
    expect(ctx, isNotNull);
    expect(ctx!.segmentSources['summary'], isNotEmpty);
    expect(ctx.segmentSources['summary'], contains('reply.'));
  });

  test('load switches context and memory when changing sessions', () async {
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);

    // 两个角色的各一个会话,各自的会话级长期记忆不同,消息也不同。
    final chars = CharacterRepository(db);
    final sessions = SessionRepository(db);
    final aliceId = await chars.insert(const CharacterCard(name: 'Alice'));
    final bobId = await chars.insert(const CharacterCard(name: 'Bob'));
    final aliceSession = await sessions.create(aliceId, 'alice-s');
    final bobSession = await sessions.create(bobId, 'bob-s');
    await MemoryRepository(db).set(aliceSession, 'alice 的长期记忆');
    await MemoryRepository(db).set(bobSession, 'bob 的长期记忆');
    await MessageRepository(db).append(sessionId: aliceSession, role: 'user', content: 'aliceMsg');
    await MessageRepository(db).append(sessionId: bobSession, role: 'user', content: 'bobMsg');

    // 载入 Alice 会话:上下文与记忆是 Alice 的。
    await controller.load(
      sessionId: aliceSession,
      character: const CharacterCard(name: 'Alice'),
    );
    final ctxA = container.read(chatControllerProvider).lastContext;
    expect(ctxA, isNotNull);
    expect(ctxA!.segmentSources['memory'], contains('alice 的长期记忆'));
    expect(ctxA.segmentSources['memory'], isNot(contains('bob')));
    expect(ctxA.messages.map((m) => m.content), contains('aliceMsg'));
    expect(container.read(chatControllerProvider).sessionId, aliceSession);

    // 切到 Bob 会话:上下文与记忆必须整体切换到 Bob,绝不留有 Alice 的内容。
    await controller.load(
      sessionId: bobSession,
      character: const CharacterCard(name: 'Bob'),
    );
    final ctxB = container.read(chatControllerProvider).lastContext;
    expect(ctxB, isNotNull);
    expect(ctxB!.segmentSources['memory'], contains('bob 的长期记忆'));
    expect(ctxB.segmentSources['memory'], isNot(contains('alice')));
    expect(ctxB.messages.map((m) => m.content), contains('bobMsg'));
    expect(ctxB.messages.map((m) => m.content), isNot(contains('aliceMsg')));
    expect(container.read(chatControllerProvider).sessionId, bobSession);
    expect(container.read(chatControllerProvider).characterId, bobId);
  });

  test('external memory edits stay frozen until applyMemoryToContext (CW: slot-0 caching)', () async {
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);

    await MemoryRepository(db).set(sessionId, '会被清掉的记忆');
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    expect(container.read(chatControllerProvider).lastContext!.segmentSources['memory'], contains('会被清掉的记忆'));

    // 模拟状态面板"清空记忆"后仅重算上下文:第 0 条消息(冻结副本)保持旧字节
    // —— 外部修改不自动穿透,保证记忆槽位与其后历史的缓存前缀稳定。
    await MemoryRepository(db).clear(sessionId);
    await controller.refreshContext();
    var ctx = container.read(chatControllerProvider).lastContext;
    expect(ctx!.segmentSources['memory'], contains('会被清掉的记忆'));

    // 用户显式「应用到上下文」后,冻结副本换成库中最新值:记忆段消失。
    await controller.applyMemoryToContext();
    ctx = container.read(chatControllerProvider).lastContext;
    expect(ctx, isNotNull);
    final mem = ctx!.segmentSources['memory'] ?? '';
    expect(mem, isNot(contains('会被清掉的记忆')));
    // 记忆已清空 → 组装器不再产出 memory 段(记忆段消失)。
    expect(ctx.segments.any((s) => s.key == 'memory'), isFalse);
  });

  test('clearError resets the error field', () async {
    final container = makeContainer(_ErrorBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    expect(container.read(chatControllerProvider).error, 'boom');

    controller.clearError();
    expect(container.read(chatControllerProvider).error, isNull);
  });

  test('send records the assembled context snapshot', () async {
    final backend = _CountingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hello');

    final ctx = container.read(chatControllerProvider).lastContext;
    expect(ctx, isNotNull);
    expect(ctx!.systemPrompt, contains('Name: Alice'));
    // 快照里是此刻发给 LLM 的消息数组:刚追加的那条 user 消息
    expect(ctx.messages.length, 1);
    expect(ctx.segmentSources['character'], contains('Alice'));
    // 发送后 lastContext 必须携带结构化 segments,否则上下文面板会变得空白
    // (segmentSources 有值但 segments 为空)。这是会话更新后面板空白的回归防护。
    expect(ctx.segments, isNotEmpty);
    // 分段顺序镜像组装顺序:静态段(内置默认预设→角色卡)在会话历史
    // (随 messages 数组)之前。全新 DB 自带 2 条默认预设,故首段为 preset。
    final keys = ctx.segments.map((s) => s.key).toList();
    expect(keys.first, 'preset');
    expect(keys.indexOf('character'), greaterThan(keys.indexOf('preset')));
    expect(keys.last, 'history');
  });

  test('rejects a second send while streaming', () async {
    final backend = _FakeBackend(); // stream intentionally left open

    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    final firstSend = controller.send('first');

    // Wait until the first send is actually streaming.
    while (!container.read(chatControllerProvider).streaming) {
      await Future<void>.delayed(Duration.zero);
    }

    // A second send while streaming is rejected before any DB write.
    await controller.send('second');

    var messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.where((m) => m.role == 'user').length, 1);
    expect(messages.where((m) => m.role == 'assistant').length, 0);

    // Let the first send finish, then assert the final state is clean.
    backend.emit(const TextDelta('done.'));
    backend.emit(const DoneEvent());
    backend.close();
    await firstSend;

    final state = container.read(chatControllerProvider);
    expect(state.streaming, isFalse);
    expect(container.read(chatDraftProvider), '');

    messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.role).toList(), ['user', 'assistant']);
    expect(messages[0].content, 'first');
    expect(messages[1].content, 'done.');
  });

  test('ChatState.copyWith clears the error with an explicit null', () {
    const state = ChatState(error: 'boom');
    expect(state.copyWith().error, 'boom');
    expect(state.copyWith(error: null).error, isNull);
    expect(state.copyWith(error: 'new').error, 'new');
  });

  test('load populates worldbook for the character via session', () async {
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    // Find the character id the session belongs to.
    final charId = (await SessionRepository(db).get(sessionId))!.characterId;
    await WorldbookRepository(db).replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, keys: ['sword'], content: 'The sword is cursed'),
    ]);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    final state = container.read(chatControllerProvider);
    expect(state.worldbook.map((e) => e.content).toList(), ['The sword is cursed']);
  });

  test('send skips occupancy-based auto compact when the model has no capacity info', () async {
    // 未种入任何 provider/模型 → 容量未知,按兜底容量 16384 估算;本用例的
    // 短消息占用远低于软挡,自动压缩不触发(触发依据是上下文占用率,不再是
    // 掉窗消息条数)。
    final backend = _CountingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    final messages = MessageRepository(db);
    for (var i = 0; i < 30; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'seed$i');
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    expect(backend.calls, 1); // 只有主写,没有任何摘要调用
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system'), isEmpty);
    expect(all.where((m) => m.isCompacted), isEmpty);
  });

  test('hard budget gate compacts before send when occupancy exceeds 80%', () async {
    // 容量 6000:硬挡线 4800。40×400 字符 ≈5000 token + 输出预留 2048,
    // 发送前超线 → 先摘要压回目标挡再发;摘要调用发生在主写**之前**。
    await seedCapacityModel(6000);
    await disablePresetItems();
    final backend = _PreSendCompactBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    final messages = MessageRepository(db);
    for (var i = 0; i < 40; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 400);
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // 第一次调用是发送前摘要,第二次才是主写回复。
    expect(backend.calls, 2);
    final all = await messages.bySession(sessionId);
    final summaries = all.where((m) => m.role == 'system').toList();
    expect(summaries, hasLength(1));
    expect(summaries.single.content, 'SUMMARY-PRESEND');
    // 压回目标挡:41 条活跃按预算保留最新 6 条(hi 占一席),35 条被折叠。
    expect(all.where((m) => m.isCompacted).length, 35);
    // 压缩不丢轮:回复照常落库。
    expect(all.last.content, 'reply.');
  });

  test('hard budget falls back to mechanical trim when summarize retries fail', () async {
    // 摘要重试 4 次(首次+3)全部失败 → 机械截断兜底:不经 LLM 折叠超限历史,
    // 写入系统注记行,请求仍能发出。
    await seedCapacityModel(6000);
    await disablePresetItems();
    final backend = _SummaryAwareBackend(summaryFailures: 99);
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    final messages = MessageRepository(db);
    for (var i = 0; i < 40; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 400);
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    expect(backend.summaryCalls, 4); // 首次 + 3 次失败重试
    expect(backend.mainCalls, 1); // 主写照常完成
    final all = await messages.bySession(sessionId);
    final notes = all.where((m) => m.role == 'system').toList();
    expect(notes, hasLength(1));
    expect(notes.single.content, contains('系统注记'));
    // 机械截断按硬挡允许额保留最新 22 条(含 hi),19 条被折叠。
    expect(all.where((m) => m.isCompacted).length, 19);
    expect(all.last.content, 'reply.');
  });

  test('soft gear auto-compacts after the turn when occupancy crosses 60%', () async {
    // 容量 5000、输出预留 256:发送前 ≈3357 ≤ 硬挡 4000 不触发;
    // 回复落库后 ≈3733 ≥ 软挡 3000 → 轮后自动把活跃历史压回目标挡。
    await seedCapacityModel(5000);
    await disablePresetItems();
    final backend = _SummaryAwareBackend();
    final container = makeContainer(backend, maxTokens: 256);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    final messages = MessageRepository(db);
    for (var i = 0; i < 22; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 450);
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // 主写先、摘要在回复落库之后(软挡是事后路径,与硬挡的发送前顺序相反)。
    expect(backend.mainCalls, 1);
    expect(backend.summaryCalls, 1);
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system').single.content, 'SOFT-SUMMARY');
    // 24 条活跃(22 种子 + hi + reply)按预算保留最新 5 条,19 条折叠。
    expect(all.where((m) => m.isCompacted).length, 19);
  });

  test('soft compact refreshes the snapshot so stale attachments leave the panel', () async {
    // 回归(2026-09-29):软挡压缩发生在 `lastContext: sentContext` 赋值**之后**
    // (事后路径),不重算快照的话面板会停在压缩前 —— 继续显示那些刚被折叠、
    // 已不再进上下文的旧附件行,与实际发送内容对不上。硬挡路径无此问题
    // (压缩在快照赋值之前完成)。
    await seedCapacityModel(5000);
    await disablePresetItems();
    final backend = _SummaryAwareBackend();
    final container = makeContainer(backend, maxTokens: 256);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    final messages = MessageRepository(db);
    // 头部一条世界书附件行(会被软挡压缩折叠掉),再铺够触发软挡的对话。
    await messages.append(
      sessionId: sessionId,
      role: 'user',
      content: ContextAssembler.worldbookAttachment('圣剑', 'The sword is cursed'),
      kind: MessageKind.attachment,
      refId: 'wb:1',
    );
    for (var i = 0; i < 22; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 450);
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    expect(backend.summaryCalls, 1);
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => !m.isChat && !m.isCompacted), isEmpty,
        reason: '测试前提:附件行已被软挡压缩折叠');

    // 面板快照必须跟上压缩后的状态 —— 折叠的附件行不得再出现在分段里。
    final ctx = container.read(chatControllerProvider).lastContext!;
    expect(ctx.segments.where((s) => s.key == 'attachments'), isEmpty,
        reason: '压缩后快照里不该再有已折叠的附件行');
  });

  test('unknown capacity falls back to a conservative budget so compaction still runs', () async {
    // 回归(2026-09-29):容量未配置时不再整体跳过占用率逻辑 —— 组装已不做条数
    // 裁剪,跳过等于没有任何保护,长会话会一路涨到上游报错。内置 provider 种子
    // 存的容量就是 0,这是开箱默认路径,不是边角情况。
    // 本用例**不调** seedCapacityModel,让容量保持未知。
    await disablePresetItems();
    final backend = _SummaryAwareBackend();
    final container = makeContainer(backend, maxTokens: 256);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);

    final messages = MessageRepository(db);
    // 兜底容量 16384 → 硬挡 80% ≈ 13107。40×1100 字符 ≈ 13750 token,发送前超线。
    for (var i = 0; i < 40; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 1100);
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    expect(backend.summaryCalls, greaterThanOrEqualTo(1),
        reason: '容量未知也应触发压缩(退回兜底容量),而不是整体跳过');
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.isCompacted), isNotEmpty,
        reason: '超线历史应被折叠');
  });

  test('sending re-syncs the worldbook so out-of-page edits take effect', () async {
    // 回归(2026-09-29):世界书可在聊天页外被改(世界书页的启停/编辑/删除/导入、
    // 状态面板的后台锚定选择),而那些入口只 `invalidate(worldbookProvider)`
    // —— 那是 UI 用的只读视图。引擎读的是 ChatState 里的快照,且只在 load 时
    // 刷新,而从世界书页返回聊天页不会重新 load(同一个 route)。不同步的话,
    // 停用的仍会触发注入、改过的仍按旧文本注入,全都要等重进会话才生效。
    final characters = CharacterRepository(db);
    final charId = await characters.insert(const CharacterCard(name: 'Alice'));
    final sid = await SessionRepository(db).create(charId, 'wb-sync');
    final wb = WorldbookRepository(db);
    await wb.replaceForCharacter(charId, const [
      WorldbookEntry(characterId: 0, name: '圣剑', keys: ['龙'], content: '旧内容'),
    ]);

    final container = makeContainer(_CountingBackend());
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state = const AppSettings(backgroundEnabled: false);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sid, character: const CharacterCard(name: 'Alice'));

    // 会话已加载之后,在"页外"改掉条目内容(模拟世界书页保存)。
    final entries = await wb.byCharacter(charId);
    await wb.replaceForCharacter(charId, [entries.single.copyWith(content: '新内容')]);

    await controller.send('龙');

    final all = await MessageRepository(db).bySession(sid);
    final attachment = all.firstWhere((m) => !m.isChat);
    expect(attachment.content, contains('新内容'),
        reason: '发送前应同步世界书快照,按最新内容注入');
    expect(attachment.content, isNot(contains('旧内容')));
  });

  test('auto compact can be disabled entirely via settings', () async {
    // 总开关关闭:即便占用远超硬挡,发送前与轮后都不做任何压缩。
    await seedCapacityModel(6000);
    await disablePresetItems();
    final backend = _SummaryAwareBackend(summaryFailures: 99);
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(appSettingsProvider.notifier).state =
        const AppSettings(backgroundEnabled: false, autoCompactEnabled: false);

    final messages = MessageRepository(db);
    for (var i = 0; i < 40; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 400);
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    expect(backend.mainCalls, 1);
    expect(backend.summaryCalls, 0);
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system'), isEmpty);
    expect(all.where((m) => m.isCompacted), isEmpty);
    expect(all.last.content, 'reply.');
  });

  test('background falls back to the main model when the dedicated model id is unknown', () async {
    final backend = _BackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    // 后台指定了一个不存在的模型 id → loadConfigForModel 返回 null → 回退主写后端。
    container.read(appSettingsProvider.notifier).state =
        const AppSettings(backgroundModelId: 999999);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    // 后台仍用主写 fake 后端跑成功(没有因未知模型 id 报错/中断)。
    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
    // 主写 + 后台各一次:第一条 main 回复,第二条背景 JSON。
    expect(backend.calls, 2);
  });

  test('background-generated image appears in the chat list immediately', () async {
    final backend = _BackgroundImageBackend();
    final image = _FakeImageBackend();
    final container = makeContainer(backend, imageBackend: image);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // 生图任务与后台轮解耦 —— 后台轮收敛时图片可能还在生成/下载。
    // 轮询等待图片消息经 onImagePlaced 刷新进聊天列表。
    var imageSeen = false;
    for (var i = 0; i < 250 && !imageSeen; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final st = container.read(chatControllerProvider);
      imageSeen = st.messages.any((m) => m.imageUrl != null);
    }
    expect(imageSeen, isTrue, reason: '后台生图落库后应立即出现在聊天列表');

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
    expect(image.lastPrompt, 'a sword in the mist');
    expect(
      state.messages.where((m) => m.imageUrl != null).map((m) => m.imageUrl),
      ['http://127.0.0.1:1/image'],
    );

    // 落库确认:同一张图片消息同时存在于库中。
    final all = await MessageRepository(db).bySession(sessionId);
    expect(all.where((m) => m.imageUrl != null).length, 1);
  });

  test('combined variables+image turn still draws when the first reply omits the scene', () async {
    final backend = _BackgroundCombinedRetryBackend();
    final image = _FakeImageBackend();
    final container = makeContainer(backend, imageBackend: image);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    // 主写 + 变量+生图合并轮 + 仅图像补调:漏掉的图像描述由补调补上。
    expect(backend.calls, 3);
    expect(image.lastPrompt, 'a quiet inn at night');
    expect(await VariableRepository(db).bySession(sessionId), {'mood': 'calm'});
    // 补调产出的图片照常落库并经 onImagePlaced 进入聊天列表。
    await waitFor(
      () => container.read(chatControllerProvider).messages.any((m) => m.imageUrl != null),
      message: '仅图像补调成功后图片应进入聊天列表',
    );
    final all = await MessageRepository(db).bySession(sessionId);
    expect(all.where((m) => m.imageUrl != null), hasLength(1));
  });

  test('background turn with imageCount>1 stores one message per distinct prompt', () async {
    final backend = _BackgroundImagesBackend();
    final image = _FakeImageBackend();
    final container = makeContainer(
      backend,
      imageBackend: image,
      imageConfig: const ImageConfig(apiKey: 'sk-test', model: 'm', count: 2),
    );
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // 后台 LLM 产出同场景的两个不同描述 → 逐描述各画一张、逐张落库刷新。
    var imagesSeen = false;
    for (var i = 0; i < 250 && !imagesSeen; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final st = container.read(chatControllerProvider);
      imagesSeen = st.messages.where((m) => m.imageUrl != null).length >= 2;
    }
    expect(imagesSeen, isTrue, reason: '两个不同描述应各落一张图并进入聊天列表');
    expect(image.prompts, ['wide shot of the misty street', 'close-up of her face']);

    final all = await MessageRepository(db).bySession(sessionId);
    expect(all.where((m) => m.imageUrl != null).length, 2);
  });

  test('background image appended after the turn settles still reaches the chat list', () async {
    final backend = _BackgroundImageBackend();
    final image = _GatedImageBackend();
    final container = makeContainer(backend, imageBackend: image);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container); // 后台轮已收敛,生图仍挂起。

    final settled = container.read(chatControllerProvider);
    expect(settled.backgroundStatus, BackgroundStatus.succeeded);
    expect(settled.backgroundSummary, contains('图片生成中'),
        reason: '后台轮只发出生图指令,图片未就绪前不得宣称"已生成"');
    expect(image.started, isTrue, reason: '生图任务应在后台轮内启动(与轮次解耦)');
    expect(
      settled.messages.where((m) => m.imageUrl != null),
      isEmpty,
      reason: '生图尚未完成,此时不应有图片消息',
    );

    // 放行生图 → 图片落库 → onImagePlaced 刷新聊天列表,无需等下一轮发送。
    image.release.complete();
    var imageSeen = false;
    for (var i = 0; i < 250 && !imageSeen; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final st = container.read(chatControllerProvider);
      imageSeen = st.messages.any((m) => m.imageUrl != null);
    }
    expect(
      imageSeen,
      isTrue,
      reason: '生图完成后图片应立即经 onImagePlaced 进入聊天列表,而非等下一轮发送',
    );
    expect(
      container.read(chatControllerProvider).backgroundSummary,
      contains('图片已生成'),
      reason: '图片就绪后状态文案应同步从「图片生成中」更新为「图片已生成」',
    );
  });

  test('background image failure surfaces in the status instead of claiming success', () async {
    final backend = _BackgroundImageBackend();
    final image = _ThrowingImageBackend();
    final container = makeContainer(backend, imageBackend: image);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // 生图失败是 best-effort:不落图片消息,但状态文案如实标注失败,状态维护
    // 本身(无 skills/变量/memory)不受影响 —— 绝不静默装作"生图完成"。
    var summaryUpdated = false;
    for (var i = 0; i < 250 && !summaryUpdated; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final st = container.read(chatControllerProvider);
      summaryUpdated = st.backgroundSummary.contains('图片生成失败');
    }
    expect(summaryUpdated, isTrue);
    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
    expect(state.backgroundSummary, contains('图片生成失败,已跳过'));
    final all = await MessageRepository(db).bySession(sessionId);
    expect(all.where((m) => m.imageUrl != null || m.imageBase64 != null), isEmpty);
  });

  group('/rerun 重跑后台维护', () {
    /// 后台请求里 `<variable_delta>` 段的正文 —— 重跑重放的是哪段对话就看它。
    String bgDelta(String prompt) => RegExp(
      r'<variable_delta>[^\n]*\n(.*?)</variable_delta>',
      dotAll: true,
    ).firstMatch(prompt)!.group(1)!;

    test('没有记录时回退重放最新一轮问答', () async {
      final repo = MessageRepository(db);
      await repo.append(sessionId: sessionId, role: 'user', content: 'we reach the inn');
      await repo.append(sessionId: sessionId, role: 'assistant', content: 'the innkeeper nods');
      final backend = _RerunBackend(['{"variables":{"place":"inn"}}']);
      final container = makeContainer(backend);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      // 没跑过维护(重启/刚进会话):回退到最新一轮「用户消息 + 助手回复」。
      expect(await controller.runCommand(SlashCommand.rerun), '正在重跑上次后台维护…');
      await awaitBackground(container);

      final state = container.read(chatControllerProvider);
      expect(state.backgroundStatus, BackgroundStatus.succeeded);
      expect(state.backgroundSummary, contains('重跑完成'));
      expect(
        bgDelta(backend.bgRequests.single.systemPrompt),
        'user: we reach the inn\nassistant: the innkeeper nods',
      );
      expect(await VariableRepository(db).bySession(sessionId), {'place': 'inn'});
    });

    test('重放上次成功的窗口,且不回退正常进度游标', () async {
      final repo = MessageRepository(db);
      final backend = _RerunBackend([
        '{"variables":{"mood":"calm"}}',
        '{"variables":{"mood":"tense"}}',
        '{"variables":{"mood":"after"}}',
      ]);
      final container = makeContainer(backend);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      await controller.send('hi');
      await awaitBackground(container);
      expect(await VariableRepository(db).bySession(sessionId), {'mood': 'calm'});

      // 之后又出现未经维护的对话:重跑不该把它算进来。
      await repo.append(sessionId: sessionId, role: 'user', content: 'later input');

      expect(await controller.runCommand(SlashCommand.rerun), isNotNull);
      await awaitBackground(container);
      final rerun = backend.bgRequests[1].systemPrompt;
      expect(bgDelta(rerun), contains('user: hi'));
      expect(rerun, isNot(contains('later input')));
      expect(await VariableRepository(db).bySession(sessionId), {'mood': 'tense'});

      // 正常进度未被回退:下一轮维护只处理游标之后的新消息。
      await controller.send('again');
      await awaitBackground(container);
      final next = backend.bgRequests.last.systemPrompt;
      expect(bgDelta(next), contains('later input'));
      expect(bgDelta(next), contains('user: again'));
      // 'hi' 只作为只读前文出现,不再进增量 —— 重跑没有回退正常游标。
      expect(bgDelta(next), isNot(contains('user: hi')));
      expect(await VariableRepository(db).bySession(sessionId), {'mood': 'after'});
    });

    test('原地重绘上一轮后台生成的图片', () async {
      final repo = MessageRepository(db);
      final backend = _RerunBackend([
        '{"variables":{"mood":"calm"},"imagePrompt":"first scene"}',
        '{"variables":{"mood":"calm"},"imagePrompt":"second scene"}',
      ]);
      final image = _TrackingImageBackend(base64: 'bmV3');
      final container = makeContainer(backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      await controller.send('hi');
      await awaitBackground(container);
      await waitFor(
        () => container.read(chatControllerProvider).backgroundSummary.contains('图片已生成'),
        message: '第一轮图片应先落库',
      );
      final before = await repo.bySession(sessionId);
      final imageRow = before.firstWhere((m) => m.imagePrompt != null);
      expect(imageRow.imagePrompt, 'first scene');

      expect(await controller.runCommand(SlashCommand.rerun), isNotNull);
      await awaitBackground(container);
      await waitFor(
        () => container.read(chatControllerProvider).backgroundSummary.contains('图片已重绘'),
        message: '重跑应原地换图并把摘要改为「图片已重绘」',
      );

      // 原地替换:同一行、消息数不变、描述换新、修订号 +1(气泡才会换掉缓存旧图)。
      final after = await repo.bySession(sessionId, includeImages: true);
      expect(after, hasLength(before.length));
      final replaced = after.firstWhere((m) => m.id == imageRow.id);
      expect(replaced.imagePrompt, 'second scene');
      expect(replaced.imageBase64, 'bmV3');
      final state = container.read(chatControllerProvider);
      expect(state.imageRevisions[imageRow.id!], 1);
      expect(image.prompts, ['first scene', 'second scene']);
    });

    test('携带修改方向重跑:提示词标识重跑并附上一轮图片描述', () async {
      final backend = _RerunBackend([
        '{"variables":{"mood":"calm"},"imagePrompt":"first scene"}',
        '{"variables":{"mood":"tense"},"imagePrompt":"second scene"}',
      ]);
      final image = _TrackingImageBackend(base64: 'bmV3');
      final container = makeContainer(backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      await controller.send('hi');
      await awaitBackground(container);
      await waitFor(
        () => container.read(chatControllerProvider).backgroundSummary.contains('图片已生成'),
        message: '第一轮图片应先落库',
      );
      // 普通维护不带重跑标识。
      expect(
        backend.bgRequests.first.systemPrompt,
        isNot(contains('<rerun_instruction>')),
      );

      expect(
        await controller.runCommand(SlashCommand.rerun, args: '画面更暗一些'),
        '正在按修改方向重跑上次后台维护…',
      );
      await awaitBackground(container);

      final rerunPrompt = backend.bgRequests[1].systemPrompt;
      expect(rerunPrompt, contains('<rerun_instruction>'));
      expect(rerunPrompt, contains('RERUN of the previous background maintenance'));
      expect(rerunPrompt, contains('画面更暗一些'));
      // 上一轮落库的图片描述作为修订基线一并送入。
      expect(rerunPrompt, contains('first scene'));
    });

    test('目标图片已被删除时改为追加新图', () async {
      final repo = MessageRepository(db);
      final backend = _RerunBackend([
        '{"variables":{},"imagePrompt":"first scene"}',
        '{"variables":{},"imagePrompt":"second scene"}',
      ]);
      final image = _TrackingImageBackend(base64: 'bmV3');
      final container = makeContainer(backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      await controller.send('hi');
      await awaitBackground(container);
      await waitFor(
        () => container.read(chatControllerProvider).backgroundSummary.contains('图片已生成'),
      );
      final before = await repo.bySession(sessionId);
      final imageRow = before.firstWhere((m) => m.imagePrompt != null);
      await repo.delete(imageRow.id!);

      expect(await controller.runCommand(SlashCommand.rerun), isNotNull);
      await awaitBackground(container);
      await waitFor(() {
        final s = container.read(chatControllerProvider).backgroundSummary;
        return s.contains('重跑完成') && s.contains('图片已生成');
      });

      // 目标已不存在 → 追加新行,旧行不复活;替换专用的修订号也不动。
      final after = await repo.bySession(sessionId);
      expect(after.where((m) => m.imagePrompt != null), hasLength(1));
      expect(after.last.imagePrompt, 'second scene');
      expect(
        container.read(chatControllerProvider).imageRevisions[imageRow.id!],
        isNull,
      );
    });

    test('后台轮在跑时拒绝重跑,不额外发起调用', () async {
      final backend = _ControlledBackgroundBackend(
        firstResponse: '{"variables":{"hp":"8"}}',
      );
      final container = makeContainer(backend);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      final sending = controller.send('hi');
      await backend.started.future;
      expect(await controller.runCommand(SlashCommand.rerun), isNull);
      expect(container.read(chatControllerProvider).error, contains('正在运行'));
      expect(backend.requests, hasLength(1), reason: '拒绝时不得发起第二次后台调用');

      backend.unblock();
      await sending;
      await awaitBackground(container);
      expect(
        container.read(chatControllerProvider).backgroundStatus,
        BackgroundStatus.succeeded,
      );
    });

    test('上一轮图片还在生成时拒绝,收敛后可重跑并原地换图', () async {
      final backend = _BackgroundImageBackend();
      final image = _GatedImageBackend();
      final container = makeContainer(backend, imageBackend: image);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      await controller.send('hi');
      await awaitBackground(container); // 轮次收敛,生图仍挂起
      expect(image.started, isTrue);
      expect(await controller.runCommand(SlashCommand.rerun), isNull);
      expect(container.read(chatControllerProvider).error, contains('仍在生成'));

      image.release.complete();
      await waitFor(
        () => container.read(chatControllerProvider).backgroundSummary.contains('图片已生成'),
      );
      // 图片收敛后放行:重跑按同一描述原地替换。
      expect(await controller.runCommand(SlashCommand.rerun), isNotNull);
      await awaitBackground(container);
      await waitFor(
        () => container.read(chatControllerProvider).backgroundSummary.contains('图片已重绘'),
      );
      final rows = await MessageRepository(db).bySession(sessionId);
      expect(rows.where((m) => m.imagePrompt != null), hasLength(1));
    });

    test('中断能停掉重跑,变量保持上一次成功结果', () async {
      final backend = _RerunBackend(
        ['{"variables":{"mood":"calm"}}', '{"variables":{"mood":"tense"}}'],
        gateCall: 2,
      );
      final container = makeContainer(backend);
      addTearDown(container.dispose);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      await controller.send('hi');
      await awaitBackground(container);
      expect(await VariableRepository(db).bySession(sessionId), {'mood': 'calm'});

      expect(await controller.runCommand(SlashCommand.rerun), isNotNull);
      await backend.started.future;
      controller.interrupt();
      await awaitBackground(container);

      final state = container.read(chatControllerProvider);
      expect(state.backgroundStatus, BackgroundStatus.interrupted);
      expect(state.backgroundSummary, '重跑已中断');
      expect(await VariableRepository(db).bySession(sessionId), {'mood': 'calm'});
    });

    test('功能全关时拒绝重跑且不发起后台调用', () async {
      final repo = MessageRepository(db);
      await repo.append(sessionId: sessionId, role: 'user', content: 'hi');
      await repo.append(sessionId: sessionId, role: 'assistant', content: 'reply');
      final backend = _RerunBackend(['{"variables":{}}']);
      final container = makeContainer(backend);
      addTearDown(container.dispose);
      container.read(backgroundFeaturesProvider.notifier).state =
          const BackgroundFeatures(variables: false, image: false);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(
        sessionId: sessionId,
        character: const CharacterCard(name: 'Alice'),
      );

      expect(await controller.runCommand(SlashCommand.rerun), isNull);
      expect(
        container.read(chatControllerProvider).error,
        contains('未选中可执行的维护功能'),
      );
      expect(backend.bgRequests, isEmpty);
    });
  });

  test('send dispatches the orchestrator after the reply', () async {
    final backend = _BackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    // 技能是全局目录、用户手动管理:后台轮不再写技能状态。
    expect(await db.db.query('skills'), isEmpty);

    // 后台用量与主写分开记账。
    final state = container.read(chatControllerProvider);
    expect(state.backgroundInputTokens, 120);
    expect(state.backgroundOutputTokens, 15);
    expect(state.backgroundCachedInputTokens, 80);
    expect(state.inputTokens, 0);
    // 后台agent 状态可见:成功 + 一句话摘要(不再含技能部分)。
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
  });

  test('background turns never write memory (CW: user-maintained only)', () async {
    final backend = _BackgroundMemoryBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    await container.read(memoriesProvider(sessionId).future);
    expect((await MemoryRepository(db).bySession(sessionId)), isEmpty);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    // 后台 LLM 即便回传 memory 字段也不落库:记忆只经用户主动路径
    // (初始化/重生成/手动编辑)写入。
    expect(await MemoryRepository(db).bySession(sessionId), isEmpty);
    final fresh = await container.read(memoriesProvider(sessionId).future);
    expect(fresh, isEmpty);
  });

  test('initializeMemory writes an initial memory from character + worldbook and marks succeeded', () async {
    final backend = _MemoryInitBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    // 先让状态面板(或其代表性读)把 memoriesProvider 缓存为"空"。
    await container.read(memoriesProvider(sessionId).future);
    expect(await MemoryRepository(db).bySession(sessionId), isEmpty);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice', description: 'a silver-haired catgirl'),
    );

    await controller.initializeMemory();
    await awaitBackground(container);

    // 落库了一条初始记忆。
    expect((await MemoryRepository(db).bySession(sessionId)).single.content,
        'Alice is a silver-haired catgirl from Eldoria.');
    // 状态:成功 + 一句话摘要;token 单独记账。
    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
    expect(state.backgroundSummary, contains('记忆已初始化'));
    expect(state.backgroundInputTokens, 60);
    expect(state.backgroundOutputTokens, 25);
    expect(state.inputTokens, 0);
    // memoriesProvider 已失效:再次读取能看到新记忆(状态面板/聊天页提示条刷新)。
    final fresh = await container.read(memoriesProvider(sessionId).future);
    expect(fresh.map((m) => m.content).toList(), ['Alice is a silver-haired catgirl from Eldoria.']);
  });

  test('initializeMemory is a no-op when memory already exists', () async {
    final backend = _MemoryInitBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    await MemoryRepository(db).set(sessionId, '已有的记忆');

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.initializeMemory();

    // 不发起任何 LLM 调用(已有记忆无需再初始化)。
    expect(backend.calls, 0);
    expect((await MemoryRepository(db).bySession(sessionId)).single.content, '已有的记忆');
    // 状态给出可读的跳过原因。
    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.skipped);
    expect(state.backgroundSummary, contains('记忆已存在'));
  });

  test('initializeMemory surfaces a backend failure and writes nothing', () async {
    final backend = _MemoryInitErrorBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.initializeMemory();
    await awaitBackground(container);

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.failed);
    expect(state.backgroundSummary, contains('初始化'));
    // 引擎披露的诊断摘要(后端错误消息)拼进状态文案,便于区分故障类型。
    expect(state.backgroundSummary, contains('bg down'));
    expect(await MemoryRepository(db).bySession(sessionId), isEmpty);
  });

  test('persistBackgroundEnabled keeps appSettingsProvider in sync with the toggle', () async {
    final container = makeContainer(_BackgroundMemoryBackend());
    addTearDown(container.dispose);

    // 初始为启用。
    expect(container.read(appSettingsProvider).backgroundEnabled, isTrue);

    await persistBackgroundEnabled(
      stateSetter: (v) => container.read(backgroundEnabledProvider.notifier).state = v,
      appSettingsSetter: (s) => container.read(appSettingsProvider.notifier).state = s,
      repo: container.read(appSettingsRepositoryProvider),
      current: container.read(appSettingsProvider),
      enabled: false,
    );

    // 两个派生源一致:后台开关 provider 与 appSettings(单一真相)都更新,
    // 否则下次重建/派生时(重启前)后台开关会回读到旧值。
    expect(container.read(backgroundEnabledProvider), isFalse);
    expect(container.read(appSettingsProvider).backgroundEnabled, isFalse);

    // 已持久化到库。
    final saved = await AppSettingsRepository(db).load();
    expect(saved.backgroundEnabled, isFalse);
  });

  test('send marks background disabled when the toggle is off', () async {
    final backend = _BackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    // 关闭后台agent:派生 provider 置为关闭(不落库也能在会话内立即生效)。
    container.read(backgroundEnabledProvider.notifier).state = false;

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.disabled);
    // 关闭时后台不调用 LLM,不记账。
    expect(state.backgroundInputTokens, 0);
    // 主回复仍正常。
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.role).toList(), ['user', 'assistant']);
  });

  test('send marks background failed when the backend errors', () async {
    // Backend replies on first call (main write) then errors on the background call.
    final seq = _BackgroundThenError();
    final container = makeContainer(seq);
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.failed);
    expect(state.backgroundSummary, isNotEmpty);
    // 主回复仍正常落库。
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.role).toList(), ['user', 'assistant']);
  });

  test('send marks background skipped when the only feature is un-actionable', () async {
    final backend = _BackgroundMemoryBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);

    // 只开 image,但没接生图 provider → 后台应"跳过"而不必发起 LLM。
    container.read(backgroundFeaturesProvider.notifier).state = const BackgroundFeatures(
      variables: false,
      image: true,
    );

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.skipped);
    expect(state.backgroundSummary, contains('跳过'));
    // 未发起后台 LLM:只发生一次主写调用。
    expect(backend.calls, 1);
  });

  test('variables-only maintains every round with a small delta window (CW: no slow rounds)', () async {
    // 回归防护:慢变降频已随逐轮记忆维护退役 —— 只开变量时每轮都是快状态轮,
    // 转录走增量游标(窗口很小),不存在"慢变维护未到期"的跳过;连续多轮每轮
    // 都真正发起后台维护。
    final backend = _MainBgRecordingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(backgroundFeaturesProvider.notifier).state = const BackgroundFeatures(
      variables: true,
      image: false,
    );
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    for (var i = 0; i < 5; i++) {
      await controller.send('round $i');
      await awaitBackground(container);
    }

    // 五轮全部做了后台维护。
    expect(backend.bgRequests, hasLength(5));
    // 每轮都是含变量块的快状态轮;纯 variables 轮不注入记忆锚定段(低成本)。
    for (final req in backend.bgRequests) {
      expect(req.systemPrompt, contains('<variables>'));
      expect(req.systemPrompt, isNot(contains('<memory>')));
    }
    // 最后一轮正常收敛为成功。
    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.succeeded);
  });

  test('strict confirmation mode stages background removals instead of deleting', () async {
    final backend = _RemovalBgBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(backgroundFeaturesProvider.notifier).state = const BackgroundFeatures(
      variables: true,
      image: false,
    );
    container.read(appSettingsProvider.notifier).state =
        const AppSettings(backgroundDeletionConfirm: true);
    final repo = VariableRepository(db);
    await repo.upsert(sessionId, 'hp', '10', access: VariableAccess.full);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    // 严格模式:只生成待确认建议,active 变量与回收站都不动。
    expect(await repo.bySession(sessionId), {'hp': '10'});
    expect(await repo.trash(sessionId), isEmpty);
    expect((await repo.pendingDeletions(sessionId)).single.key, 'hp');
    expect(container.read(chatControllerProvider).backgroundSummary, contains('待确认'));
  });

  test('image-only without a provider skips every round without wasting LLM calls', () async {
    // 只开 image 但生图 provider 不可用(未配置/密钥为空):每轮都应在编排器
    // 短路(无需发起后台 LLM),且提示仍能说清原因,而不是把轮次空烧掉。
    final backend = _MainBgRecordingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    container.read(backgroundFeaturesProvider.notifier).state = const BackgroundFeatures(
      variables: false,
      image: true,
    );
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    for (var i = 0; i < 3; i++) {
      await controller.send('q$i');
      await awaitBackground(container);
      final state = container.read(chatControllerProvider);
      expect(state.backgroundStatus, BackgroundStatus.skipped);
      expect(state.backgroundSummary, contains('未选中可执行的维护功能'));
    }
    // 三轮只有三次主写调用,后台 LLM 一次都没发。
    expect(backend.calls, 3);
  });

  test('interrupting the main write keeps the partial draft as a persisted reply', () async {
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // 启动 send 但不 await(它挂着等流)。
    final sendFuture = controller.send('hi');
    // 流入:先吐一点草稿,轮询到草稿就绪(不再赌固定延时的窗口)。
    backend.emit(const TextDelta('partial-'));
    await waitFor(() => container.read(chatDraftProvider) == 'partial-');

    // 中断:截断主写,已生成的部分文本落库保留。send 收敛即订阅已取消
    // (因果保证),此后再补发的事件不可能被消费 —— 顺序确定,无竞态窗口。
    controller.interrupt();
    await sendFuture.timeout(const Duration(seconds: 10));
    backend.emit(const TextDelta('rest')); // 之后的 delta 一律被丢弃。
    backend.emit(const DoneEvent());
    backend.close();

    final state = container.read(chatControllerProvider);
    expect(state.streaming, isFalse);
    expect(container.read(chatDraftProvider), isEmpty);
    // 用户消息与部分回复都在(不想保留可由用户自行删除)。
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.content).toList(), ['hi', 'partial-']);
    expect(messages.last.role, 'assistant');
  });

  test('interrupting during the zero-event loading phase returns immediately', () async {
    // 回归防护「加载期无法立即打断」:请求已发出、模型思考中、一个流事件都没
    // 到时,旧实现的主写消费循环 `await for` 只在**下一个事件到达**时才轮询
    // 中断标志 —— 按停止毫无反应,send 一直挂到首块或流结束(推理模型思考
    // 可达几十秒)。现在中断令牌与流完成竞速(Future.any),零事件也能立即
    // 唤醒等待并取消订阅、关闭底层请求。
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    final sendFuture = controller.send('hi');
    // 不 emit 任何事件:模拟「AI 加载中、还没生成回复」。轮询到 streaming
    // 置位,确保打断打中的是"已进入流等待"这一窗口(而非 send 尚未起步)。
    await waitFor(() => container.read(chatControllerProvider).streaming);
    controller.interrupt();
    // 流从未发过任何事件、也从未关闭 —— send 仍必须在有限时间内收敛。
    await sendFuture.timeout(const Duration(seconds: 10));

    final state = container.read(chatControllerProvider);
    expect(state.streaming, isFalse);
    expect(container.read(chatDraftProvider), isEmpty);
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.content).toList(), ['hi']);
  });

  test('interrupting a backend parked before its first byte returns immediately', () async {
    // 回归防护「打断仍被拖到请求自然结束」:真实后端的 generate 是 async*
    // 生成器,零事件期停在 `await client.send()` 上 —— 订阅取消 Future 要等
    // 生成器本体收敛,消费端 await 取消会让 streaming 一直挂着(上一版修复
    // 即栽在这里:唤醒了等待、却卡在等待取消)。本用例用同形状的假后端钉死:
    // 停在永不完成 await 上的流,中断后 send 必须立即收敛。
    final backend = _HangingStartBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    final sendFuture = controller.send('hi');
    await waitFor(() => container.read(chatControllerProvider).streaming);

    controller.interrupt();
    // 后端的 await 永不完成、流永不结束 —— 有限时间内 send 必须收敛。
    await sendFuture.timeout(const Duration(seconds: 10));

    final state = container.read(chatControllerProvider);
    expect(state.streaming, isFalse);
    expect(container.read(chatDraftProvider), isEmpty);
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.content).toList(), ['hi']);
  });

  test('interrupting the background agent marks it interrupted and skips state writes', () async {
    final backend = _BackgroundThenHang();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // send 会:主写完成 → 进入后台挂起的 LLM 调用前,先让主写跑完。
    final sendFuture = controller.send('hi');
    // 等待主写落库、后台进入 running。
    for (var i = 0; i < 250; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (container.read(chatControllerProvider).backgroundStatus == BackgroundStatus.running) {
        break;
      }
    }
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.running);

    // 中断后台,并让它停在的流自然结束以触发中断检查。
    controller.interrupt();
    backend.closeBg();
    // 解耦后 send 只等主写;后台的 interrupted 终态要等后台任务本身收敛。
    await sendFuture;
    await awaitBackground(container);

    final state = container.read(chatControllerProvider);
    expect(state.backgroundStatus, BackgroundStatus.interrupted);
    // 主回复仍在(主写已完成)。
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.role).toList().where((r) => r == 'assistant'), isNotEmpty);
  });

  test('interrupting the background agent while its stream is hung returns immediately (CR)', () async {
    // 回归测试:旧实现下后台中断要等 LLM 终于吐首个流事件才能命中
    // shouldCancel(LLM 思考期不吐事件,可能 5~30 秒)。本测试在后台进入 running
    // 后**只**调 controller.interrupt(),不主动关流 —— cancelSignal
    // 通道让状态立即翻成 interrupted,不等流事件。
    final backend = _BackgroundThenHang();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // 后台进入 running。
    await controller.send('hi');
    for (var i = 0; i < 250; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (container.read(chatControllerProvider).backgroundStatus == BackgroundStatus.running) {
        break;
      }
    }
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.running);

    // 中断(流不主动关,模拟生产中 LLM 思考期)。
    controller.interrupt();
    // 闸超时:1.5s 内应已收敛到 interrupted(主写路径量级);旧实现下,流不主动
    // 关闭时这一行要等模型吐首个 token 才返回,远超本阈值。
    await awaitBackground(container).timeout(const Duration(milliseconds: 1500));
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.interrupted);

    // 清理挂起流(测试可观察的善后)。
    backend.closeBg();
  });

  test('interrupting the next main write must not resurrect an in-flight background round (EF)', () async {
    // 回归防护「reset 吹灭并发轮的取消通道」:旧实现主写与后台共用一个令牌,
    // 第二轮主写被中断后其收尾就地 reset —— 并发在飞的后台轮若还没走到自己的
    // cancelled 判定,标志已被清成 false,按停止后后台继续跑完并写状态。
    // 令牌逐轮换发:后台轮持有自己的令牌实例,取消对它不可逆。
    final backend = _BgHangThenMainHang();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // 第一轮:主写完成 → 后台进入挂起(running)。
    await controller.send('hi');
    await waitFor(
      () => container.read(chatControllerProvider).backgroundStatus == BackgroundStatus.running,
    );

    // 第二轮:后台仍在飞时再发一条;主写吐首块后中断 —— 主写收尾必然观察到
    // cancelled(旧实现此时就地 reset 共享令牌)。
    final sendFuture = controller.send('again');
    await waitFor(() => container.read(chatControllerProvider).streaming);
    controller.interrupt();
    await sendFuture.timeout(const Duration(seconds: 10));

    // 放行后台流:新实现下后台早已被 cancelSignal 唤醒并按"已中断"收敛;
    // 旧实现下它要等这步放行、然后走解析失败(failed)—— 两态可分辨。
    backend.closeBg();
    await awaitBackground(container).timeout(const Duration(seconds: 5));
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.interrupted);

    // 善后:放行挂起的第二条主写流(其订阅已被取消,无人消费)。
    backend.closeMain2();
  });

  test('send returns while the background maintenance is still running (decoupled)', () async {
    final backend = _BackgroundThenHang();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // send 只在主写完成后返回,不等后台 LLM 调用(后台流被测试挂起)。
    await controller.send('hi');
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.running);

    // 主写已落库;用户可立即再发(不受后台挂起影响)。
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.role).toList(), ['user', 'assistant']);

    // 放行后台流 → 后台轮收敛:挂起后端吐的是无法解析的文本(修复兜底救不回),
    // 关闭流后解析失败 → failed。这里只验证 send 不阻塞后台轮。
    backend.closeBg();
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.failed);
  });

  test('busy background turns coalesce into one serialized follow-up', () async {
    final backend = _ControlledBackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await backend.started.future;
    await controller.send('again');
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.running);
    expect(container.read(chatControllerProvider).backgroundSummary, contains('合并待处理'));
    expect(backend.requests, hasLength(1));
    backend.unblock();
    await awaitBackground(container);
    expect(backend.requests, hasLength(2));
    final delta = backend.requests.last.systemPrompt.split('<variable_delta>').last.split('</variable_delta>').first;
    expect(delta, contains('user: again'));
    expect(delta, isNot(contains('user: hi')));
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('a stale background turn cannot write after switching sessions', () async {
    final backend = _ControlledBackgroundBackend(response: '{"variables":{"hp":"3"}}');
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    final otherId = await SessionRepository(db).create(
      await CharacterRepository(db).insert(const CharacterCard(name: 'Bob')), 's2',
    );
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    await backend.started.future;
    final firstTask = controller.backgroundTask;
    await controller.load(sessionId: otherId, character: const CharacterCard(name: 'Bob'));
    await controller.send('hi2');
    await awaitBackground(container);
    backend.unblock();
    await firstTask;
    expect(await VariableRepository(db).bySession(sessionId), isEmpty);
    expect(await VariableRepository(db).bySession(otherId), {'hp': '3'});
    expect(container.read(chatControllerProvider).sessionId, otherId);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('manual rename rejects a stale batch without retrying queued turns', () async {
    final backend = _ControlledBackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final variables = VariableRepository(db);
    await variables.upsert(sessionId, 'hp', '10');
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('first');
    await backend.started.future;
    await controller.send('queued');
    await variables.update(sessionId, oldKey: 'hp', newKey: 'health', value: '5');
    backend.unblock();
    await awaitBackground(container);
    expect(await variables.bySession(sessionId), {'health': '5'});
    expect(backend.requests, hasLength(1));
    expect(container.read(chatControllerProvider).backgroundSummary, contains('已丢弃旧后台结果'));
  });

  test('a failed first round retains its starting point for the next reply', () async {
    final backend = _ControlledBackgroundBackend(failingCalls: 3);
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('unprocessed-first');
    await backend.started.future;
    backend.unblock();
    await awaitBackground(container);
    expect(backend.requests, hasLength(3));
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.failed);
    await controller.send('next');
    await awaitBackground(container);
    expect(backend.requests, hasLength(4));
    final delta = backend.requests.last.systemPrompt.split('<variable_delta>').last.split('</variable_delta>').first;
    expect(delta, contains('user: unprocessed-first'));
    expect(delta, contains('user: next'));
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('failure with a new external wake permits one bounded follow-up', () async {
    final backend = _ControlledBackgroundBackend(failingCalls: 3);
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('first');
    await backend.started.future;
    await controller.send('queued');
    backend.unblock();
    await awaitBackground(container);
    expect(backend.requests, hasLength(4));
    expect(backend.requests.last.systemPrompt, contains('user: first'));
    expect(backend.requests.last.systemPrompt, contains('user: queued'));
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('catch-up stops after two batches and resumes without dropping remaining messages', () async {
    final backend = _ControlledBackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('first');
    await backend.started.future;
    for (var i = 0; i < 18; i++) {
      await controller.send('msg$i');
    }
    backend.unblock();
    await awaitBackground(container);
    expect(backend.requests, hasLength(2));
    expect(container.read(chatControllerProvider).backgroundSummary, contains('仍有对话待后续维护'));
    await controller.send('resume');
    await awaitBackground(container);
    expect(backend.requests, hasLength(4));
    final thirdDelta = backend.requests[2].systemPrompt.split('<variable_delta>').last.split('</variable_delta>').first;
    expect(thirdDelta, contains('user: msg6\n'));
    expect(thirdDelta, isNot(contains('user: msg5\n')));
    await controller.send('last');
    await awaitBackground(container);
    expect(backend.requests, hasLength(5));
    final lastDelta = backend.requests.last.systemPrompt.split('<variable_delta>').last.split('</variable_delta>').first;
    expect(lastDelta, contains('user: resume'));
    expect(lastDelta, contains('user: last'));
    expect(container.read(chatControllerProvider).backgroundSummary, isNot(contains('待后续维护')));
  });

  test('switching A to B to A invalidates the original task and cached variables', () async {
    final backend = _ControlledBackgroundBackend(response: '{"variables":{"hp":"3"}}');
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    final otherId = await SessionRepository(db).create(
      await CharacterRepository(db).insert(const CharacterCard(name: 'Bob')), 'other',
    );
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    expect(await container.read(variablesProvider(sessionId).future), isEmpty);
    await controller.send('first');
    await backend.started.future;
    final oldTask = controller.backgroundTask;
    await controller.load(sessionId: otherId, character: const CharacterCard(name: 'Bob'));
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('new-cycle');
    await awaitBackground(container);
    backend.unblock();
    await oldTask;
    expect(await VariableRepository(db).bySession(sessionId), {'hp': '3'});
    expect(await container.read(variablesProvider(sessionId).future), {'hp': '3'});
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  for (final action in ['regenerate', 'resend', 'edit', 'delete', 'clear']) {
    test('$action cancels an in-flight variable batch before changing history', () async {
      final backend = _ControlledBackgroundBackend(response: '{"variables":{"hp":"3"}}');
      final container = makeContainer(backend);
      addTearDown(container.dispose);
      addTearDown(backend.unblock);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
      await controller.send('first');
      await backend.started.future;
      final oldTask = controller.backgroundTask;
      final rows = await MessageRepository(db).bySession(sessionId);
      switch (action) {
        case 'regenerate':
          await controller.regenerate(rows.last.id!);
        case 'resend':
          await controller.resend(rows.first.id!);
        case 'edit':
          await controller.editMessage(rows.last.id!, 'edited');
        case 'delete':
          await controller.deleteMessage(rows.last.id!);
        case 'clear':
          await controller.runCommand(SlashCommand.clearHistory);
      }
      backend.unblock();
      await oldTask;
      await awaitBackground(container);
      expect((await VariableRepository(db).bySession(sessionId))['hp'], isNot('8'));
      if (action == 'edit' || action == 'delete' || action == 'clear') {
        expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.interrupted);
      }
      await controller.send('fresh');
      await awaitBackground(container);
      expect(await VariableRepository(db).bySession(sessionId), {'hp': '3'});
      expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
    });
  }

  test('maintenance queued during memory initialization runs after its slot is released', () async {
    final backend = _ControlledBackgroundBackend(firstResponse: '{"memory":"initial memory"}');
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.initializeMemory();
    await backend.started.future;
    final memoryTask = controller.backgroundTask;
    await controller.send('during-init');
    expect(backend.requests, hasLength(1));
    backend.unblock();
    await memoryTask;
    await awaitBackground(container);
    expect(backend.requests, hasLength(2));
    expect(backend.requests.last.systemPrompt, contains('user: during-init'));
    expect((await MemoryRepository(db).bySession(sessionId)).single.content, 'initial memory');
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('interrupt immediately after a reply settles background preparation', () async {
    final backend = _ControlledBackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('first');
    controller.interrupt();
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.interrupted);
    expect(await VariableRepository(db).bySession(sessionId), isEmpty);
  });

  test('disposing the controller cancels an in-flight variable write', () async {
    final backend = _ControlledBackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(backend.unblock);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('first');
    await backend.started.future;
    final task = controller.backgroundTask;
    container.dispose();
    backend.unblock();
    await task;
    expect(await VariableRepository(db).bySession(sessionId), isEmpty);
  });

  test('send survives a no-op hook runtime at each trigger point', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('Hello from the fake.'));
    backend.emit(const DoneEvent());
    backend.close();

    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.map((m) => m.role).toList(), ['user', 'assistant']);
  });

  test('afterStream hook rewrites the persisted reply', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('Hello from the fake.'));
    backend.emit(const DoneEvent());
    backend.close();

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendConfigProvider.overrideWith(
          (ref) => const BackendConfig(
            provider: BackendProvider.openai,
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-test',
            model: 'gpt-4o',
          ),
        ),
        backendProvider.overrideWith((ref) => backend),
        hookRuntimeProvider.overrideWith((ref) => _ModifyingRuntime()),
      ],
    );
    addTearDown(container.dispose);

    await db.db.insert('hooks', {'name': 'strip', 'trigger_point': 'afterStream', 'js_code': '1'});

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.last.content, 'MODIFIED');
  });

  test('beforeContextAssembly hook rewrites the user input before persistence', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('reply.'));
    backend.emit(const DoneEvent());
    backend.close();

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendConfigProvider.overrideWith(
          (ref) => const BackendConfig(
            provider: BackendProvider.openai,
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-test',
            model: 'gpt-4o',
          ),
        ),
        backendProvider.overrideWith((ref) => backend),
        hookRuntimeProvider.overrideWith((ref) => _UserTextRuntime()),
      ],
    );
    addTearDown(container.dispose);

    await db.db.insert('hooks', {'name': 'rewrite', 'trigger_point': 'beforeContextAssembly', 'js_code': '1'});

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // The rewritten text is what gets persisted (and therefore assembled
    // into the LLM history).
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.first.role, 'user');
    expect(messages.first.content, 'REWRITTEN');
  });

  test('injects the configured username into the beforeContextAssembly hook context', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('reply.'));
    backend.emit(const DoneEvent());
    backend.close();

    final capture = _UserNameMarkerRuntime();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendConfigProvider.overrideWith(
          (ref) => const BackendConfig(
            provider: BackendProvider.openai,
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-test',
            model: 'gpt-4o',
          ),
        ),
        backendProvider.overrideWith((ref) => backend),
        hookRuntimeProvider.overrideWith((ref) => capture),
        userProfileProvider.overrideWith(
          (ref) => const UserProfile(name: _UserNameMarkerRuntime.marker),
        ),
      ],
    );
    addTearDown(container.dispose);

    await db.db.insert('hooks', {'name': 'echo-user', 'trigger_point': 'beforeContextAssembly', 'js_code': '1'});

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // The injected username reached the hook context (the marker appears verbatim
    // in the HookEngine script), and the hook's rewrite of userText is persisted.
    expect(capture.sawUserName, isTrue);
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.first.content, 'REWRITTEN');
  });

  test('injects the configured username into the afterStream reply hook context', () async {
    final backend = _FakeBackend();
    backend.emit(const TextDelta('reply with {{user}}'));
    backend.emit(const DoneEvent());
    backend.close();

    final capture = _ReplyUserNameMarkerRuntime();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendConfigProvider.overrideWith(
          (ref) => const BackendConfig(
            provider: BackendProvider.openai,
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-test',
            model: 'gpt-4o',
          ),
        ),
        backendProvider.overrideWith((ref) => backend),
        hookRuntimeProvider.overrideWith((ref) => capture),
        userProfileProvider.overrideWith(
          (ref) => const UserProfile(name: _ReplyUserNameMarkerRuntime.marker),
        ),
      ],
    );
    addTearDown(container.dispose);

    // afterStream 触发点:显式插一条 hook,验证用户名注入到回复上下文 + 改写落库。
    await db.db.insert('hooks', {'name': 'reply-user', 'trigger_point': 'afterStream', 'js_code': '1'});

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    // 用户名注入了 afterStream 上下文;hook 对 text 的改写被落库为助手回复。
    expect(capture.sawUserName, isTrue);
    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.last.role, 'assistant');
    expect(messages.last.content, 'REPLY_REWRITTEN');
  });

  test('beforeGenerate hook rewrites the system prompt and request params', () async {
    final backend = _RecordingBackend();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendConfigProvider.overrideWith(
          (ref) => const BackendConfig(
            provider: BackendProvider.openai,
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'sk-test',
            model: 'gpt-4o',
            temperature: 0.9,
            maxTokens: 500,
          ),
        ),
        backendProvider.overrideWith((ref) => backend),
        hookRuntimeProvider.overrideWith((ref) => _RequestRuntime()),
      ],
    );
    addTearDown(container.dispose);

    await db.db.insert('hooks', {'name': 'tune', 'trigger_point': 'beforeGenerate', 'js_code': '1'});
    await db.db.insert('hooks', {
      'name': 'tune-ctx',
      'trigger_point': 'beforeContextAssembly',
      'js_code': '2',
      'enabled': 0,
    });

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');

    expect(backend.requests, isNotEmpty);
    final request = backend.requests.first;
    expect(request.systemPrompt, 'SP2');
    expect(request.temperature, 0.2);
    expect(request.maxTokens, 77);
  });

  test('background image scenes retain a sliding window alongside variable deltas', () async {
    final backend = _MainBgRecordingBackend();
    final container = makeContainer(backend, imageBackend: FakeImageBackend('aGVsbG8='));
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    // 连续四轮:全部是快状态(变量/生图),转录取 recent 末尾滑动窗口
    // (增量游标只作跳过判据)—— 生图轮始终看得到最近完整场景。
    await controller.send('hi');
    await awaitBackground(container);
    await controller.send('again');
    await awaitBackground(container);
    await controller.send('third');
    await awaitBackground(container);
    await controller.send('fourth');
    await awaitBackground(container);

    expect(backend.bgRequests, hasLength(4));
    for (final req in backend.bgRequests) {
      // 快状态块:变量 + 生图指令在场;结构化标签分段。
      expect(req.systemPrompt, contains('<variables>'));
      expect(req.systemPrompt, contains('# image'));
      // 本会话无记忆 → 无记忆锚定段;角色卡锚定段由控制器透传注入。
      expect(req.systemPrompt, isNot(contains('</memory>')));
      expect(req.systemPrompt, contains('<character>'));
    }
    // 滑动窗口:第二轮窗口仍含前文的 'hi'(旧增量窗口会裁掉,生图因此脱剧情);
    // 第四轮共 8 条、窗口 6 条 —— 'again' 仍在窗内,'hi' 才被裁掉。
    expect(backend.bgRequests[0].systemPrompt, contains('user: hi'));
    expect(backend.bgRequests[1].systemPrompt, contains('user: again'));
    expect(backend.bgRequests[1].systemPrompt, contains('user: hi'));
    expect(backend.bgRequests[3].systemPrompt, contains('user: fourth'));
    expect(backend.bgRequests[3].systemPrompt, contains('user: again'));
    expect(backend.bgRequests[3].systemPrompt, isNot(contains('user: hi')));
    // 全部成功收敛(游标推进、状态上报 succeeded)。
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('send accounts compact token usage in a separate bucket (D2)', () async {
    final backend = _CompactUsageBackend();
    // 容量 5000、输出预留 256:发送前不触硬挡,回复落库后越过软挡(60%)
    // 触发一次压缩摘要调用 —— 用量进 compact 第三桶。
    await seedCapacityModel(5000);
    await disablePresetItems();
    final container = makeContainer(backend, maxTokens: 256);
    addTearDown(container.dispose);

    // Seed long messages so post-turn occupancy crosses the soft gear (60%).
    final messages = MessageRepository(db);
    for (var i = 0; i < 22; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 's' * 450);
    }

    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );
    await controller.send('hi');
    await awaitBackground(container);

    final state = container.read(chatControllerProvider);
    // 压缩摘要调用的用量进第三桶,与主写/后台互不混淆。
    expect(state.compactInputTokens, 120);
    expect(state.compactOutputTokens, 15);
    expect(state.compactCachedInputTokens, 80);
    expect(state.inputTokens, 0);
    expect(state.backgroundInputTokens, 0);
    // 已持久化:重开会话仍能恢复(随 sessions 表落库)。
    final persisted = await SessionRepository(db).get(sessionId);
    expect(persisted!.compactInputTokens, 120);
    expect(persisted.compactOutputTokens, 15);
    expect(persisted.compactCachedInputTokens, 80);
  });

  test('rapid streaming deltas are throttled and cleanly flushed on completion', () async {
    final backend = _FakeBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(
      sessionId: sessionId,
      character: const CharacterCard(name: 'Alice'),
    );

    final sendFuture = controller.send('hi');

    // 先等 send 走完发送前组装、真正挂上流订阅(state.streaming 置位紧贴
    // `.listen`)再发首块。旧写法发完首块只等固定 5ms 就断言 —— 首块可见性
    // 因此与真实异步 DB 组装耗时赛跑,慢机/高载下首块尚在缓冲区即误报失败
    // (与节流逻辑本身无关的环境脆弱点);缓冲流语义下先等订阅再发是等价且
    // 确定的时序。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!container.read(chatControllerProvider).streaming && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(container.read(chatControllerProvider).streaming, isTrue, reason: 'send 应已进入流式订阅阶段');

    // 发出第一块:立即可见(距上次 flush 远超节流窗口 → 不经定时器直接刷)
    backend.emit(const TextDelta('Hello'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(container.read(chatDraftProvider), 'Hello');

    // 极高频发出后续块(模拟 SSE 快速推送)
    backend.emit(const TextDelta(', '));
    backend.emit(const TextDelta('World'));
    backend.emit(const TextDelta('!'));

    // 节流时间内可能尚未立即触发 state 刷帧,但流结束时必须完整 flush
    backend.emit(const DoneEvent());
    backend.close();
    await sendFuture;

    final messages = await MessageRepository(db).bySession(sessionId);
    expect(messages.last.content, 'Hello, World!');
  });

  test('activeWindow assembles the same snapshot as the full transcript (DV)', () async {
    // 组装窗口 = 全部 system 行 + 全部未折叠活跃行,与全量喂入逐字节一致 ——
    // 组装不再按条数裁剪,窗口只需覆盖活跃行;显示窗口
    // (300 条)与组装窗口是两个独立口径,前者不再影响后者。
    final characters = CharacterRepository(db);
    final sessions = SessionRepository(db);
    final charId = await characters.insert(const CharacterCard(name: 'Alice'));
    final sid = await sessions.create(charId, 'window-equivalence');
    final repo = MessageRepository(db);
    for (var i = 0; i < 350; i++) {
      if (i == 40) {
        await repo.append(sessionId: sid, role: 'system', content: '第 40 行附近的压缩摘要,必须进上下文。');
        continue;
      }
      await repo.append(sessionId: sid, role: i.isEven ? 'user' : 'assistant', content: '历史消息 $i:${'正文内容。' * 8}');
    }
    // 头部 20 条折叠:显示口径仍要能看到它们,组装口径必须排除它们。
    await db.db.update('messages', {'is_compacted': 1},
        where: 'session_id = ? AND seq < 20', whereArgs: [sid]);
    // 尾部附件行 + 最终用户输入:附件必须与其所属用户消息同窗。
    await repo.append(sessionId: sid, role: 'user', content: '世界书触发的附件内容', kind: MessageKind.attachment, refId: 'wb:9');
    await repo.append(sessionId: sid, role: 'user', content: '再次触发的附件内容', kind: MessageKind.attachment, refId: 'wb:10');
    await repo.append(sessionId: sid, role: 'user', content: '最后一条用户输入');

    final container = makeContainer(_FakeBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sid, character: const CharacterCard(name: 'Alice'));

    final st = container.read(chatControllerProvider);
    expect(st.canLoadOlder, isTrue, reason: '353 行超过 300 条显示窗口,应可向上分页');
    expect(st.messages.length, lessThan(353), reason: '显示窗口仍是窗口化的');

    final window = await repo.activeWindow(sid);
    final full = await repo.bySession(sid);
    expect(window.length, lessThan(full.length),
        reason: '测试前提:组装窗口应小于全量(折叠行不在窗)');

    final assembler = ContextAssembler();
    final character = const CharacterCard(name: 'Alice');
    final fromWindow = assembler.assemble(
      character: character,
      items: const [],
      history: window,
      worldbook: const [],
    );
    final fromFull = assembler.assemble(
      character: character,
      items: const [],
      history: full,
      worldbook: const [],
    );
    expect(fromWindow.systemPrompt, fromFull.systemPrompt,
        reason: 'system 段(含记忆/摘要拼装)不得因窗口化改变');
    expect(fromWindow.messages.map((m) => '${m.role}:${m.content}').toList(),
        fromFull.messages.map((m) => '${m.role}:${m.content}').toList(),
        reason: '进 LLM 的历史数组必须与全量喂入完全一致');

    // 摘要行远老于尾部,也必须在窗;附件行与末条用户输入同在。
    expect(window.where((m) => m.role == 'system').map((m) => m.content),
        contains('第 40 行附近的压缩摘要,必须进上下文。'));
    expect(window.where((m) => !m.isChat).length, 2);
    expect(window.last.content, '最后一条用户输入');
  });

  test('loadOlder pages in older history and exhausts (DV)', () async {
    final characters = CharacterRepository(db);
    final sessions = SessionRepository(db);
    final charId = await characters.insert(const CharacterCard(name: 'Alice'));
    final sid = await sessions.create(charId, 'window-pages');
    final repo = MessageRepository(db);
    for (var i = 0; i < 500; i++) {
      await repo.append(sessionId: sid, role: i.isEven ? 'user' : 'assistant', content: '页历史 $i');
    }

    final container = makeContainer(_FakeBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sid, character: const CharacterCard(name: 'Alice'));

    var st = container.read(chatControllerProvider);
    expect(st.canLoadOlder, isTrue);
    expect(st.messages.length, 300, reason: '首窗只取显示尾部 300 条');
    expect(st.messages.first.content, '页历史 200');
    expect(st.messages.last.content, '页历史 499');

    // 第一页(120 条):seq 80..199 前拼,时间序保持,仍可继续翻。
    await controller.loadOlder();
    st = container.read(chatControllerProvider);
    expect(st.messages.length, 420);
    expect(st.messages.first.content, '页历史 80');
    expect(st.canLoadOlder, isTrue);

    // 第二页取尽剩余 80 条(< 一页)并收口;再触发为空转。
    await controller.loadOlder();
    st = container.read(chatControllerProvider);
    expect(st.messages.length, 500);
    expect(st.messages.first.content, '页历史 0');
    expect(st.canLoadOlder, isFalse);
    final full = await repo.bySession(sid);
    expect(st.messages.map((m) => m.seq).toList(), full.map((m) => m.seq).toList(),
        reason: '翻页合并后的全列表必须与全量读取逐条一致');
    await controller.loadOlder();
    expect(container.read(chatControllerProvider).messages.length, 500);
  });

  test('content-flag failure offers a fallback model and one-tap switch reroutes (P1)', () async {
    // 当前 provider 目录有两个模型:主写选中 model-a 失败(风控类错误)→
    // 建议切到第一个其它模型;一键切换后 active/运行时配置都落到新模型。
    final repo = LlmProviderRepository(db);
    await repo.saveProvider(LlmProviderConfig(
      id: 0,
      providerId: 'prov-a',
      displayName: 'Prov A',
      baseUrl: 'https://api.example.com',
      protocol: LlmProtocol.openaiCompat,
      apiKey: 'k',
      isActive: true,
      models: [
        // 主写当前模型(makeContainer override 固定为 gpt-4o)即 model-a 行。
        LlmModelEntry(
          id: 0, providerId: 0, modelId: 'gpt-4o', displayName: 'Model A',
          contextCapacity: 128000, isActive: true,
        ),
        LlmModelEntry(
          id: 0, providerId: 0, modelId: 'model-b', displayName: 'Model B',
          contextCapacity: 128000,
        ),
      ],
    ));

    final backend = _ClassifiedErrorBackend('提示词已被标记,请修改后重试', UpstreamErrorKind.contentFlag);
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await controller.send('hi');

    final state = container.read(chatControllerProvider);
    expect(state.error, contains('提示词已被标记'));
    expect(state.fallbackModelHint, 'Model B');

    await controller.switchToFallbackModel();

    final switched = container.read(chatControllerProvider);
    expect(switched.error, isNull);
    expect(switched.fallbackModelHint, isNull);
    final provider = (await repo.all()).single;
    expect(provider.models.firstWhere((m) => m.modelId == 'model-b').isActive, isTrue);
    expect(provider.models.firstWhere((m) => m.modelId == 'gpt-4o').isActive, isFalse);
    expect(container.read(backendConfigProvider)!.model, 'model-b');
  });

  test('auth/transient failures do not offer a fallback model (P1)', () async {
    final repo = LlmProviderRepository(db);
    await repo.saveProvider(LlmProviderConfig(
      id: 0,
      providerId: 'prov-a',
      displayName: 'Prov A',
      baseUrl: 'https://api.example.com',
      protocol: LlmProtocol.openaiCompat,
      apiKey: 'k',
      isActive: true,
      models: [
        LlmModelEntry(
          id: 0, providerId: 0, modelId: 'model-a', displayName: 'Model A',
          contextCapacity: 128000, isActive: true,
        ),
        LlmModelEntry(
          id: 0, providerId: 0, modelId: 'model-b', displayName: 'Model B',
          contextCapacity: 128000,
        ),
      ],
    ));

    final backend = _ClassifiedErrorBackend('API key not valid', UpstreamErrorKind.auth);
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await controller.send('hi');

    final state = container.read(chatControllerProvider);
    expect(state.error, isNotNull);
    expect(state.fallbackModelHint, isNull); // 鉴权失败换模型无意义,不提供建议
  });

  test('启用的 COT 条目原样进入请求 system(组装不做任何剔除)', () async {
    // COT 已不再是默认种子;手动种入一条启用的带标签条目,验证整个条目原样
    // 进请求(2.0 起不再有请求级排除 —— 组装只认启用状态)。
    await db.db.insert('prompt_items', {
      'kind': 'preset',
      'name': 'COT',
      'text': '<cot_protocol>输出正文前先在内部完成静默演练,绝不写入回复。</cot_protocol>',
      'enabled': 1,
      'position': 10,
    });

    final repo = LlmProviderRepository(db);
    await repo.saveProvider(LlmProviderConfig(
      id: 0,
      providerId: 'prov-a',
      displayName: 'Prov A',
      baseUrl: 'https://api.example.com',
      protocol: LlmProtocol.openaiCompat,
      apiKey: 'k',
      isActive: true,
      models: [
        LlmModelEntry(
          id: 0, providerId: 0, modelId: 'gpt-4o', displayName: 'Model A',
          contextCapacity: 128000, isActive: true,
        ),
      ],
    ));

    final backend = _RecordingBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    await controller.send('hi');
    expect(backend.requests.single.systemPrompt, contains('<cot_protocol>'));
  });

  test('连续 3 轮 contractViolation 触发契约漂移预警,成功后复位(P2)', () async {
    final backend = _DriftSequenceBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));

    await controller.send('hi'); // 第 1 轮:未达阈值,只有原文
    var state = container.read(chatControllerProvider);
    expect(state.error, contains('bad SSE payload'));
    expect(state.contractDriftWarning, isFalse);

    await controller.send('hi'); // 第 2 轮:仍未达阈值
    state = container.read(chatControllerProvider);
    expect(state.contractDriftWarning, isFalse);

    await controller.send('hi'); // 第 3 轮:触发预警,错误原文保留在导语之后
    state = container.read(chatControllerProvider);
    expect(state.error, contains('契约漂移预警'));
    expect(state.error, contains('上游协议疑似变更'));
    expect(state.error, contains('bad SSE payload'));
    expect(state.contractDriftWarning, isTrue);

    await controller.send('hi'); // 第 4 轮成功:错误与预警一并复位
    state = container.read(chatControllerProvider);
    expect(state.error, isNull);
    expect(state.contractDriftWarning, isFalse);

    await controller.send('hi'); // 第 5 轮失败:计数已归零,只显示原文不带导语
    state = container.read(chatControllerProvider);
    expect(state.error, contains('bad SSE payload'));
    expect(state.error, isNot(contains('疑似变更')));
    expect(state.contractDriftWarning, isFalse);
  });
}
