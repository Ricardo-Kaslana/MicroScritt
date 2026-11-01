/// iOS 分组表单的区段标题与两种卡片容器([GroupCard]/[SurfaceCard])。
///
/// 层级靠灰底与卡片白面的明度差加 hairline 描边表达,不用阴影,保证亮暗
/// 主题下观感一致。
library;

import 'package:flutter/material.dart';

/// iOS 风格的分组标题:小号、半灰,作为区段锚点。
///
/// 样式统一走全局 `titleSmall`(13 / w600 / `onSurfaceVariant`),可选前缀
/// 图标用主色;各页不要再自绘区段标题,避免字号与颜色漂移。
class SectionHeader extends StatelessWidget {
  final String text;
  final IconData? icon;
  final EdgeInsets padding;

  const SectionHeader(this.text, {super.key, this.icon, this.padding = const EdgeInsets.only(bottom: 10)});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
          ],
          Text(text, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}

/// iOS inset-grouped 风格的分组卡片:一段连续的分组,内部用 hairline 分隔条目,
/// 整体一张白卡、14 圆角,宽度随父级。
///
/// 传入子组件应为同一竖向分组内的 `ListTile`(或自定义行);卡片只带纵向
/// 外边距,左右留白由页面提供。
class GroupCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry? padding;
  final BorderRadius radius;

  const GroupCard({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(vertical: 4),
    this.padding,
    this.radius = const BorderRadius.all(Radius.circular(14)),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: radius,
        // 弱化阴影,用 hairline 描边把分组从灰底上分出来,层级干净。
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                indent: 16,
                endIndent: 16,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            child,
          ],
        ],
      ),
    );
  }
}

/// 无外部边距的圆角卡片:16 圆角 + hairline 描边 + 内边距。
/// 常用于在灰底上承载独立成块的内容(如 token 用量卡)。
class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: child,
    );
  }
}
