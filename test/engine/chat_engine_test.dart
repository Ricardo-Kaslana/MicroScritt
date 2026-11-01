// 主写对话引擎测试:请求为提示词权威、snapshot 只提供纯文本消息数组,
// hook 改写不被快照盖回。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/context/context_assembler.dart';
import 'package:microscritt/engine/chat_engine.dart';
import 'package:microscritt/models/character_card.dart';

class _FakeBackend implements LlmBackend {
  LlmRequest? lastRequest;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    lastRequest = request;
    yield const TextDelta('ok');
    yield const DoneEvent();
  }
}

void main() {
  test('forwards request systemPrompt (hook-rewritable) and snapshot messages', () async {
    final backend = _FakeBackend();
    final engine = ChatEngine(backend);
    final snapshot = ContextAssembler().assemble(
      character: const CharacterCard(name: 'Alice'),
      items: const [],
      history: const [],
    );

    // 请求是提示词的权威来源(afterContextAssembly/beforeGenerate hook 可改写);
    // snapshot 只负责提供纯文本消息数组。
    final events = await engine
        .generate(snapshot, const LlmRequest(model: 'm', systemPrompt: 'REWRITTEN', messages: []))
        .toList();

    expect(events.whereType<TextDelta>().single.text, 'ok');
    expect(backend.lastRequest!.systemPrompt, 'REWRITTEN');
    expect(backend.lastRequest!.messages, snapshot.messages);
    expect(backend.lastRequest!.model, 'm');
    expect(snapshot.systemPrompt, isNot('REWRITTEN')); // snapshot itself untouched
  });
}
