/// 桌面端锚定弹卡(flyout):原地向上展开的卡片弹层,与移动端底部抽屉
/// ([showAppSheet])平行的桌面弹层形态。
///
/// 输入区底栏的命令/技能/模型/推理/上下文占用在桌面端不再沉到屏幕底缘,
/// 而是从触发按钮上方原地长出一张卡:鼠标点击后视线与指针都不用搬家。
///
/// 交互契约(与 ZCode 式模型卡一致):
/// - 无遮罩变暗、无叉号;点卡片外任意处或按 Esc 关闭;
/// - 卡片底边固定在锚点上方 [showAppFlyout] `gap` 处,内容向上生长,高度
///   同时受展开侧可用空间与 [kAppFlyoutMaxHeight](含窗口高度占比)约束,
///   超出由内容自身滚动接管;锚点贴近窗口顶缘时自动向下翻,卡片内容
///   永不出窗;
/// - 全局同一时刻只开一张:打开新卡前自动关掉已打开的卡;
/// - 触发件与卡片同处一个 [TapRegion] 组:再次点击触发件是 toggle,不会
///   「关了又立刻开」;
/// - [FlyoutHandle.rebuild] 支持打开期间热更新内容(斜杠建议逐键刷新)。
///
/// 定位每次布局都从锚点 RenderBox 现取:窗口缩放时卡片跟着锚点走,锚点
/// 卸载(如输入区整体收起)即关闭。
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'motion.dart';

/// 卡片与锚点的水平对齐:start = 左缘对齐锚点左缘,end = 右缘对齐锚点右缘。
enum AppFlyoutAlignment { start, end }

/// 卡片四周与窗口边缘的最小留白;水平夹取与高度上限共用。
const double _kScreenMargin = 12;

/// 弹卡高度上限:大窗口下命令/技能/模型清单不随条目数一路长高,超出的
/// 部分由卡内列表滚动接管。与窗口高度的 [kAppFlyoutHeightFactor] 取小,
/// 矮窗口下也不会一张卡吃掉大半个消息区。
const double kAppFlyoutMaxHeight = 480;

/// 弹卡可占窗口高度的最大比例(仅在窗口较矮时生效,见 [kAppFlyoutMaxHeight])。
const double kAppFlyoutHeightFactor = 0.6;

/// 全局当前打开的弹卡;打开新卡前先关它,保证同一时刻只有一张。
FlyoutHandle? _activeFlyout;

/// 组 id 发号器:每张卡(及其触发件)一个 [TapRegion] 组。
int _nextGroupId = 1;

/// 打开中的弹卡句柄:关闭、内容热更新与幂等判重。
class FlyoutHandle {
  final int groupId;
  OverlayEntry? _entry;
  RenderBox? _anchorBox;
  RenderBox? _overlayBox;
  VoidCallback? _onClose;
  bool Function(KeyEvent)? _escHandler;

  FlyoutHandle._(this.groupId);

  bool get isOpen => _entry != null;

  /// 内容热更新:OverlayEntry 不随宿主 setState 重建,逐键刷新的内容
  /// (斜杠建议)改完后显式调用。
  void rebuild() {
    final entry = _entry;
    if (entry != null && entry.mounted) entry.markNeedsBuild();
  }

  /// 关闭(幂等);[onClose] 只在真正移除时回调一次。
  void close() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    final handler = _escHandler;
    if (handler != null) {
      HardwareKeyboard.instance.removeHandler(handler);
      _escHandler = null;
    }
    if (identical(_activeFlyout, this)) _activeFlyout = null;
    _onClose?.call();
    _onClose = null;
    entry.remove();
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      close();
      return true;
    }
    return false;
  }
}

/// 触发件拿到的句柄接口:在 [FlyoutHandle] 的基础上补上主动打开与切换。
/// 单独抽成接口,避免实现类去满足 [FlyoutHandle] 的私有字段。
abstract class FlyoutTriggerHandle {
  int get groupId;
  bool get isOpen;
  void open();
  void toggle();
  void close();
  void rebuild();
}

