import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/context_snapshot.dart';
import '../state/chat_controller.dart';
import 'common/empty_state.dart';
import 'common/section_header.dart';

/// 上下文面板:实时展示当前会话发给 LLM 的上下文组成(分段 + 字符数)、
/// 历史消息条数,以及 token 用量与缓存命中率。由聊天页 AppBar 以底部抽屉打开,
/// 监听 chatControllerProvider,发送/流式过程中保持最新。
///
/// 分段严格按组装器实际顺序排列([ContextSnapshot.segments]),每段默认折叠,
/// 展开后查看其完整内容;预设/规则/世界书与会话历史还进一步按条目划分。段落
/// 按缓存角色打上小标签:稳定前缀(进 system 稳定段)/ 消息数组(随 messages
/// 发出)/ 状态旁路(缓存断点后的合成 user 消息),并可一键全部展开/收起。
class ContextPanel extends ConsumerStatefulWidget {
  const ContextPanel({super.key});

  @override
  ConsumerState<ContextPanel> createState() => _ContextPanelState();
}

class _ContextPanelState extends ConsumerState<ContextPanel> {
  /// 全部展开模式:为真时所有分段与细分条目强制展开;用户点按任何分段头会
  /// 退出该模式,恢复各自局部折叠状态。
  bool _expandAll = false;

