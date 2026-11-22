/// 设置工作区的骨架与通用卡片。
///
/// 形态对齐状态面板的桌面工作区(固定头部 + 限宽滚动正文),但常量与组件
/// 都留在设置页内部,不与 `status_*` 互相 import。
library;

import 'package:flutter/material.dart';

import '../common/section_header.dart';
import 'settings_layout.dart';

/// 工作区外壳:居中限宽、固定头部、正文占满剩余高度。
class SettingsWorkspaceFrame extends StatelessWidget {
  final Widget header;
  final Widget child;

  const SettingsWorkspaceFrame({
    super.key,
    required this.header,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: kSettingsDesktopContentMaxWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 20),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工作区头部:标题 + 说明 + 右侧动作;窄于 820 时动作折到标题下方。
class SettingsWorkspaceHeader extends StatelessWidget {
  final String title;
  final String? description;
  final List<Widget> actions;

  const SettingsWorkspaceHeader({
    super.key,
    required this.title,
    this.description,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(
            description!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final actionWrap = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: actions,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleBlock,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: actionWrap),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: titleBlock),
            if (actions.isNotEmpty) ...[const SizedBox(width: 16), actionWrap],
          ],
        );
      },
    );
  }
}

/// 卡片内小标题(图标 + 灰字),与外层 SurfaceCard 形成层级。
class SettingsCardTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;

  const SettingsCardTitle({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return SectionHeader(
      title,
      icon: icon,
      padding: EdgeInsets.zero,
      trailing: trailing,
    );
  }
}

/// 响应式列容器:内容宽 ≥ [breakpoint] 时按两列分组(顶对齐),否则单列。
///
/// 不用 IntrinsicHeight:Material 的 ListTile/Slider 实测高度与固有高度存在
/// 偏差,强制等高会把卡片内容挤出底边;顶对齐允许各卡按内容自然收高。
class SettingsResponsiveColumns extends StatelessWidget {
  final List<Widget> children;
  final double gap;
  final double breakpoint;

  const SettingsResponsiveColumns({
    super.key,
    required this.children,
    this.gap = 16,
    this.breakpoint = 900,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < breakpoint || children.length < 2) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) SizedBox(height: gap),
                child,
              ],
            ],
          );
        }
        final rows = <Widget>[];
        for (var i = 0; i < children.length; i += 2) {
          final hasSecond = i + 1 < children.length;
          if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: children[i]),
                if (hasSecond) ...[
                  SizedBox(width: gap),
                  Expanded(child: children[i + 1]),
                ],
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

/// 可点击入口卡:图标 + 标题 + 说明 + chevron,整卡跳转。
class SettingsLinkCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const SettingsLinkCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right, size: 20, color: scheme.outline),
        ],
      ),
    );
  }
}

/// 动作卡:标题 + 说明 + 底部操作按钮(配置导入导出用)。
class SettingsActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback? onPressed;

  const SettingsActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsCardTitle(icon: icon, title: title),
          const SizedBox(height: 10),
          Text(
            description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}
