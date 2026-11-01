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

  /// 网格排布;默认按可用宽度自适应列数,单卡上限 220 宽、3:4 竖版。
  final SliverGridDelegate? gridDelegate;

  /// 回顶钮距列表底部的距离:默认让开右下角的扩展 FAB。
  final double scrollTopBottom;

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
    this.scrollTopBottom = 88,
  });

  @override
  State<SearchableList<T>> createState() => _SearchableListState<T>();
}

class _SearchableListState<T> extends State<SearchableList<T>> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.items
        : widget.items
              .where(
                (item) => widget.searchText(item).toLowerCase().contains(query),
              )
              .toList(growable: false);
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
            Expanded(
              child: filtered.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off,
                      title: '没有匹配项',
                      message: '换一个关键词试试。',
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
        Positioned(
          right: 16,
          bottom: widget.scrollTopBottom,
          child: ScrollToTopFab(controller: _scroll),
        ),
      ],
    );
  }
}
