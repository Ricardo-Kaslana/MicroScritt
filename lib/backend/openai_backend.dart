/// OpenAI 兼容 `chat/completions` 的流式后端。
///
/// 负责 SSE 解析、用量快照合并与上游故障分类;每次请求独享连接,
/// 取消订阅即断链。
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

/// 403 响应追加的排查指引:不少兼容网关在网关层按请求头放行(校验
/// Origin/Referer/User-Agent 等,拒绝时只回一个裸 403,正文往往是含糊的
/// "无可用渠道"之类),不提示的话用户无从把状态码与「缺请求头」关联起来。
const String kForbiddenHeaderHint =
    ' —— 部分站点要求特定请求头(如 Origin / Referer / User-Agent)才放行,'
    '可在 Provider 编辑页「自定义请求头」中补充后重试';

/// 一轮请求的结局:驱动层据此决定重试/透出错误。
class _RoundOutcome {
  /// 该轮用量终值(轮内多块累计快照已 mergeMax)。
  final TokenUsage? usage;

  /// 待透出的错误。仅 transient 家族(连接超时/5xx/提前断)会挂在这里等待
  /// 驱动层重试决策 —— 可重试且零正文时该错误被丢弃,不透出;其余错误在
  /// 轮内就地发出,不进此字段。
  final ErrorEvent? failure;

  /// [failure] 属于零正文可透明重试的瞬态失败。
  final bool retryableTransient;

  const _RoundOutcome({
    this.usage,
    this.failure,
    this.retryableTransient = false,
  });
}

/// 工具调用轮的流内累计器:按 tool_calls[].index 拼接 id / name /
/// arguments(与网关的工具流式拼接语义一致)。
class _ToolCallAccum {
  String? id;
  String? name;
  String arguments = '';
}

/// OpenAI 兼容协议后端。
class OpenAiBackend implements LlmBackend {
  /// 本次后端使用的 provider/模型配置。
  final BackendConfig config;

  /// 测试注入的 client(生产为 null,每次请求独享新建)。
  final http.Client? providedClient;

  /// 连接(到响应头)/流空闲超时护栏,测试可注入短时限;见 [stream_timeout]。
  final Duration connectTimeout;
  final Duration idleTimeout;
  OpenAiBackend({
    required this.config,
    http.Client? client,
    this.connectTimeout = kLlmConnectTimeout,
    this.idleTimeout = kLlmIdleTimeout,
  }) : providedClient = client;

