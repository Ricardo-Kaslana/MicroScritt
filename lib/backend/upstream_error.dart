/// 上游故障的稳定分类。
///
/// **失效不可避免,可诊断性才是健壮性** —— 本分类把"上游怎么拒的"归一成
/// 稳定枚举,让重试策略、测试连接与错误横幅都建立在语义上,而不是状态码
/// 与报错文本的字面猜测。
library;

import 'dart:convert';

enum UpstreamErrorKind {
  /// 密钥无效/被禁用/鉴权头缺失。处置:检查密钥与自定义请求头。
  auth,

  /// 账户在该渠道的额度不足,或上游已调整计费归属(402 是最高频信号)。
  quota,

  /// 网关按客户端特征/渠道策略拒绝(403 裸拒、FreeTierError、地区封锁、
  /// "无可用渠道")。处置:检查自定义请求头。
  gatewayPolicy,

  /// 内容被上游风控拦截(400「提示词已被标记」、finish_reason=content_filter、
  /// 零正文空回)。处置:调整内容后重试,或更换服务。
  contentFlag,

  /// 触发限流(429 / rate limit)。
  rateLimit,

  /// 网络/服务端瞬态故障(超时、断连、5xx)。可重试。
  transient,

  /// 本地模型配置不完整(如 Anthropic 协议未填「最大输出 tokens」)。
  /// 非上游故障,不应重试;补全模型配置后可直接重发。
  configuration,

  /// 请求超出模型上下文容量(400 且正文含上下文超长签名)。非瞬态:
  /// 原样重试必然再次失败,处置是压缩历史或换更大上下文的模型。
  contextLength,

  /// 契约不符:SSE 载荷损坏、未知字段被拒、只回工具调用、以及一切
  /// "响应形状对不上已知协议"的情形 —— 上游协议漂移的首要信号。
  contractViolation;

  /// 面向 UI 的中文标签。
  String get label => switch (this) {
        UpstreamErrorKind.auth => '鉴权失败',
        UpstreamErrorKind.quota => '额度不足',
        UpstreamErrorKind.gatewayPolicy => '网关策略拦截',
        UpstreamErrorKind.contentFlag => '内容风控拦截',
        UpstreamErrorKind.rateLimit => '触发限流',
        UpstreamErrorKind.transient => '瞬态故障',
        UpstreamErrorKind.configuration => '配置错误',
        UpstreamErrorKind.contextLength => '上下文超长',
        UpstreamErrorKind.contractViolation => '契约不符',
      };

  /// 面向 UI 的一句处置建议(错误横幅/测试连接结果共用)。
  String get hint => switch (this) {
        UpstreamErrorKind.auth => 'API Key 无效或被禁用;检查密钥与自定义请求头配置',
        UpstreamErrorKind.quota => '账户在该渠道的额度不足;若额度正常,可能上游已调整计费方式,请用「测试连接」复核',
        UpstreamErrorKind.gatewayPolicy => '请求被网关按客户端特征或渠道策略拒绝;检查自定义请求头,或该服务仅限特定客户端使用',
        UpstreamErrorKind.contentFlag => '请求内容被上游风控标记;调整内容后重试,或更换服务',
        UpstreamErrorKind.rateLimit => '请求频率超限;稍后重试',
        UpstreamErrorKind.transient => '网络或服务端临时故障;可重试',
        UpstreamErrorKind.configuration => '模型配置不完整;请在设置 → LLM Provider 的模型编辑中补全所需字段',
        UpstreamErrorKind.contextLength => '请求超出模型上下文容量;请压缩历史或切换到更大上下文的模型',
        UpstreamErrorKind.contractViolation => '响应与已知契约不符 —— 上游协议可能已变更;请用「测试连接」复核',
      };
}

/// 正文/错误类型特征表(小写匹配)。签名是**尽力归类**的嗅探,不是协议:
/// 命中已知签名给准确分类,未命中按状态码兜底 —— 未知形态宁可持续观察,
/// 不可错杀成确定结论。
const List<String> _authSignatures = [
  'invalid api key',
  'invalid_api_key',
  'api key not valid',
  'api key has been',
  '密钥无效',
  '密钥已被禁用',
  'unauthorized',
  'authentication',
];

const List<String> _quotaSignatures = ['quota', '额度不足', 'insufficient'];

const List<String> _policySignatures = [
  'free tier',
  'freetier',
  'location is not supported',
  'unsupported_country',
  '无可用渠道',
];

const List<String> _contentFlagSignatures = [
  '已被标记',
  '被屏蔽',
  '内容过滤',
  '敏感内容',
  'flagged',
  'content_policy',
  'content policy',
  'content_filter',
  'contentfilter',
  'prohibited_content',
  'safety system',
  'blocked due to',
];

const List<String> _rateLimitSignatures = [
  'rate limit',
  'rate_limit',
  'ratelimit',
  '限流',
  'too many requests',
];

/// 上下文超长签名:OpenAI/Anthropic 及其兼容网关的常见文案。命中即
/// [UpstreamErrorKind.contextLength](非瞬态,重试无意义),优先于 400
/// 的通用「契约不符」判定。
const List<String> _contextLengthSignatures = [
  'context_length_exceeded',
  'maximum context length',
  'context length exceeded',
  'exceeds the context window',
  'context window',
  'prompt is too long',
  'input is too long',
  'too many tokens',
  'context 超长',
  '上下文长度',
];

