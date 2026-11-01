import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
import '../models/token_usage.dart';
import 'backend_config.dart';
import 'llm_backend.dart';
import 'sse_parser.dart';
import 'stream_timeout.dart';
import 'upstream_error.dart';

class AnthropicBackend implements LlmBackend {
  final BackendConfig config;

  /// 测试注入的 client(生产为 null,每次请求独享新建)。
  final http.Client? providedClient;

  /// 连接(到响应头)/流空闲超时护栏,测试可注入短时限;见 [stream_timeout]。
  final Duration connectTimeout;
  final Duration idleTimeout;
  AnthropicBackend({
    required this.config,
    http.Client? client,
    this.connectTimeout = kLlmConnectTimeout,
    this.idleTimeout = kLlmIdleTimeout,
  }) : providedClient = client;

  @override
  String get id => 'anthropic';

  /// 推理等级 → Anthropic thinking budget_tokens 映射。
  static const _thinkingBudgets = {
    ReasoningLevel.low: 5000,
    ReasoningLevel.medium: 10000,
    ReasoningLevel.high: 30000,
  };

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    // 每次请求独享一个 http.Client(注入的除外):消费方取消订阅时 close 断链,
    // 服务端立刻停止生成;独享也隔离主写/后台并发共用实例时的误伤。详见
    // OpenAI 后端同款注释。
    final owned = providedClient == null ? http.Client() : null;
    final client = owned ?? providedClient!;
    var cancelled = false;
    var producerDone = false;
    final controller = StreamController<LlmEvent>(
      onCancel: () {
        // 仅在请求尚未自然收尾时关闭:正常完成后的补位 cancel 不能把复用中的
        // 注入 client(测试多轮请求)标成 closed。
        cancelled = true;
        if (!producerDone) client.close();
      },
    );
    unawaited(() async {
      try {
        final uri = Uri.parse('${config.baseUrl}/v1/messages');
        final wireMessages = <Map<String, dynamic>>[
          for (final m in request.messages)
            {'role': m.wireRole, 'content': m.content},
        ];
        if (request.cacheContext &&
            request.cacheMessageBreakpoint &&
            wireMessages.isNotEmpty) {
          // 锚一个显式断点在 messages 末条上:把稳定前缀(system + 记忆第 0 条 +
          // 历史 + 附件)整体缓存。CW 批起可变内容只追加在数组尾部(新消息/新附件/
          // 一次性通知),断点前的字节跨轮一致,轮次间命中稳定区。后台请求只缓存
          // stableSystemPart(可变尾部不重复读),置 cacheMessageBreakpoint=false
          // 跳过此断点。
          // 注意 cache_control 是 **content block 级**字段(message 顶层没有该字段,
          // 放在 message 对象上会被服务端静默忽略,缓存段不会建立)—— 末条消息的
          // content 改发块数组,把断点放进 {type: text} 块内。content 支持字符串或
          // 块数组两种形态,此项只影响末条消息的线上格式。
          final last = wireMessages.removeLast();
          wireMessages.add({
            ...last,
            'content': [
              {
                'type': 'text',
                'text': last['content'],
                'cache_control': {'type': 'ephemeral'},
              },
            ],
          });
        }

        // 多断点 system 缓存:当提供了稳定/可变 system 分段时,
        // 将 system 字段拆为 content block 数组,在稳定块末尾放置 cache_control 断点。
        // 这样即使可变尾部被后台引擎改写,稳定前缀仍可命中缓存。
        // 若未提供分段(hook 改写了 system prompt,分段不可靠),回退到纯字符串格式。
        final system = _buildSystem(request);

        var maxTokens = request.maxTokens ?? 1024;
        final budget = _thinkingBudgets[request.reasoningLevel];
        final body = <String, dynamic>{
          'model': request.model,
          'system': system,
          'messages': wireMessages,
          'stream': true,
          'max_tokens': maxTokens,
        };
        if (budget == null) {
          // 推理等级 off:不发送 thinking 参数(避免非 reasoning 请求收到未知
          // 字段),采样参数正常携带。
          body['temperature'] = request.temperature;
        } else {
          // thinking 组合约束(API 硬性要求,缺一即 400):
          // ① max_tokens 必须 > budget_tokens,且 budget_tokens ≥ 1024;
          // ② 开启 thinking 时不得携带非 1 的 temperature(此处直接省略)。
          // budget 以用户的 max_tokens 上限为准收缩(输出预算的意图优先于
          // 推理深度);max_tokens 小到装不下最低档(≤2048)时抬高到最小
          // 可行值,而不是放弃 thinking。
          var b = budget;
          if (b >= maxTokens) {
            b = maxTokens - 1024;
            if (b < 1024) b = 1024;
            if (b >= maxTokens) {
              maxTokens = b + 1024;
              body['max_tokens'] = maxTokens;
            }
          }
          body['thinking'] = {'type': 'enabled', 'budget_tokens': b};
        }

        final req = http.Request('POST', uri)
          ..headers.addAll({
            // 键统一小写,与 extraHeaders 的归一化存储格式一致(与 OpenAI
            // 后端同款):provider 自定义头可覆盖内置默认。
            'x-api-key': config.apiKey,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
            ...config.extraHeaders,
          })
          ..body = jsonEncode(body);
        // 连接/响应头超时:超时即掐断底层连接,按可重试的后端错误上报
        //(与 OpenAI 后端同款护栏,见 stream_timeout.dart)。
        late final http.StreamedResponse response;
        try {
          response = await client.send(req).timeout(connectTimeout);
        } on TimeoutException {
          client.close();
          controller.add(ErrorEvent(
            'Anthropic 请求超时:服务器 ${connectTimeout.inSeconds}s 内未响应',
            kind: UpstreamErrorKind.transient,
          ));
          return;
        }
        if (cancelled) return;
        if (response.statusCode != 200) {
          final detail = await response.stream.bytesToString();
          final shape = extractUpstreamErrorShape(detail);
          final kind = classifyUpstreamFailure(statusCode: response.statusCode, errorType: shape.type, body: detail);
          controller.add(ErrorEvent(
            'Anthropic ${response.statusCode}: $detail',
            kind: kind,
            statusCode: response.statusCode,
          ));
          return;
        }
        // 流空闲护栏:SSE 停滞(半开连接/网关挂起)时以 TimeoutException 掐断
        // 底层订阅,`await for` 不再永久挂起。
        final lines = withIdleTimeout(
          response.stream.transform(utf8.decoder).transform(const LineSplitter()),
          idleTimeout,
        );
        var sawStop = false;
        var sawError = false;
        // 用量快照合并暂存:message_start 报 input(+初始 output)、message_delta 报
        // 最终 output —— 都是请求内累计快照;合并取最大、流结束时只发一次,上层
        // 按增量求和会把快照叠加虚高(OpenAI 兼容网关逐块附带 usage 时尤为失控)。
        TokenUsage? usageSnapshot;
        await for (final event in parseSse(lines)) {
          late final Map<String, dynamic> json;
          try {
            json = jsonDecode(event.data) as Map<String, dynamic>;
          } on FormatException {
            sawError = true;
            controller.add(ErrorEvent('bad SSE payload: ${event.data}', kind: UpstreamErrorKind.contractViolation));
            continue;
          }
          switch (json['type']) {
            case 'content_block_delta':
              final delta = json['delta'] as Map<String, dynamic>?;
              if (delta?['type'] == 'text_delta') {
                controller.add(TextDelta(delta!['text'] as String));
              }
            case 'message_delta':
              final usage = json['usage'];
              if (usage != null) {
                final snapshot = TokenUsage.fromAnthropic(usage as Map<String, dynamic>);
                usageSnapshot = usageSnapshot == null ? snapshot : usageSnapshot.mergeMax(snapshot);
              }
            case 'message_start':
              final usage = (json['message'] as Map<String, dynamic>?)?['usage'];
              if (usage != null) {
                final snapshot = TokenUsage.fromAnthropic(usage as Map<String, dynamic>);
                usageSnapshot = usageSnapshot == null ? snapshot : usageSnapshot.mergeMax(snapshot);
              }
            case 'message_stop':
              sawStop = true;
              controller.add(const DoneEvent());
            case 'error':
              // 流中途的错误事件(overloaded/rate-limit/invalid_request):显式转成
              // ErrorEvent,不再静默漏过 —— 否则缓冲区空/半截,上层把真实后端故障
              // 误判成"解析失败"。
              sawError = true;
              final err = json['error'];
              final message = err is Map && err['message'] != null ? err['message'] : err;
              final errorType = err is Map && err['type'] is String ? err['type'] as String : null;
              controller.add(ErrorEvent(
                'stream error: $message',
                kind: classifyUpstreamFailure(errorType: errorType, body: '$message'),
              ));
          }
        }
        // 流结束却没有 message_stop:连接被提前掐断(http 层静默完成、不抛错)。
        // 显式转成错误 —— 上层按可重试的后端故障处理并给出"连接中断"的诊断,
        // 而不是当成"模型未返回任何内容"的解析失败。
        if (!sawStop && !sawError) {
          controller.add(const ErrorEvent(
            'stream ended before message_stop (connection closed early)',
            kind: UpstreamErrorKind.transient,
          ));
        }
        // 用量只在流结束时发一次(合并后的最终快照),与 OpenAI 后端语义一致。
        if (usageSnapshot != null) controller.add(UsageEvent(usageSnapshot));
      } catch (e) {
        // 断链中止(取消后 socket 抛出的异常)一律吞掉;真实异常透传给监听者
        // (与旧 async* 实现的流级错误语义一致)。
        if (!cancelled) controller.addError(e);
      } finally {
        producerDone = true;
        owned?.close();
        if (!controller.isClosed) await controller.close();
      }
    }());
    return controller.stream;
  }

  /// 构建 Anthropic API 的 system 字段。
  ///
  /// - cacheContext 且有 stableSystemPart → 拆为两个 content block 数组,
  ///   稳定块带 cache_control 断点(多断点缓存);
  /// - 否则 → 纯字符串格式(向后兼容 / hook 改写后的回退路径)。
  dynamic _buildSystem(LlmRequest request) {
    final stable = request.stableSystemPart;
    if (request.cacheContext && stable != null && stable.isNotEmpty) {
      final blocks = <Map<String, dynamic>>[
        {'type': 'text', 'text': stable, 'cache_control': {'type': 'ephemeral'}},
      ];
      final variable = request.variableSystemPart;
      if (variable != null && variable.isNotEmpty) {
        blocks.add({'type': 'text', 'text': variable});
      }
      return blocks;
    }
    return request.systemPrompt;
  }
}
