/// OpenAI 兼容 `chat/completions` 的流式后端。
///
/// 负责 SSE 解析、工具通道回复(`replyViaTool`)、提示词随机前缀
/// (`noncePrefix`)、用量快照合并与上游故障分类;每次请求独享连接,
/// 取消订阅即断链。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
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

/// 兼容选项 replyViaTool 注入的回复通道工具:整条回复改经 output_reply 的
/// content 参数输出 —— 适用于对普通正文流式截断/丢块、但工具调用参数能
/// 完整送达的端点。
const Map<String, dynamic> kReplyViaToolTool = {
  'type': 'function',
  'function': {
    'name': 'output_reply',
    'description': '将本次回复交给聊天界面显示。把完整回复原文放入 content 参数,作为 JSON 字符串正确转义;不要在普通消息中重复输出。',
    'parameters': {
      'type': 'object',
      'properties': {
        'content': {'type': 'string', 'description': '本次回复的原文,保留原有格式;作为 JSON 字符串正确转义。'},
      },
      'required': ['content'],
      'additionalProperties': false,
    },
  },
};

/// replyViaTool 收尾的结构错误与空回文案。
const String kReplyInvalidArgumentsMessage = '回复工具的参数格式错误,应为仅含 content 字符串的 JSON 对象';
const String kReplyEmptyMessage = 'API 未返回工具通道输出,可能为空回复或端点不支持该输出方式,请重试';

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

  /// 干净收尾但零正文零工具零思考(replyViaTool 空回重试判据)。
  final bool emptyRound;

  const _RoundOutcome({
    this.usage,
    this.failure,
    this.retryableTransient = false,
    this.emptyRound = false,
  });
}

/// 工具调用轮的流内累计器:按 tool_calls[].index 拼接 id / name /
/// arguments(与网关的工具流式拼接语义一致)。
class _ToolCallAccum {
  String? id;
  String? name;
  String arguments = '';

  // replyViaTool:output_reply 的 content 增量解码状态(仅回复工具使用)。
  bool replyStarted = false; // 已匹配 `{"content":"` 头
  bool replyClosed = false; // content 字符串已闭合
  bool replyInvalid = false; // 结构非法(控制字符/非法转义)
  int replyPosition = 0; // 已解码到的 arguments 索引
  final StringBuffer replyDecoded = StringBuffer(); // 已解码正文(供收尾校验)
}

/// JSON 简单转义 → 实际字符(\uXXXX 由数值路径处理)。
const Map<String, String> _kSimpleJsonEscapes = {
  '"': '"',
  r'\': r'\',
  '/': '/',
  'b': '\b',
  'f': '\f',
  'n': '\n',
  'r': '\r',
  't': '\t',
};

/// replyViaTool 增量解码:把 [call.arguments] 中尚未解码的部分按 JSON 字符串
/// 语义推进,返回新解码出的正文增量。
///
/// 只解码**已收齐**的字符 —— JSON 外壳与未收齐的转义序列不进入正文;流被
/// 风控/长度中途掐断时,已解码前缀照常透出(截断容忍的核心)。结构非法
/// 置 [call.replyInvalid],由调用方报错。高代理悬在块尾时回滚等低代理到齐,
/// 不发孤立代理。
String _feedReplyDecoder(_ToolCallAccum call) {
  if (call.replyClosed || call.replyInvalid) return '';
  final source = call.arguments;
  if (!call.replyStarted) {
    final header = RegExp(r'^\s*\{\s*"content"\s*:\s*"').firstMatch(source);
    if (header == null) return '';
    call.replyStarted = true;
    call.replyPosition = header.end;
  }
  final units = <int>[];
  var lastUnitSize = 0;
  while (call.replyPosition < source.length) {
    final ch = source[call.replyPosition];
    if (ch == '"') {
      call.replyPosition++;
      call.replyClosed = true;
      break;
    }
    if (ch.codeUnitAt(0) < 32) {
      call.replyInvalid = true;
      return '';
    }
    var size = 1;
    if (ch == r'\') {
      if (call.replyPosition + 1 >= source.length) break; // 转义未收齐,等下一块
      final esc = source[call.replyPosition + 1];
      if (esc == 'u') {
        if (call.replyPosition + 6 > source.length) break; // \uXXXX 未收齐,等下一块
        final hex = source.substring(call.replyPosition + 2, call.replyPosition + 6);
        final code = int.tryParse(hex, radix: 16);
        if (code == null) {
          call.replyInvalid = true;
          return '';
        }
        size = 6;
        units.add(code);
        lastUnitSize = 6;
      } else {
        final decoded = _kSimpleJsonEscapes[esc];
        if (decoded == null) {
          call.replyInvalid = true;
          return '';
        }
        size = 2;
        units.add(decoded.codeUnitAt(0));
        lastUnitSize = 1;
      }
    } else {
      units.add(ch.codeUnitAt(0));
      lastUnitSize = 1;
    }
    call.replyPosition += size;
  }
  // 未闭合且块尾悬着高代理:回滚该单元(等低代理下一块到齐再解码),
  // \uXXXX 转义回滚整个转义序列,裸字符回滚一个码元。
  if (!call.replyClosed && units.isNotEmpty) {
    final last = units.last;
    if (last >= 0xD800 && last <= 0xDBFF) {
      call.replyPosition -= lastUnitSize;
      units.removeLast();
    }
  }
  if (units.isEmpty) return '';
  final delta = String.fromCharCodes(units);
  call.replyDecoded.write(delta);
  return delta;
}

