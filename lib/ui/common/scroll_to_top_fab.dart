import 'package:flutter/material.dart';

/// 长列表的「回到顶部」小按钮:滚动超过 [showAfter] 后出现,隐藏时零高度。
/// 直接放进各页 `floatingActionButton` 的 Column 里,叠在新增 FAB 上方。
class ScrollToTopFab extends StatefulWidget {
  final ScrollController controller;
  final double showAfter;

  const ScrollToTopFab({
    super.key,
    required this.controller,
    this.showAfter = 480,
  });

  @override
  State<ScrollToTopFab> createState() => _ScrollToTopFabState();
}

class _ScrollToTopFabState extends State<ScrollToTopFab> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollToTopFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleScroll);
      widget.controller.addListener(_handleScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleScroll);
    super.dispose();
  }

  void _handleScroll() {
    final visible =
        widget.controller.hasClients &&
        widget.controller.offset > widget.showAfter;
    if (visible != _visible) {
      setState(() => _visible = visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      transitionBuilder: (child, animation) => ScaleTransition(
        scale: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: _visible
          ? FloatingActionButton.small(
              key: const ValueKey('scroll-to-top'),
              heroTag: null,
              tooltip: '回到顶部',
              onPressed: () => widget.controller.animateTo(
                0,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
              ),
              child: const Icon(Icons.vertical_align_top_rounded, size: 20),
            )
          : const SizedBox.shrink(key: ValueKey('scroll-to-top-hidden')),
    );
  }
}
