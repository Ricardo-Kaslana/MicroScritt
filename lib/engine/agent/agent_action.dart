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
///
/// 无参工具的空参数是常见网关行为(`""`/纯空白/字面 `null`),统一归一为
/// 空对象而不是判非法:否则连续三次空参调用就会触发非法连击护栏、丢掉
/// 整轮暂存。只有**非空畸形** JSON 才判非法。
Map<String, Object?>? decodeToolArguments(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const {};
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, Object?>) return decoded;
    // 字面 null 与空参数等价;其他非对象(数组/标量)仍是非法调用。
    if (decoded == null) return const {};
  } on FormatException {
    // 落入 null:非法参数。
  }
  return null;
}