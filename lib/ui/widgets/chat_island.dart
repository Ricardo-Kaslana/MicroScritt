import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/background_status.dart';
import '../../state/chat_controller.dart';
import '../theme/brand.dart';

/// 聊天页「灵动岛」:悬浮在消息区顶部的深色胶囊,统一承载原本散落在聊天顶部的
/// 全部裸露状态 —— 错误横幅、token 用量条(主写/后台/压缩三路记账)、后台agent
/// 状态条(运行时 + 运行后摘要)、「初始化记忆」提示条、/compact 运行动画条,
/// 以及命令反馈(如压缩成功)的 SnackBar。以上 UI 全部退役,由本组件一处收纳。
///
/// 交互语言(对齐 iOS 灵动岛):
/// - **形变** —— 模式切换时胶囊以 AnimatedSize + 缩放回弹过渡,宽度/高度随内容
///   连续变化,而不是一行行文本的生灭;
/// - **优先级** —— 同一时刻只显示最高优先级的活动:命令反馈闪示 > 错误警报 >
///   压缩中 / 流式中 / 后台维护中(三者在现实中互斥)> 后台结果闪示 > 记忆
///   初始化行动项 > 用量粒 > 隐藏;
/// - **瞬态** —— 后台运行后摘要与命令反馈是「闪示」:弹出抢一下注意力,TTL 到了
///   自动收敛回底层状态(详情可在状态面板回看),聊天顶部不再长期悬着一行字;
/// - **常驻最小化** —— 用量粒是唯一常驻态,且只在有用量时出现;用户贴顶翻历史时
///   自动让位(idleHushed),入场收敛期整体隐藏。
///
/// 视觉:黑胶囊是灵动岛的辨识度来源,亮暗主题都不翻白;语义色用 iOS 系统调
/// (蓝=主写、绿=后台、橙=压缩、紫=记忆、红=错误/中断)。悬浮于聊天背景图与
/// 消息之上,靠阴影与描边保证可读性,不占布局空间(消息从其下方滚过)。

/// 灵动岛语义色(iOS 系统调,与 AppTheme 的 iOS 设计语言同源)。
/// 三点与胶囊取自 [AppBrand],与图标母版同源。
const _toneBlue = AppBrand.dotBlue;
const _toneGreen = AppBrand.dotGreen;
const _toneOrange = AppBrand.dotOrange;
const _tonePurple = Color(0xFFBF5AF2);
const _toneRed = Color(0xFFFF453A);

/// 岛面底色:亮色主题用近黑、深色主题用提亮一档的黑,两版都是「黑胶囊」。
const _pillLight = AppBrand.capsuleLight;
const _pillDark = AppBrand.capsuleDark;

/// 瞬态通知的语义色调。
enum IslandTone { info, success, danger }

/// 语义色调 → 灵岛语义色。
Color _toneColor(IslandTone tone) => switch (tone) {
  IslandTone.success => _toneGreen,
  IslandTone.danger => _toneRed,
  IslandTone.info => _toneBlue,
};

/// 一条瞬态通知(命令反馈等):文本 + 语义色,TTL 由 [IslandHub] 管理。
class IslandNotice {
  final String text;
  final IslandTone tone;
  final IconData icon;
  const IslandNotice({required this.text, this.tone = IslandTone.info, this.icon = Icons.info_outline});
}

/// 瞬态通知中枢:聊天页持有并传给灵岛;任何处(如命令收尾的反馈文本)可
/// [push],灵岛把它作为最高优先级的闪示展示,TTL 到期自动消失。
/// 同一时刻只保留最新一条(新通知顶掉旧通知),[dismiss] 供点击立即收掉。
class IslandHub extends ChangeNotifier {
  IslandNotice? _active;
  Timer? _timer;

  /// 当前活跃的通知(null = 无)。
  IslandNotice? get active => _active;