  @override
  String get id => 'openai';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    // 每次请求独享一个 http.Client(注入的除外):消费方取消订阅时 close 断链,
    // 服务端立刻停止生成 —— 否则"打断"只是 UI 层收敛,请求在服务端跑到自然
    // 结束,白烧推理 token。独享还隔离了主写/后台并发共用同一实例时的误伤
    // (取消一方不再掐断另一方的连接)。
    final owned = providedClient == null ? http.Client() : null;
    final client = owned ?? providedClient!;
    var cancelled = false;
    var producerDone = false;
    final controller = StreamController<LlmEvent>(
      onCancel: () {
        // 消费方取消:断链中止。仅在请求尚未自然收尾时关闭 —— 正常完成后的
        // 补位 cancel(chat_controller 的 unawaited(sub.cancel()))不能把
        // 复用中的注入 client(测试多轮请求)标成 closed。
        cancelled = true;
        if (!producerDone) client.close();
      },
    );
    unawaited(() async {
      try {
        final uri = Uri.parse('${config.baseUrl}/chat/completions');
        final hasTools = request.tools.isNotEmpty;
        final baseBody = {
          'model': request.model,
          'messages': _wireMessages(request),
          'stream': true,
          'temperature': request.temperature,
          // 官方 OpenAI 参数风格(v47):推理模型(o 系列 / GPT-5 等)只认
          // max_completion_tokens,发 max_tokens 直接 400;兼容网关普遍两认。
          if (request.maxTokens != null)
            config.modernParams ? 'max_completion_tokens' : 'max_tokens': request.maxTokens,
          // 官方端点流式默认不带 usage,不开此开关用量统计恒为零;部分劣质
          // 网关对未知字段回 400,故跟随 provider 级开关而非无条件携带。
          if (config.modernParams) 'stream_options': {'include_usage': true},
          // 推理等级:off 时不发送,避免非 reasoning 模型收到未知参数报错。
          if (request.reasoningLevel != ReasoningLevel.off)
            'reasoning_effort': switch (request.reasoningLevel) {
              ReasoningLevel.off => 'low', // unreachable,仅供 switch 完备
              ReasoningLevel.low => 'low',
              ReasoningLevel.medium => 'medium',
              ReasoningLevel.high => 'high',
            },
          // 原生工具:tools 非空才发送(普通端点不发 tools,避免未知字段 400)。
          // tool_choice 恒 auto;不发 parallel_tool_calls —— 多调用由消费方按
          // 收到顺序串行执行,顺序确定且少一个网关可能不认的字段。
          if (hasTools) 'tools': _toolsWire(request.tools),
          if (hasTools) 'tool_choice': 'auto',
        };

        // 跨轮共享累计器:续写与重试对消费方完全透明 —— 事件序列、
        // UsageEvent 每逻辑请求一次的语义都保持不变(轮内多块按网关累计快照
        // mergeMax,轮与轮之间逐项求和)。usage 累计在轮外做:闭包内写的可空
        // 变量会失去 flow analysis 提升,把每轮用量作为返回值带出。
        var totalUsage = const TokenUsage();
        var hasUsage = false;
        var sawContent = false;
        var sawReasoning = false;
        var sawDone = false;
        var sawError = false;

        // 一轮请求:发出、吃流、归类错误。transient 家族失败(连接超时/5xx/
        // 提前断)不就地发出,挂进 outcome.failure 等驱动层重试决策;其余
        // 错误就地发出并置 sawError。重试决策只在干净收尾时做出。
        Future<_RoundOutcome> round(Map<String, dynamic> body) async {
          final req = http.Request('POST', uri)
            ..headers.addAll({
              // 键统一小写(http 包的 headers map 大小写不敏感,发送层亦然):
              // 与 extraHeaders 的归一化存储格式一致,同名字段在 map 层即合并为
              // 同一条目,用户值覆盖内置默认(含 authorization,个别网关要求
              // key 走别的头名)。
              'authorization': 'Bearer ${config.apiKey}',
              'content-type': 'application/json',
              ...config.extraHeaders,
            })
            ..body = jsonEncode(body);
          // 连接/响应头超时:超时即掐断底层连接(否则连接继续挂在后台)。
          // 零正文时可透明重试一次,错误暂不发出 —— 由驱动层决定。
          late final http.StreamedResponse response;
          try {
            response = await client.send(req).timeout(connectTimeout);
          } on TimeoutException {
            client.close();
            return _RoundOutcome(
              failure: ErrorEvent(
                'OpenAI 请求超时:服务器 ${connectTimeout.inSeconds}s 内未响应',
                kind: UpstreamErrorKind.transient,
              ),
              retryableTransient: true,
            );
          }
          if (cancelled) return const _RoundOutcome();
          if (response.statusCode != 200) {
            final detail = await response.stream.bytesToString();
            final hint = response.statusCode == 403 ? kForbiddenHeaderHint : '';
            final shape = extractUpstreamErrorShape(detail);
            final kind = classifyUpstreamFailure(
              statusCode: response.statusCode,
              errorType: shape.type,
              body: detail,
            );
            final failure = ErrorEvent(
              'OpenAI ${response.statusCode}: $detail$hint',
              kind: kind,
              statusCode: response.statusCode,
            );
            // 仅瞬态家族(5xx/408)延迟透出等重试决策;鉴权/额度/策略/风控/
            // 契约错误重试无意义,就地发出。
            if (kind == UpstreamErrorKind.transient) {
              return _RoundOutcome(failure: failure, retryableTransient: true);
            }
            sawError = true;
            controller.add(failure);
            return const _RoundOutcome();
          }
          // 流空闲护栏:SSE 停滞(半开连接/网关挂起)时以 TimeoutException 掐断
          // 底层订阅,`await for` 不再永久挂起(异常上抛给驱动层做重试决策)。
          final lines = withIdleTimeout(
            response.stream.transform(utf8.decoder).transform(const LineSplitter()),
            idleTimeout,
          );
          final roundToolCalls = <int, _ToolCallAccum>{};
          var roundDone = false;
          TokenUsage? roundUsage;
          await for (final event in parseSse(lines)) {
            if (event.data == '[DONE]') {
              roundDone = true;
              sawDone = true;
              continue;
            }
            late final Map<String, dynamic> json;
            try {
              json = jsonDecode(event.data) as Map<String, dynamic>;
            } on FormatException {
              sawError = true;
              controller.add(ErrorEvent('bad SSE payload: ${event.data}', kind: UpstreamErrorKind.contractViolation));
              continue;
            }
            // 流中途的错误负载(限流/过载/内容过滤,常见于 OpenAI 兼容网关):
            // {"error": {...}} 块没有 choices/usage,不显式处理就会被静默吞掉 ——
            // 缓冲区空/半截,上层把真实后端故障误判成"解析失败"。
            final error = json['error'];
            if (error != null) {
              sawError = true;
              final message = error is Map && error['message'] != null ? error['message'] : error;
              final errorType = error is Map && error['type'] is String ? error['type'] as String : null;
              controller.add(ErrorEvent(
                'stream error: $message',
                kind: classifyUpstreamFailure(errorType: errorType, body: '$message'),
              ));
              continue;
            }
            final choices = json['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final choice = choices.first as Map<String, dynamic>;
              // 先取本块的正文/推理,再判 finish_reason —— 终块可能同时携带最后一
              // 段正文与 finish_reason,顺序反了会把有正文的截断误判成零正文。
              final delta = choice['delta'] as Map<String, dynamic>?;
              final content = delta?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                sawContent = true;
                controller.add(TextDelta(content));
              }
              // 推理通道(DeepSeek-R1 式网关):思考文本不算正文,只作空响应归因。
              final reasoning = delta?['reasoning_content'];
              if (reasoning is String && reasoning.isNotEmpty) sawReasoning = true;
              // 工具调用块:按 index 拼接 id/name/arguments。当前无工具消费方,
              // 累计仅用于"纯工具零正文"归因;正文与工具并存时正文照常透出。
              final toolParts = delta?['tool_calls'];
              if (toolParts is List) {
                for (final part in toolParts) {
                  if (part is! Map) continue;
                  final index = part['index'] is int ? part['index'] as int : 0;
                  final call = roundToolCalls.putIfAbsent(index, _ToolCallAccum.new);
                  if (part['id'] is String && (part['id'] as String).isNotEmpty) {
                    call.id ??= part['id'] as String;
                  }
                  final fn = part['function'];
                  if (fn is Map) {
                    if (fn['name'] is String && (fn['name'] as String).isNotEmpty) {
                      call.name ??= fn['name'] as String;
                    }
                    if (fn['arguments'] is String) call.arguments += fn['arguments'] as String;
                  }
                }
              }
              // 内容过滤截停:正文为空但流正常结束 —— 不透出就会表现为"模型未返回
              // 任何内容"的解析失败,用户无从知道是内容被上游过滤。
              if (choice['finish_reason'] == 'content_filter') {
                sawError = true;
                controller.add(const ErrorEvent(
                  'upstream content filter stopped the response',
                  kind: UpstreamErrorKind.contentFlag,
                ));
                continue;
              }
              // 输出在正文出现前就被 max_tokens 掐断(finish_reason=length):推理模型
              // 把预算烧在不可见思考上、兼容网关把推理 token 计入 max_tokens 时的典型
              // 形态 —— 零正文、流却以 [DONE] 正常收尾。不透出同样表现为"模型未返回
              // 任何内容"的解析失败;归为可重试的后端错误(上层重试不带 max_tokens)。
              // 已有正文的 length 截断不在此列:交给上层修复解析救截断的 JSON。
              if (choice['finish_reason'] == 'length' && !sawContent) {
                sawError = true;
                controller.add(const ErrorEvent(
                  'output cut by max_tokens before any content (reasoning may have consumed the budget)',
                  kind: UpstreamErrorKind.contractViolation,
                ));
                continue;
              }
            }
            final usage = json['usage'];
            if (usage != null) {
              final snapshot = TokenUsage.fromOpenAi(usage as Map<String, dynamic>);
              roundUsage = roundUsage == null ? snapshot : roundUsage.mergeMax(snapshot);
            }
          }
          // 轮内多块 usage 是累计快照(mergeMax),整轮作为该轮终值返回;
          // 轮与轮之间是两次独立请求,由调用方逐项求和。

          // 流结束却没有 [DONE]:连接被提前掐断(http 层静默完成、不抛错)。
          // 零正文可透明重试一次(错误暂不发出);已有正文不重试(部分内容已
          // 透出,重试会重复),错误照旧透出交上层按可重试故障处理。
          if (!roundDone) {
            return _RoundOutcome(
              usage: roundUsage,
              failure: sawError
                  ? null
                  : const ErrorEvent(
                      'stream ended before [DONE] (connection closed early)',
                      kind: UpstreamErrorKind.transient,
                    ),
              retryableTransient: !sawError,
            );
          }
          // 原生工具请求:工具调用即响应(无论是否并存正文/思考),成功透出
          // ToolCallsEvent。这是与无工具请求的关键语义差异 —— 后者把"纯工具
          // 零正文"判为契约错误(主写没有工具消费方)。已有错误在场时不冒充成功。
          if (hasTools && !sawError && roundToolCalls.isNotEmpty) {
            controller.add(ToolCallsEvent(_callsInOrder(roundToolCalls)));
            return _RoundOutcome(usage: roundUsage);
          }
          // 流以 [DONE] 正常收尾、零正文、但模型一直在推思考(reasoning_content):
          // 网关把"只思考未作答"包装成正常完成 —— 透出成可重试错误并给出准确归因,
          // 不再让上层报无法区分的"模型未返回任何内容"。已有其他错误(length 截停
          // 等)在场时不再叠加。
          if (!sawError && !sawContent && sawReasoning) {
            sawError = true;
            controller.add(const ErrorEvent(
              'model produced only reasoning content, no reply text',
              kind: UpstreamErrorKind.contentFlag,
            ));
            return _RoundOutcome(usage: roundUsage);
          }
          // 纯工具调用、零正文:本应用没有工具消费方,显式报错而不是静默
          // 空回;绝不把工具调用当成正常回复。
          if (roundDone && !sawError && !sawContent && roundToolCalls.isNotEmpty) {
            sawError = true;
            controller.add(const ErrorEvent('模型仅返回工具调用、未返回正文', kind: UpstreamErrorKind.contractViolation));
            return const _RoundOutcome();
          }
          return _RoundOutcome(usage: roundUsage);
        }

        // 驱动循环:transient 零正文透明重试一次(失败发生在任何内容产出
        // 之前)。已有正文流式透出后绝不重来 —— 消费方不会看到重复文本。
        // 原生工具请求不在此内部重试:步级重试归 agent runner 独占,错误直接
        // 透出,避免后端+runner 双层重试叠加。
        final body = baseBody;
        var transientRetried = false;
        while (!cancelled) {
          _RoundOutcome outcome;
          try {
            outcome = await round(body);
          } on TimeoutException {
            // 流空闲超时从 await for 直接抛出(非 ErrorEvent 通道):
            // 零正文可透明重试一次,否则原样上抛(流级错误语义不变)。
            if (!hasTools && !transientRetried && !sawContent) {
              transientRetried = true;
              continue;
            }
            rethrow;
          }
          if (outcome.usage != null) {
            final u = outcome.usage!;
            totalUsage = TokenUsage(
              inputTokens: totalUsage.inputTokens + u.inputTokens,
              outputTokens: totalUsage.outputTokens + u.outputTokens,
              cachedInputTokens: totalUsage.cachedInputTokens + u.cachedInputTokens,
            );
            hasUsage = true;
          }
          if (outcome.failure != null) {
            if (!hasTools && outcome.retryableTransient && !sawContent && !transientRetried) {
              transientRetried = true;
              continue; // 该次失败不透出,透明重试
            }
            controller.add(outcome.failure!);
            sawError = true;
            break;
          }
          break;
        }
        // DoneEvent 语义与单轮实现一致:见过 [DONE] 才发;用量只在流结束时发一次
        //(合并后的最终快照):上层按"每请求一次"的语义累加,网关逐块附带累计
        // usage 也不会再被叠加成天文数字。
        if (sawDone) controller.add(const DoneEvent());
        if (hasUsage) controller.add(UsageEvent(totalUsage));
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

  /// 块感知消息序列化:system 纯文本;assistant 工具调用轮带 `tool_calls`
  /// (正文空时 content 置 null,符合 OpenAI 工具轮形态);tool 结果消息走
  /// `tool` 角色 + `tool_call_id`;其余角色纯文本。
  static List<Map<String, dynamic>> _wireMessages(LlmRequest request) => [
    {'role': 'system', 'content': request.systemPrompt},
    for (final m in request.messages)
      if (m.role == ChatRole.tool)
        {'role': 'tool', 'tool_call_id': m.toolCallId ?? '', 'content': m.content}
      else if (m.role == ChatRole.assistant && (m.toolCalls?.isNotEmpty ?? false))
        {
          'role': 'assistant',
          'content': m.content.isEmpty ? null : m.content,
          'tool_calls': [
            for (final c in m.toolCalls!)
              {
                'id': c.id,
                'type': 'function',
                'function': {'name': c.name, 'arguments': c.arguments},
              },
          ],
        }
      else
        {'role': m.wireRole, 'content': m.content},
  ];

  /// 工具定义 → OpenAI `tools` 数组(function 形态)。
  static List<Map<String, dynamic>> _toolsWire(List<LlmTool> tools) => [
    for (final t in tools)
      {
        'type': 'function',
        'function': {
          'name': t.name,
          'description': t.description,
          'parameters': t.parameters,
        },
      },
  ];

  /// 流内累计器 → 按 index 序的 [ToolCall] 列表(id/name 缺失给空串,由消费方
  /// 校验残缺调用)。
  static List<ToolCall> _callsInOrder(Map<int, _ToolCallAccum> accum) {
    final indices = accum.keys.toList()..sort();
    return [
      for (final i in indices)
        ToolCall(
          id: accum[i]!.id ?? '',
          name: accum[i]!.name ?? '',
          arguments: accum[i]!.arguments,
        ),
    ];
  }
}