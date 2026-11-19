/// 行级 diff 渲染:红绿行、+/- 槽、未变段折叠与超长截断。
///
/// 只渲染折叠后的前 [maxLinesBeforeExpand] 行(默认 200),避免大段正文
/// 一次铺满卡片;点击「展开全部」再渲染剩余行。整块包在 [SelectionArea]
/// 里,用户可直接选中复制。
library;

import 'package:flutter/material.dart';

import '../../engine/card_studio/card_diff.dart';

class DiffTextView extends StatefulWidget {
  final TextDiff diff;

  /// 折叠/截断前最多渲染的行数(含折叠占位)。
  final int maxLinesBeforeExpand;

  const DiffTextView({
    super.key,
    required this.diff,
    this.maxLinesBeforeExpand = 200,
  });

  @override
  State<DiffTextView> createState() => _DiffTextViewState();
}

class _DiffTextViewState extends State<DiffTextView> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant DiffTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diff != widget.diff) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final folded = foldDiffLines(widget.diff);
    if (folded.isEmpty) return const SizedBox.shrink();
    final visible = _expanded
        ? folded
        : folded.take(widget.maxLinesBeforeExpand).toList(growable: false);
    final hidden = folded.length - visible.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in visible) _DiffLineRow(line: line),
              ],
            ),
          ),
        ),
        if (hidden > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expanded = true),
              child: Text('展开全部（还有 $hidden 行）'),
            ),
          ),
      ],
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  final FoldedDiffLine line;
  const _DiffLineRow({required this.line});

  static const Color _added = Color(0xFF2E7D32);
  static const Color _removed = Color(0xFFC62828);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = line.collapsedCount;
    if (collapsed != null) {
      return Container(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Text(
          '… $collapsed 行未变 …',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
      );
    }
    final (gutter, color, background) = switch (line.kind) {
      DiffLineKind.added => ('+', _added, _added.withValues(alpha: 0.10)),
      DiffLineKind.removed => ('-', _removed, _removed.withValues(alpha: 0.08)),
      DiffLineKind.same => (' ', scheme.onSurfaceVariant, Colors.transparent),
    };
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            child: Text(
              gutter,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              line.text.isEmpty ? ' ' : line.text,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