  /// 推送一条通知:顶掉当前通知并重置 TTL。
  void push(
    String text, {
    IslandTone tone = IslandTone.info,
    IconData? icon,
    Duration ttl = const Duration(milliseconds: 4200),
  }) {
    _timer?.cancel();
    _active = IslandNotice(
      text: text,
      tone: tone,
      icon: switch (tone) {
        IslandTone.success => Icons.check_circle_outline,
        IslandTone.danger => Icons.error_outline,
        IslandTone.info => Icons.info_outline,
      },
    );
    notifyListeners();
    _timer = Timer(ttl, () {
      _active = null;
      notifyListeners();
    });
  }

  /// 立即收掉当前通知(灵岛点击收起用)。
  void dismiss() {
    _timer?.cancel();
    if (_active == null) return;
    _active = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// 灵岛要展示什么。判定优先级见 [ChatIsland] 注释。
enum _IslandMode {
  hidden,
  idle,
  liveStream,
  liveBg,
  liveCompact,
  alert,
  action,
  flashBg,
  flashNotice,
}

/// 聊天页灵动岛。必须作为 Stack 的直接后代使用(内部返回 [Positioned]),
/// 悬浮在消息列表顶部,不参与外层 Column 的布局排布。
class ChatIsland extends StatefulWidget {
  final ChatState chat;

  /// 「初始化记忆」行动项是否可见(记忆为空 + 未手动关闭 + 后台不在运行)。
  final bool memoryInitPrompt;

  /// 是否有耗时命令(/compact 等)在飞:灵岛进入压缩中活动态。
  final bool compacting;

  /// 整体隐藏(会话入场收敛期):灵岛退场,内部定时器照常清理。
  final bool hidden;

  /// 贴顶翻历史时收起用量粒(常驻态让位给阅读);活动态不受影响。
  final bool idleHushed;

  /// 瞬态通知中枢(命令反馈);null 表示本页没有可闪示的通知源。
  final IslandHub? hub;

  final VoidCallback onOpenStatus;
  final VoidCallback onInterrupt;
  final VoidCallback onInitMemory;
  final VoidCallback onDismissMemoryInit;
  final VoidCallback onDismissError;

  /// 备用模型一键切换(P1 契约层):[ChatState.fallbackModelHint] 非空时
  /// 错误横幅渲染「切换备用模型」胶囊按钮;null(无建议/宿主未接)不渲染。
  final VoidCallback? onSwitchFallbackModel;

  const ChatIsland({
    super.key,
    required this.chat,
    required this.memoryInitPrompt,
    required this.compacting,
    required this.hidden,
    required this.idleHushed,
    required this.onOpenStatus,
    required this.onInterrupt,
    required this.onInitMemory,
    required this.onDismissMemoryInit,
    required this.onDismissError,
    this.onSwitchFallbackModel,
    this.hub,
  });

  @override
  State<ChatIsland> createState() => _ChatIslandState();
}

class _ChatIslandState extends State<ChatIsland> {
  /// 活动态(流式/后台维护/压缩中)的共用动画时钟:Timer.periodic 逐步推进
  /// [_tick],波形条/旋转指示/呼吸辉光全由它取值。刻意不用 repeat 的
  /// AnimationController —— Ticker 会持续调度帧,pumpAndSettle 在流式期间
  /// (灵岛必然处于活动态)会直接超时;Timer 只排时间回调不排帧,测试与
  /// 真实退场都不会被动画卡住。20fps 对 3 根小波条/15px 旋转图标足够顺滑。
  Timer? _liveTimer;
  int _tick = 0;

  /// 用量粒/流式粒点开后的展开明细。
  bool _expanded = false;

  /// 后台agent 刚收尾的闪示(运行后消息):TTL 到了自动收敛回底层状态。
  bool _bgFlash = false;
  Timer? _bgFlashTimer;

  /// 流式已进行秒数(Timer.periodic 驱动,不读墙钟 —— 测试的 FakeAsync 推不动
  /// 真实时钟,推得动 Timer)。
  int _elapsed = 0;
  Timer? _elapsedTimer;

  /// 本轮流式起点的累计输出 token:灵岛显示的是本轮增量,不是会话累计。
  int _outAtStreamStart = 0;

  /// 当前订阅的瞬态通知中枢(hub 在 push/dismiss 时通知灵岛重建)。
  IslandHub? _subscribedHub;

  @override
  void initState() {
    super.initState();
    _resubscribeHub();
    // 挂载即流式(热重建/测试直构):秒表与增量基线当场对齐。
    if (widget.chat.streaming) {
      _syncStreamTimer(true);
      _outAtStreamStart = widget.chat.outputTokens;
    }
  }

  @override
  void didUpdateWidget(covariant ChatIsland old) {
    super.didUpdateWidget(old);
    _resubscribeHub();
    _syncStreamTimer(widget.chat.streaming);
    if (widget.chat.streaming && !old.chat.streaming) {
      _outAtStreamStart = widget.chat.outputTokens;
    }
    final status = widget.chat.backgroundStatus;
    if (status != old.chat.backgroundStatus) {
      _bgFlashTimer?.cancel();
      if (status == BackgroundStatus.running || status == BackgroundStatus.idle) {
        _bgFlash = false;
      } else {
        // 运行后消息:闪示一次,TTL 后收敛。失败/中断多停一拍,给足感知。
        _bgFlash = true;
        final ttl = status == BackgroundStatus.failed || status == BackgroundStatus.interrupted
            ? const Duration(seconds: 7)
            : const Duration(seconds: 5);
        _bgFlashTimer = Timer(ttl, () {
          if (!mounted) return;
          setState(() => _bgFlash = false);
        });
      }
    }
  }

  /// 流式秒表:进入流式归零起跳,退出即停(异步收敛可能晚于流结束,晚了也要停)。
  void _syncStreamTimer(bool streaming) {
    if (streaming && _elapsedTimer == null) {
      _elapsed = 0;
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += 1);
      });
    } else if (!streaming && _elapsedTimer != null) {
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
    }
  }

  /// 订阅当前的 hub(换实例/置空时换订);hub 变更即整粒重建。
  void _resubscribeHub() {
    if (identical(_subscribedHub, widget.hub)) return;
    _subscribedHub?.removeListener(_onHubChanged);
    _subscribedHub = widget.hub;
    _subscribedHub?.addListener(_onHubChanged);
  }

  void _onHubChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _subscribedHub?.removeListener(_onHubChanged);
    _bgFlashTimer?.cancel();
    _elapsedTimer?.cancel();
    _liveTimer?.cancel();
    super.dispose();
  }

  /// 备用模型建议在场(P1 契约层):错误横幅据此渲染「切换备用模型」胶囊。
  bool get _hasFallbackSuggestion =>
      (widget.chat.fallbackModelHint ?? '').isNotEmpty && widget.onSwitchFallbackModel != null;

  _IslandMode _resolve() {
    if (widget.hidden) return _IslandMode.hidden;
    if (widget.hub?.active != null) return _IslandMode.flashNotice;
    if ((widget.chat.error ?? '').isNotEmpty) return _IslandMode.alert;
    if (widget.compacting) return _IslandMode.liveCompact;
    if (widget.chat.streaming) return _IslandMode.liveStream;
    if (widget.chat.backgroundStatus == BackgroundStatus.running) return _IslandMode.liveBg;
    if (_bgFlash) return _IslandMode.flashBg;
    if (widget.memoryInitPrompt) return _IslandMode.action;
    if (_hasUsage && !widget.idleHushed) return _IslandMode.idle;
    return _IslandMode.hidden;
  }

  bool get _hasUsage =>
      widget.chat.inputTokens > 0 ||
      widget.chat.outputTokens > 0 ||
      widget.chat.backgroundInputTokens > 0 ||
      widget.chat.backgroundOutputTokens > 0;

  /// 活动时钟随模式启停(见 [_liveTimer] 注释)。build 内直接调用,不触发 setState。
  void _syncAnimations(_IslandMode mode) {
    final live = mode == _IslandMode.liveStream || mode == _IslandMode.liveBg || mode == _IslandMode.liveCompact;
    if (live && _liveTimer == null) {
      _liveTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) return;
        setState(() => _tick += 1);
      });
    } else if (!live && _liveTimer != null) {
      _liveTimer?.cancel();
      _liveTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = _resolve();
    _syncAnimations(mode);
    // 离开可展开的模式时静默收起,回到该模式不带着上一次的展开态。
    if (_expanded &&
        mode != _IslandMode.idle &&
        mode != _IslandMode.liveStream &&
        mode != _IslandMode.alert) {
      _expanded = false;
    }

    return Positioned(
      top: 6,
      left: 20,
      right: 20,
      // Align 一层不可省:Positioned(left+right) 传给 AnimatedSize 的是紧宽度
      // 约束,而 RenderAnimatedSize 遇 isTight 会整体短路(constraints.smallest,
      // 永不动画)—— 岛面塌成零高且点击全部落空。Align 把约束放松成 loose,
      // 尺寸形变才能推进,同时把较窄的胶囊在整行宽度内居中。
      child: Align(
        alignment: Alignment.topCenter,
        // 展开态明细含 Expanded 行(用量分账/行动项长文),会吃满可用宽度 ——
        // 桌面宽窗下整粒拉到近全窗宽,面积失控。统一封顶 420:移动端可用
        // 宽度本就小于此值不受影响,桌面端展开约一掌宽,与移动端观感一致。
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          // hidden 态在 AnimatedSize 之外直接返回零高占位:从 hidden 首次进入任何
          // 模式时 AnimatedSize 是全新挂载,首帧布局即取目标尺寸(_layoutStart 直接
          // 采纳 child 尺寸,不从 0 开始生长)—— 既省掉"从零长出"的中间态,也保证
          // 刚出现的胶囊立刻可点(零高盒会吞掉落在其上的全部点击)。
          child: mode == _IslandMode.hidden
              ? const SizedBox(width: double.infinity)
              : AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 240),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(mode),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _onTapPill(mode),
                        child: _pill(context, mode),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  void _onTapPill(_IslandMode mode) {
    switch (mode) {
      case _IslandMode.idle:
      case _IslandMode.liveStream:
        setState(() => _expanded = !_expanded);
      case _IslandMode.flashBg:
        widget.onOpenStatus();
      case _IslandMode.flashNotice:
        widget.hub?.dismiss();
      case _IslandMode.alert:
        // 警报粒点开看完整错误:收拢态最多两行,服务端长报错(URL/JSON 体)
        // 会被省略,而全文此前无处可看(EO 批)。
        setState(() => _expanded = !_expanded);
      default:
      // 行动项/活动态:各按钮自有命中区,整粒点击不做事。
    }
  }

  // ---------------------------------------------------------------------------
  // 岛面
  // ---------------------------------------------------------------------------

  Widget _pill(BuildContext context, _IslandMode mode) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final expanded = _expanded;
    final glow = switch (mode) {
      _IslandMode.liveStream => _toneBlue,
      _IslandMode.liveBg => _toneGreen,
      _IslandMode.liveCompact => _toneOrange,
      _ => null,
    };
    return Container(
      padding: expanded
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
          : const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: dark ? _pillDark : _pillLight,
        borderRadius: BorderRadius.circular(expanded ? 26 : 24),
        border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.10 : 0.06)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 18, offset: const Offset(0, 6)),
          if (glow != null)
            BoxShadow(color: glow.withValues(alpha: 0.08 + 0.10 * (0.5 + 0.5 * math.sin(_tick * 0.18))), blurRadius: 24, spreadRadius: 0.5),
        ],
      ),
      child: expanded ? _detail(context, mode) : _capsule(context, mode),
    );
  }

  /// 收拢态:一行胶囊内容。
  Widget _capsule(BuildContext context, _IslandMode mode) {
    switch (mode) {
      case _IslandMode.idle:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _EngineDots(),
            const SizedBox(width: 8),
            Flexible(
              child: _RichLabel('in ${_fmt(widget.chat.inputTokens)} tok', append: ' · out ${_fmt(widget.chat.outputTokens)} tok'),
            ),
            const SizedBox(width: 6),
            Icon(Icons.expand_less_rounded, size: 16, color: Colors.white.withValues(alpha: 0.45)),
          ],
        );
      case _IslandMode.liveStream:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _WaveBars(phase: _tick * 0.5),
            const SizedBox(width: 8),
            Flexible(
              child: _RichLabel(
                '生成中',
                append: ' · ${_elapsed}s · out +${_fmt(widget.chat.outputTokens - _outAtStreamStart)} tok',
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.expand_less_rounded, size: 16, color: Colors.white.withValues(alpha: 0.45)),
          ],
        );
      case _IslandMode.liveBg:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Spin(phase: _tick * 0.45, color: _toneGreen),
            const SizedBox(width: 8),
            Flexible(child: _RichLabel('后台agent', append: ' · 状态维护中…')),
            const SizedBox(width: 10),
            _MiniAction(
              tooltip: '中断后台维护',
              onTap: widget.onInterrupt,
              child: Icon(Icons.stop_rounded, size: 20, color: _toneRed),
            ),
          ],
        );
      case _IslandMode.liveCompact:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Spin(phase: _tick * 0.45, color: _toneOrange),
            const SizedBox(width: 8),
            Flexible(child: _RichLabel('正在压缩会话历史…')),
          ],
        );
      case _IslandMode.alert:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 16, color: _toneRed),
            const SizedBox(width: 8),
            Flexible(child: _RichLabel(widget.chat.error!, maxLines: 2)),
            if (_hasFallbackSuggestion) ...[
              const SizedBox(width: 6),
              _PillButton(label: '切换备用模型', onTap: widget.onSwitchFallbackModel!),
            ],
            const SizedBox(width: 6),
            _MiniAction(
              tooltip: '关闭',
              onTap: widget.onDismissError,
              child: Icon(Icons.close_rounded, size: 15, color: Colors.white.withValues(alpha: 0.55)),
            ),
          ],
        );
      case _IslandMode.action:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.psychology_outlined, size: 16, color: _tonePurple),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '新会话记忆为空,可用角色卡 + 常驻世界书初始化一次',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, height: 1.25, color: Colors.white.withValues(alpha: 0.92)),
              ),
            ),
            const SizedBox(width: 8),
            _PillButton(label: '初始化记忆', onTap: widget.onInitMemory),
            const SizedBox(width: 4),
            _MiniAction(
              tooltip: '关闭初始化提示',
              onTap: widget.onDismissMemoryInit,
              child: Icon(Icons.close_rounded, size: 15, color: Colors.white.withValues(alpha: 0.45)),
            ),
          ],
        );
      case _IslandMode.flashBg:
        final status = widget.chat.backgroundStatus;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_statusIcon(status), size: 16, color: _statusColor(status)),
            const SizedBox(width: 8),
            Flexible(
              child: _RichLabel(
                '后台agent · ${backgroundStatusLabel(status)}',
                append: widget.chat.backgroundSummary.isEmpty ? null : ' · ${widget.chat.backgroundSummary}',
                maxLines: 2,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 16, color: Colors.white.withValues(alpha: 0.35)),
          ],
        );
      case _IslandMode.flashNotice:
        final notice = widget.hub!.active!;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(notice.icon, size: 16, color: _toneColor(notice.tone)),
            const SizedBox(width: 8),
            Flexible(child: _RichLabel(notice.text, maxLines: 2)),
          ],
        );
      case _IslandMode.hidden:
        return const SizedBox.shrink();
    }
  }

  /// 展开态:三路引擎的分账明细(idle)、流式实况 + 分账(liveStream)或
  /// 完整错误文本(alert,EO 批)。
  Widget _detail(BuildContext context, _IslandMode mode) {
    final chat = widget.chat;
    final labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
      color: Colors.white.withValues(alpha: 0.55),
    );
    // 警报展开:完整错误不再省略 —— 可滚动(超长封顶 320 高,不撑爆页面)、
    // 可选中复制(整段贴出去排查)。点头部/页体收起,「关闭」仍是抹掉错误。
    if (mode == _IslandMode.alert) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, size: 16, color: _toneRed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '请求出错(点击收起)',
                  style: labelStyle.copyWith(color: Colors.white.withValues(alpha: 0.75)),
                ),
              ),
              _MiniAction(
                tooltip: '关闭',
                onTap: widget.onDismissError,
                child: Icon(Icons.close_rounded, size: 15, color: Colors.white.withValues(alpha: 0.55)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: SelectableText(
                chat.error ?? '',
                style: TextStyle(fontSize: 12, height: 1.35, color: Colors.white.withValues(alpha: 0.92)),
              ),
            ),
          ),
          if (_hasFallbackSuggestion) ...[
            const SizedBox(height: 8),
            _PillButton(
              label: '切换备用模型:${chat.fallbackModelHint}',
              onTap: widget.onSwitchFallbackModel!,
            ),
          ],
        ],
      );
    }
    final liveHead = mode == _IslandMode.liveStream
        ? Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                _WaveBars(phase: _tick * 0.5),
                const SizedBox(width: 8),
                _RichLabel('生成中', append: ' · ${_elapsed}s · 本轮 out +${_fmt(chat.outputTokens - _outAtStreamStart)} tok'),
              ],
            ),
          )
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (liveHead != null) liveHead,
        Row(
          children: [
            const _EngineDots(),
            const SizedBox(width: 8),
            Text('用量', style: labelStyle),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() => _expanded = false),
              child: Icon(Icons.expand_more_rounded, size: 18, color: Colors.white.withValues(alpha: 0.45)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _engineRow(color: _toneBlue, name: '主写', input: chat.inputTokens, cached: chat.cachedInputTokens, output: chat.outputTokens),
        if (chat.backgroundInputTokens > 0 || chat.backgroundOutputTokens > 0)
          _engineRow(
            color: _toneGreen,
            name: '后台',
            input: chat.backgroundInputTokens,
            cached: chat.backgroundCachedInputTokens,
            output: chat.backgroundOutputTokens,
          ),
        if (chat.compactInputTokens > 0 || chat.compactOutputTokens > 0)
          _engineRow(
            color: _toneOrange,
            name: '压缩',
            input: chat.compactInputTokens,
            cached: chat.compactCachedInputTokens,
            output: chat.compactOutputTokens,
          ),
        const SizedBox(height: 6),
        Divider(height: 1, thickness: 0.5, color: Colors.white.withValues(alpha: 0.10)),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('合计', style: labelStyle),
            const SizedBox(width: 10),
            _RichLabel(
              'in ${_fmt(chat.inputTokens + chat.backgroundInputTokens + chat.compactInputTokens)} tok',
              append: ' · out ${_fmt(chat.outputTokens + chat.backgroundOutputTokens + chat.compactOutputTokens)} tok',
            ),
          ],
        ),
      ],
    );
  }

  Widget _engineRow({required Color color, required String name, required int input, required int cached, required int output}) {
    final hit = input == 0 ? null : cached / input;
    final detailStyle = TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.92));
    final dimStyle = TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.5));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          SizedBox(
            width: 30,
            child: Text(name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.75))),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'in ${_fmt(input)} tok', style: detailStyle),
                  if (hit != null) TextSpan(text: ' (cached ${_fmt(cached)} tok · hit ${(hit * 100).toStringAsFixed(0)}%)', style: dimStyle),
                  TextSpan(text: ' · out ${_fmt(output)} tok', style: detailStyle),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(BackgroundStatus s) => switch (s) {
    BackgroundStatus.succeeded => _toneGreen,
    BackgroundStatus.failed => _toneRed,
    BackgroundStatus.interrupted => _toneOrange,
    BackgroundStatus.skipped || BackgroundStatus.disabled => Colors.white.withValues(alpha: 0.5),
    _ => _toneBlue,
  };

  IconData _statusIcon(BackgroundStatus s) => switch (s) {
    BackgroundStatus.succeeded => Icons.check_circle_outline,
    BackgroundStatus.failed => Icons.error_outline,
    BackgroundStatus.interrupted => Icons.stop_circle_outlined,
    BackgroundStatus.skipped => Icons.skip_next_outlined,
    BackgroundStatus.disabled => Icons.visibility_off_outlined,
    _ => Icons.psychology_outlined,
  };

  /// token 数缩写:千位起折成 k,免得胶囊被一长串数字撑宽;单位(tok)由
  /// 调用方拼接在数量之后。
  static String _fmt(int v) {
    if (v >= 100000) return '${(v / 1000).round()}k';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return '$v';
  }
}

