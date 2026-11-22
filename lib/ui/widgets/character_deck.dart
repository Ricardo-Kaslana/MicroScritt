/// 扑克牌堆式角色卡布局:正面一张卡居中完整展示,其余卡向左右扇形展开,
/// 按距离旋转、缩小、模糊并压暗,底边对齐;点两侧卡把它换到正面,左右轻扫
/// 或底部按钮翻牌,点正面卡(或「进入对话」)进入会话。换牌时整副牌平滑
/// 流转:离开的正面卡滑向侧翼,深处的卡淡出视野。拖动时整副牌带阻尼地
/// 跟手并轻微倾斜抬起,松手按「位移 + 速度投射」判断方向;翻牌时近处的
/// 卡先落位、深处的卡稍滞后,整副牌有层次地收拢。
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/character_repository.dart';
import '../common/motion.dart';
import 'character_avatar_preview.dart';

/// 牌堆视图:调用方给出当前(已过滤的)记录全集与打开/操作回调。
///
/// 只渲染可见窗口内的卡面(正面 + 每侧至多 2 张),更深的卡是廉价卡背,
/// 头像惰性读取因此不随角色总数增长;列表变化(搜索/删除)时按 id 保住
/// 正面卡,找不到才 clamp 到合法下标。
class CharacterDeckView extends StatefulWidget {
  final List<CharacterRecord> records;
  final ValueChanged<CharacterRecord> onOpen;
  final ValueChanged<CharacterRecord> onActions;

  /// 上次浏览停在正面的角色 id;恢复时找不到(已删除/被过滤)则回落到
  /// 当前列表第一张。
  final int? initialFrontId;

  /// 正面卡变化时按角色 id 回调,供上层持久化浏览进度。
  final ValueChanged<int>? onFrontChanged;

  const CharacterDeckView({
    super.key,
    required this.records,
    required this.onOpen,
    required this.onActions,
    this.initialFrontId,
    this.onFrontChanged,
  });

  @override
  State<CharacterDeckView> createState() => _CharacterDeckViewState();
}

class _CharacterDeckViewState extends State<CharacterDeckView> {
  /// 每侧最多画几张卡面;更深的卡收进透明的卡背堆。窄屏只留每侧 1 张。
  static const int _maxSideWide = 2;
  static const double _scaleStep = 0.08;
  static const double _radius = 16;

  /// 拖动跟手:膝盖以内 1:1,超出后以指数阻尼逼近上限,拖得再远也不脱手。
  static const double _dragKnee = 72;
  static const double _dragMax = 120;
  static const double _dragFollow = 0.55;
  static const double _dragTilt = 0.02;

  /// 松手判定:位移阈值 + 速度阈值;方向按「当前位移 + 速度投射」决定,
  /// 松手瞬间的微小反向速度不会压倒一次明确的拖动。
  static const double _flipDistance = 48;
  static const double _flingVelocity = 220;
  static const double _flingProjection = 0.1;

  int _front = 0;
  int? _frontId;

