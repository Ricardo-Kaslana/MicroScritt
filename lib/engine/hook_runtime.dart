/// Hook 求值抽象与按触发点串行执行引擎。
///
/// 上下文以 JSON `__ctx` 在 Dart 与脚本之间往返;返回结果剥离 `__` 前缀
/// 内部键,内部错误标记不会泄漏给下游 hook 或 LLM 上下文。
library;

import 'dart:convert';
import '../models/hook.dart';

/// Hook 脚本求值抽象:隔离 flutter_js/QuickJS 的具体 API,测试可注入 fake。
///
/// 实现方负责沙箱与超时;求值失败/超时返回 null,调用方按"本 hook 未生效"
/// 继续执行后续 hook。
abstract class HookRuntime {
  /// 求值一段 JS,返回最后一个表达式的字符串结果;失败返回 null。
  Future<String?> evaluate(String js);
}

/// 按触发点串行执行启用的 hook。
///
/// 每个 hook 把上下文 JSON 注入 `__ctx` 后运行,读回 `JSON.stringify(__ctx)`
/// 作为新上下文;单个 hook 的输出无法解析时保持进入该 hook 前的上下文,
/// 不中断同一触发点上的其余 hook。剥离 `__` 前缀内部键(如 `__hookError`)
/// 是硬约束:内部标记不进入下游 hook,也不会随上下文进入 LLM 请求。
class HookEngine {
  /// 脚本求值器;生产为 QuickJS 适配器,测试用 fake。
  final HookRuntime runtime;
  HookEngine(this.runtime);

  /// 按 [hooks] 列表顺序执行触发点匹配且启用的 hook,返回新上下文。
  ///
  /// 串行是硬约束:后一个 hook 必须看到前一个 hook 的产出,不能并发执行;
  /// 任一 hook 失败(求值 null/输出不可解析)时保留当时的上下文继续,
  /// 整轮不会因单个脚本出错而放弃。
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
        // 剥离内部标记(如 __hookError),避免泄漏给下游 hook 或 LLM 上下文。
        parsed.removeWhere((key, _) => key.startsWith('__'));
        ctx = Map<String, dynamic>.from(parsed);
      } catch (_) {
        // 输出畸形:保留进入本 hook 前的上下文,继续下一个 hook。
      }
    }
    return ctx;
  }
}
