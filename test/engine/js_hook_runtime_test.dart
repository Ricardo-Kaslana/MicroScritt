import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/js_hook_runtime.dart';

/// 真实 QuickJS 沙箱约束(死循环/分配炸弹)—— 修复前 `QuickJsRuntime2()` 无参
/// 构造不装 interrupt handler、不限内存,一段 `while(true){}` 会永久冻死管线。
///
/// flutter test 的宿主进程不一定能加载 quickjs 动态库(Windows CI 常缺
/// quickjs_c_bridge.dll)—— 先探测,库不可用时整体跳过而不是空转假绿。
/// 库可用时,死循环用例有真实墙钟耗时(interrupt handler 约 5s 触发)。
///
/// **跳过判据必须与生产求值同路径**(EL 修):flutter_js 0.8.7 的 Windows
/// bridge DLL 缺 `jsSetMemoryLimit` 符号,带 memoryLimit 的构造抛错 —— 若只用
/// 无参构造探活,三个用例全跑、正常求值却因构造失败静默返回 null,内存炸弹
/// 用例"恰好期望 null"而假绿, hook 全灭的回归就这样漏网。现在每个用例先经
/// [JsHookRuntime.probe] 探活,再按本平台是否启用 memoryLimit 分别断言。
Future<void> main() async {
  // probe 走真实求值,必须 await(async main)。
  final available = await JsHookRuntime.probe() != null;

  // 本平台 bridge 是否支持 jsSetMemoryLimit(直接构造全约束档探测)。
  var memoryLimitSupported = false;
  try {
    QuickJsRuntime2(timeout: 5000, memoryLimit: 1 << 20).dispose();
    memoryLimitSupported = true;
  } catch (_) {
    // Windows 等:仅 timeout 档可用,内存上限不生效。
  }

  test('normal hook script still evaluates on the real runtime', () async {
    final result = await JsHookRuntime().evaluate('1 + 1');
    expect(result, '2');
  }, skip: available ? false : 'quickjs 动态库不可用(宿主环境缺 DLL)');

  test('hook-style script returns the rewritten ctx string', () async {
    // 与生产 HookEngine 同形态的脚本(JSON 往返 + 改写 __ctx):钉住
    // "构造降级后正常 hook 仍生效",不再只测裸算术。
    final result = await JsHookRuntime().evaluate('''
var __ctx = JSON.parse({"userText":"main 测试"}.userText === undefined ? '{}' : '{"userText":"main 测试"}');
var t = String(__ctx.userText == null ? '' : __ctx.userText);
var m = /^(main(?:\\s+([\\s\\S]*))?)\\s*\$/i.exec(t);
if (m) { __ctx.userText = (m[2] || '').trim() + '\\n\\n<main_note>主导模式</main_note>'; }
JSON.stringify(__ctx);
''');
    expect(result, isNotNull);
    expect(result, contains('main_note'));
  }, skip: available ? false : 'quickjs 动态库不可用(宿主环境缺 DLL)');

  test('memory bomb is capped by the QuickJS heap limit, not the process', () async {
    final result = await JsHookRuntime().evaluate('var a=[]; while(1) a.push(1); "done"');
    expect(result, isNull); // 超限抛错 → 按"求值失败"处理,进程无损
  },
      skip: !available
          ? 'quickjs 动态库不可用(宿主环境缺 DLL)'
          : memoryLimitSupported
              ? false
              : '本平台 bridge 缺 jsSetMemoryLimit,内存上限不生效(死循环用例仍覆盖 interrupt handler)');

  test('death-loop script is interrupted instead of hanging forever', () async {
    final sw = Stopwatch()..start();
    final result = await JsHookRuntime().evaluate('while(true){}');
    sw.stop();
    expect(result, isNull);
    // interrupt handler 5s 触发;外层 Dart 竞速 15s 兜底。留 20s 上限防 CI 抖动。
    expect(sw.elapsed.inSeconds, lessThan(20),
        reason: '死循环应在 QuickJS interrupt handler 超时内被打断,而非永久挂起');
  }, skip: available ? false : 'quickjs 动态库不可用(宿主环境缺 DLL)');
}
