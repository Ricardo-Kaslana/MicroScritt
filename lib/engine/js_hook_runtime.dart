/// flutter_js/QuickJS 的 `HookRuntime` 实现。
///
/// 求值在独立 isolate 中执行,UI 线程不阻塞;用户脚本受超时与内存上限约束,
/// 超时、内存爆掉或引擎缺失一律按 hook 失败返回 null,发送管线继续。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_js/flutter_js.dart';
import 'hook_runtime.dart';

/// flutter_js 适配器,求值在**工作 isolate** 中执行,UI 线程永不阻塞于 QuickJS。
///
/// flutter_js 的 runtime 对象不能跨 isolate 发送,因此每次求值在 isolate 内
/// 新建一个 `QuickJsRuntime2`(求值后立即 dispose)。Hook 每轮只触发几次,
/// 每次新建 runtime 的开销可接受;若极端平台无法派生 isolate(Isolate.run 抛错),
/// 回退到同步求值,保证 hook 功能不丢(代价是那个平台重新阻塞 UI —— 但同样
/// 受超时/内存上限约束,最坏阻塞 [jsTimeout] 而非永久卡死)。
///
/// **沙箱约束**:runtime 安装了 interrupt handler 与(可用时的)内存上限 ——
/// 用户脚本写死循环会在 [jsTimeout] 内被打断,分配炸弹(如 `while(1)a.push(1)`)
/// 在 [_jsMemoryLimit] 处抛错;两种情况都按"hook 求值失败"返回 null,管线继续,
/// 绝不让一段脚本永久冻死发送管线或打穿进程内存。外层竞速超时意味着 isolate
/// 只能被放弃而不能强杀:记录该超时并熔断 [circuitCooldown],冷却期内的后续
/// 求值直接短路,避免每次 hook 触发都泄漏一个新 isolate。
///
/// **平台能力降级**:flutter_js 0.8.7 的 Windows bridge DLL 不导出
/// `jsSetMemoryLimit` 符号 —— 带 memoryLimit 的构造在 Windows 上直接抛
/// "Failed to lookup symbol",而求值路径把它静默吞成 null,表现为**所有 hook
/// (main/jump 输入改写等)静默失效**。因此构造分两档:全约束档失败时回退
/// 仅 timeout 档(死循环保护仍在 —— interrupt handler 走的是 `jsSetMaxStackSize`
/// 一路的信号机制,不受缺符号影响);仅 timeout 也失败才是引擎真不可用。
/// [probe] 用同一判定供 main.dart 启动探测与测试跳过判据复用,三者永不分叉。
class JsHookRuntime implements HookRuntime {
  JsHookRuntime({
    this.jsTimeout = defaultJsTimeout,
    Duration? outerTimeout,
    this.circuitCooldown = defaultCircuitCooldown,
  }) : outerTimeout = outerTimeout ?? jsTimeout * 3;

  /// QuickJS interrupt handler 超时。Hook 都是改写上下文的小脚本,5 秒远超
  /// 正常耗时;外层 Dart 竞速再留 3 倍余量兜底 FFI 边界异常。
  static const Duration defaultJsTimeout = Duration(milliseconds: 5000);

  /// 超时熔断冷却窗口:一旦外层竞速超时(interrupt handler 未能收敛的极端
  /// 边界),这段时间内所有求值立即按失败返回,不再每次 hook 触发都派生并
  /// 放弃一个新 isolate。冷却结束后放行一次探测,成功即恢复。
  static const Duration defaultCircuitCooldown = Duration(seconds: 60);

  final Duration jsTimeout;
  final Duration outerTimeout;
  final Duration circuitCooldown;

  /// QuickJS 堆内存上限(字节)。角色卡级文本处理给 16MB 足够宽裕,
  /// 同时拦住分配炸弹。
  static const int _jsMemoryLimit = 16 * 1024 * 1024;

  DateTime? _circuitOpenUntil;

