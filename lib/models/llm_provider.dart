/// LLM 后端按 provider 分组的配置模型。
///
/// 设计目标:每个 provider 是一份独立配置(Provider ID/显示名/API 地址/协议/密钥),
/// 其下挂一个**模型目录**(每个模型:模型 id / 展示名 / 上下文容量 / 最大输出)。
/// 这与旧的单行 `BackendConfig` 不同 —— 后者只描述"当前在用的那一个模型"。
/// 运行链路仍消费 `BackendConfig`(见 `loadBackendConfig`),但设置入口管理的是
/// 下面这份多值数据。
library;

import 'dart:convert';

import 'endpoint_compat.dart';

/// API 协议。决定用哪套 wire(factory 据此路由到具体后端实现)。
///
/// - `openaiCompat`:OpenAI 兼容(`{base}/chat/completions` + `Authorization: Bearer`)。
/// - `anthropic`:Anthropic Messages(`{base}/v1/messages` + `x-api-key`)。
enum LlmProtocol {
  openaiCompat,
  anthropic;

  /// 从 wire(库内存储字符串)解析;未知协议回退 openaiCompat。
  static LlmProtocol fromWire(String s) {
    switch (s) {
      case 'anthropic':
        return LlmProtocol.anthropic;
      default:
        return LlmProtocol.openaiCompat;
    }
  }
}

/// [LlmProtocol] 的落库字面值与界面标签。
extension LlmProtocolX on LlmProtocol {
  /// 落库/传输用字面值;openaiCompat 存为 `openai`(历史值)。
  String get wire => switch (this) {
    LlmProtocol.openaiCompat => 'openai',
    LlmProtocol.anthropic => 'anthropic',
  };

  /// 面向 UI 的中文标签。
  String get label => switch (this) {
    LlmProtocol.openaiCompat => 'OpenAI 兼容',
    LlmProtocol.anthropic => 'Anthropic',
  };
}

/// 一个 provider 下的模型条目(模型目录中的一项)。
class LlmModelEntry {
  /// 库内自增 id;0 表示尚未落库。
  final int id;

  /// 所属 provider 的库内 id。
  final int providerId;

  /// 发送给 API 的模型标识(如 `deepseek-chat`)。
  final String modelId;

  /// 设置页展示名;空时回退 [modelId]。
  final String displayName;

  /// 上下文容量(tokens),用于压缩阈值与用量占比。
  final int contextCapacity;

  /// 最大输出 tokens;空表示用后端/协议默认值。
  final int? maxOutput;

  /// 采样温度(0–2);空表示用主写引擎默认值(0.7)。
  final double? temperature;

  /// 是否为该 provider 当前选中的模型。
  final bool isActive;

  /// 模型目录排序位(升序)。
  final int position;

  const LlmModelEntry({
    required this.id,
    required this.providerId,
    required this.modelId,
    required this.displayName,
    required this.contextCapacity,
    this.maxOutput,
    this.temperature,
    this.isActive = false,
    this.position = 0,
  });

  LlmModelEntry copyWith({
    int? id,
    int? providerId,
    String? modelId,
    String? displayName,
    int? contextCapacity,
    int? Function()? maxOutput,
    double? Function()? temperature,
    bool? isActive,
    int? position,
  }) => LlmModelEntry(
    id: id ?? this.id,
    providerId: providerId ?? this.providerId,
    modelId: modelId ?? this.modelId,
    displayName: displayName ?? this.displayName,
    contextCapacity: contextCapacity ?? this.contextCapacity,
    maxOutput: maxOutput != null ? maxOutput() : this.maxOutput,
    temperature: temperature != null ? temperature() : this.temperature,
    isActive: isActive ?? this.isActive,
    position: position ?? this.position,
  );
}

/// 一个 LLM provider(带其模型目录)。
class LlmProviderConfig {
  /// 库内自增 id;0 表示尚未落库。
  final int id;

  /// 逻辑/路由标识,同一库内唯一(如 `deepseek`、`my-proxy`)。
  final String providerId;

  /// 设置页显示名。
  final String displayName;

  /// API 根地址(不含 `/chat/completions` 等路径后缀)。
  final String baseUrl;

  /// API 协议,决定请求/响应编码与鉴权头。
  final LlmProtocol protocol;

  /// API Key;明文保存在库与配置文件中,不做加密。
  final String apiKey;

