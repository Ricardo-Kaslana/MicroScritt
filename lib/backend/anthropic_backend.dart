/// Anthropic Messages 协议的流式后端。
///
/// 负责 SSE 解析、system/末条消息的多断点提示缓存、thinking budget 映射
/// 与用量快照合并;每次请求独享连接,取消订阅即断链。
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/llm_tool.dart';
import '../models/token_usage.dart';
import '../models/backend_config.dart';
import 'llm_backend.dart';
import 'sse_parser.dart';
import 'stream_timeout.dart';
import 'upstream_error.dart';

/// Anthropic Messages 协议后端。
class AnthropicBackend implements LlmBackend {
  /// 本次后端使用的 provider/模型配置。
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

  /// 推理等级 → Anthropic thinking budget_tokens 映射;off 不在表中。
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
        // Anthropic Messages API 的 max_tokens 为必填项,不能像 OpenAI
        // 兼容端点那样省略。请求级值(如 hook 改写)优先,否则用模型配置
        // 的「最大输出 tokens」;两者皆空即配置不完整 —— 本地直接报错,
        // 不发请求、不猜测兜底值。
        final configuredMaxTokens = request.maxTokens ?? config.maxTokens;
        if (configuredMaxTokens == null) {
          controller.add(const ErrorEvent(
            'Anthropic 协议要求填写模型的最大输出 tokens:请在设置 → LLM Provider 的模型编辑中补全「最大输出 tokens」',
            kind: UpstreamErrorKind.configuration,
          ));
          return;
        }
        final uri = Uri.parse('${config.baseUrl}/v1/messages');
        final hasTools = request.tools.isNotEmpty;
        // 无工具请求维持扁平 {role, content:String} 序列化(主写路径字节不变);
        // 工具请求改块感知(tool_use/tool_result/thinking 回放),见 _wireMessagesWithTools。
        final wireMessages = hasTools
            ? _wireMessagesWithTools(request)
            : <Map<String, dynamic>>[
                for (final m in request.messages)
                  {'role': m.wireRole, 'content': m.content},
              ];
        if (request.cacheContext &&
            request.cacheMessageBreakpoint &&
            wireMessages.isNotEmpty) {
          // 锚一个显式断点在 messages 末条上:把稳定前缀(system + 记忆第 0 条 +
          // 历史 + 附件)整体缓存。可变内容只追加在数组尾部(新消息/新附件/
          // 一次性通知),断点前的字节跨轮一致,轮次间命中稳定区。后台请求只缓存
          // stableSystemPart(可变尾部不重复读),置 cacheMessageBreakpoint=false
          // 跳过此断点。
          // 注意 cache_control 是 **content block 级**字段(message 顶层没有该字段,
          // 放在 message 对象上会被服务端静默忽略,缓存段不会建立)—— 末条消息的
          // content 改发块数组,把断点放进末块内。content 支持字符串或块数组两种
          // 形态:字符串包成 {type: text} 块(主写路径,字节不变);已是块数组
          // (工具路径的 tool_result user 消息)则给末块补 cache_control。
          final last = wireMessages.removeLast();
          final content = last['content'];
          if (content is String) {
            wireMessages.add({
              ...last,
              'content': [
                {
                  'type': 'text',
                  'text': content,
                  'cache_control': {'type': 'ephemeral'},
                },
              ],
            });
          } else if (content is List && content.isNotEmpty) {
            final blocks = [for (final b in content) Map<String, dynamic>.from(b as Map)];
            blocks.last['cache_control'] = {'type': 'ephemeral'};
            wireMessages.add({...last, 'content': blocks});
          } else {
            wireMessages.add(last);
          }
        }

        // 多断点 system 缓存:当提供了稳定/可变 system 分段时,
        // 将 system 字段拆为 content block 数组,在稳定块末尾放置 cache_control 断点。
        // 这样即使可变尾部被后台引擎改写,稳定前缀仍可命中缓存。
        // 若未提供分段(hook 改写了 system prompt,分段不可靠),回退到纯字符串格式。
        final system = _buildSystem(request);