/// 生成提示词随机前缀:6–8 位小写字母数字,至少含一个字母与一个数字。
/// 各次生成相互独立,使每轮请求的 system 字节不同。
String _generateNonce() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random();
  while (true) {
    final length = 6 + random.nextInt(3); // 6–8 位
    final units = [for (var i = 0; i < length; i++) chars[random.nextInt(chars.length)]];
    final hasLetter = units.any((c) => c.contains(RegExp(r'[a-z]')));
    final hasDigit = units.any((c) => c.contains(RegExp(r'[0-9]')));
    if (hasLetter && hasDigit) return units.join();
  }
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
        // 兼容选项 noncePrefix:system 头部前置随机 nonce,每轮请求字节不同。
        // 同一轮的续写/重试共用同一 nonce(同一个逻辑请求)。
        var systemContent = request.systemPrompt;
        if (config.compat.noncePrefix) {
          systemContent = '${_generateNonce()}\n$systemContent';
        }
        final wireMessages = <Map<String, dynamic>>[
          {'role': 'system', 'content': systemContent},
          ...request.messages.map((m) => {'role': m.wireRole, 'content': m.content}),
        ];
        final compatTools = [
          if (config.compat.replyViaTool) kReplyViaToolTool,
        ];
        final baseBody = {
          'model': request.model,
          'messages': wireMessages,
          'stream': true,
          'temperature': request.temperature,
          // 官方 OpenAI 参数风格(v47):推理模型(o 系列等)只认
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
          // 端点兼容选项:replyViaTool = 回复改经 output_reply 通道。普通
          // 端点不发送 tools —— 部分劣质网关对未知字段回 400。
          if (compatTools.isNotEmpty) 'tools': compatTools,
          if (config.compat.replyViaTool) 'tool_choice': {
            'type': 'function',
            'function': {'name': 'output_reply'},
          },
          if (config.compat.replyViaTool) 'parallel_tool_calls': false,
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
          var replyInvalidReported = false;
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
              // 工具调用块(回复通道):按 index 拼接。replyViaTool 下
              // output_reply 的 arguments 即回复正文,增量解码照常流式透出;
              // 其余工具只用于空回归因,正文与工具调用并存的轮静默丢弃工具
              // 部分(本应用没有工具消费方)。
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
                  if (config.compat.replyViaTool && call.name == 'output_reply') {
                    final replyDelta = _feedReplyDecoder(call);
                    if (replyDelta.isNotEmpty) {
                      sawContent = true;
                      controller.add(TextDelta(replyDelta));
                    }
                    if (call.replyInvalid && !replyInvalidReported) {
                      replyInvalidReported = true;
                      sawError = true;
                      controller.add(const ErrorEvent(
                        kReplyInvalidArgumentsMessage,
                        kind: UpstreamErrorKind.contractViolation,
                      ));
                    }
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
          // replyViaTool 收尾:output_reply 调用优先于空回判定。
          if (config.compat.replyViaTool && roundToolCalls.values.any((c) => c.name == 'output_reply')) {
            final replies = roundToolCalls.values.where((c) => c.name == 'output_reply').toList();
            if (replies.length > 1) {
              sawError = true;
              controller.add(const ErrorEvent(kReplyInvalidArgumentsMessage, kind: UpstreamErrorKind.contractViolation));
              return _RoundOutcome(usage: roundUsage);
            }
            final call = replies.single;
            if (!call.replyInvalid) _feedReplyDecoder(call); // 收尾喂完剩余可解码部分
            if (call.replyInvalid && !replyInvalidReported) {
              sawError = true;
              controller.add(const ErrorEvent(kReplyInvalidArgumentsMessage, kind: UpstreamErrorKind.contractViolation));
              return _RoundOutcome(usage: roundUsage);
            }
            if (call.replyInvalid) return _RoundOutcome(usage: roundUsage); // 流内已报过
            Object? payload;
            try {
              payload = jsonDecode(call.arguments);
            } on FormatException {
              payload = null;
            }
            if (payload is Map<String, dynamic> && payload['content'] is String && payload.length == 1) {
              final full = payload['content'] as String;
              if (!full.startsWith(call.replyDecoded.toString())) {
                sawError = true;
                controller.add(const ErrorEvent(kReplyInvalidArgumentsMessage, kind: UpstreamErrorKind.contractViolation));
              } else {
                final tail = full.substring(call.replyDecoded.length);
                if (tail.isNotEmpty) {
                  sawContent = true;
                  controller.add(TextDelta(tail));
                  call.replyDecoded.write(tail);
                }
                if (!sawContent) {
                  // output_reply 在场但 content 为空:模型给出了空回复 ——
                  // 有调用即有响应,不重试。
                  sawError = true;
                  controller.add(const ErrorEvent(kReplyEmptyMessage, kind: UpstreamErrorKind.contentFlag));
                }
              }
              return _RoundOutcome(usage: roundUsage);
            }
            // JSON 残缺:容忍"已开始解码且未闭合"(被风控/长度掐断,保留已解码
            // 前缀);从未开始解码、或闭合后还有残渣 → 结构错误。
            final closedWithJunk =
                call.replyClosed && call.arguments.substring(call.replyPosition).trim().isNotEmpty;
            if (!call.replyStarted || closedWithJunk) {
              sawError = true;
              controller.add(const ErrorEvent(kReplyInvalidArgumentsMessage, kind: UpstreamErrorKind.contractViolation));
              return _RoundOutcome(usage: roundUsage);
            }
            return _RoundOutcome(usage: roundUsage);
          }
          // 纯工具调用、零正文:本应用没有工具消费方,显式报错而不是静默
          // 空回;绝不把工具调用当成正常回复。
          if (roundDone && !sawError && !sawContent && roundToolCalls.isNotEmpty) {
            sawError = true;
            controller.add(const ErrorEvent('模型仅返回工具调用、未返回正文', kind: UpstreamErrorKind.contractViolation));
            return const _RoundOutcome();
          }
          // 干净收尾但零正文零工具零思考:replyViaTool 下的"空回",由驱动层
          // 自动重试(模型忽略强制工具选择/网关剥掉 tools 时的典型形态);
          // 普通模式保持历史行为(静默空回,上层按无回复处理)。
          return _RoundOutcome(
            usage: roundUsage,
            emptyRound: !sawContent && roundToolCalls.isEmpty && !sawReasoning,
          );
        }

        // 驱动循环:transient 零正文透明重试一次(失败发生在任何内容产出
        // 之前);replyViaTool 空回最多重试 2 次(共 3 次尝试)。已有正文
        // 流式透出后绝不重来 —— 消费方不会看到重复文本。
        final body = baseBody;
        var transientRetried = false;
        var emptyRetries = 0;
        while (!cancelled) {
          _RoundOutcome outcome;
          try {
            outcome = await round(body);
          } on TimeoutException {
            // 流空闲超时从 await for 直接抛出(非 ErrorEvent 通道):
            // 零正文可透明重试一次,否则原样上抛(流级错误语义不变)。
            if (!transientRetried && !sawContent) {
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
            if (outcome.retryableTransient && !sawContent && !transientRetried) {
              transientRetried = true;
              continue; // 该次失败不透出,透明重试
            }
            controller.add(outcome.failure!);
            sawError = true;
            break;
          }
          if (outcome.emptyRound && config.compat.replyViaTool && emptyRetries < 2) {
            emptyRetries++;
            continue;
          }
          if (outcome.emptyRound && config.compat.replyViaTool) {
            // 空回重试穷尽:显式报错,不再静默空回。
            sawError = true;
            controller.add(const ErrorEvent(kReplyEmptyMessage, kind: UpstreamErrorKind.contentFlag));
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
}
