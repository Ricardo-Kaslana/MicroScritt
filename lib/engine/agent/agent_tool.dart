/// agent 工具定义与注册表:执行器是闭包,内核不认识变量/生图/数据库。
/// profile 把业务校验与暂存操作封进执行器,内核只负责调度与回喂。
library;

import 'dart:convert';

import '../../models/llm_tool.dart';

/// finish 是内核保留工具名:注册表拒收,runner 自动追加进请求工具面。
const String kFinishToolName = 'finish';

/// 工具结果 JSON 预算(字符)。必须低于内核硬帽 4000
/// (`AgentRunner.maxToolResultChars`):所有返回 JSON 的工具在正常路径下
/// 都应把编码长度压在此预算内,给模型回喂留出余量,绝不让合法 JSON 被截成
/// 半截。内核硬截断只保留为兜底,正常路径不应触发。
const int kToolResultBudget = 3900;

/// 截断终点不拆代理对,避免产出半个 emoji/生僻字。
int safeStringEnd(String text, int end) {
  if (end <= 0 || end >= text.length) return end;
  final unit = text.codeUnitAt(end - 1);
  return unit >= 0xD800 && unit <= 0xDBFF ? end - 1 : end;
}

/// 分页起点不落在低位代理上,避免产生半个字符。
int safeStringStart(String text, int offset) {
  if (offset <= 0 || offset >= text.length) return offset;
  final unit = text.codeUnitAt(offset);
  return unit >= 0xDC00 && unit <= 0xDFFF ? offset - 1 : offset;
}

/// 结构安全的 JSON 编码:反复调用 [shrink](当前超出预算的字符数)收缩负载,
/// 直到编码长度回到 [kToolResultBudget] 内。[shrink] 每次必须真正减少内容,
/// 返回 false 表示已无字段可裁,此时返回当前编码交内核硬截断兜底。
String encodeToolResultWithinBudget(
  Map<String, Object?> Function() build,
  bool Function(int excess) shrink,
) {
  var json = jsonEncode(build());
  // 步数帽只防收缩器写错时死循环;正常实现一次收缩就接近预算。
  for (var i = 0; i < 256 && json.length > kToolResultBudget; i++) {
    if (!shrink(json.length - kToolResultBudget)) break;
    json = jsonEncode(build());
  }
  return json;
}

/// 执行器返回字符串 = tool_result 文本。**语义拒绝**(readonly/超限/键不存在)
/// 也走返回:那是合法工具调用,错误文本回喂让模型自纠,不计非法连击。
typedef AgentToolExecutor = Future<String> Function(Map<String, Object?> args);

/// 执行器抛出 = **坏参数**(schema 违规:非对象/缺字段/类型错):计入非法
/// 连击,与未知工具/纯 prose 同级。语义拒绝与坏参数的划分是护栏语义的
/// 关键:三次 readonly 尝试应永远自纠,三次畸形调用才终止整轮。
class AgentToolFailure implements Exception {
  final String message;
  const AgentToolFailure(this.message);

  @override
  String toString() => message;
}

/// 一个已注册工具:中立定义 + 闭包执行器。
class AgentTool {
  final LlmTool tool;
  final AgentToolExecutor execute;

  /// 纯读工具:同一 run 内结果只取决于不可变历史,内核可对同参重复调用
  /// 回喂短占位而不重复执行。暂存态/写工具必须置 false —— 它们的输出随
  /// 之前的写动作变化,去重会回喂过期结果。
  final bool pure;
  const AgentTool({
    required this.tool,
    required this.execute,
    this.pure = false,
  });
}

/// 工具注册表:按名查找,definitions 供请求工具面(finish 由 runner 追加)。
class AgentToolRegistry {
  final Map<String, AgentTool> _tools = {};

  void register(AgentTool tool) {
    final name = tool.tool.name;
    if (name == kFinishToolName) {
      throw ArgumentError.value(name, 'tool.name', 'finish 是内核保留工具');
    }
    _tools[name] = tool;
  }

  AgentTool? lookup(String name) => _tools[name];

  List<LlmTool> get definitions => [for (final t in _tools.values) t.tool];
}
