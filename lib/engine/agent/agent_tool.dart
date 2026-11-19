/// agent 工具定义与注册表:执行器是闭包,内核不认识变量/生图/数据库。
/// profile 把业务校验与暂存操作封进执行器,内核只负责调度与回喂。
library;

import '../../models/llm_tool.dart';

/// finish 是内核保留工具名:注册表拒收,runner 自动追加进请求工具面。
const String kFinishToolName = 'finish';

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
  const AgentTool({required this.tool, required this.execute});
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