import '../models/endpoint_compat.dart';

enum BackendProvider { openai, anthropic }

class BackendConfig {
  final BackendProvider provider;
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final int? maxTokens;

  /// 随请求附加的自定义请求头(来自 provider 配置,键为小写)。部分兼容网关
  /// 按请求头放行(校验 Origin/Referer/User-Agent 等),后端合并时用户值覆盖
  /// 内置默认头(含 Authorization —— 个别网关要求 key 走别的头名)。
  final Map<String, String> extraHeaders;

  /// 官方 OpenAI 参数风格(来自 provider 配置,v47):改发
  /// `max_completion_tokens` + `stream_options: {include_usage: true}`。
  /// 见 `LlmProviderConfig.modernParams` 的取舍说明。
  final bool modernParams;

  /// 端点兼容选项(来自 provider 配置):replyViaTool(回复经工具参数通道)/
  /// noncePrefix(提示词随机前缀),由后端在发送/解析侧消化,调用方零感知。
  final EndpointCompat compat;

  const BackendConfig({
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.7,
    this.maxTokens,
    this.extraHeaders = const {},
    this.modernParams = false,
    this.compat = EndpointCompat.standard,
  });

  String get providerWire => provider.name;

  static BackendProvider providerFrom(String s) => BackendProvider.values.firstWhere((p) => p.name == s);
}