        var maxTokens = configuredMaxTokens;
        final budget = _thinkingBudgets[request.reasoningLevel];
        final body = <String, dynamic>{
          'model': request.model,
          'system': system,
          'messages': wireMessages,
          'stream': true,
          'max_tokens': maxTokens,
          // 原生工具:tools 非空才发送(普通端点不发,避免未知字段 400)。
          // tool_choice 默认 auto,无需显式携带。
          if (hasTools) 'tools': _toolsWire(request.tools),
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
        // 工具调用按 content block index 累计(input_json_delta 拼接 arguments);
        // thinking/redacted_thinking 块捕获后随 ToolCallsEvent.replayBlocks 带出,
        // 供下一轮原样回放(协议要求未改且原序,否则 400)。无工具请求这些 map
        // 恒空,主写路径行为不变。
        final toolCalls = <int, _ToolUseAccum>{};
        final thinkingBlocks = <int, Map<String, dynamic>>{};
        final replayBlocks = <Map<String, dynamic>>[];
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
            case 'content_block_start':
              final index = json['index'] is int ? json['index'] as int : 0;
              final cb = json['content_block'] as Map<String, dynamic>?;
              switch (cb?['type']) {
                case 'tool_use':
                  toolCalls[index] = _ToolUseAccum(
                    id: cb?['id'] as String? ?? '',
                    name: cb?['name'] as String? ?? '',
                  );
                case 'thinking':
                  thinkingBlocks[index] = {'type': 'thinking', 'thinking': '', 'signature': ''};
                case 'redacted_thinking':
                  replayBlocks.add({'type': 'redacted_thinking', 'data': cb?['data']});
              }
            case 'content_block_delta':
              final index = json['index'] is int ? json['index'] as int : 0;
              final delta = json['delta'] as Map<String, dynamic>?;
              switch (delta?['type']) {
                case 'text_delta':
                  controller.add(TextDelta(delta!['text'] as String));
                case 'input_json_delta':
                  toolCalls[index]?.args.write(delta!['partial_json'] as String? ?? '');
                case 'thinking_delta':
                  final b = thinkingBlocks[index];
                  if (b != null) b['thinking'] = '${b['thinking']}${delta!['thinking'] ?? ''}';
                case 'signature_delta':
                  final b = thinkingBlocks[index];
                  if (b != null) b['signature'] = '${b['signature']}${delta!['signature'] ?? ''}';
              }
            case 'content_block_stop':
              final index = json['index'] is int ? json['index'] as int : 0;
              final b = thinkingBlocks.remove(index);
              if (b != null) replayBlocks.add(b);
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
              // 工具调用即响应:按 index 序透出 ToolCallsEvent,并携带 thinking
              // 回放块。无工具调用(纯正文轮)不发此事件,主写路径不变。
              if (toolCalls.isNotEmpty) {
                final indices = toolCalls.keys.toList()..sort();
                controller.add(ToolCallsEvent(
                  [
                    for (final i in indices)
                      ToolCall(
                        id: toolCalls[i]!.id,
                        name: toolCalls[i]!.name,
                        arguments: toolCalls[i]!.args.toString(),
                      ),
                  ],
                  replayBlocks: replayBlocks,
                ));
              }
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

  /// 工具请求的块感知序列化:assistant 轮 = [opaque 回放块(thinking),正文文本?,
  /// tool_use...];连续的 user/tool 消息合并为单条 user 消息 —— tool_result 块
  /// 必须紧跟 assistant tool_use,软提醒文本块与 tool_result 共存于同一 user
  /// 消息(角色交替约束)。无工具请求不走此路径(主写扁平序列化字节不变)。
  static List<Map<String, dynamic>> _wireMessagesWithTools(LlmRequest request) {
    final out = <Map<String, dynamic>>[];
    var userBlocks = <Map<String, dynamic>>[];
    void flushUser() {
      if (userBlocks.isNotEmpty) {
        out.add({'role': 'user', 'content': userBlocks});
        userBlocks = [];
      }
    }

    for (final m in request.messages) {
      if (m.role == ChatRole.assistant) {
        flushUser();
        final blocks = <Map<String, dynamic>>[];
        if (m.opaqueBlocks != null) blocks.addAll(m.opaqueBlocks!);
        if (m.content.isNotEmpty) blocks.add({'type': 'text', 'text': m.content});
        for (final c in m.toolCalls ?? const <ToolCall>[]) {
          blocks.add({
            'type': 'tool_use',
            'id': c.id,
            'name': c.name,
            'input': _decodeArgs(c.arguments),
          });
        }
        out.add({'role': 'assistant', 'content': blocks});
      } else if (m.role == ChatRole.tool) {
        userBlocks.add({
          'type': 'tool_result',
          'tool_use_id': m.toolCallId ?? '',
          'content': m.content,
        });
      } else {
        userBlocks.add({'type': 'text', 'text': m.content});
      }
    }
    flushUser();
    return out;
  }

  /// 工具定义 → Anthropic `tools` 数组(`input_schema` 形态)。
  static List<Map<String, dynamic>> _toolsWire(List<LlmTool> tools) => [
    for (final t in tools)
      {'name': t.name, 'description': t.description, 'input_schema': t.parameters},
  ];

  /// `tool_use.input` 必须是对象:解码 arguments JSON,残缺/非对象回退空对象。
  static Map<String, dynamic> _decodeArgs(String arguments) {
    try {
      final decoded = jsonDecode(arguments);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // 残缺参数:回退空对象,交由协议/消费方裁决。
    }
    return {};
  }
}

/// Anthropic `tool_use` 块的流内累计器:`input_json_delta` 拼接 arguments。
class _ToolUseAccum {
  final String id;
  final String name;
  final StringBuffer args = StringBuffer();
  _ToolUseAccum({required this.id, required this.name});
}
