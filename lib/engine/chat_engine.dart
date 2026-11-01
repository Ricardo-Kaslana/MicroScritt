/// 主写对话引擎:把一个 [ContextSnapshot] 翻译成单次 LLM 请求并流式返回。
///
/// 后台维护走 `BackgroundEngine`/`Orchestrator`,不复用这条路径;主写是
/// 唯一产出对话回复的生成路径。
library;

import '../backend/llm_backend.dart';
import '../models/context_snapshot.dart';

/// 主写引擎:无状态转发,不重试、不落库;取消与消息写入由控制器负责。
class ChatEngine {
  /// 底层 LLM 后端;每次 [generate] 都直接委托给它。
  final LlmBackend backend;
  ChatEngine(this.backend);

  /// 以 [request] 为权威参数、[snapshot] 为消息数组发起一次流式生成。
  ///
  /// `systemPrompt`/`temperature`/`maxTokens` 可被 hook 改写,只能读
  /// [request];[snapshot] 只提供纯文本消息数组,绝不把
  /// `snapshot.systemPrompt` 盖回 [request],否则 hook 的改写会被静默丢弃。
  Stream<LlmEvent> generate(ContextSnapshot snapshot, LlmRequest request) {
    return backend.generate(LlmRequest(
      model: request.model,
      systemPrompt: request.systemPrompt,
      messages: snapshot.messages,
      temperature: request.temperature,
      maxTokens: request.maxTokens,
      reasoningLevel: request.reasoningLevel,
      cacheContext: request.cacheContext,
      cacheMessageBreakpoint: request.cacheMessageBreakpoint,
      stableSystemPart: request.stableSystemPart,
      variableSystemPart: request.variableSystemPart,
    ));
  }
}
