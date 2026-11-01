import '../backend/llm_backend.dart';
import '../models/context_snapshot.dart';

/// P1 单写引擎:把上下文快照翻译成一次 LLM 请求并流式返回。
/// P3 将在此之上扩展双写引擎 + 编排器。
class ChatEngine {
  final LlmBackend backend;
  ChatEngine(this.backend);

  /// request 是权威来源(systemPrompt/temperature/maxTokens 可被
  /// afterContextAssembly/beforeGenerate hook 改写);snapshot 只提供
  /// 纯文本消息数组。绝不把 snapshot.systemPrompt 盖回 request。
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