  /// 横向拖动累计距离(逻辑像素,正 = 向右)。绘制、阈值与松手方向都按
  /// [_dragOffset] 阻尼后的位移计算,手指行程本身只做累加。
  double _dragRaw = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    final records = widget.records;
    if (records.isEmpty) return;
    final restored = records.indexWhere((r) => r.id == widget.initialFrontId);
    _front = restored >= 0 ? restored : 0;
    _frontId = records[_front].id;
  }

  @override
  void didUpdateWidget(covariant CharacterDeckView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final records = widget.records;
    if (records.isEmpty) {
      _front = 0;
      _frontId = null;
      return;
    }
    // 搜索/删除后尽量让同一张卡留在正面;被过滤掉才退回合法下标。
    final kept = records.indexWhere((r) => r.id == _frontId);
    _front = kept >= 0 ? kept : math.min(_front, records.length - 1);
    _frontId = records[_front].id;
  }

  int _depth(int index, int count) => (index - _front) % count;

  ///  signed 扇形位置:0 = 正面,正 = 右翼第几张,负 = 左翼;超出可见窗口
  ///  clamp 到窗口外一格(透明度 0),翻牌时只有进出窗口的卡真正跑动画。
  double _position(int index, int count, int maxSide) {
    final depth = _depth(index, count);
    if (depth == 0) return 0;
    final half = count ~/ 2;
    final p = depth <= half ? depth.toDouble() : -(count - depth).toDouble();
    return p.clamp(-(maxSide + 1).toDouble(), (maxSide + 1).toDouble());
  }

  void _bringToFront(int index) {
    if (index == _front) return;
    // 翻牌给一声轻触觉:手势/按钮/点侧卡共用同一反馈。
    HapticFeedback.selectionClick();
    final id = widget.records[index].id;
    setState(() {
      _front = index;
      _frontId = id;
    });
    widget.onFrontChanged?.call(id);
  }

  void _step(int delta) {
    final n = widget.records.length;
    if (n < 2) return;
    _bringToFront((_front + delta) % n);
  }

  /// 拖动累计值 → 绘制位移:膝盖以内线性跟手,超出后以指数曲线逼近
  /// 上限,越拖越紧但始终有反馈(硬 clamp 会让手指与牌瞬间脱节)。
  double _dragOffset() {
    final magnitude = _dragRaw.abs();
    if (magnitude <= _dragKnee) return _dragRaw;
    final slack = _dragMax - _dragKnee;
    return _dragRaw.sign *
        (_dragKnee + slack * (1 - math.exp(-(magnitude - _dragKnee) / slack)));
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.records;
    final n = records.length;
    if (n == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final duration = motionDurationOf(
      context,
      const Duration(milliseconds: 300),
    );
    // 轻微过冲(约 1%)给卡牌落位一点「嗒」的收束感,幅度小到不会晃。
    const curve = Cubic(0.2, 0.9, 0.3, 1.06);
    final drag = _dragOffset();
    final dragProgress = (drag / _dragMax).clamp(-1.0, 1.0);

    return Padding(
      // 底部让开右下角的「添加」FAB,与列表/网格模式的留白一致。
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 点空白处收起检索键盘(牌堆没有可拖动的滚动视图)。
              onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
              onHorizontalDragStart: (_) => setState(() {
                _dragging = true;
                _dragRaw = 0;
              }),
              onHorizontalDragUpdate: (details) => setState(() {
                _dragRaw += details.delta.dx;
              }),
              onHorizontalDragCancel: () => setState(() {
                _dragging = false;
                _dragRaw = 0;
              }),
              onHorizontalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                final dx = _dragOffset();
                setState(() {
                  _dragging = false;
                  _dragRaw = 0;
                });
                // 方向用「位移 + 速度投射」:轻扫看速度,慢拖看位移;
                // 反向的惯性不会让一次明确拖动突然倒转。
                final projected = dx + velocity * _flingProjection;
                if (dx.abs() >= _flipDistance ||
                    velocity.abs() >= _flingVelocity) {
                  _step(projected < 0 ? 1 : -1);
                }
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxSide = constraints.maxWidth >= 640
                      ? _maxSideWide
                      : 1;
                  // 3:4 竖版卡面;宽度封顶,桌面不无限放大。侧翼要留出
                  // 露出的部分,卡面本身只占可用宽度的六成。
                  final cardW = math.min(
                    320.0,
                    math.min(
                      constraints.maxWidth * 0.6,
                      (constraints.maxHeight - 24) * 3 / 4,
                    ),
                  );
                  final cardH = cardW * 4 / 3;
                  // 侧翼间距:保证最外一张卡不越出可用宽度。
                  final spread = math.min(
                    0.66 * cardW,
                    (constraints.maxWidth / 2 - 0.42 * cardW) / maxSide,
                  );
                  // 深度大的先画,正面卡最后画(最上层、最先命中)。
                  final order = List<int>.generate(n, (i) => i)
                    ..sort(
                      (a, b) => _position(
                        b,
                        n,
                        maxSide,
                      ).abs().compareTo(_position(a, n, maxSide).abs()),
                    );
                  return AnimatedContainer(
                    // 拖动中即时跟手(0 时长),松手用短动画回到原位。
                    duration: _dragging
                        ? Duration.zero
                        : motionDurationOf(
                            context,
                            const Duration(milliseconds: 200),
                          ),
                    curve: Curves.easeOutCubic,
                    // 跟手之外再补一点同向倾斜与抬升:牌像被手指带起来,
                    // 而不是整块底板在平移。
                    transform: Matrix4.translationValues(
                      drag * _dragFollow,
                      -2.0 * dragProgress.abs(),
                      0,
                    )..rotateZ(dragProgress * _dragTilt),
                    transformAlignment: Alignment.center,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final i in order)
                          Positioned.fill(
                            key: ValueKey('deck-${records[i].id}'),
                            child: _animatedCard(
                              records[i],
                              i,
                              n,
                              maxSide: maxSide,
                              cardW: cardW,
                              cardH: cardH,
                              spread: spread,
                              duration: duration,
                              curve: curve,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          // 索引行恒占位(单卡显示「1 / 1」):此前单卡时整行消失,卡区
          // 高度变化会让 cardW 跟着跳,增减角色或搜索过滤后卡面忽大忽小。
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              n > 1 ? '${_front + 1} / $n · 点两侧卡切换,左右轻扫翻牌' : '1 / 1',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              if (n > 1)
                IconButton.filledTonal(
                  tooltip: '上一张',
                  onPressed: () => _step(-1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
              FilledButton.tonal(
                onPressed: () => widget.onOpen(records[_front]),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.surfaceContainerHighest,
                  foregroundColor: scheme.onSurface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('进入对话'),
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded, size: 18),
                  ],
                ),
              ),
              if (n > 1)
                IconButton.filledTonal(
                  tooltip: '下一张',
                  onPressed: () => _step(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 单张卡的扇形动画:一个 TweenAnimationBuilder 驱动 signed 位置 p,
  /// 偏移/旋转/缩放/模糊/压暗/透明度全部由 p 导出,翻牌时整副牌连贯流转。
  /// 时长按深度轻微错峰(近处先落位、深处稍滞后),扇形收拢更有层次。
  /// 卡面只在 |p| 进入可见窗口时构建(头像惰性读取),淡出到 0 才换卡背,
  /// 不会露出内容切换的瞬间。
  Widget _animatedCard(
    CharacterRecord record,
    int index,
    int count, {
    required int maxSide,
    required double cardW,
    required double cardH,
    required double spread,
    required Duration duration,
    required Curve curve,
  }) {
    final target = _position(index, count, maxSide);
    final lag = motionDurationOf(
      context,
      Duration(milliseconds: (target.abs() * 22).round()),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: duration + lag,
      curve: curve,
      builder: (context, p, _) {
        final a = p.abs();
        final scale = 1 - _scaleStep * a;
        final opacity = ((maxSide + 0.5 - a) * 2).clamp(0.0, 1.0);
        final scheme = Theme.of(context).colorScheme;
        // 深度 veil:用页面背景色罩住卡面,亮暗主题都自然变「远」。
        final veil = Theme.of(
          context,
        ).scaffoldBackgroundColor.withValues(alpha: math.min(0.16 * a, 0.4));
        return Align(
          alignment: Alignment.center,
          child: Transform.translate(
            // 底边对齐:缩放围绕中心,向下补半个高度差,扇形底边成一条线。
            offset: Offset(p * spread, (1 - scale) * cardH / 2),
            child: Transform.rotate(
              angle:
                  (p < 0 ? -1 : 1) * math.min(0.014 * a, 0.028) * 2 * math.pi,
              child: Transform.scale(
                scale: scale,
                child: SizedBox(
                  width: cardW,
                  height: cardH,
                  child: Opacity(
                    opacity: opacity,
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: 1.6 * a,
                        sigmaY: 1.6 * a,
                      ),
                      child: Container(
                        foregroundDecoration: BoxDecoration(
                          color: veil,
                          borderRadius: BorderRadius.circular(_radius),
                        ),
                        child: IgnorePointer(
                          ignoring: a > maxSide + 0.25,
                          child: a < maxSide + 0.5
                              ? _cardFace(
                                  record,
                                  index,
                                  front: a < 0.5,
                                  side: p < 0 ? -1 : 1,
                                )
                              : _cardBack(scheme),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 卡面:整块立绘 + 底部渐变叠名字;正面卡加描述与操作菜单。侧翼卡的
  /// 名字靠外缘对齐(露出的那一侧),保证能被认出、点中。
  Widget _cardFace(
    CharacterRecord record,
    int index, {
    required bool front,
    required int side,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final card = record.card;
    final description = card.description.trim();
    final align = front || side < 0
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.end;
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        onTap: front ? () => widget.onOpen(record) : () => _bringToFront(index),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CharacterAvatarPreview(
              recordId: record.id,
              card: card,
              borderRadius: 0,
              cacheWidth: 768,
            ),
            // 底部压暗保证白字可读,上半部保持立绘原样。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.45, 1],
                  colors: [Colors.transparent, Color(0xB3000000)],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: align,
                children: [
                  Text(
                    card.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: align == CrossAxisAlignment.start
                        ? TextAlign.left
                        : TextAlign.right,
                    style: (front ? text.titleMedium : text.titleSmall)
                        ?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (front && description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: const Color(0xCCFFFFFF),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (front)
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  tooltip: '更多操作',
                  onPressed: () => widget.onActions(record),
                  // 显式 40×40 命中区:立绘上的小图标容易被当成纯装饰,
                  // 紧凑密度下也保证手指点得中。
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: const EdgeInsets.all(8),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0x4D000000),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.more_vert, size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 卡背:堆底与翻牌过渡用,不读头像、不挂手势,代价与角色总数无关。
  Widget _cardBack(ColorScheme scheme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius - 6),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: Center(
            child: Icon(
              Icons.style_outlined,
              size: 28,
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}
