/// 状态面板的变量全量列表与回收站底部弹层。

part of '../status_screen.dart';

/// 变量全量底部弹层:用虚拟化列表承载任意数量的变量,避免状态面板
/// 为每条变量都构建一行。编辑/删除复用状态面板的既有流程。
/// 顶部检索框按键名与值过滤(内存过滤,数据本就全量加载)。
class _VariableListSheet extends ConsumerStatefulWidget {
  final int sessionId;
  final Future<void> Function(
    BuildContext context,
    WidgetRef ref,
    List<Variable> rows,
    Variable variable,
  )
  onEdit;
  final Future<void> Function(BuildContext context, WidgetRef ref, String key)
  onDelete;

  const _VariableListSheet({
    required this.sessionId,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  ConsumerState<_VariableListSheet> createState() => _VariableListSheetState();
}

class _VariableListSheetState extends ConsumerState<_VariableListSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Variable> _filter(List<Variable> rows) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return rows;
    return rows
        .where(
          (v) =>
              v.key.toLowerCase().contains(query) ||
              v.value.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(variableRowsProvider(widget.sessionId));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hasRows = rowsAsync.value?.isNotEmpty ?? false;
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHeader(title: '全部变量'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Text(
                    '点一行编辑;值仅预览前两行。',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (hasRows)
                  AppSearchField(
                    controller: _search,
                    hint: '搜索变量键名/值',
                    padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
                    onChanged: (v) {
                      if (_query != v) setState(() => _query = v);
                    },
                  ),
                Flexible(
                  child: AsyncSection<List<Variable>>(
                    value: rowsAsync,
                    onRetry: () =>
                        ref.invalidate(variableRowsProvider(widget.sessionId)),
                    builder: (context, rows) {
                      if (rows.isEmpty) {
                        return const EmptyState(
                          compact: true,
                          icon: Icons.data_object,
                          title: '还没有变量',
                          message: '后台引擎写入变量后会出现在这里。',
                        );
                      }
                      final filtered = _filter(rows);
                      if (filtered.isEmpty) {
                        return const EmptyState(
                          icon: Icons.search_off,
                          title: '没有匹配项',
                          message: '换一个关键词试试。',
                        );
                      }
                      return ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                        itemBuilder: (_, i) {
                          final variable = filtered[i];
                          return ListTile(
                            key: ValueKey('variable-row-${variable.key}'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    variable.key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                VariableAccessBadge(
                                  access: variable.agentAccess,
                                  showLabel: false,
                                ),
                              ],
                            ),
                            subtitle: Text(
                              variable.value,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: '删除变量',
                              icon: Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: scheme.error,
                              ),
                              onPressed: () =>
                                  widget.onDelete(context, ref, variable.key),
                            ),
                            onTap: () =>
                                widget.onEdit(context, ref, rows, variable),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 回收站底部弹层:列出已删除变量并支持逐条恢复、彻底删除与清空。
class _VariableTrashSheet extends ConsumerWidget {
  final int sessionId;
  const _VariableTrashSheet({required this.sessionId});

  void _refreshTrash(WidgetRef ref) {
    ref.invalidate(variableTrashProvider(sessionId));
  }

  /// 恢复一条回收站变量:同名 active 变量仍存在时仓库拒绝,这里把两种结果
  /// 都提示出来;恢复后的权限固定为 protected,避免下一轮又被后台删掉。
  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    VariableTrashEntry entry,
  ) async {
    final restored = await ref
        .read(variableRepositoryProvider)
        .restore(sessionId, entry.id!);
    if (!context.mounted) return;
    ref.invalidate(variableTrashProvider(sessionId));
    ref.invalidate(variableRowsProvider(sessionId));
    ref.invalidate(variablesProvider(sessionId));
    ref.invalidate(pendingVariableDeletionsProvider(sessionId));
    showAppSnack(
      context,
      restored ? '已恢复「${entry.key}」并设为受保护' : '同名变量仍存在,无法恢复',
    );
  }

  /// 彻底删除单条:不走软删除,确认后不可恢复。
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
    _refreshTrash(ref);
    if (removed) {
      showAppSnack(context, '已彻底删除「${entry.key}」');
    }
  }

  /// 清空本会话回收站:全部永久删除,不可恢复。
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
    _refreshTrash(ref);
    showAppSnack(context, '已清空回收站($removed 条)');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final trash = ref.watch(variableTrashProvider(sessionId));
    final count = trash.maybeWhen(data: (list) => list.length, orElse: () => 0);
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(
                  title: '已删除的变量',
                  actions: [
                    if (count > 0)
                      IconButton(
                        tooltip: '清空回收站',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.delete_sweep_outlined,
                          size: 20,
                          color: scheme.error,
                        ),
                        onPressed: () => _clearAll(context, ref, count),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Text(
                    '恢复后自动设为受保护,避免再次被后台删除;彻底删除后不可恢复。',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Flexible(
                  child: AsyncSection<List<VariableTrashEntry>>(
                    value: trash,
                    onRetry: () => _refreshTrash(ref),
                    builder: (context, list) => list.isEmpty
                        ? const EmptyState(
                            compact: true,
                            icon: Icons.delete_outline,
                            title: '回收站是空的',
                            message: '手动删除或后台清理的变量会出现在这里,可逐条恢复。',
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: list.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: scheme.outlineVariant.withValues(
                                alpha: 0.5,
                              ),
                            ),
                            itemBuilder: (_, i) {
                              final entry = list[i];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                title: Text(
                                  entry.key,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  '${entry.value}\n${entry.byAgent ? '后台移除' : '手动删除'}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: '恢复变量',
                                      icon: const Icon(Icons.restore, size: 20),
                                      onPressed: () =>
                                          _restore(context, ref, entry),
                                    ),
                                    IconButton(
                                      tooltip: '彻底删除变量',
                                      icon: Icon(
                                        Icons.delete_outline,
                                        size: 20,
                                        color: scheme.error,
                                      ),
                                      onPressed: () =>
                                          _purge(context, ref, entry),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
