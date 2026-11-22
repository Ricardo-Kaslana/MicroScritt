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
  /// 驱动层重试决策 —— 可重试且零正文时该错误被丢弃,不透出;其余终局错误
  /// 进 [errors],由驱动层在用量快照之后透出。
  final ErrorEvent? failure;

  /// 轮内已发生、但必须等 UsageEvent 之后才能透出的终局错误。
  ///
  /// 上层(agent/后台)在 ErrorEvent 到达时即落定失败结果,ErrorEvent 先于
  /// UsageEvent 会让已计量的 token 归零;因此流内错误先暂存,收尾时先发
  /// 用量快照再按原序发错误。
  final List<ErrorEvent> errors;

  const _RoundOutcome({this.usage, this.failure, this.errors = const []});
}

/// 工具调用轮的流内累计器:拼接 id / name / arguments(与网关的工具流式
/// 拼接语义一致)。同一调用的分块可能省略 index/id,按 id 或 index 归槽。
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
    //
    // 自建 client 的生命周期覆盖整次 generate(含透明重试):连接超时时旧
    // 连接可能仍挂着,只能关掉并重建;注入的 client 归调用方所有,超时分支
    // **不能** close —— 否则零正文透明重试会拿着一个已关闭的 client 直接失败。
    final ownsClient = providedClient == null;
    var client = providedClient ?? http.Client();
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
        // 消费方取消:断链中止。仅在请求尚未自然收尾时关闭 —— 正常完成后的
        // 补位 cancel(chat_controller 的 unawaited(sub.cancel()))不能把
        // 复用中的注入 client(测试多轮请求)标成 closed。
        cancelled = true;
        if (!producerDone) closeClient();
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
            config.modernParams ? 'max_completion_tokens' : 'max_tokens':
                request.maxTokens,
          // 官方端点流式默认不带 usage,不开此开关用量统计恒为零;部分劣质
          // 网关对未知字段回 400,故跟随 provider 级开关而非无条件携带。
          if (config.modernParams) 'stream_options': {'include_usage': true},
          // 推理等级:off 时不发送,避免非 reasoning 模型收到未知参数报错;
          // 其余档位与 Chat Completions 的枚举字面值一一对应(minimal/low/
          // medium/high/xhigh/max),是否支持由具体模型决定。GPT-5.4+ 在
          // Chat Completions 下同时携带 tools 与 reasoning_effort 可能被上游
          // 拒绝;这里保留用户请求,不自动降级为 none。
          if (request.reasoningLevel != ReasoningLevel.off)
            'reasoning_effort': request.reasoningLevel.name,
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
        // 提前断)不就地发出,挂进 outcome.failure 等驱动层重试决策;终局错误
        // 暂存进 outcome.errors,由驱动层在用量快照之后透出(sawError 恒置位)。
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
          // 零正文时可透明重试一次,错误暂不发出 —— 由驱动层决定。自建 client
          // 关闭后重建,重试才不是拿着已关闭的实例;注入 client 归调用方所有,
          // 不在此关闭(否则测试/探测的透明重试必然失败)。
          late final http.StreamedResponse response;
          try {
            response = await client.send(req).timeout(connectTimeout);
          } on TimeoutException {
            if (ownsClient) {
              closeClient();
              client = http.Client();
              clientClosed = false;
            }
            return _RoundOutcome(
              failure: ErrorEvent(
                'OpenAI 请求超时:服务器 ${connectTimeout.inSeconds}s 内未响应',
                kind: UpstreamErrorKind.transient,
              ),
            );
          }
          if (cancelled) return const _RoundOutcome();
          if (response.statusCode != 200) {
            // 错误体只用于诊断:设空闲超时与字节上限,避免上游错误路径挂起
            // 或回传整页 HTML 时把等待与内存交给服务端。
            final detail = await _readErrorBody(response.stream);
            final hint = response.statusCode == 403 ? kForbiddenHeaderHint : '';
            final shape = extractUpstreamErrorShape(detail);
            final kind = classifyUpstreamFailure(
              statusCode: response.statusCode,
              errorType: shape.type,
              body: detail,
            );
            final failure = ErrorEvent(
              'OpenAI ${response.statusCode}: '
              '${redactSecrets(detail, apiKey: config.apiKey)}$hint',
              kind: kind,
              statusCode: response.statusCode,
            );
            // 仅瞬态家族(5xx/408)延迟透出等重试决策;鉴权/额度/策略/风控/
            // 契约错误重试无意义,暂存到用量快照之后透出。
            if (kind == UpstreamErrorKind.transient) {
              return _RoundOutcome(failure: failure);
            }
            return _RoundOutcome(errors: [failure]);
          }
          // 流空闲护栏:SSE 停滞(半开连接/网关挂起)时以 TimeoutException 掐断
          // 底层订阅,`await for` 不再永久挂起(异常上抛给驱动层做重试决策)。
          final lines = withIdleTimeout(
            response.stream
                .transform(utf8.decoder)
                .transform(const LineSplitter()),
            idleTimeout,
          );
          final roundToolCalls = <int, _ToolCallAccum>{};
          final roundErrors = <ErrorEvent>[];
          var roundDone = false;
          TokenUsage? roundUsage;
          await for (final event in parseSse(lines)) {
            if (event.data.trim() == '[DONE]') {
              roundDone = true;
              sawDone = true;
              // 终局帧即请求结束:主动退出读取并取消底层订阅。keep-alive 网关
              // 出完 [DONE] 后仍保活几十秒,继续等只会被空闲超时误判成故障,
              // 连带 Done/Usage 丢失、agent 重试并重复计费。
              break;
            }
            final json = decodeSseJsonObject(event.data);
            if (json == null) {
              // 坏 JSON 与非对象 JSON(数组/字符串/数字/null)都是契约不符,
              // 不能走未分类异常让上层猜。
              sawError = true;
              roundErrors.add(
                ErrorEvent(
                  'bad SSE payload: '
                  '${redactSecrets(event.data, apiKey: config.apiKey)}',
                  kind: UpstreamErrorKind.contractViolation,
                ),
              );
              continue;
            }
            // 流中途的错误负载(限流/过载/内容过滤,常见于 OpenAI 兼容网关):
            // {"error": {...}} 块没有 choices/usage,不显式处理就会被静默吞掉 ——
            // 缓冲区空/半截,上层把真实后端故障误判成"解析失败"。
            final error = json['error'];
            if (error != null) {
              sawError = true;
              final message = error is Map && error['message'] != null
                  ? error['message']
                  : error;
              final errorType = error is Map && error['type'] is String
                  ? error['type'] as String
                  : null;
              roundErrors.add(
                ErrorEvent(
                  'stream error: '
                  '${redactSecrets('$message', apiKey: config.apiKey)}',
                  kind: classifyUpstreamFailure(
                    errorType: errorType,
                    body: '$message',
                  ),
                ),
              );
              // 流内错误是终局帧:停止读取,连接尽快关闭。
              break;
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
              if (reasoning is String && reasoning.isNotEmpty) {
                sawReasoning = true;
              }
              // 工具调用块:按 index/id 归槽拼接 arguments。当前无工具消费方,
              // 累计仅用于"纯工具零正文"归因;正文与工具并存时正文照常透出。
              final toolParts = delta?['tool_calls'];
              if (toolParts is List) {
                for (final part in toolParts) {
                  if (part is! Map) continue;
                  final partId =
                      part['id'] is String && (part['id'] as String).isNotEmpty
                      ? part['id'] as String
                      : null;
                  final rawIndex = part['index'] is int
                      ? part['index'] as int
                      : null;
                  final call = _slotFor(roundToolCalls, rawIndex, partId);
                  final fn = part['function'];
                  final partName =
                      fn is Map &&
                          fn['name'] is String &&
                          (fn['name'] as String).isNotEmpty
                      ? fn['name'] as String
                      : null;
                  final partArgs = fn is Map && fn['arguments'] is String
                      ? fn['arguments'] as String
                      : null;
                  // 重复完整块(同一 id/name/arguments 整体重发)覆盖而不是
                  // 追加:网关在重连/重放时会补发完整块,追加会把 JSON 拼坏。
                  // 只有"已累计完整 + 本块也完整"才判重发:半截累计后的 `{}`
                  // 这类合法续块仍走追加。
                  final isFullBlock =
                      partId != null &&
                      partName != null &&
                      partArgs != null &&
                      partArgs.isNotEmpty &&
                      call.id == partId &&
                      call.arguments.isNotEmpty &&
                      _isCompleteJson(call.arguments) &&
                      _isCompleteJson(partArgs);
                  if (partId != null) call.id ??= partId;
                  if (partName != null) call.name ??= partName;
                  if (partArgs != null) {
                    if (isFullBlock) {
                      call.arguments = partArgs;
                    } else {
                      call.arguments += partArgs;
                    }
                  }
                }
              }
              // 内容过滤截停:正文为空但流正常结束 —— 不透出就会表现为"模型未返回
              // 任何内容"的解析失败,用户无从知道是内容被上游过滤。
              if (choice['finish_reason'] == 'content_filter') {
                sawError = true;
                roundErrors.add(
                  const ErrorEvent(
                    'upstream content filter stopped the response',
                    kind: UpstreamErrorKind.contentFlag,
                  ),
                );
                continue;
              }
              // 输出在正文出现前就被 max_tokens 掐断(finish_reason=length):推理模型
              // 把预算烧在不可见思考上、兼容网关把推理 token 计入 max_tokens 时的典型
              // 形态 —— 零正文、流却以 [DONE] 正常收尾。不透出同样表现为"模型未返回
              // 任何内容"的解析失败;归为可重试的后端错误(上层重试不带 max_tokens)。
              // 已有正文的 length 截断不在此列:交给上层修复解析救截断的 JSON。
              if (choice['finish_reason'] == 'length' && !sawContent) {
                sawError = true;
                roundErrors.add(
                  const ErrorEvent(
                    'output cut by max_tokens before any content (reasoning may have consumed the budget)',
                    kind: UpstreamErrorKind.contractViolation,
                  ),
                );
                continue;
              }
            }
            final usage = json['usage'];
            if (usage != null) {
              final snapshot = TokenUsage.fromOpenAi(
                usage as Map<String, dynamic>,
              );
              roundUsage = roundUsage == null
                  ? snapshot
                  : roundUsage.mergeMax(snapshot);
            }
          }
          // 轮内多块 usage 是累计快照(mergeMax),整轮作为该轮终值返回;
          // 轮与轮之间是两次独立请求,由调用方逐项求和。

          // 流结束却没有 [DONE]:连接被提前掐断(http 层静默完成、不抛错)。
          // 零正文可透明重试一次(错误暂不发出);已有正文不重试(部分内容已
          // 透出,重试会重复),错误照旧透出交上层按可重试故障处理。
          if (!roundDone) {
            if (sawError) {
              return _RoundOutcome(usage: roundUsage, errors: roundErrors);
            }
            return _RoundOutcome(
              usage: roundUsage,
              failure: const ErrorEvent(
                'stream ended before [DONE] (connection closed early)',
                kind: UpstreamErrorKind.transient,
              ),
            );
          }
          // 原生工具请求:工具调用即响应(无论是否并存正文/思考),成功透出
          // ToolCallsEvent。这是与无工具请求的关键语义差异 —— 后者把"纯工具
          // 零正文"判为契约错误(主写没有工具消费方)。已有错误在场时不冒充成功。
          if (hasTools && !sawError && roundToolCalls.isNotEmpty) {
            final collected = _collectToolCalls(roundToolCalls);
            if (collected.dropped > 0 && collected.calls.isEmpty) {
              // 空 name 无法执行也无法回放(上游会 400),显式判协议错误。
              sawError = true;
              roundErrors.add(
                const ErrorEvent(
                  '上游返回了缺少函数名的工具调用,已丢弃',
                  kind: UpstreamErrorKind.contractViolation,
                ),
              );
            } else if (collected.calls.isNotEmpty) {
              controller.add(ToolCallsEvent(collected.calls));
              return _RoundOutcome(usage: roundUsage, errors: roundErrors);
            }
          }
          // 流以 [DONE] 正常收尾、零正文、但模型一直在推思考(reasoning_content):
          // 网关把"只思考未作答"包装成正常完成 —— 透出成可重试错误并给出准确归因,
          // 不再让上层报无法区分的"模型未返回任何内容"。已有其他错误(length 截停
          // 等)在场时不再叠加。
          if (!sawError && !sawContent && sawReasoning) {
            sawError = true;
            roundErrors.add(
              const ErrorEvent(
                'model produced only reasoning content, no reply text',
                kind: UpstreamErrorKind.contentFlag,
              ),
            );
            return _RoundOutcome(usage: roundUsage, errors: roundErrors);
          }
          // 纯工具调用、零正文:本应用没有工具消费方,显式报错而不是静默
          // 空回;绝不把工具调用当成正常回复。
          if (!sawError && !sawContent && roundToolCalls.isNotEmpty) {
            sawError = true;
            roundErrors.add(
              const ErrorEvent(
                '模型仅返回工具调用、未返回正文',
                kind: UpstreamErrorKind.contractViolation,
              ),
            );
            return _RoundOutcome(usage: roundUsage, errors: roundErrors);
          }
          // 正常收尾但正文/推理/工具调用全空:不能再静默成功 —— 上层只会
          // 落一条空回复,用户与后台都无从归因。只有任一通道有产出才合法。
          if (!sawError &&
              !sawContent &&
              !sawReasoning &&
              roundToolCalls.isEmpty) {
            sawError = true;
            roundErrors.add(
              const ErrorEvent(
                '模型正常收尾但未返回任何内容(正文/推理/工具调用均为空)',
                kind: UpstreamErrorKind.contentFlag,
              ),
            );
          }
          return _RoundOutcome(usage: roundUsage, errors: roundErrors);
        }

        // 驱动循环:transient 零正文透明重试一次(失败发生在任何内容产出
        // 之前)。已有正文流式透出后绝不重来 —— 消费方不会看到重复文本。
        // 原生工具请求不在此内部重试:步级重试归 agent runner 独占,错误直接
        // 透出,避免后端+runner 双层重试叠加。
        final body = baseBody;
        var transientRetried = false;
        final terminalErrors = <ErrorEvent>[];
        while (!cancelled) {
          _RoundOutcome outcome;
          try {
            outcome = await round(body);
          } on TimeoutException {
            // 流空闲超时从 await for 直接抛出(非 ErrorEvent 通道):
            // 零正文且无已发错误可透明重试一次,否则原样上抛(流级错误语义不变)。
            if (!hasTools && !transientRetried && !sawContent && !sawError) {
              transientRetried = true;
              continue;
            }
            rethrow;
          }
          if (outcome.usage != null) {
            totalUsage = totalUsage + outcome.usage!;
            hasUsage = true;
          }
          terminalErrors.addAll(outcome.errors);
          if (outcome.failure != null) {
            if (!hasTools && !sawContent && !sawError && !transientRetried) {
              transientRetried = true;
              continue; // 该次失败不透出,透明重试
            }
            terminalErrors.add(outcome.failure!);
            sawError = true;
            break;
          }
          break;
        }
        // 事件顺序固定为 Done → Usage → Error:上层(agent/后台)在 ErrorEvent
        // 到达时即落定失败结果,用量必须先到才能让失败也带上已计数 token。
        // DoneEvent 语义与单轮实现一致:见过 [DONE] 才发;用量只在流结束时发一次
        //(合并后的最终快照):上层按"每请求一次"的语义累加,网关逐块附带累计
        // usage 也不会再被叠加成天文数字。
        if (sawDone) controller.add(const DoneEvent());
        if (hasUsage) controller.add(UsageEvent(totalUsage));
        for (final error in terminalErrors) {
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

  /// 为一条 tool_call 分块找归槽槽位。
  ///
  /// 兼容网关的分块形态不统一:有的只在首块带 index,有的每块重复 id,
  /// 有的完全省略 index。规则:非空 id 优先按 id 归槽(id 相同即同一调用);
  /// 新 id 必建新槽(即使 index 已被旧调用占用);无 id 时按 index;
  /// 两者都缺则视为上一个槽的续块(流内单调用占绝大多数)。
  static _ToolCallAccum _slotFor(
    Map<int, _ToolCallAccum> calls,
    int? index,
    String? id,
  ) {
    if (id != null) {
      for (final call in calls.values) {
        if (call.id == id) return call;
      }
      if (index != null) {
        final atIndex = calls[index];
        if (atIndex == null) {
          return calls[index] = _ToolCallAccum()..id = id;
        }
        // index 槽还没有 id(前几块省略了 id):把 id 补进同一调用,不能
        // 另建新槽 —— 否则一个调用会被拆成两条,回放与 tool_result 失配。
        if (atIndex.id == null || atIndex.id!.isEmpty) {
          atIndex.id = id;
          return atIndex;
        }
        // index 已被另一个 id 占用:这是新调用,另起槽位。
      }
      final key = _nextSlotKey(calls);
      return calls[key] = _ToolCallAccum()..id = id;
    }
    if (index != null) {
      calls.putIfAbsent(index, _ToolCallAccum.new);
      return calls[index]!;
    }
    if (calls.isNotEmpty) {
      return calls[calls.keys.reduce((a, b) => a > b ? a : b)]!;
    }
    return calls[0] = _ToolCallAccum();
  }

  static int _nextSlotKey(Map<int, _ToolCallAccum> calls) =>
      calls.isEmpty ? 0 : calls.keys.reduce((a, b) => a > b ? a : b) + 1;

  /// 分块参数是否已是完整 JSON:完整块重发与增量分片的区分依据。
  static bool _isCompleteJson(String text) {
    try {
      jsonDecode(text);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// 累计槽 → 按 index 序的 [ToolCall] 列表。
  ///
  /// 缺失 id 合成 `call_<index>`:assistant 回放与 tool_result 必须引用同一 id,
  /// 留空会让下一轮上游 400。空 name 的调用不进入列表(返回 dropped 计数,
  /// 由调用方判协议错误),否则无法执行、也无法原样回放。
  static ({List<ToolCall> calls, int dropped}) _collectToolCalls(
    Map<int, _ToolCallAccum> accum,
  ) {
    final indices = accum.keys.toList()..sort();
    final calls = <ToolCall>[];
    var dropped = 0;
    for (final i in indices) {
      final a = accum[i]!;
      final name = a.name;
      if (name == null || name.isEmpty) {
        dropped++;
        continue;
      }
      final id = a.id;
      calls.add(
        ToolCall(
          id: id == null || id.isEmpty ? 'call_$i' : id,
          name: name,
          arguments: a.arguments,
        ),
      );
    }
    return (calls: calls, dropped: dropped);
  }

  /// 块感知消息序列化:system 纯文本;assistant 工具调用轮带 `tool_calls`
  /// (正文空时 content 置 null,符合 OpenAI 工具轮形态);tool 结果消息走
  /// `tool` 角色 + `tool_call_id`;其余角色纯文本。
  static List<Map<String, dynamic>> _wireMessages(LlmRequest request) => [
    {'role': 'system', 'content': request.systemPrompt},
    for (final m in request.messages)
      if (m.role == ChatRole.tool)
        {
          'role': 'tool',
          'tool_call_id': m.toolCallId ?? '',
          'content': m.content,
        }
      else if (m.role == ChatRole.assistant &&
          (m.toolCalls?.isNotEmpty ?? false))
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
}
