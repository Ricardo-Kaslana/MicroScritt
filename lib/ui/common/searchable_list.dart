/// 管理类长列表的通用外壳:检索框 + 虚拟化列表/网格 + 滚动回顶钮。
///
/// 过滤在内存里完成(管理数据本来就已全量加载),这里只做小写包含匹配;
/// 有数据但无匹配时展示内置空态,完全无数据时的引导页仍由调用方负责。
library;

import 'package:flutter/material.dart';
import 'app_search_field.dart';
import 'empty_state.dart';
import 'scroll_to_top_fab.dart';

/// 管理类长列表的通用外壳:检索框 + 虚拟化列表 + 滚动回顶钮。
///
/// 过滤在内存里完成(管理数据本来就已全量加载),页面只需提供
/// [searchText] 与 [itemBuilder];空数据态仍由调用方展示自己的引导页。
class SearchableList<T> extends StatefulWidget {
  final List<T> items;
  final String Function(T item) searchText;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final String searchHint;
  final EdgeInsets padding;

  /// 网格模式(图片优先的卡面展示)。列表与网格共用同一个 State:页面原地
  /// 切换布局时检索词与过滤结果保留,不必重建外壳。
  final bool grid;

  /// 网格模式的内边距(列表模式的 [padding] 只留纵向,横向由条目自带外边距)。
  final EdgeInsets? gridPadding;

  /// 牌堆等自由布局模式:非 null 时取代列表/网格,把过滤后的全集交给
  /// 调用方排布(检索框、无匹配空态仍由外壳负责,检索词跨模式保留);
  /// 此模式没有滚动视图,[padding]/[gridDelegate] 与回顶钮不生效。
  final Widget Function(BuildContext context, List<T> items)? deckBuilder;

  /// 网格排布;默认按可用宽度自适应列数,单卡上限 220 宽、3:4 竖版。
  final SliverGridDelegate? gridDelegate;

  /// 回顶钮距列表底部的距离:默认让开右下角的扩展 FAB。
  final double scrollTopBottom;

  /// 无匹配时的空态文案;页面可按业务语境覆盖(如「没有匹配的会话」)。
  final String noMatchTitle;
  final String noMatchMessage;

  /// 拖拽排序回调:收到重排后的完整列表,返回是否接受(跨类型移动等
  /// 业务约束由页面判定并拒绝)。非空时列表切到 [ReorderableListView],
  /// 检索状态下仍为普通列表(过滤下标无法映射回全量顺序);桌面端带
  /// 拖动把手,移动端长按条目拖动。
  final Future<bool> Function(List<T> reordered)? onReorder;

  /// 拖拽排序的稳定 key(通常用库内 id);与 [onReorder] 同时提供才生效。
  final String Function(T item)? reorderKey;

  const SearchableList({
    super.key,
    required this.items,
    required this.searchText,
    required this.itemBuilder,
    this.searchHint = '搜索',
    this.padding = const EdgeInsets.only(top: 4, bottom: 96),
    this.grid = false,
    this.gridPadding,
    this.gridDelegate,
    this.deckBuilder,
    this.scrollTopBottom = 88,
    this.noMatchTitle = '没有匹配项',
    this.noMatchMessage = '换一个关键词试试。',
    this.onReorder,
    this.reorderKey,
  });

  @override
  State<SearchableList<T>> createState() => _SearchableListState<T>();
}

class _SearchableListState<T> extends State<SearchableList<T>> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  /// 拖拽后的乐观顺序:落库完成前先把列表按用户松手的位置显示,避免
  /// provider 异步刷新期间先弹回旧顺序。父级传入新的 items 实例时清空,
  /// 以后端顺序为准。
  List<T>? _pendingOrder;

  @override
  void didUpdateWidget(covariant SearchableList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.items, widget.items)) _pendingOrder = null;
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    if (_query.isNotEmpty) setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final source = _pendingOrder ?? widget.items;
    final filtered = query.isEmpty
        ? source
        : source
              .where(
                (item) => widget.searchText(item).toLowerCase().contains(query),
              )
              .toList(growable: false);
    final scheme = Theme.of(context).colorScheme;
    final reorderable = widget.onReorder != null && widget.reorderKey != null;
    return Stack(
      children: [
        Column(
          children: [
            AppSearchField(
              controller: _search,
              hint: widget.searchHint,
              onChanged: (v) {
                if (_query != v) setState(() => _query = v);
              },
            ),
            // 检索结果计数:输入关键词后告诉用户命中多少条,长列表里避免
            // "到底是不匹配还是没滚到"的困惑;清除入口与结果一起出现。
            if (query.isNotEmpty && filtered.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 2),
                child: Row(
                  children: [
                    Text(
                      '找到 ${filtered.length} 项',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _clearSearch,
                      child: const Text('清除搜索'),
                    ),
                  ],
                ),
              ),
            // 排序提示:排序页在检索态下无法把过滤下标映射回全量顺序,
            // 明确告诉用户先清空搜索,而不是拖了没反应。
            if (reorderable && widget.items.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    query.isEmpty ? '长按或拖动条目可调整顺序' : '搜索状态下不可调整顺序',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: filtered.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: widget.noMatchTitle,
                      message: widget.noMatchMessage,
                      action: query.isEmpty
                          ? null
                          : FilledButton.tonalIcon(
                              onPressed: _clearSearch,
                              icon: const Icon(Icons.close),
                              label: const Text('清除搜索'),
                            ),
                    )
                  : widget.deckBuilder != null
                  ? widget.deckBuilder!(context, filtered)
                  : reorderable && query.isEmpty
                  ? ReorderableListView.builder(
                      scrollController: _scroll,
                      padding: widget.padding,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: filtered.length,
                      onReorder: (oldIndex, newIndex) {
                        // ReorderableListView 的 newIndex 是移除前的目标位,
                        // 后移时要先减一才是松手后的最终下标。
                        if (newIndex > oldIndex) newIndex -= 1;
                        if (newIndex == oldIndex) return;
                        final reordered = [...source];
                        final item = reordered.removeAt(oldIndex);
                        reordered.insert(newIndex, item);
                        setState(() => _pendingOrder = reordered);
                        widget.onReorder!(reordered).then(
                          (accepted) {
                            if (!accepted && mounted) {
                              setState(() => _pendingOrder = null);
                            }
                          },
                          onError: (Object _) {
                            if (mounted) {
                              setState(() => _pendingOrder = null);
                            }
                          },
                        );
                      },
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return KeyedSubtree(
                          key: ValueKey(widget.reorderKey!(item)),
                          child: widget.itemBuilder(context, item),
                        );
                      },
                    )
                  : widget.grid
                  ? GridView.builder(
                      controller: _scroll,
                      padding:
                          widget.gridPadding ??
                          const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      gridDelegate:
                          widget.gridDelegate ??
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 220,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 3 / 4,
                          ),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) =>
                          widget.itemBuilder(context, filtered[index]),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: widget.padding,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) =>
                          widget.itemBuilder(context, filtered[index]),
                    ),
            ),
          ],
        ),
        if (widget.deckBuilder == null)
          Positioned(
            right: 16,
            bottom: widget.scrollTopBottom,
            child: ScrollToTopFab(controller: _scroll),
          ),
      ],
    );
  }
}