/// 按状态码 + 服务端错误类型 + 正文特征归类一次上游失败。
///
/// [statusCode] 为流中途错误负载(200 响应内的 `{"error":{...}}` 块)时传
/// null,此时按正文特征归类、默认 [UpstreamErrorKind.transient]。
/// 三类输入都允许为空;全部为空时返回 transient(无信息可依,按可重试对待)。
UpstreamErrorKind classifyUpstreamFailure({int? statusCode, String? errorType, String? body}) {
  final type = (errorType ?? '').toLowerCase();
  final text = '${(body ?? '').toLowerCase()} $type';
  bool has(List<String> signatures) => signatures.any(text.contains);

  // 正文特征优先于状态码:402「密钥无效」比状态码更说明问题,反之
  // 403 + 密钥签名同样该报鉴权而不是网关策略。
  if (has(_authSignatures)) return UpstreamErrorKind.auth;
  if (has(_policySignatures)) return UpstreamErrorKind.gatewayPolicy;
  if (has(_quotaSignatures)) return UpstreamErrorKind.quota;
  // 上下文超长是确定性失败:与「契约漂移」共用 400,但处置完全不同
  // (压缩/换模型,而不是重试或排查协议)。
  if (has(_contextLengthSignatures)) return UpstreamErrorKind.contextLength;

  final status = statusCode;
  if (status != null) {
    if (status == 401) return UpstreamErrorKind.auth;
    if (status == 402) return UpstreamErrorKind.quota;
    if (status == 403) return UpstreamErrorKind.gatewayPolicy;
    if (status == 429) return UpstreamErrorKind.rateLimit;
    if (status == 408 || status >= 500) return UpstreamErrorKind.transient;
    if (status == 400) {
      return has(_contentFlagSignatures)
          ? UpstreamErrorKind.contentFlag
          : UpstreamErrorKind.contractViolation;
    }
    // 其余状态码(404/405/…)一律视为契约不符:路径或方法对不上已知协议。
    return UpstreamErrorKind.contractViolation;
  }

  // 无状态码(流中途错误负载):正文特征已试过,再试限流特征,默认瞬态。
  if (has(_rateLimitSignatures)) return UpstreamErrorKind.rateLimit;
  // invalid_request_error 是确定性请求错误(参数/长度/结构不合法):归非瞬态,
  // 否则 agent 会把同一条注定失败的请求重试到尝试耗尽并重复计费。
  if (type.contains('invalid_request') || type.contains('invalid request')) {
    return UpstreamErrorKind.contractViolation;
  }
  return UpstreamErrorKind.transient;
}

final RegExp _bearerPattern = RegExp(
  r'\b(Bearer)\s+[A-Za-z0-9._~+/=-]{8,}',
  caseSensitive: false,
);
final RegExp _skKeyPattern = RegExp(r'\bsk-[A-Za-z0-9_-]{6,}');
final RegExp _keyFieldPattern = RegExp(
  r'''("?(?:api[_-]?key|x-api-key|authorization)"?\s*[:=]\s*"?)([^\s"',}]{8,})''',
  caseSensitive: false,
);
final RegExp _longTokenPattern = RegExp(r'\b[A-Za-z0-9_-]{40,}\b');

/// 上游错误文本的统一脱敏:服务端可能回显请求头或密钥。
///
/// 先按本次请求的 [apiKey] 精确替换(长度足够时),再遮蔽 Bearer 令牌、
/// `sk-` 前缀密钥、`api_key: ...` 形态的字段值与超长 token 串。宁可多遮蔽
/// 诊断文本,也不让密钥进入错误横幅/日志。
String redactSecrets(String text, {String? apiKey}) {
  var out = text;
  if (apiKey != null && apiKey.length >= 4) {
    out = out.replaceAll(apiKey, '***');
  }
  out = out.replaceAllMapped(_bearerPattern, (m) => '${m.group(1)} ***');
  out = out.replaceAll(_skKeyPattern, 'sk-***');
  out = out.replaceAllMapped(_keyFieldPattern, (m) => '${m.group(1)}***');
  out = out.replaceAll(_longTokenPattern, '***');
  return out;
}

/// 从非 2xx 响应体中尽力提取服务端错误类型与消息,供 [classifyUpstreamFailure]
/// 使用。兼容三种形态:OpenAI 扁平 `{"error":{"type","message"}}`、
/// 嵌套 `{"type":"error","error":{...}}`(两者都有 `error` 键,
/// 同一条路径)、裸字符串/纯文本。解析失败返回全 null —— 分类退回状态码。
({String? type, String? message}) extractUpstreamErrorShape(String body) {
  Object? decoded;
  try {
    decoded = body.isEmpty ? null : jsonDecode(body);
  } on FormatException {
    decoded = null;
  }
  if (decoded is! Map) return (type: null, message: null);
  final err = decoded['error'];
  if (err is Map) {
    return (
      type: err['type'] is String ? err['type'] as String : null,
      message: err['message']?.toString(),
    );
  }
  if (err is String && err.isNotEmpty) return (type: null, message: err);
  return (
    type: decoded['type'] is String ? decoded['type'] as String : null,
    message: decoded['message']?.toString(),
  );
}
