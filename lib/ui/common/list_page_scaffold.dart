/// 管理类列表页的统一骨架:标题动作、FAB、加载/错误/空态与检索列表。
///
/// 技能、正则、Hooks、提示词、生图风格、生图插件与世界书共用同一套页面
/// 结构;各页只声明标题、动作与条目渲染,不再各自手写 Scaffold + when。
library;

import 'package:flutter/material.dart';

import 'empty_state.dart';
import 'inline_spinner.dart';
import 'searchable_list.dart';

/// 检索型管理页骨架。
///
/// [items] 为 null 表示数据尚未就绪;配 [loading] 显示加载态,[error] 非空
/// 显示错误态并可经 [onRetry] 重试。空列表只在数据就绪后展示 [emptyState]
/// —— 加载中的空列表与"确实没有数据"是两种语义,不能混用。
class ListPageScaffold<T> extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final Widget? floatingActionButton;

  /// 数据是否仍在加载(仅当 [items] 为 null 时生效)。
  final bool loading;

  /// 加载错误;非空时显示错误态。
  final Object? error;

  /// 错误态重试入口(null 时不显示重试按钮)。
  final VoidCallback? onRetry;

  final List<T>? items;
  final EmptyState emptyState;
  final String searchHint;
  final String Function(T item) searchText;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// 检索框与列表上方的附加区块(如正则页的内置对话高亮开关卡)。
  final Widget? header;

  /// 列表内边距;默认留出 FAB 的底部空间。
  final EdgeInsets listPadding;

  /// 可选拖拽排序(见 [SearchableList.onReorder]);需同时提供
  /// [reorderKey] 才会启用。
  final Future<bool> Function(List<T> reordered)? onReorder;
  final String Function(T item)? reorderKey;

  const ListPageScaffold({
    super.key,
    required this.title,
    required this.emptyState,
    required this.searchHint,
    required this.searchText,
    required this.itemBuilder,
    this.actions = const [],
    this.floatingActionButton,
    this.loading = false,
    this.error,
    this.onRetry,
    this.items,
    this.header,
    this.listPadding = const EdgeInsets.fromLTRB(16, 4, 16, 96),
    this.onReorder,
    this.reorderKey,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      floatingActionButton: floatingActionButton,
      body: _body(),
    );
  }

  Widget _body() {
    final list = items;
    if (loading && list == null) {
      return const Center(child: InlineSpinner(size: 36, strokeWidth: 4));
    }
    if (error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: '加载失败',
        message: '$error',
        action: onRetry == null
            ? null
            : FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
      );
    }
    if (list == null || list.isEmpty) return emptyState;
    return Column(
      children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: header!,
          ),
        Expanded(
          child: SearchableList<T>(
            items: list,
            searchHint: searchHint,
            searchText: searchText,
            itemBuilder: itemBuilder,
            padding: listPadding,
            // 回顶钮让开 FAB;无 FAB 时贴近底部即可。
            scrollTopBottom: floatingActionButton == null ? 24 : 88,
            onReorder: onReorder,
            reorderKey: reorderKey,
          ),
        ),
      ],
    );
  }
}
