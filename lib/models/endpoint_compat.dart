import 'dart:convert';

/// Provider 级「端点兼容选项」。
///
/// 个别端点/网关的契约怪癖只能**按 provider 声明式配置**,不能焊进请求路径
/// ——怪癖可叠加,用**可组合的布尔位**而非大枚举(modernParams 同款先例):
/// 新怪癖 = 新增一位,不改既有行为。
///
/// 两位皆为通用请求整形,不针对任何特定服务:
/// - [replyViaTool]:个别端点对普通正文流式截断/丢块,但工具调用参数能完整
///   送达;开启后整条回复改经工具参数的 JSON content 字符串输出,零正文
///   空回自动重试(至多 3 次尝试)。
/// - [noncePrefix]:每次请求在 system 提示词头部前置 6–8 位随机字符,使每轮
///   请求字节不同;只在端点明确需要时开启,并请确认符合所配置服务的条款。
///   只改请求字节,不改落库、不改界面显示。
///
/// 落库为 `llm_providers.compat_flags` JSON 文本(`''` = 全关,与列默认值
/// 一致);解析 **fail-safe**:坏 JSON / 非对象 / 未知字段一律忽略回落默认
/// —— 该列随 provider 行在启动时水合,脏值抛错会炸掉整个启动(与
/// `extra_headers` 同一条家规)。旧版本写入的未知键同样按未知字段忽略。
class EndpointCompat {
  /// 工具通道回复:整条回复改经 output_reply 工具参数输出。anthropic
  /// 后端不消费此开关。
  final bool replyViaTool;

  /// 提示词随机前缀:每请求在 system 头部前置随机字符。
  final bool noncePrefix;

  const EndpointCompat({
    this.replyViaTool = false,
    this.noncePrefix = false,
  });

  static const EndpointCompat standard = EndpointCompat();

  bool get isStandard => !replyViaTool && !noncePrefix;

  EndpointCompat copyWith({bool? replyViaTool, bool? noncePrefix}) =>
      EndpointCompat(
        replyViaTool: replyViaTool ?? this.replyViaTool,
        noncePrefix: noncePrefix ?? this.noncePrefix,
      );

  /// 编码为落库 JSON 文本;全关存空串(与列 DEFAULT '' 一致,老行与
  /// 「用户关掉全部开关」不可区分也无需区分)。
  String toWire() {
    final flags = <String, dynamic>{
      if (replyViaTool) 'replyViaTool': true,
      if (noncePrefix) 'noncePrefix': true,
    };
    return flags.isEmpty ? '' : jsonEncode(flags);
  }

  static EndpointCompat fromWire(String? wire) {
    if (wire == null || wire.isEmpty) return standard;
    try {
      final decoded = jsonDecode(wire);
      if (decoded is! Map) return standard;
      return EndpointCompat(
        replyViaTool: decoded['replyViaTool'] == true,
        noncePrefix: decoded['noncePrefix'] == true,
      );
    } on FormatException {
      return standard;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is EndpointCompat &&
      other.replyViaTool == replyViaTool &&
      other.noncePrefix == noncePrefix;

  @override
  int get hashCode => Object.hash(replyViaTool, noncePrefix);

  @override
  String toString() =>
      'EndpointCompat(replyViaTool: $replyViaTool, noncePrefix: $noncePrefix)';
}
