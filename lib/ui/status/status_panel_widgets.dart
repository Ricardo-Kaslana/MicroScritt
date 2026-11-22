/// 状态面板区块的加载骨架与失败提示行。

part of '../status_screen.dart';

/// 区块加载骨架:固定三行灰条,数据到达时的高度变化远小于一颗居中转圈,
/// 面板内三个区块加载时不再整体跳动。
class _SectionSkeleton extends StatelessWidget {
  const _SectionSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double widthFactor) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: 12,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
    return GroupCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [bar(0.4), bar(0.85), bar(0.65)],
          ),
        ),
      ],
    );
  }
}

/// 面板内的错误提示行(变量 / 记忆 / 生图指导三区块共用)。
/// 空态已统一为 [EmptyState] 紧凑档,这里只承担加载失败的红色提示。
class _EmptyHint extends StatelessWidget {
  final String text;
  final bool isError;
  const _EmptyHint(this.text, {this.isError = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? scheme.error : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
