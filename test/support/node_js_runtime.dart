import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:microscritt/backend/plugin_image_backend.dart';

/// 用 Node(V8)实现生图宿主的 [ImagePluginEvaluator],让内置协议插件的 JS 在
/// `flutter test` 里**真的被执行**。
///
/// 为什么需要它:生产沙箱是 flutter_js/QuickJS,而它的原生桥接库在测试宿主里
/// 不一定可加载(Windows 上 `JsHookRuntime.probe()` 返回 null)。若测试按
/// 「probe 失败就 return」写,整份种子 JS 就是**零执行假绿** —— 超时裁剪、轮询
/// 节奏、字段消毒这类回归全靠肉眼读 JS,漏掉的代价由用户在真机上付。宿主的 JS
/// 契约只用 ES5(var/function/JSON/正则),QuickJS 与 V8 语义一致,用 node 执行
/// 同样能钉住行为;node 也不可用时调用方必须 `markTestSkipped`,让「没跑到」在
/// 报告里显式可见,而不是冒充通过。
class NodeJsRuntime {
  final Directory _dir;
  int _seq = 0;

  NodeJsRuntime._(this._dir);

  /// 探测并返回可用求值器;node 不在 PATH 时返回 null。
  static Future<NodeJsRuntime?> probe() async {
    try {
      final result = await Process.run('node', <String>['--version']);
      if (result.exitCode != 0) return null;
    } on ProcessException {
      return null;
    }
    return NodeJsRuntime._(Directory.systemTemp.createTempSync('microscritt_node_js_'));
  }

  /// 宿主交给求值器的脚本是一个返回 JSON 字符串的 IIFE;把它的值写到 stdout 即
  /// 是本方法要返回的串。求值异常/超时按契约返回 null(与 QuickJS 路径同语义)。
  Future<String?> evaluate(String js) async {
    Process? process;
    try {
      final file = File('${_dir.path}/step_${_seq++}.js');
      await file.writeAsString('process.stdout.write(String($js));');
      process = await Process.start('node', <String>[file.path]);
      // 必须按 UTF-8 解码:node 的 stdout 恒是 UTF-8,而 systemEncoding 在中文
      // Windows 上是 GBK —— 种子 JS 返回的动作里就带着「提示词:」这类中文,
      // 用错编码等于把每个用例都变成乱码假失败。
      final out = process.stdout.transform(utf8.decoder).join();
      final err = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(const Duration(seconds: 20));
      final text = await out.timeout(const Duration(seconds: 5));
      await err.timeout(const Duration(seconds: 5));
      if (code != 0) return null;
      return text;
    } on TimeoutException {
      process?.kill();
      return null;
    } catch (_) {
      process?.kill();
      return null;
    }
  }

  void dispose() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录删不掉不影响测试结论。
    }
  }
}
