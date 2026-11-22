/// 聊天页骨架展示件:输入区抬升、侧栏收展动画、桌面消息导航与悬浮滚动导航组。

part of '../chat_screen.dart';

/// 空会话输入区抬升的底部留白:在 0 与 [height] 之间做 easeOutCubic 过渡。
/// 窗口缩放导致 [height] 变化时按当前进度即时随动 —— 隐式动画在持续缩放
/// 中会一直追新目标,输入区会橡皮一样滞后;只有「有/无内容」切换才播动画。
/// 留白取内容区高度的四分之一,不必测量输入区的实际高度。
class _ComposerLift extends StatefulWidget {
  final bool lifted;
  final double height;
  final Duration duration;

  const _ComposerLift({
    required this.lifted,
    required this.height,
    required this.duration,
  });

  @override
  State<_ComposerLift> createState() => _ComposerLiftState();
}

class _ComposerLiftState extends State<_ComposerLift>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.lifted ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant _ComposerLift oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.lifted != oldWidget.lifted) {
      if (widget.lifted) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => SizedBox(
        height:
            widget.height * Curves.easeOutCubic.transform(_controller.value),
      ),
    );
  }
}

/// 宽窗侧栏的收展容器:槽宽按 [visible] 在 0..[kChatSidebarWidth] 间做
/// easeOutCubic 动画,聊天区随行重排;子树始终按侧栏满宽布局并锚定槽右缘,
/// 被 [ClipRect] 按槽宽裁切 —— 滑入滑出而不是整体缩放,标题/检索框/行宽
/// 在动画中不重排。完全收起后卸载子树:隐藏的检索框不应留在焦点遍历与
/// widget 树里(也避免测试把侧栏输入框误当聊天输入框)。
class _SidebarReveal extends StatefulWidget {
  final bool visible;
  final Duration duration;
  final Widget child;

  const _SidebarReveal({
    required this.visible,
    required this.duration,
    required this.child,
  });

  @override
  State<_SidebarReveal> createState() => _SidebarRevealState();
}

class _SidebarRevealState extends State<_SidebarReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    // 首帧即按目标状态成形:从宽窗打开聊天页不该先播一次展开动画。
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant _SidebarReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final width =
              kChatSidebarWidth *
              Curves.easeOutCubic.transform(_controller.value);
          if (width <= 0) return const SizedBox.shrink();
          return SizedBox(
            width: width,
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: kChatSidebarWidth,
              maxWidth: kChatSidebarWidth,
              child: SizedBox(width: kChatSidebarWidth, child: widget.child),
            ),
          );
        },
      ),
    );
  }
}

/// 桌面端消息导航:收起态是贴窗口右缘的一列 user 消息刻度,鼠标悬停展开成
/// 可滚动卡片,点击条目跳到对应消息。
///
/// 取代桌面端原先的悬浮爬楼按键组(移动端仍用 [_ScrollNavRail]):爬楼按钮
/// 只能一步一步走,长会话里想回到某次发言得点几十次;卡片一次列出全量 user
/// 消息,点哪去哪。
///
/// 悬停热区刻意只取收起态的窄条(且留出 [kChatNavInset] 避开窗口滚动条):
/// [MouseRegion] 默认 opaque,热区越宽,越会挡住消息列表右缘的滚轮与点击。
/// 展开后卡片是悬浮层,拦截下方气泡点击正是期望行为。
///
/// 显隐与滚动进度全部走 [ValueListenable],滚动路径上零 setState —— 与
/// [_ScrollNavRail] 同一约束,避免每次滚动 tick 都连消息列表一起重建。
class _MessageNavigator extends StatefulWidget {
  /// 全量 user 消息索引(不受显示窗口裁剪),按时间升序。
  final List<UserMessageRef> messages;

  /// 视口当前对应的 user 消息 id;null = 视口内没有 user 消息。
  final ValueListenable<int?> currentMessageId;
  final ValueListenable<bool> nearTop;
  final ValueListenable<bool> nearBottom;

  /// 「回到顶部」逐页取旧进行中:头部按钮换成转圈,不接受重复点击。
  final ValueListenable<bool> autoTopRunning;
  final VoidCallback onScrollToTop;
  final VoidCallback onScrollToBottom;
  final ValueChanged<int> onJumpTo;

