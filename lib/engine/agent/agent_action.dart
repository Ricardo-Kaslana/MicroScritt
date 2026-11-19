/// 工具调用解析:finish 判定与 arguments 解码。arguments 是原始 JSON 串
/// (后端不解释语义),解码失败/非对象一律判非法,由 runner 回喂纠错。
library;

import 'dart:convert';
import '../../models/llm_tool.dart';
import 'agent_tool.dart';

/// 内核内置的结束工具:可带一句摘要;runner 追加进每步请求的工具面。
const LlmTool kFinishTool = LlmTool(
  name: kFinishToolName,
  description:
      'End the maintenance run and commit all staged changes. Call this when the state board '
      'reflects the conversation delta. Optionally include a one-sentence summary.',
  parameters: {
    'type': 'object',
    'properties': {
      'summary': {'type': 'string', 'description': 'Optional one-sentence summary of this run.'},
    },
  },
);

/// 解码工具 arguments:必须是合法 JSON 对象,否则 null(非法调用)。
/// 残缺 JSON 不做修复 —— 修复是 legacy 单发解析的兜底,agent 有回喂自纠
/// 通道,畸形参数直接报错让模型重发更可靠。
Map<String, Object?>? decodeToolArguments(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // 落入 null:非法参数。
  }
  return null;
}