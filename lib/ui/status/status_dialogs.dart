/// 状态面板的共用对话框:后台世界书多选、变量回收站与「应用到上下文」确认。
///
/// 桌面端不再复用移动端的底部弹层:宽窗下选择/回收站都以带固定标题栏与
/// 动作栏的居中对话框呈现,确认前不落库;移动记忆页与桌面工作台则共用
/// 同一份应用记忆确认文案。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/variable.dart';
import '../../models/worldbook_entry.dart';
import '../../state/providers.dart';
import '../common/app_dialog_frame.dart';
import '../common/app_search_field.dart';
import '../common/app_snack_bar.dart';
import '../common/async_section.dart';
import '../common/confirm_dialog.dart';
import '../common/empty_state.dart';
import 'status_widgets.dart';

/// 后台世界书多选对话框。返回选中的条目 id 集合;取消返回 null。
Future<Set<int?>?> showWorldbookPickerDialog(
  BuildContext context, {
  required List<WorldbookEntry> entries,
  required Set<int?> initialSelected,
}) {
  return showDialog<Set<int?>>(
    context: context,
    builder: (_) => _WorldbookPickerDialog(
      entries: entries,
      initialSelected: initialSelected,
    ),
  );
}

/// 变量回收站对话框:逐条恢复/彻底删除、清空回收站。
Future<void> showVariableTrashDialog(
  BuildContext context, {
  required int sessionId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _VariableTrashDialog(sessionId: sessionId),
  );
}