  /// 窗口之上是否还有未加载的旧历史。贴顶但仍有旧页时「回到顶部」必须
  /// 保持可用:时间预算兜底结束或流式拒绝加载后,按钮若随贴顶禁用,用户
  /// 就无法执行提示里的「再点一次继续加载」。
  final bool canLoadOlder;

  const _MessageNavigator({
    required this.messages,
    required this.currentMessageId,
    required this.nearTop,
    required this.nearBottom,
    required this.autoTopRunning,
    required this.onScrollToTop,
    required this.onScrollToBottom,
    required this.onJumpTo,
    required this.canLoadOlder,
  });

  @override
  State<_MessageNavigator> createState() => _MessageNavigatorState();
}

class _MessageNavigatorState extends State<_MessageNavigator> {
  bool _expanded = false;

  /// 鼠标离开后延迟收起:光标从热区移到卡片项、或短暂移出右缘时不要立刻
  /// 消失;重新进入会撤销计时。
  Timer? _collapseTimer;

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  void _expand() {
    _collapseTimer?.cancel();
    if (!_expanded) setState(() => _expanded = true);
  }

  void _collapseLater() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(milliseconds: 240), () {
      if (mounted && _expanded) setState(() => _expanded = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: kChatNavInset,
      top: 0,
      bottom: 0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 卡片高约消息区 2/3:足够长的索引列表,又不至于上下顶满把正文
          // 全部盖住。矮窗口(如横屏手机/小窗)取可用高度,避免卡片溢出。
          final available = constraints.maxHeight;
          if (available <= 0) return const SizedBox.shrink();
          final height = math.min(
            available,
            (available * 0.68).clamp(300.0, 620.0),
          );
          return AnimatedBuilder(
            animation: Listenable.merge([widget.nearTop, widget.nearBottom]),
            builder: (context, _) {
              // 内容不足一屏(既贴顶又贴底)没有导航意义;没有任何 user
              // 消息时卡片是空的,整组直接不出现。
              if (widget.messages.isEmpty ||
                  (widget.nearTop.value && widget.nearBottom.value)) {
                return const SizedBox.shrink();
              }
              return Align(
                alignment: Alignment.centerRight,
                widthFactor: 1,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => _expand(),
                  onExit: (_) => _collapseLater(),
                  child: SizedBox(
                    width: _expanded ? kChatNavCardWidth : kChatNavRailWidth,
                    height: height,
                    // 宽度在收起/展开间瞬变,但内容始终按卡片满宽布局、锚定
                    // 右缘裁切 —— 否则收起瞬间卡片会被压成窄条重排,刻度条
                    // 也没法贴在右缘不动。
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.centerRight,
                        minWidth: kChatNavCardWidth,
                        maxWidth: kChatNavCardWidth,
                        minHeight: height,
                        maxHeight: height,
                        child: AnimatedSwitcher(
                          duration: motionDurationOf(
                            context,
                            const Duration(milliseconds: 160),
                          ),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.centerRight,
                            children: [
                              ...previous,
                              if (current != null) current,
                            ],
                          ),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0.03, 0),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: _expanded
                              ? _NavCard(
                                  key: const ValueKey('message-nav-card'),
                                  messages: widget.messages,
                                  height: height,
                                  currentMessageId: widget.currentMessageId,
                                  nearTop: widget.nearTop,
                                  nearBottom: widget.nearBottom,
                                  autoTopRunning: widget.autoTopRunning,
                                  canLoadOlder: widget.canLoadOlder,
                                  onScrollToTop: widget.onScrollToTop,
                                  onScrollToBottom: widget.onScrollToBottom,
                                  onJumpTo: widget.onJumpTo,
                                )
                              : _NavRail(
                                  key: const ValueKey('message-nav-rail'),
                                  messages: widget.messages,
                                  maxHeight: height,
                                  currentMessageId: widget.currentMessageId,
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 收起态的刻度条:每条 user 消息一根短横线,当前视口位置加长并换成主色。
///
/// 整条高度按消息数自适应:每条消息占 [kChatNavTickSpacing] 的固定间距,
/// 1–2 条消息时只是一小段刻度,不会在卡片高度里只剩顶部/底部两根孤线;
/// 消息多到超出 [maxHeight] 后才封顶,按可用高度均分。
///
/// 消息再多也不能把刻度糊成实心条 —— 超过可用槽位时按步长抽样,当前项
/// 始终单独绘制。
class _NavRail extends StatelessWidget {
  final List<UserMessageRef> messages;

  /// 刻度条的高度上限(即展开态卡片高度)。
  final double maxHeight;
  final ValueListenable<int?> currentMessageId;

  const _NavRail({
    super.key,
    required this.messages,
    required this.maxHeight,
    required this.currentMessageId,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = messages.length;
    final railHeight = math.min(
      maxHeight,
      kChatNavRailPadding * 2 +
          math.max(0, count - 1) * kChatNavTickSpacing,
    );
    return SizedBox(
      width: kChatNavRailWidth,
      height: railHeight,
      child: Semantics(
        label: '消息导航',
        value: '$count 条用户消息',
        child: AnimatedBuilder(
          animation: currentMessageId,
          builder: (context, _) {
            final id = currentMessageId.value;
            final current = id == null
                ? -1
                : messages.indexWhere((m) => m.messageId == id);
            return CustomPaint(
              painter: _NavRailPainter(
                count: count,
                current: current,
                line: scheme.outlineVariant,
                accent: scheme.primary,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NavRailPainter extends CustomPainter {
  final int count;
  final int current;
  final Color line;
  final Color accent;

  const _NavRailPainter({
    required this.count,
    required this.current,
    required this.line,
    required this.accent,
  });

  /// 刻度条上下留白:贴到卡片上下缘会显得被窗口切断。
  static const double _pad = kChatNavRailPadding;

  @override
  void paint(Canvas canvas, Size size) {
    if (count <= 0 || size.height <= _pad * 2) return;
    final usable = size.height - _pad * 2;
    final slot = count <= 1 ? 0.0 : usable / (count - 1);
    // 只保留横线,不再画贯通上下的竖轨道。抽样上限按最小间距
    // [kChatNavTickSpacing] 计算:消息再多也不把刻度糊成实心条,且当前项
    // 周围留出一个间距的空白,避免高亮线与邻近抽样线贴在一起。
    final slots = math.max(1, (usable / kChatNavTickSpacing).floor());
    final step = math.max(1, (count / slots).ceil());
    final right = size.width - 4;
    final tick = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i += step) {
      if (i == current) continue;
      final y = _pad + i * slot;
      if (current >= 0 &&
          (i - current).abs() * slot < kChatNavTickSpacing) {
        continue;
      }
      tick
        ..color = line.withValues(alpha: 0.55)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(right - 7, y), Offset(right, y), tick);
    }
    // 当前项可能不在抽样集合里,单独画;加长 + 主色让"我现在在哪"一眼可见。
    if (current >= 0) {
      final currentY = _pad + current * slot;
      canvas.drawLine(
        Offset(right - 14, currentY),
        Offset(right, currentY),
        tick
          ..color = accent
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _NavRailPainter oldDelegate) =>
      oldDelegate.count != count ||
      oldDelegate.current != current ||
      oldDelegate.line != line ||
      oldDelegate.accent != accent;
}

/// 展开态导航卡片:头部是标题/条数/首尾跳转,正文是可滚轮滚动的 user 消息
/// 索引。每项固定行高,单行摘要 —— 卡片宽度有限,多行摘要会把可见条目数
/// 压到个位数,失去"总览"的意义。
class _NavCard extends StatefulWidget {
  final List<UserMessageRef> messages;
  final double height;
  final ValueListenable<int?> currentMessageId;
  final ValueListenable<bool> nearTop;
  final ValueListenable<bool> nearBottom;
  final ValueListenable<bool> autoTopRunning;
  final VoidCallback onScrollToTop;
  final VoidCallback onScrollToBottom;
  final ValueChanged<int> onJumpTo;

  /// 窗口之上是否还有未加载的旧历史(见 [_MessageNavigator.canLoadOlder])。
  final bool canLoadOlder;

  const _NavCard({
    super.key,
    required this.messages,
    required this.height,
    required this.currentMessageId,
    required this.nearTop,
    required this.nearBottom,
    required this.autoTopRunning,
    required this.onScrollToTop,
    required this.onScrollToBottom,
    required this.onJumpTo,
    required this.canLoadOlder,
  });

  @override
  State<_NavCard> createState() => _NavCardState();
}

class _NavCardState extends State<_NavCard> {
  /// 头部行高 + 分割线:列表视口 = 卡片高 − 头部 − 列表上下内边距。
  static const double _headerHeight = 45;
  static const double _listPadding = 8;

  late final ScrollController _list;

  double get _viewport =>
      math.max(1.0, widget.height - _headerHeight - _listPadding);

  @override
  void initState() {
    super.initState();
    // 展开即定位到当前视口对应的 user 消息(消息列表给出的真实可见 id),
    // 找不到时兜底最新一条 —— 用户在读中段历史时打开导航,第一眼就该看到
    // 自己在哪,而不是按比例猜。
    final id = widget.currentMessageId.value;
    var index = math.max(0, widget.messages.length - 1);
    if (id != null) {
      final found = widget.messages.indexWhere((m) => m.messageId == id);
      if (found >= 0) index = found;
    }
    final extent = widget.messages.length * kChatNavItemExtent;
    final maxOffset = math.max(0.0, extent - _viewport);
    final offset = (index * kChatNavItemExtent - _viewport / 2 +
            kChatNavItemExtent / 2)
        .clamp(0.0, maxOffset);
    _list = ScrollController(initialScrollOffset: offset);
    // 锚点变化(消息列表滚动、回顶/回底、导航跳转)时让卡片列表跟着走:
    // 否则视口已经到边界,卡片还停在用户上次手动浏览的中段 —— 看起来
    // 就是"已经到了,卡片却停在中间某条消息"。
    widget.currentMessageId.addListener(_followCurrent);
  }

  @override
  void dispose() {
    widget.currentMessageId.removeListener(_followCurrent);
    _list.dispose();
    super.dispose();
  }

  /// 当前项离开卡片视口时,把卡片列表滚到能让它完整可见的位置。
  ///
  /// 只在锚点真正变化时执行(用户单独滚动卡片列表时消息列表不动、锚点不变),
  /// 不会干扰"打开卡片后自己往上翻"。
  void _followCurrent() {
    final id = widget.currentMessageId.value;
    if (id == null || !_list.hasClients) return;
    final index = widget.messages.indexWhere((m) => m.messageId == id);
    if (index < 0) return;
    final viewport = _viewport;
    final offset = _list.offset;
    final start = index * kChatNavItemExtent;
    if (start >= offset && start + kChatNavItemExtent <= offset + viewport) {
      return;
    }
    final extent = widget.messages.length * kChatNavItemExtent;
    final maxOffset = math.max(0.0, extent - viewport);
    final target =
        (start - viewport / 2 + kChatNavItemExtent / 2).clamp(0.0, maxOffset);
    _list.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 不叠加投影:卡片被导航的宽度裁切层夹在同尺寸矩形里,PhysicalModel
    // 的外阴影会被裁掉,只剩圆角内缘一圈灰弧。层级改用发丝边 + 明度差
    // 表达(与 SurfaceCard 同一配方),底单在浅色下也不会显脏。
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.cardBorder,
        side: AppStroke.cardSide(scheme),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _header(context, scheme),
          Divider(
            height: 1,
            thickness: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          Expanded(
            child: ValueListenableBuilder<int?>(
              valueListenable: widget.currentMessageId,
              builder: (context, currentId, _) {
                return Scrollbar(
                  controller: _list,
                  child: ListView.builder(
                    key: const ValueKey('message-nav-list'),
                    controller: _list,
                    primary: false,
                    itemExtent: kChatNavItemExtent,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: widget.messages.length,
                    itemBuilder: (context, index) {
                      final message = widget.messages[index];
                      return _NavCardItem(
                        index: index,
                        message: message,
                        current: message.messageId == currentId,
                        onTap: () => widget.onJumpTo(message.messageId),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, ColorScheme scheme) {
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Row(
          children: [
            Text('消息导航', style: textTheme.labelLarge),
            const SizedBox(width: 6),
            Text(
              '${widget.messages.length}',
              style: textTheme.labelSmall?.copyWith(color: scheme.outline),
            ),
            const Spacer(),
            AnimatedBuilder(
              animation: Listenable.merge([
                widget.nearTop,
                widget.nearBottom,
                widget.autoTopRunning,
              ]),
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _NavHeaderButton(
                    tooltip: '回到顶部',
                    icon: Icons.vertical_align_top,
                    spinning: widget.autoTopRunning.value,
                    // 贴顶但仍有未加载旧页时保持可用:否则预算兜底/流式拒绝
                    // 后按钮禁用,提示里的「再点一次」无从执行。
                    onPressed:
                        (widget.nearTop.value && !widget.canLoadOlder) ||
                            widget.autoTopRunning.value
                        ? null
                        : widget.onScrollToTop,
                  ),
                  _NavHeaderButton(
                    tooltip: '回到底部',
                    icon: Icons.vertical_align_bottom,
                    onPressed: widget.nearBottom.value
                        ? null
                        : widget.onScrollToBottom,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片头部的紧凑图标按钮:标准 IconButton 的 48 最小点击区会把 44 高的
/// 头部撑变形,这里用 30×30 的自绘热区。
class _NavHeaderButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool spinning;

  const _NavHeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.spinning = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Center(
            child: spinning
                ? const InlineSpinner(size: 14)
                : Icon(
                    icon,
                    size: 18,
                    color: onPressed == null
                        ? scheme.outline.withValues(alpha: 0.6)
                        : scheme.onSurfaceVariant,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 导航卡片的一条 user 消息:序号徽标 + 单行摘要。当前视口附近那条用主色
/// 底 + 深色文字标出,与刻度条的高亮口径一致。
class _NavCardItem extends StatelessWidget {
  final int index;
  final UserMessageRef message;
  final bool current;
  final VoidCallback onTap;

  const _NavCardItem({
    required this.index,
    required this.message,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final preview = message.preview.isEmpty ? '图片消息' : message.preview;
    return Semantics(
      button: true,
      label: '第 ${index + 1} 条用户消息',
      child: ColoredBox(
        color: current
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: scheme.primary.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Container(
                  key: current
                      ? ValueKey('nav-current-${message.messageId}')
                      : null,
                  width: 24,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: current
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: textTheme.labelSmall?.copyWith(
                      color: current
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: current
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮滚动导航按键组:顶部方向(回到顶部/上一条消息)与底部方向(下一条
/// 消息/回到底部),「收起/展开滚动导航」夹在两组之间(列表中部时是第 3 颗,
/// 即正中间;贴顶/贴底只剩单侧方向组时,收起钮放在该组另一端,不与方向钮
/// 挤在一起)。整组可折叠:点收起折成一颗半透明小钮,再点即展开。用户滚动
/// 列表(拖动/滚轮/惯性)期间整组自动隐藏,滚动真正停止后延迟恢复(由
/// ChatScreen 的滚动通知驱动 `_navAutoHidden`)。
///
/// 六个显隐/折叠开关全部是 [ValueListenable] 且由本组通过 [AnimatedBuilder]
/// 自行监听:滚动期间这些开关频繁翻转(贴底/贴顶阈值跨越、自动隐藏/恢复),
/// 若在 ChatScreen 里走 setState 会连消息列表一起整页重建,滑动掉帧、表现为
/// 一卡一卡;这里只重建这一小块,滚动路径上零 setState。页面内悬浮的滚动
/// 工具钮统一禁用 hero 动画(`heroTag: null`),避免与其它页面的 FAB 撞默认
/// hero 标签(多个同 tag hero 触发断言)。
class _ScrollNavRail extends StatelessWidget {
  final ValueListenable<bool> nearTop;
  final ValueListenable<bool> nearBottom;
  final ValueListenable<bool> autoHidden;

  /// 选中消息的操作按钮排(复制/编辑/删除/重新发送)是否可见:可见期间整组
  /// 隐藏 —— 操作排贴在列表内容底端,选中最后一条消息时正好落在导航组的
  /// 位置上,叠着会挡住最右的重新发送/重新生成。
  final ValueListenable<bool> actionsOpen;
  final ValueListenable<bool> collapsed;

  /// 「回到顶部」逐页取旧是否进行中:进行中整组导航钮换成一颗进度指示钮并
  /// **常驻**(不随贴顶邻域/滚动自动隐藏消失 —— 旧实现正是按钮在贴顶 80px 内
  /// 消失导致用户卡在半截历史无从继续)。
  final ValueListenable<bool> autoTopRunning;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onScrollToTop;
  final VoidCallback onScrollToPreviousMessage;
  final VoidCallback onScrollToNextMessage;
  final VoidCallback onScrollToBottom;

  /// 窗口之上是否还有未加载的旧历史。贴顶但仍有旧页时顶部方向组不能
  /// 消失 —— 否则预算兜底或流式拒绝后,提示「再点一次」却已无按钮可点。
  final bool canLoadOlder;

  const _ScrollNavRail({
    required this.nearTop,
    required this.nearBottom,
    required this.autoHidden,
    required this.actionsOpen,
    required this.collapsed,
    required this.autoTopRunning,
    required this.onToggleCollapsed,
    required this.onScrollToTop,
    required this.onScrollToPreviousMessage,
    required this.onScrollToNextMessage,
    required this.onScrollToBottom,
    required this.canLoadOlder,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 12,
      bottom: 12,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          nearTop,
          nearBottom,
          autoHidden,
          actionsOpen,
          collapsed,
          autoTopRunning,
        ]),
        builder: (context, _) {
          // 逐页取旧进行中:整组换成进度钮,常驻显示直到落定(优先级高于
          // 下面的隐藏/折叠判定)。
          if (autoTopRunning.value) {
            return FloatingActionButton.small(
              tooltip: '正在加载更早的历史…',
              heroTag: null,
              onPressed: null,
              child: const InlineSpinner(size: 18),
            );
          }
          // 内容不足一屏(既贴顶又贴底)没有导航意义;滚动中与消息操作排
          // 可见期间自动隐藏让位。
          if ((nearTop.value && nearBottom.value) ||
              autoHidden.value ||
              actionsOpen.value) {
            return const SizedBox.shrink();
          }
          if (collapsed.value) {
            return Opacity(
              opacity: 0.55,
              child: FloatingActionButton.small(
                tooltip: '展开滚动导航',
                heroTag: null,
                onPressed: onToggleCollapsed,
                child: const Icon(Icons.unfold_more),
              ),
            );
          }
          // 贴顶但仍有更早历史时保留顶部方向组(见 canLoadOlder 注释)。
          final showTop = !nearTop.value || canLoadOlder;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showTop) ...[
                FloatingActionButton.small(
                  tooltip: '回到顶部',
                  heroTag: null,
                  onPressed: onScrollToTop,
                  child: const Icon(Icons.keyboard_double_arrow_up),
                ),
                const SizedBox(height: 6),
                FloatingActionButton.small(
                  tooltip: '上一条消息',
                  heroTag: null,
                  onPressed: onScrollToPreviousMessage,
                  child: const Icon(Icons.keyboard_arrow_up),
                ),
              ],
              // 间距按"相邻组可见即加":贴顶/贴底只剩单侧方向组时,收起钮与
              // 最近的方向钮之间也要有 6px,不能贴住。
              if (showTop) const SizedBox(height: 6),
              FloatingActionButton.small(
                tooltip: '收起滚动导航',
                heroTag: null,
                onPressed: onToggleCollapsed,
                child: const Icon(Icons.unfold_less),
              ),
              if (!nearBottom.value) const SizedBox(height: 6),
              if (!nearBottom.value) ...[
                FloatingActionButton.small(
                  tooltip: '下一条消息',
                  heroTag: null,
                  onPressed: onScrollToNextMessage,
                  child: const Icon(Icons.expand_more),
                ),
                const SizedBox(height: 6),
                FloatingActionButton.small(
                  tooltip: '回到底部',
                  heroTag: null,
                  onPressed: onScrollToBottom,
                  child: const Icon(Icons.keyboard_double_arrow_down),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
