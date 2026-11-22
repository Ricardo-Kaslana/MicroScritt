/// 嵌入式异步区块:统一 loading / error+retry / data 三态。
///
/// [compact] 用于卡片/面板内的小区块:更小的加载圈与紧凑错误空态;
/// 整页正文传 false。错误态默认给 [EmptyState] 与「重试」按钮(传
/// [onRetry] 时),调用方仍可用 [loadingBuilder]/[errorBuilder] 覆盖
/// 骨架屏等特殊版式。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'empty_state.dart';
import 'inline_spinner.dart';

class AsyncSection<T> extends StatelessWidget {
  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;
  final bool compact;
  final String errorTitle;
  final WidgetBuilder? loadingBuilder;
  final Widget Function(BuildContext context, Object error)? errorBuilder;

  const AsyncSection({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
    this.compact = true,
    this.errorTitle = '加载失败',
    this.loadingBuilder,
    this.errorBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: (data) => builder(context, data),
      loading: () =>
          loadingBuilder?.call(context) ??
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: InlineSpinner(
                size: compact ? 24 : 36,
                strokeWidth: compact ? 2.5 : 4,
              ),
            ),
          ),
      error: (error, _) =>
          errorBuilder?.call(context, error) ??
          EmptyState(
            compact: compact,
            icon: Icons.error_outline,
            title: errorTitle,
            message: '$error',
            action: onRetry == null
                ? null
                : FilledButton.tonalIcon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
          ),
    );
  }
}
