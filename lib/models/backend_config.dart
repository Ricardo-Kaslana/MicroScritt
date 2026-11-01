/// 运行链路消费的单模型后端配置。
///
/// 由 provider 配置映射而来(取当前 provider 的当前模型),只描述一次
/// 请求需要的协议、地址、凭据与参数;不感知 provider 目录的多行管理。
/// 放在 models 层,让持久化层(`lib/data`)与后端层(`lib/backend`)共用
/// 同一份中立类型而不互相 import。
library;

import 'endpoint_compat.dart';

/// API 协议;决定工厂创建哪个后端实现。
enum BackendProvider { openai, anthropic }

/// 一次 LLM 请求的后端配置(不可变)。
class BackendConfig {
  /// 协议实现。
  final BackendProvider provider;

  /// API 根地址(不带协议路径后缀)。
  final String baseUrl;

  /// API Key;明文保存在调用方配置中。
  final String apiKey;

  /// 模型标识,直接发送给 API。
  final String model;

  /// 采样温度。
  final double temperature;

  /// 最大输出 tokens;null 表示由协议默认值决定。
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

  /// provider 的落库字面值。
  String get providerWire => provider.name;

  /// 从落库字面值解析;未知值会抛错,调用方必须先做 fail-safe 校验。
  static BackendProvider providerFrom(String s) => BackendProvider.values.firstWhere((p) => p.name == s);
}