  /// 是否当前在用的 provider;同一时刻至多一行为 true。
  final bool isActive;

  /// 列表排序位(升序)。
  final int position;

  /// 模型目录(有序);空目录时无法发起请求。
  final List<LlmModelEntry> models;

  /// 随请求附加的自定义头(键已归一化小写)。
  /// 用于少数网关要求 Origin/Referer/User-Agent 等放行头的场景。
  final Map<String, String> extraHeaders;

  /// 官方 OpenAI 参数风格(v47):开启后 OpenAI 兼容后端改发
  /// `max_completion_tokens`(o 系列等推理模型只认它,`max_tokens` 直接 400)
  /// 并携带 `stream_options: {include_usage: true}`(官方端点流式默认不带
  /// usage,不开则用量统计恒为零)。部分劣质网关会对未知字段回 400,故默认
  /// 关闭、由用户按端点显式开启。
  final bool modernParams;

  /// 端点兼容选项:replyViaTool(回复经工具参数通道输出)/ noncePrefix
  /// (提示词随机前缀,使每轮请求字节不同)。按 provider 声明式配置,怪癖
  /// 只进配置不焊代码路径 —— 上游契约变更时在设置页开关,不改源码发版。
  final EndpointCompat compat;

  const LlmProviderConfig({
    required this.id,
    required this.providerId,
    required this.displayName,
    required this.baseUrl,
    required this.protocol,
    required this.apiKey,
    this.isActive = false,
    this.position = 0,
    this.models = const [],
    this.extraHeaders = const {},
    this.modernParams = false,
    this.compat = EndpointCompat.standard,
  });

  /// 当前选中的模型;目录空或没有选中项时取第一个。
  LlmModelEntry? get activeModel {
    for (final m in models) {
      if (m.isActive) return m;
    }
    return models.isEmpty ? null : models.first;
  }

  LlmProviderConfig copyWith({
    int? id,
    String? providerId,
    String? displayName,
    String? baseUrl,
    LlmProtocol? protocol,
    String? apiKey,
    bool? isActive,
    int? position,
    List<LlmModelEntry>? models,
    Map<String, String>? extraHeaders,
    bool? modernParams,
    EndpointCompat? compat,
  }) => LlmProviderConfig(
    id: id ?? this.id,
    providerId: providerId ?? this.providerId,
    displayName: displayName ?? this.displayName,
    baseUrl: baseUrl ?? this.baseUrl,
    protocol: protocol ?? this.protocol,
    apiKey: apiKey ?? this.apiKey,
    isActive: isActive ?? this.isActive,
    position: position ?? this.position,
    models: models ?? this.models,
    extraHeaders: extraHeaders ?? this.extraHeaders,
    modernParams: modernParams ?? this.modernParams,
    compat: compat ?? this.compat,
  );

  /// 自定义请求头归一化:键 trim + 小写(dart:io 发送时本就不区分大小写,
  /// 归一化让「Origin/origin」不会在 map 里并存成两个键),值仅 trim(保留
  /// 大小写 —— UA 等值大小写敏感)。空键条目丢弃;空值保留(个别网关要求
  /// 显式发送空值头)。
  static Map<String, String> normalizeExtraHeaders(Map<String, String> raw) => {
    for (final e in raw.entries)
      if (e.key.trim().isNotEmpty) e.key.trim().toLowerCase(): e.value.trim(),
  };

  /// 编码为落库 JSON 文本(键已归一化)。空 map 存空串,与列默认值一致,
  /// 老行(默认 '')与「用户清空全部配置」不可区分也无需区分。
  static String extraHeadersWire(Map<String, String> headers) {
    final normalized = normalizeExtraHeaders(headers);
    return normalized.isEmpty ? '' : jsonEncode(normalized);
  }

  /// 从库中 JSON 文本解析。空串(老行默认值)返回空 map;坏 JSON/非对象/
  /// 非字符串值一律跳过或回退空 map —— 损坏的配置不应挡住整个 provider 加载。
  static Map<String, String> extraHeadersFromWire(String? wire) {
    if (wire == null || wire.isEmpty) return const {};
    try {
      final decoded = jsonDecode(wire);
      if (decoded is! Map) return const {};
      return normalizeExtraHeaders({
        for (final e in decoded.entries)
          if (e.value is String) e.key as String: e.value as String,
      });
    } on FormatException {
      return const {};
    }
  }
}