// ---------------------------------------------------------------------------
// 零件
// ---------------------------------------------------------------------------

/// 主写/后台/压缩三路引擎的迷你标识点(蓝绿橙),灵岛的常驻签名。
class _EngineDots extends StatelessWidget {
  const _EngineDots();

  @override
  Widget build(BuildContext context) {
    const colors = [_toneBlue, _toneGreen, _toneOrange];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < colors.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Container(width: 5, height: 5, decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle)),
        ],
      ],
    );
  }
}

/// 灵岛通用文本:主文本白亮、[append] 同串灰阶收尾(状态后缀不抢主信息)。
class _RichLabel extends StatelessWidget {
  final String text;
  final String? append;
  final int maxLines;
  const _RichLabel(this.text, {this.append, this.maxLines = 1});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.25, color: Colors.white.withValues(alpha: 0.95)),
          ),
          if (append != null)
            TextSpan(
              text: append,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, height: 1.25, color: Colors.white.withValues(alpha: 0.55)),
            ),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 胶囊内的迷你主按钮(如「初始化记忆」):半透明白系反色,与黑胶囊同语言。
class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PillButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
      ),
    );
  }
}

/// 胶囊内的迷你动作钮(关闭/中断),带 tooltip 保住无障碍语义。
class _MiniAction extends StatelessWidget {
  final String tooltip;
  final Widget child;
  final VoidCallback onTap;
  const _MiniAction({required this.tooltip, required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.tap,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(3), child: child),
      ),
    );
  }
}

/// 流式中的声波条:三根错相正弦高度的小条,主写引擎「正在说话」的具象。
/// [phase] 由活动时钟逐帧推进(重建由其 setState 驱动)。
class _WaveBars extends StatelessWidget {
  final double phase;
  const _WaveBars({required this.phase});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: 3,
            height: 5 + 9 * (0.5 + 0.5 * math.sin(phase + i * 1.1)),
            margin: const EdgeInsets.symmetric(horizontal: 1.5),
            decoration: BoxDecoration(color: _toneBlue, borderRadius: BorderRadius.circular(2)),
          ),
      ],
    );
  }
}

/// 后台维护/压缩中的旋转指示。
class _Spin extends StatelessWidget {
  final double phase;
  final Color color;
  const _Spin({required this.phase, required this.color});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(angle: phase, child: Icon(Icons.autorenew, size: 15, color: color));
  }
}
