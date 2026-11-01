// 生图插件求值引擎选择:QuickJS 优先,不可用时回落 Node;两者皆无则由
// 调用方 markTestSkipped,禁止空转假绿。
import 'package:microscritt/backend/plugin_image_backend.dart';
import 'package:microscritt/engine/js_hook_runtime.dart';

import 'node_js_runtime.dart';

/// 生图插件求值引擎:优先生产同路径的 QuickJS,平台起不来时回落到 Node。
///
/// 两者都不可用时返回 null —— 调用方**必须** `markTestSkipped` 而不是 `return`:
/// 早退的测试会以「通过」的姿态出现在报告里,内置协议 JS 就这样在零覆盖下长期
/// 「全绿」(Windows 上 QuickJS 缺桥接库即为此坑)。
class PluginJsEngine {
  const PluginJsEngine(this.name, this.evaluate, this._dispose);

  /// 引擎名,进用例标题/跳过理由,保证「这次到底跑的哪条实现」可追溯。
  final String name;
  final ImagePluginEvaluator evaluate;
  final void Function() _dispose;

  void dispose() => _dispose();

  @override
  String toString() => name;
}

Future<PluginJsEngine?> probePluginJsEngine() async {
  final quick = await JsHookRuntime.probe();
  if (quick != null) return PluginJsEngine('quickjs', quick.evaluate, () {});
  final node = await NodeJsRuntime.probe();
  if (node == null) return null;
  return PluginJsEngine('node', node.evaluate, node.dispose);
}