  /// 测试探针:当前是否处于熔断冷却期。
  @visibleForTesting
  bool get debugCircuitOpen => _circuitOpen();

  /// 测试探针:手动打开熔断(真实路径由外层竞速超时触发)。
  @visibleForTesting
  void debugTripCircuit() => _tripCircuit();

  bool _circuitOpen() {
    final until = _circuitOpenUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _circuitOpenUntil = null; // 冷却结束:放行下一次探测。
    return false;
  }

  void _tripCircuit() {
    _circuitOpenUntil = DateTime.now().add(circuitCooldown);
  }

  /// 引擎可用性探测(与 [evaluate] 走同一条求值路径):真的求值一次 `1+1`,
  /// null = 连仅 timeout 档都构造失败(缺 DLL 等),hook 应整体置为 inert;
  /// 非 null = hook 可用。注意不能用"只构造 runtime 探活"—— 构造器本身不做
  /// 求值,检测不出缺 DLL/缺符号的平台。
  static Future<JsHookRuntime?> probe() async {
    final runtime = JsHookRuntime();
    final ok = await runtime.evaluate('1 + 1') != null;
    return ok ? runtime : null;
  }

  /// 求值一次 hook 脚本:优先在 isolate 中执行,并叠加 3 倍 [jsTimeout]
  /// 的 Dart 竞速超时兜底;isolate 不可用时回退同步求值。
  ///
  /// 返回 null 表示超时、脚本报错、熔断中或引擎缺失;调用方一律按"本 hook
  /// 未生效"处理,求值失败绝不炸掉发送管线。外层超时会打开熔断,冷却期内
  /// 直接短路,避免极端脚本把 isolate 泄漏变成每次 hook 调用都复发的慢性泄漏。
  @override
  Future<String?> evaluate(String js) async {
    if (_circuitOpen()) return null;
    final timeoutMs = jsTimeout.inMilliseconds;
    try {
      // Isolate.run 需要可发送的闭包:只捕获字符串与整数,不捕获 this。
      // 竞速超时兜底:interrupt handler 万一没触发(如卡在 FFI 内部),
      // 也不让调用方永久等待。
      return await Isolate.run(() => _evaluateSync(js, timeoutMs))
          .timeout(outerTimeout);
    } on TimeoutException {
      // 兜底超时:脚本疑似卡死在 interrupt handler 覆盖不到的边界。被放弃
      // 的 isolate 仍可能存活到自身超时,记录并熔断一个冷却窗口;不再同步
      // 重跑 —— 同一段脚本大概率同样卡死,只是换个线程冻结 UI。
      _tripCircuit();
      return null;
    } catch (_) {
      // isolate 不可用(如个别 web 环境)→ 同步回退,保持 hook 可用
      // (回退路径同样受 [jsTimeout]/[_jsMemoryLimit] 约束,最坏阻塞 5s)。
      return _evaluateSync(js, timeoutMs);
    }
  }

  static String? _evaluateSync(String js, int timeoutMs) {
    // 全约束档优先;本平台 bridge 缺 jsSetMemoryLimit 符号时(如 Windows 的
    // flutter_js 0.8.7)回退仅 timeout 档 —— 构造失败绝不能吞成"求值失败",
    // 那会把所有 hook 静默变 inert。
    try {
      return _evaluateWith(QuickJsRuntime2(timeout: timeoutMs, memoryLimit: _jsMemoryLimit), js);
    } catch (_) {
      try {
        return _evaluateWith(QuickJsRuntime2(timeout: timeoutMs), js);
      } catch (_) {
        return null; // 连仅 timeout 档都构造失败 = 引擎真不可用。
      }
    }
  }

  static String? _evaluateWith(QuickJsRuntime2 runtime, String js) {
    try {
      final result = runtime.evaluate(js);
      if (result.isError) return null;
      return result.stringResult;
    } finally {
      runtime.dispose();
    }
  }
}
