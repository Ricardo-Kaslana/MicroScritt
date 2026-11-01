import 'package:flutter/material.dart';

/// iOS 风格的分组标题:小号、半灰、全大写,作为区段锚点。
///
/// 与 Settings/Status 等屏的 `_SectionTitle` 语义一致,但样式更贴近 iOS 分组
/// 表格 —— 不再加粗,减小字号、提高字距,搭灰色小图标提示区段内容。
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
/// 整体一张白卡、圆角,贴紧左右留白。
///
/// 传入子组件应为同一竖向分组内的 `ListTile`(或自定义行)。卡片自带左右边距与
/// 8 圆角 —— 与系统「设置」的分组一致。
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

/// 一张无需外部边距的圆角卡片(继承全局 CardThemeData 的圆角/无阴影)。
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
