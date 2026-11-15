/// 编辑页的未保存修改防护:返回前二次确认,避免整页表单随手势/返回键丢弃。
///
/// 只读 [hasChanges] 判断脏值;文本输入等变更经 [changes] 中的 Listenable
/// 通知后重新求值,非文本状态(开关/选择)随父级重建一并复查。保存后页面
/// 直接 `Navigator.pop` —— 程序性 pop 不咨询 [PopScope.canPop],不会被拦。
library;

import 'package:flutter/material.dart';

import 'confirm_dialog.dart';

/// 未保存修改的返回防护壳。
///
/// 把整页(通常是一个 `Scaffold`)包进 [PopScope]:有未保存修改时拦截返回
/// (系统返回键、AppBar 返回键、iOS 侧滑),弹确认框;确认放弃后才真正退出。
/// 无修改时行为与普通页面完全一致,不多一次确认。
class UnsavedChangesGuard extends StatefulWidget {
  /// 当前是否与初始状态不同;在监听回调与每次重建时求值。
  final bool Function() hasChanges;

  /// 触发重新求值的变更源(文本控制器等)。列表内容变化时按元素重新订阅。
  final List<Listenable> changes;

  final String title;
  final String message;
  final String confirmLabel;
  final Widget child;

  const UnsavedChangesGuard({
    super.key,
    required this.hasChanges,
    required this.child,
    this.changes = const [],
    this.title = '放弃未保存的修改?',
    this.message = '返回后,本次编辑的内容不会保存。',
    this.confirmLabel = '放弃修改',
  });

  @override
  State<UnsavedChangesGuard> createState() => _UnsavedChangesGuardState();
}

class _UnsavedChangesGuardState extends State<UnsavedChangesGuard> {
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _subscribe(widget.changes);
    _dirty = widget.hasChanges();
  }

  @override
  void didUpdateWidget(covariant UnsavedChangesGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameListenables(oldWidget.changes, widget.changes)) {
      _unsubscribe(oldWidget.changes);
      _subscribe(widget.changes);
    }
    // 父级重建通常意味着头像/开关等非文本状态变化,顺带复查一次。
    _dirty = widget.hasChanges();
  }

  @override
  void dispose() {
    _unsubscribe(widget.changes);
    super.dispose();
  }

  void _subscribe(List<Listenable> listenables) {
    for (final listenable in listenables) {
      listenable.addListener(_recheck);
    }
  }

  void _unsubscribe(List<Listenable> listenables) {
    for (final listenable in listenables) {
      listenable.removeListener(_recheck);
    }
  }

  /// 元素级比较:页面每次 build 都可能新建同内容的列表,按引用比较会让
  /// 监听在每次重建时反复摘挂。
  static bool _sameListenables(List<Listenable> a, List<Listenable> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  void _recheck() {
    final next = widget.hasChanges();
    if (next != _dirty && mounted) setState(() => _dirty = next);
  }

  Future<void> _confirmLeave() async {
    final leave = await showConfirmDialog(
      context,
      title: widget.title,
      message: widget.message,
      confirmLabel: widget.confirmLabel,
    );
    if (leave && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    _dirty = widget.hasChanges();
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 弹确认框本身是异步的;拦截标志已在 canPop=false 时生效,无需再阻塞。
        _confirmLeave();
      },
      child: widget.child,
    );
  }
}
