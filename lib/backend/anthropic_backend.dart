/// Anthropic Messages 协议的流式后端。
///
/// 负责 SSE 解析、system/末条消息的多断点提示缓存、按模型代际映射 thinking
/// (旧模型 budget_tokens / 新模型 adaptive + output_config.effort)与用量快照
/// 合并;每次请求独享连接,取消订阅即断链。
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/llm_tool.dart';
import '../models/token_usage.dart';
import '../models/backend_config.dart';
import 'anthropic_model_capabilities.dart';
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

  /// 旧式 thinking 的 budget_tokens 映射;off 与 adaptive 模型不走此表。
  static const _thinkingBudgets = {
    ReasoningLevel.minimal: 2048,
    ReasoningLevel.low: 5000,
    ReasoningLevel.medium: 10000,
    ReasoningLevel.high: 30000,
    ReasoningLevel.xhigh: 50000,
    ReasoningLevel.max: 100000,
  };

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    // 每次请求独享一个 http.Client(注入的除外):消费方取消订阅时 close 断链,
    // 服务端立刻停止生成;独享也隔离主写/后台并发共用实例时的误伤。详见
    // OpenAI 后端同款注释。自建 client 覆盖整次 generate;注入 client 归调用方
    // 所有,超时分支不关闭(否则调用方无可复用实例)。
    final ownsClient = providedClient == null;
    final client = providedClient ?? http.Client();
    var clientClosed = false;
    void closeClient() {
      if (clientClosed) return;
      clientClosed = true;
      client.close();
    }

    var cancelled = false;
    var producerDone = false;
    final controller = StreamController<LlmEvent>(
      onCancel: () {
        // 仅在请求尚未自然收尾时关闭:正常完成后的补位 cancel 不能把复用中的
        // 注入 client(测试多轮请求)标成 closed。
        cancelled = true;
        if (!producerDone) closeClient();
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
          controller.add(
            const ErrorEvent(
              'Anthropic 协议要求填写模型的最大输出 tokens:请在设置 → LLM Provider 的模型编辑中补全「最大输出 tokens」',
              kind: UpstreamErrorKind.configuration,
            ),
          );
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
            final blocks = [
              for (final b in content) Map<String, dynamic>.from(b as Map),
            ];
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
        final reasoning = request.reasoningLevel;
        final capabilities = resolveAnthropicModelCapabilities(request.model);
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
        if (capabilities.isAdaptive) {
          if (reasoning == ReasoningLevel.off) {
            switch (capabilities.offMode) {
              case AnthropicOffMode.disabled:
                body['thinking'] = {'type': 'disabled'};
                body['temperature'] = request.temperature;
                break;
              case AnthropicOffMode.betweenTools:
                // Sonnet 5.5 拒绝 disabled;between_tools 是它的最低思考档。
                body['thinking'] = {'type': 'between_tools'};
                break;
              case AnthropicOffMode.omit:
                // Opus 5.5 / Fable / Mythos 无法关闭思考:省略 thinking 避免
                // 400;默认 adaptive 仍可能思考,同时保守省略 temperature。
                break;
            }
          } else {
            body['thinking'] = {'type': 'adaptive'};
            body['output_config'] = {'effort': adaptiveEffortOf(reasoning)!};
            // adaptive thinking 仍在约束采样参数,与旧式 enabled 一样省略
            // temperature(非 1 的取值会 400)。
          }
        } else {
          final budget = _thinkingBudgets[reasoning];
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
        //(与 OpenAI 后端同款护栏,见 stream_timeout.dart)。自建 client 关闭;
        // 注入 client 不关,交给调用方(探测/测试自会收尾)。
        late final http.StreamedResponse response;
        try {
          response = await client.send(req).timeout(connectTimeout);
        } on TimeoutException {
          if (ownsClient) closeClient();
          controller.add(
            ErrorEvent(
              'Anthropic 请求超时:服务器 ${connectTimeout.inSeconds}s 内未响应',
              kind: UpstreamErrorKind.transient,
            ),
          );
          return;
        }
        if (cancelled) return;
        if (response.statusCode != 200) {
          // 错误体只用于诊断:空闲超时 + 字节上限,读不动按状态码分类。
          final detail = await _readErrorBody(response.stream);
          final shape = extractUpstreamErrorShape(detail);
          final kind = classifyUpstreamFailure(
            statusCode: response.statusCode,
            errorType: shape.type,
            body: detail,
          );
          controller.add(
            ErrorEvent(
              'Anthropic ${response.statusCode}: '
              '${redactSecrets(detail, apiKey: config.apiKey)}',
              kind: kind,
              statusCode: response.statusCode,
            ),
          );
          return;
        }
        // 流空闲护栏:SSE 停滞(半开连接/网关挂起)时以 TimeoutException 掐断
        // 底层订阅,`await for` 不再永久挂起。
        final lines = withIdleTimeout(
          response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
          idleTimeout,
        );
        var sawStop = false;
        var sawError = false;
        var sawContent = false;
        var sawThinking = false;
        // 用量快照合并暂存:message_start 报 input(+初始 output)、message_delta 报
        // 最终 output —— 都是请求内累计快照;合并取最大、流结束时只发一次,上层
        // 按增量求和会把快照叠加虚高(OpenAI 兼容网关逐块附带 usage 时尤为失控)。
        TokenUsage? usageSnapshot;
        // 工具调用按 content block index 累计(input_json_delta 拼接 arguments);
        // thinking/redacted_thinking 块按 index 暂存,message_stop 时按 index
        // 排序生成 replayBlocks —— 回放必须保持原块序,否则下一轮 400。
        // 无工具请求这些 map 恒空,主写路径行为不变。
        final toolCalls = <int, _ToolUseAccum>{};
        final thinkingBlocks = <int, Map<String, dynamic>>{};
        // 终局错误暂存:UsageEvent 必须先于 ErrorEvent 透出,否则上层在错误
        // 落定时拿不到已计量用量(失败结果用量归零)。
        final pendingErrors = <ErrorEvent>[];
        // 标签用于从 switch 内直接退出整条流读取(裸 break 只会退出 switch)。
        streamLoop:
        await for (final event in parseSse(lines)) {
          final json = decodeSseJsonObject(event.data);
          if (json == null) {
            sawError = true;
            pendingErrors.add(
              ErrorEvent(
                'bad SSE payload: '
                '${redactSecrets(event.data, apiKey: config.apiKey)}',
                kind: UpstreamErrorKind.contractViolation,
              ),
            );
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
                    // 部分网关在 start 块里直接给完整 input、不再发
                    // input_json_delta:留作没有增量时的 fallback 参数。
                    initialInput: cb?['input'],
                  );
                case 'thinking':
                  sawThinking = true;
                  thinkingBlocks[index] = {
                    'type': 'thinking',
                    'thinking': '',
                    'signature': '',
                  };
                case 'redacted_thinking':
                  sawThinking = true;
                  // 按 index 统一暂存,不能按到达顺序直接追加:redacted 块可能与
                  // thinking 块交错,回放顺序错乱会让下一轮 400。
                  thinkingBlocks[index] = {
                    'type': 'redacted_thinking',
                    'data': cb?['data'],
                  };
              }
            case 'content_block_delta':
              final index = json['index'] is int ? json['index'] as int : 0;
              final delta = json['delta'] as Map<String, dynamic>?;
              switch (delta?['type']) {
                case 'text_delta':
                  final text = delta!['text'] as String?;
                  if (text != null && text.isNotEmpty) {
                    sawContent = true;
                    controller.add(TextDelta(text));
                  }
                case 'input_json_delta':
                  toolCalls[index]?.args.write(
                    delta!['partial_json'] as String? ?? '',
                  );
                case 'thinking_delta':
                  sawThinking = true;
                  final b = thinkingBlocks[index];
                  if (b != null) {
                    b['thinking'] =
                        '${b['thinking']}${delta!['thinking'] ?? ''}';
                  }
                case 'signature_delta':
                  final b = thinkingBlocks[index];
                  if (b != null) {
                    b['signature'] =
                        '${b['signature']}${delta!['signature'] ?? ''}';
                  }
              }
            case 'content_block_stop':
              // thinking 块不在此处出队:message_stop 统一按 index 排序。
              break;
            case 'message_delta':
              final usage = json['usage'];
              if (usage != null) {
                final snapshot = TokenUsage.fromAnthropic(
                  usage as Map<String, dynamic>,
                );
                usageSnapshot = usageSnapshot == null
                    ? snapshot
                    : usageSnapshot.mergeMax(snapshot);
              }
            case 'message_start':
              final usage =
                  (json['message'] as Map<String, dynamic>?)?['usage'];
              if (usage != null) {
                final snapshot = TokenUsage.fromAnthropic(
                  usage as Map<String, dynamic>,
                );
                usageSnapshot = usageSnapshot == null
                    ? snapshot
                    : usageSnapshot.mergeMax(snapshot);
              }
            case 'message_stop':
              sawStop = true;
              final replayBlocks = _sortedThinkingBlocks(thinkingBlocks);
              final collected = _collectToolCalls(toolCalls);
              if (collected.dropped > 0 && collected.calls.isEmpty) {
                // 空 name 既不能执行也不能回放(上游 400):显式判协议错误。
                sawError = true;
                pendingErrors.add(
                  const ErrorEvent(
                    '上游返回了缺少函数名的工具调用,已丢弃',
                    kind: UpstreamErrorKind.contractViolation,
                  ),
                );
              }
              // 工具调用即响应:按 index 序透出 ToolCallsEvent,并携带 thinking
              // 回放块。无工具调用(纯正文轮)不发此事件,主写路径不变。
              if (collected.calls.isNotEmpty) {
                controller.add(
                  ToolCallsEvent(collected.calls, replayBlocks: replayBlocks),
                );
              }
              // 正常收尾但正文/推理/工具调用全空:静默成功只会落一条空回复,
              // 用户与后台都无从归因。thinking 或工具调用在场则是合法响应。
              if (!sawError &&
                  !sawContent &&
                  !sawThinking &&
                  collected.calls.isEmpty) {
                sawError = true;
                pendingErrors.add(
                  const ErrorEvent(
                    '模型正常收尾但未返回任何内容(正文/推理/工具调用均为空)',
                    kind: UpstreamErrorKind.contentFlag,
                  ),
                );
              }
              controller.add(const DoneEvent());
              // 终局帧即请求结束:主动退出读取并取消底层订阅,不再等网关
              // 关流(keep-alive 网关会空挂到空闲超时,连带 Done/Usage 丢失)。
              break streamLoop;
            case 'error':
              // 流中途的错误事件(overloaded/rate-limit/invalid_request):显式转成
              // ErrorEvent,不再静默漏过 —— 否则缓冲区空/半截,上层把真实后端故障
              // 误判成"解析失败"。错误是终局帧:暂存后立即退出读取。
              sawError = true;
              final err = json['error'];
              final message = err is Map && err['message'] != null
                  ? err['message']
                  : err;
              final errorType = err is Map && err['type'] is String
                  ? err['type'] as String
                  : null;
              pendingErrors.add(
                ErrorEvent(
                  'stream error: '
                  '${redactSecrets('$message', apiKey: config.apiKey)}',
                  kind: classifyUpstreamFailure(
                    errorType: errorType,
                    body: '$message',
                  ),
                ),
              );
              break streamLoop;
          }
        }
        // 流结束却没有 message_stop:连接被提前掐断(http 层静默完成、不抛错)。
        // 显式转成错误 —— 上层按可重试的后端故障处理并给出"连接中断"的诊断,
        // 而不是当成"模型未返回任何内容"的解析失败。
        if (!sawStop && !sawError) {
          pendingErrors.add(
            const ErrorEvent(
              'stream ended before message_stop (connection closed early)',
              kind: UpstreamErrorKind.transient,
            ),
          );
        }
        // 用量只在流结束时发一次(合并后的最终快照),且必须先于错误事件:
        // 上层在 ErrorEvent 到达时即落定失败结果,用量后到会被丢弃。
        if (usageSnapshot != null) controller.add(UsageEvent(usageSnapshot));
        for (final error in pendingErrors) {
          controller.add(error);
        }
      } catch (e) {
        // 断链中止(取消后 socket 抛出的异常)一律吞掉;真实异常透传给监听者
        // (与旧 async* 实现的流级错误语义一致)。
        if (!cancelled) controller.addError(e);
      } finally {
        producerDone = true;
        if (ownsClient) closeClient();
        if (!controller.isClosed) await controller.close();
      }
    }());
    return controller.stream;
  }

  /// 非 2xx 错误体读取:空闲超时 + 64KiB 上限;读不动时退回占位文本,
  /// 分类仍按状态码进行,绝不因错误体让请求挂起。
  Future<String> _readErrorBody(http.ByteStream stream) async {
    try {
      return await readUpstreamErrorBody(stream, idleTimeout);
    } on Exception {
      return '(无法读取上游错误信息)';
    }
  }

  /// thinking/redacted_thinking 块按 content block index 排序:回放必须保持
  /// 原始块序(协议要求未改且原序),map 的插入序会受网关发送顺序影响。
  static List<Map<String, dynamic>> _sortedThinkingBlocks(
    Map<int, Map<String, dynamic>> blocks,
  ) {
    final indices = blocks.keys.toList()..sort();
    return [for (final i in indices) blocks[i]!];
  }

  /// 工具调用槽 → 按 index 序的 [ToolCall] 列表。
  ///
  /// 缺失 id 合成 `call_<index>`:assistant 回放与 tool_result 必须引用同一
  /// id,留空会让下一轮上游 400。空 name 的调用不进入列表(返回 dropped 计数,
  /// 由调用方判协议错误),否则无法执行、也无法原样回放。
  static ({List<ToolCall> calls, int dropped}) _collectToolCalls(
    Map<int, _ToolUseAccum> accum,
  ) {
    final indices = accum.keys.toList()..sort();
    final calls = <ToolCall>[];
    var dropped = 0;
    for (final i in indices) {
      final a = accum[i]!;
      if (a.name.isEmpty) {
        dropped++;
        continue;
      }
      // 没有 input_json_delta 时用 start 块里的完整 input 作为参数。
      final args = a.args.isEmpty && a.initialInput is Map
          ? jsonEncode(a.initialInput)
          : a.args.toString();
      calls.add(
        ToolCall(
          id: a.id.isEmpty ? 'call_$i' : a.id,
          name: a.name,
          arguments: args,
        ),
      );
    }
    return (calls: calls, dropped: dropped);
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
        {
          'type': 'text',
          'text': stable,
          'cache_control': {'type': 'ephemeral'},
        },
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
        if (m.content.isNotEmpty) {
          blocks.add({'type': 'text', 'text': m.content});
        }
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
      {
        'name': t.name,
        'description': t.description,
        'input_schema': t.parameters,
      },
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

/// Anthropic `tool_use` 块的流内累计器:`input_json_delta` 拼接 arguments;
/// [initialInput] 是 start 块自带的完整参数(没有增量时的 fallback)。
class _ToolUseAccum {
  final String id;
  final String name;
  final Object? initialInput;
  final StringBuffer args = StringBuffer();
  _ToolUseAccum({required this.id, required this.name, this.initialInput});
}
