/// 居中对话框外框:标题栏 + 可选次栏 + 内容 + 动作栏。
///
/// 高度随内容收缩,最高 [maxHeightFactor] 屏高:条目少时不留半屏空白,
/// 条目多时在对话框内部滚动。列表需配 `shrinkWrap: true` 才能按内容量高。
/// 状态面板的变量回收站/世界书多选与用户头像预览共用同一外框。
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class AppDialogFrame extends StatelessWidget {
  /// 测试/定位用的内容约束 key(如 `status_dialog_frame`)。
  final Key? frameKey;
  final String title;
  final String? subtitle;
  final List<Widget> headerActions;
  final Widget? secondaryBar;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;
  final double maxHeightFactor;
  final EdgeInsets insetPadding;

  const AppDialogFrame({
    super.key,
    this.frameKey,
    required this.title,
    this.subtitle,
    this.headerActions = const [],
    this.secondaryBar,
    required this.child,
    this.actions = const [],
    this.maxWidth = 640,
    this.maxHeightFactor = 0.7,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 40,
      vertical: 32,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final height = MediaQuery.sizeOf(context).height * maxHeightFactor;
    return Dialog(
      insetPadding: insetPadding,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sheet),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: ConstrainedBox(
        key: frameKey,
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ...headerActions,
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(
              height: 0.5,
              thickness: 0.5,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
            if (secondaryBar != null) secondaryBar!,
            Flexible(child: child),
            if (actions.isNotEmpty) ...[
              Divider(
                height: 0.5,
                thickness: 0.5,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