/// 在 [anchorContext] 对应的锚点(通常是触发按钮/输入卡)上方打开一张弹卡。
///
/// [width] 为卡片定宽;[alignment] 决定水平对齐边;[gap] 是卡片底边与锚点
/// 顶边的间距;[groupId] 传入触发件所在 [TapRegion] 组以保证 toggle 语义;
/// [onClose] 在卡片因任何途径(点外/Esc/被新卡顶替/宿主卸载)移除时回调。
/// 返回的句柄可 [FlyoutHandle.close]/[FlyoutHandle.rebuild]。
FlyoutHandle showAppFlyout({
  required BuildContext anchorContext,
  required WidgetBuilder builder,
  required double width,
  AppFlyoutAlignment alignment = AppFlyoutAlignment.end,
  double gap = 6,
  int? groupId,
  VoidCallback? onClose,
}) {
  _activeFlyout?.close();
  final handle = FlyoutHandle._(groupId ?? _nextGroupId++);
  final overlay = Overlay.of(anchorContext, rootOverlay: true);
  final anchorBox = anchorContext.findRenderObject();
  final overlayBox = overlay.context.findRenderObject();
  if (anchorBox is! RenderBox || overlayBox is! RenderBox || !anchorBox.attached) {
    // 锚点还挂着弹卡却定位不了:不开卡,只把句柄按「已关闭」交给调用方,
    // 避免用异常打断点击链路。
    return handle;
  }
  handle
    .._anchorBox = anchorBox
    .._overlayBox = overlayBox
    .._onClose = onClose;

  final entry = OverlayEntry(
    builder: (entryContext) => LayoutBuilder(
      builder: (context, constraints) => _positionedCard(handle, context, constraints, builder, width, alignment, gap),
    ),
  );
  handle._entry = entry;
  handle._escHandler = handle._handleKey;
  HardwareKeyboard.instance.addHandler(handle._handleKey);
  _activeFlyout = handle;
  overlay.insert(entry);
  return handle;
}

/// 按锚点现算位置摆放卡片:默认底边固定在锚点上方、向上生长;锚点上方
/// 空间比下方小时(锚点贴近窗口顶缘)向下翻。卡片高度取展开侧可用空间
/// 与 [kAppFlyoutMaxHeight] 的较小者,超出由内容自身滚动接管。窗口缩放
/// 会触发重布局,位置随之更新。Overlay 的每个 entry 子树不是直接的
/// Stack 子级,这里自带一层满幅 Stack 来承载 [Positioned]。
Widget _positionedCard(
  FlyoutHandle handle,
  BuildContext context,
  BoxConstraints constraints,
  WidgetBuilder builder,
  double width,
  AppFlyoutAlignment alignment,
  double gap,
) {
  return LayoutBuilder(
    builder: (context, constraints) => Stack(
      children: [_flyoutStackChild(handle, context, constraints, builder, width, alignment, gap)],
    ),
  );
}

Widget _flyoutStackChild(
  FlyoutHandle handle,
  BuildContext context,
  BoxConstraints constraints,
  WidgetBuilder builder,
  double width,
  AppFlyoutAlignment alignment,
  double gap,
) {
  final anchorBox = handle._anchorBox;
  final overlayBox = handle._overlayBox;
  final overlaySize = constraints.biggest;
  if (anchorBox == null ||
      overlayBox == null ||
      !anchorBox.attached ||
      !overlaySize.isFinite) {
    // 锚点在弹卡打开期间被卸载:下一帧关闭,不留悬空卡片。
    WidgetsBinding.instance.addPostFrameCallback((_) => handle.close());
    return const SizedBox.shrink();
  }
  final topLeft = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
  final bottomRight = anchorBox.localToGlobal(
    anchorBox.size.bottomRight(Offset.zero),
    ancestor: overlayBox,
  );
  // 展开侧二选一:向上为默认语义,空间不足(锚点贴近顶缘)向下翻,
  // 卡片内容永不出窗。
  final spaceAbove = topLeft.dy - _kScreenMargin - gap;
  final spaceBelow = overlaySize.height - bottomRight.dy - _kScreenMargin - gap;
  final upward = spaceAbove >= spaceBelow;
  final availableHeight = math.max(0.0, upward ? spaceAbove : spaceBelow);
  // 展开侧空间只决定能否放下,再叠加固定上限:大窗口下长清单(命令/技能/
  // 模型)不再把卡片一路拉高,超出的条目改由卡内列表滚动。
  final cardMaxHeight = math.min(
    availableHeight,
    math.min(kAppFlyoutMaxHeight, overlaySize.height * kAppFlyoutHeightFactor),
  );
  final cardLeft = alignment == AppFlyoutAlignment.start
      ? topLeft.dx
      : bottomRight.dx - width;
  final clampedLeft = cardLeft
      .clamp(
        _kScreenMargin,
        math.max(_kScreenMargin, overlaySize.width - _kScreenMargin - width),
      )
      .toDouble();
  final scheme = Theme.of(context).colorScheme;
  final appearance = switch ((upward, alignment)) {
    (true, AppFlyoutAlignment.start) => Alignment.bottomLeft,
    (true, AppFlyoutAlignment.end) => Alignment.bottomRight,
    (false, AppFlyoutAlignment.start) => Alignment.topLeft,
    (false, AppFlyoutAlignment.end) => Alignment.topRight,
  };
  return Positioned(
    left: clampedLeft,
    width: width,
    bottom: upward ? overlaySize.height - topLeft.dy + gap : null,
    top: upward ? null : bottomRight.dy + gap,
    child: TapRegion(
      groupId: handle.groupId,
      onTapOutside: (_) => handle.close(),
      child: _FlyoutAppear(
        alignment: appearance,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: cardMaxHeight),
          child: Material(
            color: scheme.surface,
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: 0.22),
            surfaceTintColor: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadius.cardBorder,
              side: AppStroke.cardSide(scheme),
            ),
            child: builder(context),
          ),
        ),
      ),
    ),
  );
}

