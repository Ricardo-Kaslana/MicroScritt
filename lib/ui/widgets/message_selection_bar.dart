/// 会话内消息多选模式的快捷选择栏。
///
/// 删除与导出由 AppBar 右上角承载;这里只保留「全选 / 取消全选 / 图片 / 文本」。
/// 每项带当前可选项数,选中数与可选项数齐平时「全选」置灰、没有选中时
/// 「取消全选」置灰、某一类为空时对应项置灰 —— 选项状态一眼可见,不必
/// 点一下才知道没有可选项。快捷选择只作用于当前已加载到消息列表的可见
/// 消息(system 摘要与附件行不参与)。
///
/// 布局按可用宽切换:宽屏四个快捷项单行居中;窄屏左右各两个分组,左组贴
/// 左、右组贴右,并压缩 chip 内边距,避免换行后底部栏高度抖动。宽窗仍与
/// 聊天内容列同宽居中。
library;

import 'package:flutter/material.dart';

import '../common/chat_layout.dart';

/// 底部批量快捷选择栏。
class MessageSelectionBar extends StatelessWidget {
  /// 当前已选中的消息数。
  final int selectedCount;

  /// 可参与多选的可见消息总数。
  final int totalCount;

  /// 带图片的可见消息数。
  final int imageCount;

  /// 不带图片的可见消息数。
  final int textCount;

  /// 选中当前已加载的全部可见消息。
  final VoidCallback onSelectAll;

  /// 清空选择。
  final VoidCallback onClearSelection;

  /// 只选带图片的消息(本地资产或远程 URL)。
  final VoidCallback onSelectImages;

  /// 只选不带图片的消息。
  final VoidCallback onSelectText;

  /// 单行布局的内容宽阈值(已扣除左右内边距)。
  static const double singleRowBreakpoint = 500;

  const MessageSelectionBar({
    super.key,
    required this.selectedCount,
    required this.totalCount,
    required this.imageCount,
    required this.textCount,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onSelectImages,
    required this.onSelectText,
  });

  bool get _canSelectAll => totalCount > 0 && selectedCount < totalCount;
  bool get _canClear => selectedCount > 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final viewWidth = MediaQuery.sizeOf(context).width;
    final column = chatColumnMaxWidth(viewWidth);
    final maxWidth = column.isFinite ? column - 24 : double.infinity;
    final desktop = viewWidth >= kChatWideBreakpoint;

    final chips = <Widget>[
      _quickChip(
        key: 'message_selection_all',
        label: '全选 $totalCount',
        desktop: desktop,
        onPressed: _canSelectAll ? onSelectAll : null,
      ),
      _quickChip(
        key: 'message_selection_none',
        label: '取消全选',
        desktop: desktop,
        onPressed: _canClear ? onClearSelection : null,
      ),
      _quickChip(
        key: 'message_selection_images',
        label: '图片 $imageCount',
        desktop: desktop,
        onPressed: imageCount > 0 ? onSelectImages : null,
      ),
      _quickChip(
        key: 'message_selection_text',
        label: '文本 $textCount',
        desktop: desktop,
        onPressed: textCount > 0 ? onSelectText : null,
      ),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: SizedBox(
              width: double.infinity,
              child: Material(
                key: const ValueKey('message_selection_bar'),
                color: scheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= singleRowBreakpoint) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < chips.length; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              chips[i],
                            ],
                          ],
                        );
                      }
                      // 窄屏第一行分两组:全选/取消全选贴左,图片/文本
                      // 贴右。组内可换行,极窄或大字号时只增高不横向溢出。
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 2,
                              alignment: WrapAlignment.start,
                              children: [chips[0], chips[1]],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 2,
                              alignment: WrapAlignment.end,
                              children: [chips[2], chips[3]],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _quickChip({
    required String key,
    required String label,
    required bool desktop,
    required VoidCallback? onPressed,
  }) {
    return ActionChip(
      key: ValueKey(key),
      label: Text(label),
      onPressed: onPressed,
      visualDensity: desktop ? VisualDensity.standard : VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelPadding: EdgeInsets.symmetric(horizontal: desktop ? 2 : 1),
      padding: EdgeInsets.symmetric(horizontal: desktop ? 6 : 4, vertical: 0),
    );
  }
}
