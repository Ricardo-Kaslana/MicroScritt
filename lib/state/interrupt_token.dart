/// 协作式中断令牌:主写引擎、后台 agent 与制卡 agent 共用的取消通道。
/// 双通道语义 —— 轮询([InterruptToken.cancelled],每消费一个事件/每步状态
/// 写入前检查,后台引擎的 shouldCancel 用)+ 即时通知
/// ([InterruptToken.whenCancelled],让"等待首个流事件"的消费者在零事件期
/// 也能被立即唤醒)。
library;

import 'dart:async';

/// 令牌**不可复用**:没有 reset。"供下一轮使用"靠控制器每轮入口换发新实例。
/// 在飞轮持有自己的实例,其 cancelled 永真;若在实例上清标志,会把**另一条
/// 还在飞的轮**的取消通道一并吹灭。
class InterruptToken {
  bool _cancelled = false;
  Completer<void>? _completer;

  /// 是否已取消;在飞轮每消费一个事件/每步状态写入前轮询。
  bool get cancelled => _cancelled;

  /// 下一次 [cancel] 发生时完成的 Future;已取消时立即完成。
  /// 仅用于"睡眠中等待"的竞速唤醒,轮询检查仍走 [cancelled]。
  Future<void> get whenCancelled =>
      _cancelled ? Future.value() : (_completer ??= Completer<void>()).future;

  /// 取消一次:幂等,并唤醒 [whenCancelled] 的等待者;该实例此后永久为取消态。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer?.complete();
    _completer = null;
  }
}
