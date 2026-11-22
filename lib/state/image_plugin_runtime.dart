/// 生图插件 JS 的运行期最小校验。
///
/// 配置导入与单插件导入共用同一检查:求值插件代码并确认同步 `step(ctx)`
/// 存在。执行发生在写库前,失败即拒绝导入;引擎不可用的平台由调用方决定
/// 是否允许仅恢复数据。
library;

import '../engine/hook_runtime.dart';
import '../models/image_plugin.dart';

/// 用当前 JS 引擎验证插件代码可求值且定义了同步 `step(ctx)`。
Future<bool> validateImagePluginRuntime(
  HookRuntime runtime,
  ImagePlugin plugin,
) async {
  try {
    final valid = await runtime.evaluate('''
(function() {
${plugin.code}
  return typeof step === "function" ? "ok" : "missing";
})()
''');
    return valid == 'ok';
  } catch (_) {
    return false;
  }
}