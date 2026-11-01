import 'dart:async';
import 'dart:isolate';

import 'package:flutter_js/flutter_js.dart';
import 'hook_runtime.dart';

/// flutter_js 适配器,求值在**工作 isolate** 中执行,UI 线程永不阻塞于 QuickJS。
///
/// flutter_js 的 runtime 对象不能跨 isolate 发送,因此每次求值在 isolate 内
/// 新建一个 `QuickJsRuntime2`(求值后立即 dispose)。Hook 每轮只触发几次,
/// 每次新建 runtime 的开销可接受;若极端平台无法派生 isolate(Isolate.run 抛错),
/// 回退到同步求值,保证 hook 功能不丢(代价是那个平台重新阻塞 UI —— 但同样
/// 受超时/内存上限约束,最坏阻塞 [_jsTimeout] 而非永久卡死)。
///
/// **沙箱约束**:runtime 安装了 interrupt handler 与(可用时的)内存上限 ——
/// 用户脚本写死循环会在 [_jsTimeout] 内被打断,分配炸弹(如 `while(1)a.push(1)`)
/// 在 [_jsMemoryLimit] 处抛错;两种情况都按"hook 求值失败"返回 null,管线继续,
/// 绝不让一段脚本永久冻死发送管线或打穿进程内存。
///
/// **平台能力降级**(EL 修):flutter_js 0.8.7 的 Windows bridge DLL 不导出
/// `jsSetMemoryLimit` 符号 —— 带 memoryLimit 的构造在 Windows 上直接抛
/// "Failed to lookup symbol",而求值路径把它静默吞成 null,表现为**所有 hook
/// (main/jump 输入改写等)静默失效**。因此构造分两档:全约束档失败时回退
/// 仅 timeout 档(死循环保护仍在 —— interrupt handler 走的是 `jsSetMaxStackSize`
/// 一路的信号机制,不受缺符号影响);仅 timeout 也失败才是引擎真不可用。
/// [probe] 用同一判定供 main.dart 启动探测与测试跳过判据复用,三者永不分叉。
class JsHookRuntime implements HookRuntime {
  const JsHookRuntime();

  /// QuickJS interrupt handler 超时(毫秒)。Hook 都是改写上下文的小脚本,
  /// 5 秒远超正常耗时;外层 Dart 竞速再留 3 倍余量兜底 FFI 边界异常。
  static const int _jsTimeout = 5000;

  /// QuickJS 堆内存上限(字节)。角色卡级文本处理给 16MB 足够宽裕,
  /// 同时拦住分配炸弹。
  static const int _jsMemoryLimit = 16 * 1024 * 1024;

  /// 引擎可用性探测(与 [evaluate] 走同一条求值路径):真的求值一次 `1+1`,
  /// null = 连仅 timeout 档都构造失败(缺 DLL 等),hook 应整体置为 inert;
  /// 非 null = hook 可用。注意不能用"构造一个 runtime 探活"—— const 构造器
  /// 不做任何 FFI 工作、永不抛,检测不出缺 DLL/缺符号的平台。
  static Future<JsHookRuntime?> probe() async {
    final ok = await const JsHookRuntime().evaluate('1 + 1') != null;
    return ok ? const JsHookRuntime() : null;
  }

  @override
  Future<String?> evaluate(String js) async {
    try {
      // Isolate.run 需要可发送的闭包:_evaluateSync 是静态方法,可发送。
      // 竞速超时兜底:interrupt handler 万一没触发(如卡在 FFI 内部),
      // 也不让调用方永久等待(isolate 会随 QuickJS 超时自行收敛)。
      return await Isolate.run(() => _evaluateSync(js)).timeout(const Duration(milliseconds: _jsTimeout * 3));
    } on TimeoutException {
      // 兜底超时:脚本疑似卡死在 interrupt handler 覆盖不到的边界。
      // 不再同步重跑 —— 同一段脚本大概率同样卡死,只是换个线程冻结 UI。
      return null;
    } catch (_) {
      // isolate 不可用(如个别 web 环境)→ 同步回退,保持 hook 可用
      // (回退路径同样受 [_jsTimeout]/[_jsMemoryLimit] 约束,最坏阻塞 5s)。
      return _evaluateSync(js);
    }
  }

  static String? _evaluateSync(String js) {
    // 全约束档优先;本平台 bridge 缺 jsSetMemoryLimit 符号时(如 Windows 的
    // flutter_js 0.8.7)回退仅 timeout 档 —— 构造失败绝不能吞成"求值失败",
    // 那会把所有 hook 静默变 inert(EL 回归的根因)。
    try {
      return _evaluateWith(QuickJsRuntime2(timeout: _jsTimeout, memoryLimit: _jsMemoryLimit), js);
    } catch (_) {
      try {
        return _evaluateWith(QuickJsRuntime2(timeout: _jsTimeout), js);
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
