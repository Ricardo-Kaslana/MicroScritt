/// 桌面状态工作台的居中对话框:后台世界书多选与变量回收站。
///
/// 桌面端不再复用移动端的底部弹层:宽窗下选择/回收站都以带固定标题栏与
/// 动作栏的居中对话框呈现,确认前不落库。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/variable.dart';
import '../../models/worldbook_entry.dart';
import '../../state/providers.dart';
import '../common/app_search_field.dart';
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

/// 两类桌面对话框共用的外框:标题栏 + 可选次栏 + 内容 + 动作栏。
///
/// 高度随内容收缩,最高 70% 屏高:条目少时不留半屏空白,条目多时在
/// 对话框内部滚动。列表需配 `shrinkWrap: true` 才能按内容量出高度。
class _StatusDialogFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> headerActions;
  final Widget? secondaryBar;
  final Widget child;
  final List<Widget> actions;

  const _StatusDialogFrame({
    required this.title,
    this.subtitle,
    this.headerActions = const [],
    this.secondaryBar,
    required this.child,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.7;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: ConstrainedBox(
        key: const ValueKey('status_dialog_frame'),
        constraints: BoxConstraints(maxWidth: 640, maxHeight: height),
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
    return _StatusDialogFrame(
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
                return InkWell(
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(restored ? '已恢复「${entry.key}」并设为受保护' : '同名变量仍存在,无法恢复'),
      ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已彻底删除「${entry.key}」')));
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已清空回收站($removed 条)')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trash = ref.watch(variableTrashProvider(sessionId));
    final count = trash.maybeWhen(data: (list) => list.length, orElse: () => 0);
    return _StatusDialogFrame(
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
      child: trash.when(
        data: (list) => list.isEmpty
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
        error: (e, _) =>
            Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
