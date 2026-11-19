/// LLM 原生工具调用的中立类型:工具定义与模型发起的调用。
///
/// 放在 models 层,让后端层(`lib/backend`)与引擎层(`lib/engine`)共用同一份
/// 类型而不互相 import;协议细节(OpenAI `tool_calls` / Anthropic `tool_use`)
/// 由各后端在序列化/解析侧消化,这里只描述语义。
library;

/// 一个可供模型调用的工具定义(名称 + 说明 + JSON Schema 参数)。
class LlmTool {
  /// 工具名;模型按它发起调用,宿主按它路由到执行器。
  final String name;

  /// 面向模型的工具用途说明(进请求,影响模型是否/如何调用)。
  final String description;

  /// 参数的 JSON Schema(object 形态);各后端映射为协议的
  /// `parameters`(OpenAI)/ `input_schema`(Anthropic)。
  final Map<String, dynamic> parameters;

  const LlmTool({
    required this.name,
    required this.description,
    required this.parameters,
  });
}

/// 模型发起的一次工具调用。
class ToolCall {
  /// 调用 id;宿主回传工具结果时按它配对(OpenAI `tool_call_id` /
  /// Anthropic `tool_use_id`)。
  final String id;

  /// 被调用的工具名。
  final String name;

  /// 调用参数,**原始 JSON 字符串**(未解码):流式按块拼接而成,可能残缺,
  /// 由消费方 `jsonDecode` 并自行容错。保留原始串而非 Map,让后端无需在
  /// 流式累计阶段强行解析半截 JSON。
  final String arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}