/// 入场过渡:自下缘淡入微缩放;减弱动态效果时直切。
class _FlyoutAppear extends StatelessWidget {
  final AlignmentGeometry alignment;
  final Widget child;
  const _FlyoutAppear({required this.alignment, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: motionDurationOf(context, const Duration(milliseconds: 150)),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.96 + 0.04 * t,
          alignment: alignment,
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 触发件锚点:把任意入口按钮包成「点击弹出上方卡片」的组件。
///
/// [builder] 拿到句柄自行接线(通常 `onTap: handle.toggle`);触发件整体被
/// 包进与卡片相同的 [TapRegion] 组 —— 卡片开着时再点触发件是关闭而不是
/// 「关了又开」。宿主卸载时联动关闭。
class AppFlyoutAnchor extends StatefulWidget {
  /// 触发件构建器;[FlyoutTriggerHandle] 供开/关/热更新。
  final Widget Function(BuildContext context, FlyoutTriggerHandle handle) builder;

  /// 卡片内容构建器;同样拿到句柄,便于行点选后自行关闭。
  final Widget Function(BuildContext context, FlyoutTriggerHandle handle)
  flyoutBuilder;

  /// 卡片定宽。
  final double width;

  /// 卡片与锚点的水平对齐。
  final AppFlyoutAlignment alignment;

  /// 卡片底边与锚点顶边的间距。
  final double gap;

  /// 卡片关闭时回调(见 [showAppFlyout])。
  final VoidCallback? onClose;

  const AppFlyoutAnchor({
    super.key,
    required this.builder,
    required this.flyoutBuilder,
    required this.width,
    this.alignment = AppFlyoutAlignment.end,
    this.gap = 6,
    this.onClose,
  });

  @override
  State<AppFlyoutAnchor> createState() => _AppFlyoutAnchorState();
}

class _AppFlyoutAnchorState extends State<AppFlyoutAnchor> {
  late final int _groupId = _nextGroupId++;
  FlyoutHandle? _handle;

  void _open() {
    if (_handle?.isOpen ?? false) return;
    final trigger = _FlyoutTrigger(this);
    _handle = showAppFlyout(
      anchorContext: context,
      builder: (cardContext) => widget.flyoutBuilder(cardContext, trigger),
      width: widget.width,
      alignment: widget.alignment,
      gap: widget.gap,
      groupId: _groupId,
      onClose: () {
        // 句柄已被顶层注册表清空,这里只清本地引用并透传宿主回调。
        _handle = null;
        widget.onClose?.call();
      },
    );
  }

  void _close() => _handle?.close();

  /// 开/关切换;open 是幂等的(重复 open 不叠加)。
  void _toggle() {
    if (_handle?.isOpen ?? false) {
      _close();
    } else {
      _open();
    }
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: _groupId,
      child: widget.builder(context, _FlyoutTrigger(this)),
    );
  }
}

/// 触发件拿到的不变句柄视图:只暴露开关与状态,不泄漏内部字段。
class _FlyoutTrigger implements FlyoutTriggerHandle {
  final _AppFlyoutAnchorState _state;
  _FlyoutTrigger(this._state);

  @override
  int get groupId => _state._groupId;

  @override
  bool get isOpen => _state._handle?.isOpen ?? false;

  @override
  void close() => _state._close();

  @override
  void open() => _state._open();

  @override
  void toggle() => _state._toggle();

  @override
  void rebuild() => _state._handle?.rebuild();
}

/// 弹卡标题行:主色小图标 + 标题,无叉号(点卡外/Esc 关闭)。
class AppFlyoutHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;

  const AppFlyoutHeader({super.key, required this.icon, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 弹卡通用行:可选图标 + 标题 + 可选两行副标题 + 尾部件(如选中勾)。
/// 命令卡/技能卡/模型卡共用,保证行高、内边距与悬停反馈一致。
class AppFlyoutRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  const AppFlyoutRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm + 2),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
