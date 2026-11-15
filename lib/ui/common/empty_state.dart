/// 列表/面板的空态占位组件。
///
/// 只做展示,不判断何时为空;是否给引导按钮由页面传入的 [EmptyState.action]
/// 决定。整页空态用默认档,嵌在分组卡/面板内的小区块用 [compact] 档。
library;

import 'package:flutter/material.dart';

/// 列表为空时的占位展示:图标(置于柔和圆形底内)+ 标题 + 说明 + 可选操作按钮。
/// 采用 iOS 风格——图标放进一档浅色圆片里,比裸 outline 图标更精致,层级更稳。
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  /// 紧凑档:更小的图标圆片与字号,用于状态面板等长页面的区块空态,
  /// 不抢整页空态的视觉重量。两个档位同源,避免各页自绘灰字提示。
  final bool compact;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final circle = compact ? 48.0 : 72.0;
    final iconSize = compact ? 22.0 : 32.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: circle,
              height: circle,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: iconSize,
                color: scheme.onSecondaryContainer,
              ),
            ),
            SizedBox(height: compact ? 10 : 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: compact
                  ? Theme.of(context).textTheme.titleSmall
                  : Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
            ),
            if (message != null) ...[
              SizedBox(height: compact ? 4 : 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: compact
                    ? Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      )
                    : Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
              ),
            ],
            if (action != null) ...{
              SizedBox(height: compact ? 12 : 22),
              action!,
            },
          ],
        ),
      ),
    );
  }
}
