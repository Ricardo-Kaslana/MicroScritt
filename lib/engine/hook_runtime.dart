import 'dart:convert';
import '../models/hook.dart';

/// 抽象 JS 求值,隔离 flutter_js 具体 API(测试用 fake)。
abstract class HookRuntime {
  Future<String?> evaluate(String js);
}

/// 按触发点串行执行启用的 hook:把上下文 JSON 注入 `__ctx`,运行 hook 的 js,
/// 读回 `JSON.stringify(__ctx)` 作为新上下文。hook 输出无法解析时保持原上下文。
class HookEngine {
  final HookRuntime runtime;
  HookEngine(this.runtime);

  Future<Map<String, dynamic>> run({
    required HookTriggerPoint point,
    required List<Hook> hooks,
    required Map<String, dynamic> context,
  }) async {
    var ctx = Map<String, dynamic>.from(context);
    for (final hook in hooks) {
      if (!hook.enabled || hook.triggerPoint != point) continue;
      final script = '''
var __ctx = JSON.parse(${jsonEncode(jsonEncode(ctx))});
try {
${hook.jsCode}
} catch (e) {
  __ctx.__hookError = String(e);
}
JSON.stringify(__ctx);
''';
      final result = await runtime.evaluate(script);
      if (result == null) continue;
      try {
        final parsed = jsonDecode(result) as Map<String, dynamic>;
        // Strip internal markers (e.g. __hookError) so they never leak into the
        // context that downstream hooks / the LLM see.
        parsed.removeWhere((key, _) => key.startsWith('__'));
        ctx = Map<String, dynamic>.from(parsed);
      } catch (_) {
        // malformed hook output — keep previous context
      }
    }
    return ctx;
  }
}