  void _clearExpandAll() {
    if (_expandAll) setState(() => _expandAll = false);
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final ctx = chat.lastContext;

    return Column(
      children: [
        _PanelHeader(onClose: () => Navigator.pop(context)),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _TokensCard(chat: chat),
              if (ctx == null)
                const Padding(
                  padding: EdgeInsets.only(top: 32),
                  child: EmptyState(
                    icon: Icons.inbox_outlined,
                    title: '还没有上下文',
                    message: '发送一条消息后,这里展示本次请求实际发给 LLM 的内容组成。',
                  ),
                )
              else ...[
                const SizedBox(height: 12),
                // 会话概况:历史条数 + 系统提示词规模,一眼可读。
                GroupCard(
                  children: [
                    _InfoRow(
                      icon: Icons.forum_outlined,
                      label: '历史消息',
                      value: '${ctx.messages.length} 条',
                    ),
                    _InfoRow(
                      icon: Icons.article_outlined,
                      label: '系统提示词',
                      value: '${ctx.systemPrompt.length} 字符',
                    ),
                    // 历史截断标注:加载窗口下界之外还有更早历史时,面板只显示
                    // 已加载的部分 —— 不加说明会被误读成"旧消息被丢弃"(消息全部
                    // 在库,聊天区上滑可逐页加载完整记录)。组装自 2026-09-28 批
                    // 起不再按条数裁剪,「窗口之外」与「未进上下文」已是同一件
                    // 事,判据收敛到 canLoadOlder。不写具体条数:组装器只见得到
                    // 已加载部分,精确总数会低报。
                    if (chat.canLoadOlder) const _HistoryTruncationTile(),
                  ],
                ),
                // 上下文组成区段头 + 全部展开/收起。
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: SectionHeader(
                          '上下文组成',
                          icon: Icons.layers_outlined,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      if (ctx.segments.isNotEmpty)
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _expandAll = !_expandAll),
                          icon: Icon(
                            _expandAll ? Icons.unfold_less : Icons.unfold_more,
                            size: 16,
                          ),
                          label: Text(_expandAll ? '全部收起' : '全部展开'),
                          style: TextButton.styleFrom(
                            minimumSize: Size.zero,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (ctx.segments.isEmpty)
                  const _EmptyHint('本会话没有可展示的上下文分段。')
                else
                  GroupCard(
                    children: [
                      for (final segment in ctx.segments)
                        _SegmentTile(
                          segment: segment,
                          forceExpanded: _expandAll,
                          onUserToggle: _clearExpandAll,
                        ),
                    ],
                  ),
                // 缓存友好提示放在所有分段之后 —— 不挤占上方分段的位置,避免
                // 影响会话历史/世界书等分段在列表中的滚动定位。
                _StablePrefixTile(
                  ctx: ctx,
                  prevHash: chat.prevStableSystemHash,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 抽屉顶栏:图标 + 标题 + 关闭按钮,与聊天页一致的浅色块图标语言。
class _PanelHeader extends StatelessWidget {
  final VoidCallback onClose;
  const _PanelHeader({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.query_stats_outlined,
              size: 18,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '会话上下文',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// 上下分段在缓存布局中的角色,决定标签颜色与图标色调。
enum _SegmentBucket {
  /// 进 system 稳定段:preset / rules / character / postHistory / 常驻世界书。
  /// (CW 批起技能不再进 system —— 只有 @技能名 主动触发的附件行,归 messages。)
  stable,

  /// 随 messages 数组发出:记忆第 0 条 + 压缩摘要(数组头部合成消息)+ 会话历史
  /// + 已落库的附件行。
  history,

  /// 一次性通知(压缩/记忆 diff):合成插在最新用户消息之前,发出即消失。
  /// (变量自 CL 批起只进后台 agent 上下文,主写分段里不会出现。)
  state,
}

_SegmentBucket _bucketOf(String key) => switch (key) {
  'preset' ||
  'rules' ||
  'character' ||
  'postHistory' ||
  'worldbookConstant' => _SegmentBucket.stable,
  'memory' || 'history' || 'summary' || 'attachments' => _SegmentBucket.history,
  _ => _SegmentBucket.state,
};

(String, Color) _bucketSpec(_SegmentBucket bucket, ColorScheme scheme) =>
    switch (bucket) {
      _SegmentBucket.stable => ('稳定前缀', scheme.primary),
      _SegmentBucket.history => ('消息数组', scheme.secondary),
      _SegmentBucket.state => ('通知', scheme.tertiary),
    };

IconData _segmentIcon(String key) => switch (key) {
  'preset' => Icons.auto_fix_high,
  'rules' => Icons.gavel,
  'character' => Icons.person_outline,
  'postHistory' => Icons.notes,
  'worldbookConstant' => Icons.menu_book_outlined,
  'memory' => Icons.lightbulb_outline,
  'history' => Icons.forum_outlined,
  'summary' => Icons.compress,
  'attachments' => Icons.attach_file,
  // 'variables' 分段已随 CL 批移除:变量只进后台 agent 上下文,主写快照不再产出。
  _ => Icons.article_outlined,
};

/// 单个上下分段:图标 + 标签 + 计数 + 缓存角色标签,点击整行展开/收起。
/// 有细分条目时按条目划分;纯文本段展开显示完整可选中内容。
class _SegmentTile extends StatefulWidget {
  final ContextSegment segment;
  final bool forceExpanded;
  final VoidCallback onUserToggle;

  const _SegmentTile({
    required this.segment,
    required this.forceExpanded,
    required this.onUserToggle,
  });

  @override
  State<_SegmentTile> createState() => _SegmentTileState();
}

class _SegmentTileState extends State<_SegmentTile> {
  bool _expanded = false;

  /// 历史/世界书子项的初始展示条数:超长历史点开时先铺一页,
  /// 其余按需加载,避免一次布局几百条消息内容。
  static const int _subEntryPageSize = 60;
  int _visibleSubEntries = _subEntryPageSize;

  bool get _effective => _expanded || widget.forceExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segment = widget.segment;
    final subCount = segment.subEntries.length;
    final (bucketLabel, bucketColor) = _bucketSpec(
      _bucketOf(segment.key),
      scheme,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            setState(() => _expanded = !_effective);
            // 用户手动收起时退出"全部展开"模式,其余分段回到各自折叠状态。
            widget.onUserToggle();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bucketColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _segmentIcon(segment.key),
                    size: 18,
                    color: bucketColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        segment.label,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        subCount > 0
                            ? '$subCount 条 · ${segment.content.length} 字符'
                            : '${segment.content.length} 字符',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _BucketChip(label: bucketLabel, color: bucketColor),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _effective ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.expand_more,
                    size: 18,
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
        _AnimatedReveal(
          visible: _effective,
          // 用 builder 而不是直接传 child:折叠态不构建子项。旧实现即使
          // 收起也会构建整段历史的所有 _SubEntryTile(Offstage 只省布局,
          // 不省构建),上下文越长打开面板越慢。
          childBuilder: (context) {
            final visibleSubs = segment.subEntries
                .take(_visibleSubEntries)
                .toList(growable: false);
            final hasMore = visibleSubs.length < segment.subEntries.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Divider(
                  height: 1,
                  indent: 60,
                  endIndent: 14,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 有逐条细分(世界书命中 / 会话历史消息)时,整段全文已在各条里
                      // 分别展示,不再在底部重复一段拼接全文 —— 那会在大历史里垫出
                      // 一大块尾部,挤在滚动区底缘上,导致靠后的条目被裁切/看不全
                      // 高亮胶囊。
                      if (segment.hasSubEntries)
                        for (final sub in visibleSubs)
                          _SubEntryTile(
                            label: sub.label,
                            content: sub.content,
                            forceExpanded: widget.forceExpanded,
                          )
                      else if (segment.content.isNotEmpty)
                        _SelectableBlock(text: segment.content, scheme: scheme),
                      if (hasMore)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: TextButton.icon(
                            onPressed: () => setState(
                              () => _visibleSubEntries += _subEntryPageSize,
                            ),
                            icon: const Icon(Icons.expand_more, size: 18),
                            label: Text(
                              '显示更多(${segment.subEntries.length - visibleSubs.length} 条)',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 缓存角色标签:稳定前缀 / 消息数组 / 状态旁路。
class _BucketChip extends StatelessWidget {
  final String label;
  final Color color;
  const _BucketChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          letterSpacing: 0.2,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 细分条目(预设的单个预设 / 世界书的单条命中 / 会话历史的单条消息)。
/// 默认折叠:只显示标签胶囊,不暴露具体内容;点击二级展开才显示完整可选中全文。
/// 预设/世界书/会话历史这种多条目长内容,展开整段时不一次性铺满全文。
class _SubEntryTile extends StatefulWidget {
  final String label;
  final String content;
  final bool forceExpanded;

  const _SubEntryTile({
    required this.label,
    required this.content,
    required this.forceExpanded,
  });

  @override
  State<_SubEntryTile> createState() => _SubEntryTileState();
}

class _SubEntryTileState extends State<_SubEntryTile> {
  bool _expanded = false;

  /// 全文内容区按下时的原始指针事件(用于绕过 SelectionArea 对手势竞技场的
  /// 占据,让"点击可选文本也能收起"仍然生效)。
  PointerDownEvent? _contentDown;

  bool get _effective => _expanded || widget.forceExpanded;

  void _handleContentPointerUp(PointerUpEvent e) {
    final down = _contentDown;
    _contentDown = null;
    if (down == null) return;
    final moved = (e.position - down.position).distance;
    final quick =
        e.timeStamp - down.timeStamp < const Duration(milliseconds: 350);
    // 快速轻点视为"点击收起";长按选区、拖动选择等由 SelectionArea 处理。
    if (quick && moved <= 24) setState(() => _expanded = !_effective);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            // 全部展开模式下点击单条:只折叠这一条,其余保持展开。
            setState(() => _expanded = !_effective);
          },
          child: Padding(
            // 右侧不留内边距:三角与分段级三角共用同一条右缘线
            // (分段行右缩进 14,子条目卡片本身已处于该缩进内)。
            padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 单一 flex 子组件:Expanded+Align 让胶囊左对齐、三角固定在
                    // 行右缘。此前 Flexible(默认 flex 1)与 Spacer(flex 1)平分
                    // 剩余空间,三角悬在行中部且横向位置随标签长度漂移。
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _effective ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more,
                        size: 16,
                        color: scheme.outline,
                      ),
                    ),
                  ],
                ),
                // 二级展开:折叠态不显示任何内容(整个内容区 Offstage 隐藏,finder
                // 跳过),只留标签胶囊;展开时全文从 0 向下平滑长出(含顶部小间隙)。
                _AnimatedReveal(
                  visible: _effective,
                  duration: const Duration(milliseconds: 200),
                  childBuilder: (context) => Padding(
                    // 头部行右侧无内边距(三角对齐用),正文单独补回右边距。
                    padding: const EdgeInsets.only(right: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        Listener(
                          onPointerDown: (e) => _contentDown = e,
                          onPointerUp: _handleContentPointerUp,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SelectionArea(
                              child: Text(
                                widget.content,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.45,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
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

/// 高度展开/收拢动画容器:折叠态以 Offstage 隐藏(默认 finder 跳过 offstage
/// 子树)。子内容由 [childBuilder] 按需构建 —— 完全折叠时**不构建**子树
/// (长历史点开前零成本),展开时构建,收拢动画结束后释放。
///
/// 结构要点:AnimatedBuilder 必须包在最外层 —— 只有它的 builder 会在动画每一
/// 帧(含收尾帧)重新执行,从而让 Offstage 的 offstage 标志与 Align 的
/// heightFactor 都随动画实时求值;若把它们放在父级 widget 里,动画结束后
/// (status=dismissed)父级不会重建,隐藏内容仍会被 finder / 命中测试看到。
class _AnimatedReveal extends StatefulWidget {
  final bool visible;
  final WidgetBuilder childBuilder;
  final Duration duration;

  const _AnimatedReveal({
    required this.visible,
    required this.childBuilder,
    this.duration = const Duration(milliseconds: 220),
  });

  @override
  State<_AnimatedReveal> createState() => _AnimatedRevealState();
}

class _AnimatedRevealState extends State<_AnimatedReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.visible ? 1 : 0,
  );
  late final Animation<double> _height = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    // 收拢动画结束:重建一次,让 build 里的 shouldBuild 落到 false,
    // 释放已构建的子项(不再仅仅藏起来)。
    _controller.addStatusListener(_handleStatus);
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        !widget.visible &&
        mounted &&
        _controller.value == 0) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(_AnimatedReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && _controller.value < 1) _controller.forward();
    if (!widget.visible && _controller.value > 0) _controller.reverse();
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 完全折叠且动画归零后才不构建;展开过程中保持已构建的子项。
    final shouldBuild = widget.visible || _controller.value > 0;
    final child = shouldBuild
        ? widget.childBuilder(context)
        : const SizedBox.shrink();
    // Offstage 必须随动画逐帧重建,否则动画收尾(dismissed)后 flag 停留在
    // 上一次 widget 重建时的值,隐藏内容在 finder/命中测试里仍然可见。
    // 因此把 AnimatedBuilder 提到最外层,让 builder 在每一帧(含收尾帧)
    // 重新计算 offstage 与 heightFactor。
    return AnimatedBuilder(
      animation: _height,
      child: child,
      builder: (context, child) {
        final settledHidden =
            !widget.visible && _controller.status == AnimationStatus.dismissed;
        return Offstage(
          offstage: settledHidden,
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: _height.value,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 可选择文本块(bodySmall)。
class _SelectableBlock extends StatelessWidget {
  final String text;
  final ColorScheme scheme;
  const _SelectableBlock({required this.text, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SelectionArea(
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// token 用量卡片:主写/后台 + 缓存命中率。
class _TokensCard extends StatelessWidget {
  final ChatState chat;
  const _TokensCard({required this.chat});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hitRate = chat.inputTokens == 0
        ? 0.0
        : chat.cachedInputTokens / chat.inputTokens;
    final hasBg =
        chat.backgroundInputTokens > 0 || chat.backgroundOutputTokens > 0;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.data_usage, size: 16, color: scheme.primary),
              ),
              const SizedBox(width: 10),
              Text('Token 用量', style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 10),
          _row(context, '输入', '${chat.inputTokens} tok'),
          _row(
            context,
            '缓存命中',
            '${chat.cachedInputTokens} tok · 命中率 ${(hitRate * 100).toStringAsFixed(0)}%',
            valueColor: chat.cachedInputTokens > 0 ? scheme.primary : null,
          ),
          if (chat.inputTokens > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: hitRate,
                  minHeight: 4,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ),
          _row(context, '输出', '${chat.outputTokens} tok'),
          if (hasBg) ...[
            const Divider(height: 18),
            Text(
              '后台引擎(状态维护)',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: 4),
            _row(
              context,
              '输入',
              '${chat.backgroundInputTokens} tok(缓存 ${chat.backgroundCachedInputTokens} tok)',
            ),
            _row(context, '输出', '${chat.backgroundOutputTokens} tok'),
          ],
          if (chat.inputTokens == 0 && chat.outputTokens == 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '尚未产生用量',
                style: TextStyle(color: scheme.outline, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    Color? valueColor,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 历史截断标注行(会话概况卡内):沿用面板既有的折叠语言 —— 收起态只留
/// 一行"更早的历史未进入上下文(并未丢失)"提示与展开箭头,点击展开完整
/// 说明。常驻长文案会把概况卡撑高、压在世界书/历史分段上方,点开才展开
/// 更贴合"标注"的定位。
class _HistoryTruncationTile extends StatefulWidget {
  const _HistoryTruncationTile();

  @override
  State<_HistoryTruncationTile> createState() => _HistoryTruncationTileState();
}

class _HistoryTruncationTileState extends State<_HistoryTruncationTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: scheme.outline),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '更早的历史未进入上下文(并未丢失)',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.expand_more,
                    size: 18,
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
            _AnimatedReveal(
              visible: _expanded,
              childBuilder: (context) => Padding(
                padding: const EdgeInsets.fromLTRB(30, 2, 0, 0),
                child: Text(
                  '仅展示实际发给模型的最近历史,更早的消息未进入上下文;'
                  '完整记录可在聊天区上滑加载查看。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话概况行:图标 + 标签 + 值(等宽数字,便于对齐)。
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.outline),
        ),
      ),
    );
  }
}

/// 缓存友好提示:对比本轮稳定 system 前缀与上一轮的哈希,直观显示缓存重用区
/// 是否漂移。稳定前缀(预设/规则/角色卡/剧情后注/常驻世界书)不变 ⇒ 本轮请求可
/// 命中 LLM 提示缓存;变了 ⇒ 缓存区漂移,本轮的 cache_creation 会增大。
class _StablePrefixTile extends StatelessWidget {
  final ContextSnapshot ctx;
  final int? prevHash;
  const _StablePrefixTile({required this.ctx, required this.prevHash});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hash = ctx.stableSystemHash;
    final bool hasStable = hash != 0;
    final bool changed = hasStable && prevHash != null && prevHash != hash;

    final String status;
    final String hint;
    final Color color;
    if (!hasStable) {
      // 无稳定前缀(纯 system,如无预设/规则/角色卡)或首轮(无上一轮可对照)。
      if (prevHash == null) {
        status = '首轮 · 尚无对照';
        hint = '发送一条消息后,与下一轮对比稳定前缀哈希。';
      } else {
        status = '无稳定前缀';
        hint = '本会话没有预设/规则/角色卡等可缓存稳定段。';
      }
      color = scheme.outline;
    } else if (changed) {
      status = '稳定前缀已变化';
      hint = '缓存区漂移,本轮将重新建立提示缓存。';
      color = scheme.error;
    } else {
      status = '稳定前缀未变';
      hint = '可命中 LLM 提示缓存,节省本轮输入开销。';
      color = scheme.primary;
    }

    return GroupCard(
      margin: const EdgeInsets.only(top: 8),
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.auto_awesome_motion, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasStable) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.7,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    hash.toRadixString(16),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.5,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
