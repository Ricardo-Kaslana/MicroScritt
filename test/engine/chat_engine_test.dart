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

    // The request is authoritative for the prompt (allow afterContextAssembly
    // / beforeGenerate hooks to rewrite it); the snapshot only supplies the
    // pure-text message array.
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