/// 「应用到上下文」确认框;返回 true 表示用户确认。
///
/// 第 0 条记忆整体换新会改变提示前缀,缓存只能重新预热,因此不静默执行。
/// 文案与两处入口(移动记忆页 / 桌面工作台)保持一致。
Future<bool> confirmApplyMemoryToContext(
  BuildContext context, {
  required bool pending,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('应用到上下文?'),
      content: Text(
        pending
            ? '库中记忆已修改,上下文开头仍是旧版本。应用后记忆整体换新,提示前缀会变化(缓存重新预热);改动的差异此前已以通知送达。'
            : '上下文里的记忆已是最新,应用只会重新组装一次上下文。仍要继续吗?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('应用'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

class _WorldbookPickerDialog extends StatefulWidget {
  final List<WorldbookEntry> entries;
  final Set<int?> initialSelected;

  const _WorldbookPickerDialog({
    required this.entries,
    required this.initialSelected,
  });

  @override
  State<_WorldbookPickerDialog> createState() => _WorldbookPickerDialogState();
}

class _WorldbookPickerDialogState extends State<_WorldbookPickerDialog> {
  late final Set<int?> _selected = {...widget.initialSelected};
  final Set<int?> _expanded = {};
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<WorldbookEntry> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.entries;
    return [
      for (final e in widget.entries)
        if (e.displayLabel.toLowerCase().contains(q) ||
            e.content.toLowerCase().contains(q))
          e,
    ];
  }

  int get _inertSelected => widget.entries
      .where((e) => _selected.contains(e.id) && !e.enabled)
      .length;

  void _toggleSelected(int? id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleExpanded(int? id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filtered = _filtered;
    return AppDialogFrame(
      frameKey: const ValueKey('status_dialog_frame'),
      title: '后台世界书条目',
      subtitle:
          '已选 ${_selected.length} / ${widget.entries.length} 条进入后台上下文'
          '${_inertSelected > 0 ? ' · 其中 $_inertSelected 条已停用不生效' : ''}',
      secondaryBar: Column(
        children: [
          AppSearchField(
            controller: _search,
            hint: '搜索条目名称/内容',
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            onChanged: (v) {
              if (_query != v) setState(() => _query = v);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '勾选且启用的条目才会进入后台上下文。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _selected.addAll(filtered.map((e) => e.id)),
                  ),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => setState(_selected.clear),
                  child: const Text('取消全选'),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, Set<int?>.of(_selected)),
          icon: const Icon(Icons.check, size: 18),
          label: Text('保存(${_selected.length})'),
        ),
      ],
      child: filtered.isEmpty
          ? const EmptyState(
              compact: true,
              icon: Icons.search_off,
              title: '没有匹配项',
              message: '换一个关键词试试。',
            )
          : ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
              itemBuilder: (_, i) {
                final e = filtered[i];
                final selected = _selected.contains(e.id);
                final expanded = _expanded.contains(e.id);
                return Semantics(
                  button: true,
                  checked: selected,
                  child: InkWell(
                    key: ValueKey('worldbook_pick_${e.id}'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _toggleSelected(e.id),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 22,
                              color: selected ? scheme.primary : scheme.outline,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        e.displayLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyLarge,
                                      ),
                                    ),
                                    if (!e.enabled) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        '已停用',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(color: scheme.error),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                if (expanded)
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 220,
                                    ),
                                    child: SingleChildScrollView(
                                      child: Text(
                                        e.content,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                  )
                                else
                                  Text(
                                    e.content,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: expanded ? '收起预览' : '展开预览',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              expanded ? Icons.expand_less : Icons.expand_more,
                              size: 20,
                            ),
                            onPressed: () => _toggleExpanded(e.id),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _VariableTrashDialog extends ConsumerWidget {
  final int sessionId;
  const _VariableTrashDialog({required this.sessionId});

  void _refresh(WidgetRef ref) {
    ref.invalidate(variableTrashProvider(sessionId));
    refreshVariableViews(ref, sessionId);
    ref.invalidate(pendingVariableDeletionsProvider(sessionId));
  }

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    VariableTrashEntry entry,
  ) async {
    final restored = await ref
        .read(variableRepositoryProvider)
        .restore(sessionId, entry.id!);
    if (!context.mounted) return;
    _refresh(ref);
    showAppSnack(
      context,
      restored ? '已恢复「${entry.key}」并设为受保护' : '同名变量仍存在,无法恢复',
    );
  }

  Future<void> _purge(
    BuildContext context,
    WidgetRef ref,
    VariableTrashEntry entry,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '彻底删除「${entry.key}」?',
      message: '该变量将从回收站永久删除,无法恢复。',
      confirmLabel: '删除',
    );
    if (!confirmed) return;
    final removed = await ref
        .read(variableRepositoryProvider)
        .purgeTrashEntry(sessionId, entry.id!);
    if (!context.mounted) return;
    _refresh(ref);
    if (removed) {
      showAppSnack(context, '已彻底删除「${entry.key}」');
    }
  }

  Future<void> _clearAll(BuildContext context, WidgetRef ref, int count) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空回收站?',
      message: '回收站内的 $count 条变量将被永久删除,无法恢复。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    final removed = await ref
        .read(variableRepositoryProvider)
        .clearTrash(sessionId);
    if (!context.mounted) return;
    _refresh(ref);
    showAppSnack(context, '已清空回收站($removed 条)');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trash = ref.watch(variableTrashProvider(sessionId));
    final count = trash.maybeWhen(data: (list) => list.length, orElse: () => 0);
    return AppDialogFrame(
      frameKey: const ValueKey('status_dialog_frame'),
      title: '已删除的变量',
      subtitle: '恢复后自动设为受保护,避免再次被后台删除;彻底删除后不可恢复。',
      headerActions: [
        if (count > 0)
          IconButton(
            tooltip: '清空回收站',
            icon: Icon(
              Icons.delete_sweep_outlined,
              size: 20,
              color: scheme.error,
            ),
            onPressed: () => _clearAll(context, ref, count),
          ),
      ],
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
      child: AsyncSection<List<VariableTrashEntry>>(
        value: trash,
        onRetry: () => _refresh(ref),
        builder: (context, list) => list.isEmpty
            ? const EmptyState(
                compact: true,
                icon: Icons.delete_outline,
                title: '回收站是空的',
                message: '手动删除或后台清理的变量会出现在这里,可逐条恢复。',
              )
            : ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                itemCount: list.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
                itemBuilder: (_, i) {
                  final entry = list[i];
                  return ListTile(
                    key: ValueKey('trash_row_${entry.id}'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      entry.key,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '${entry.value}\n${entry.byAgent ? '后台移除' : '手动删除'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    isThreeLine: true,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '恢复变量',
                          icon: const Icon(Icons.restore, size: 20),
                          onPressed: () => _restore(context, ref, entry),
                        ),
                        IconButton(
                          tooltip: '彻底删除变量',
                          icon: Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: scheme.error,
                          ),
                          onPressed: () => _purge(context, ref, entry),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
