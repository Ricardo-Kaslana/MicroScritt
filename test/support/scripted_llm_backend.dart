// 事件脚本化 LLM 后端:按调用序号弹事件脚本(耗尽重复末条),捕获全部请求,
// 可选门控(调用序号 → 发事件前等待的 completer)供取消/冲突交错测试。
// 泛化 orchestrator_test 的 _ScriptedBackend/_GatedBackend 到 LlmEvent 粒度。
import 'dart:async';
import 'package:microscritt/backend/llm_backend.dart';

class ScriptedLlmBackend implements LlmBackend {
  final List<List<LlmEvent>> scripts;
  final Map<int, Completer<void>> gates;

  /// 每次调用发起时通知(调用序号),供冲突/取消测试精确交错,不依赖计时。
  final void Function(int index)? onRequest;
  final List<LlmRequest> requests = [];
  int _calls = 0;

  ScriptedLlmBackend(
    this.scripts, {
    Map<int, Completer<void>>? gates,
    this.onRequest,
  }) : gates = gates ?? {};

  /// 已发起的调用数。
  int get calls => _calls;

  @override
  String get id => 'scripted';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    final index = _calls++;
    requests.add(request);
    onRequest?.call(index);
    final gate = gates[index];
    if (gate != null) await gate.future;
    final script = scripts[index < scripts.length ? index : scripts.length - 1];
    for (final event in script) {
      yield event;
    }
  }
}