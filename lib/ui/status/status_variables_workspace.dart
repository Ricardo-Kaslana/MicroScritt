/// 桌面状态工作台:变量表格与行内编辑。
///
/// 变量由后台引擎维护,默认不进主写上下文(Agentic 可把选中键注入为附件);
/// 本工作区的人工增删改沿用仓库语义(删除进回收站、权限在仓库事务内复核),
/// 只失效变量相关 provider。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/variable.dart';
import '../../state/providers.dart';
import '../common/app_search_field.dart';
import '../common/async_section.dart';
import '../common/confirm_dialog.dart';
import '../common/section_header.dart';
import '../common/empty_state.dart';
import '../common/form_field.dart';
import 'status_dialogs.dart';
import 'status_widgets.dart';

/// 表格列宽刻度:键/值走 flex,权限与操作固定,窄工作区下仍能对齐。
const double _kAccessColumnWidth = 124;
const double _kActionsColumnWidth = 96;

class StatusVariablesWorkspace extends ConsumerStatefulWidget {
  final int sessionId;
  const StatusVariablesWorkspace({super.key, required this.sessionId});

  @override
  ConsumerState<StatusVariablesWorkspace> createState() =>
      _StatusVariablesWorkspaceState();
}

class _StatusVariablesWorkspaceState
    extends ConsumerState<StatusVariablesWorkspace> {
  final _search = TextEditingController();
  String _query = '';

  final _keyController = TextEditingController();
  final _valueController = TextEditingController();
  VariableAccess _access = VariableAccess.protected;

  bool _adding = false;
  Variable? _editingVariable;

  bool get _isEditing => _adding || _editingVariable != null;

  @override
  void dispose() {
    _search.dispose();
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  void _startAdd() {
    setState(() {
      _adding = true;
      _editingVariable = null;
      _keyController.text = '';
      _valueController.text = '';
      _access = VariableAccess.protected;
    });
  }

  void _startEdit(Variable variable) {
    setState(() {
      _adding = false;
      _editingVariable = variable;
      _keyController.text = variable.key;
      _valueController.text = variable.value;
      _access = variable.agentAccess;
    });
  }

  void _cancelEdit() {
    if (!_isEditing) return;
    setState(() {
      _adding = false;
      _editingVariable = null;
    });
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    final value = _valueController.text.trim();
    final repo = ref.read(variableRepositoryProvider);
    final editing = _editingVariable;
    if (editing != null &&
        key == editing.key &&
        value == editing.value &&
        _access == editing.agentAccess) {
      _cancelEdit();
      return;
    }
    if (editing == null) {
      await repo.upsert(widget.sessionId, key, value, access: _access);
    } else {
      await repo.update(
        widget.sessionId,
        oldKey: editing.key,
        newKey: key,
        value: value,
        access: _access,
      );
    }
    if (!mounted) return;
    refreshVariableViews(ref, widget.sessionId);
    refreshVariableAuxViews(ref, widget.sessionId);
    setState(() {
      _adding = false;
      _editingVariable = null;
    });
  }

  Future<void> _deleteVariable(Variable variable) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除变量?',
      message: '将把「${variable.key}」移入回收站,可在状态面板恢复。',
      confirmLabel: '删除',
    );
    if (!confirmed) return;
    await ref
        .read(variableRepositoryProvider)
        .delete(widget.sessionId, variable.key);
    if (!mounted) return;
    refreshVariableViews(ref, widget.sessionId);
    refreshVariableAuxViews(ref, widget.sessionId);
  }

  Future<void> _clearAll() async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空全部变量?',
      message: '本会话的变量将全部移入回收站,可在「已删除」中逐条恢复。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    await ref.read(variableRepositoryProvider).clear(widget.sessionId);
    if (!mounted) return;
    refreshVariableViews(ref, widget.sessionId);
    refreshVariableAuxViews(ref, widget.sessionId);
  }

  List<Variable> _applyQuery(List<Variable> rows) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return rows;
    return [
      for (final v in rows)
        if (v.key.toLowerCase().contains(q) ||
            v.value.toLowerCase().contains(q))
          v,
    ];
  }

  Set<String> _existingKeys(List<Variable> rows) {
    final editing = _editingVariable;
    return {
      for (final v in rows)
        if (editing == null || v.key != editing.key) v.key,
    };
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(variableRowsProvider(widget.sessionId));
    final trashAsync = ref.watch(variableTrashProvider(widget.sessionId));
    final pendingAsync = ref.watch(
      pendingVariableDeletionsProvider(widget.sessionId),
    );
    final trashCount = trashAsync.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );
    final hasPending = pendingAsync.maybeWhen(
      data: (list) => list.isNotEmpty,
      orElse: () => false,
    );
    final rows = rowsAsync.value ?? const <Variable>[];
    // 编辑目标被后台维护/其它页面删除或改名后,编辑行不再渲染,但 _isEditing
    // 仍会锁住搜索/新增/清空。数据就绪后若目标已不存在,自动退出编辑态。
    if (!_adding && rowsAsync.hasValue && _editingVariable != null) {
      final editKey = _editingVariable!.key;
      if (!rows.any((v) => v.key == editKey)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _adding || _editingVariable?.key != editKey) return;
          _cancelEdit();
        });
      }
    }
    final countLabel = rowsAsync.maybeWhen(
      data: (list) => '${list.length} 项',
      orElse: () => null,
    );

    return StatusWorkspaceFrame(
      header: StatusWorkspaceHeader(
        title: '变量',
        badge: countLabel,
        description: '后台维护的快状态;可手动新增、改值、调整权限,删除会进入回收站。',
        actions: [
          SizedBox(
            width: 240,
            child: IgnorePointer(
              ignoring: _isEditing,
              child: Opacity(
                opacity: _isEditing ? 0.5 : 1,
                child: AppSearchField(
                  key: const ValueKey('variable_search'),
                  controller: _search,
                  hint: '搜索键名/值',
                  padding: EdgeInsets.zero,
                  onChanged: (v) {
                    if (_query != v) setState(() => _query = v);
                  },
                ),
              ),
            ),
          ),
          Tooltip(
            message: '已删除的变量($trashCount)',
            child: StatusSecondaryAction(
              icon: Icons.restore_from_trash_outlined,
              label: '回收站',
              badgeCount: trashCount,
              onPressed: () =>
                  showVariableTrashDialog(context, sessionId: widget.sessionId),
            ),
          ),
          StatusPrimaryAction(
            buttonKey: const ValueKey('variable_add_button'),
            icon: Icons.add,
            label: '新增变量',
            onPressed: _isEditing ? null : () => _startAdd(),
          ),
          if (!_isEditing) StatusClearMenuButton(onClear: _clearAll),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasPending)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: PendingVariableDeletions(sessionId: widget.sessionId),
            ),
          Expanded(
            child: _VariablesTable(
              rowsAsync: rowsAsync,
              rows: rows,
              filteredRows: _applyQuery(rows),
              isEditing: _isEditing,
              adding: _adding,
              editingVariable: _editingVariable,
              keyController: _keyController,
              valueController: _valueController,
              access: _access,
              existingKeys: _existingKeys(rows),
              onAccessChanged: (a) => setState(() => _access = a),
              onStartAdd: _startAdd,
              onStartEdit: _startEdit,
              onCancelEdit: _cancelEdit,
              onSave: _save,
              onDelete: _deleteVariable,
              onRetry: () =>
                  ref.invalidate(variableRowsProvider(widget.sessionId)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 表格卡本体:固定表头 + 虚拟化行列表。拆成独立 widget 只是为了让变量
/// 工作区的 build 保持在可读长度内;编辑状态仍由父级持有。
class _VariablesTable extends StatelessWidget {
  final AsyncValue<List<Variable>> rowsAsync;
  final List<Variable> rows;
  final List<Variable> filteredRows;
  final bool isEditing;
  final bool adding;
  final Variable? editingVariable;
  final TextEditingController keyController;
  final TextEditingController valueController;
  final VariableAccess access;
  final Set<String> existingKeys;
  final ValueChanged<VariableAccess> onAccessChanged;
  final VoidCallback onStartAdd;
  final ValueChanged<Variable> onStartEdit;
  final VoidCallback onCancelEdit;
  final Future<void> Function() onSave;
  final Future<void> Function(Variable variable) onDelete;
  final VoidCallback onRetry;

  const _VariablesTable({
    required this.rowsAsync,
    required this.rows,
    required this.filteredRows,
    required this.isEditing,
    required this.adding,
    required this.editingVariable,
    required this.keyController,
    required this.valueController,
    required this.access,
    required this.existingKeys,
    required this.onAccessChanged,
    required this.onStartAdd,
    required this.onStartEdit,
    required this.onCancelEdit,
    required this.onSave,
    required this.onDelete,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SurfaceCard(
      key: const ValueKey('variable_table'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tableHeader(context),
          Divider(
            height: 0.5,
            thickness: 0.5,
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
          Expanded(child: _tableBody(context)),
          if (rows.isNotEmpty) _tableFooter(context),
        ],
      ),
    );
  }

  Widget _tableFooter(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    int count(VariableAccess access) =>
        rows.where((v) => v.agentAccess == access).length;
    final textStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Container(
      key: const ValueKey('variable_table_footer'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.18),
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Text(
            '共 ${rows.length} 项',
            style: textStyle?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '可改可删 ${count(VariableAccess.full)} · '
              '可改不可删 ${count(VariableAccess.protected)} · '
              '只读常量 ${count(VariableAccess.readonly)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '删除先进回收站',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _tableHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 8),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('键', style: style)),
          Expanded(flex: 4, child: Text('值', style: style)),
          SizedBox(
            width: _kAccessColumnWidth,
            child: Text('权限', style: style),
          ),
          SizedBox(
            width: _kActionsColumnWidth,
            child: Text('操作', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }

  Widget _tableBody(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AsyncSection<List<Variable>>(
      value: rowsAsync,
      onRetry: onRetry,
      builder: (context, _) {
        if (rows.isEmpty && !adding) {
          return EmptyState(
            compact: true,
            icon: Icons.data_object,
            title: '暂无变量',
            message: '后台引擎尚未写入变量。也可以手动新增,作为后台维护的起始状态。',
            action: FilledButton.tonalIcon(
              onPressed: onStartAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新增变量'),
            ),
          );
        }
        if (filteredRows.isEmpty && !adding) {
          return const EmptyState(
            compact: true,
            icon: Icons.search_off,
            title: '没有匹配项',
            message: '换一个关键词试试。',
          );
        }
        final extra = adding ? 1 : 0;
        return ListView.builder(
          primary: false,
          padding: const EdgeInsets.only(bottom: 6),
          itemCount: filteredRows.length + extra,
          itemBuilder: (context, index) {
            if (adding && index == 0) {
              return Column(
                children: [
                  _editRow(context),
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ],
              );
            }
            final variable = filteredRows[index - extra];
            if (editingVariable != null &&
                editingVariable!.key == variable.key) {
              return Column(
                children: [
                  _editRow(context),
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ],
              );
            }
            return Column(
              children: [
                _normalRow(context, variable),
                if (index < filteredRows.length + extra - 1)
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: 16,
                    endIndent: 16,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _normalRow(BuildContext context, Variable variable) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      key: ValueKey('variable_row_${variable.key}'),
      onTap: isEditing ? null : () => onStartEdit(variable),
      hoverColor: scheme.primary.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                variable.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              flex: 4,
              child: Tooltip(
                message: variable.value.isEmpty ? '(空值)' : variable.value,
                child: Text(
                  variable.value.isEmpty ? '(空值)' : variable.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            SizedBox(
              width: _kAccessColumnWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: VariableAccessBadge(
                  access: variable.agentAccess,
                  showLabel: true,
                ),
              ),
            ),
            SizedBox(
              width: _kActionsColumnWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.max,
                children: [
                  IconButton(
                    tooltip: isEditing ? '请先保存或取消当前编辑' : '编辑变量',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: isEditing ? null : () => onStartEdit(variable),
                  ),
                  IconButton(
                    tooltip: isEditing ? '请先保存或取消当前编辑' : '删除变量',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: scheme.error,
                    ),
                    onPressed: isEditing ? null : () => onDelete(variable),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editRow(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: keyController,
      builder: (context, keyValue, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final key = keyValue.text.trim();
        final conflict = key.isNotEmpty && existingKeys.contains(key);
        final canSave = key.isNotEmpty;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): onCancelEdit,
          },
          child: Container(
            key: const ValueKey('variable_edit_row'),
            color: scheme.primary.withValues(alpha: 0.04),
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: _inlineField(
                        context,
                        key: const ValueKey('variable_key_field'),
                        controller: keyController,
                        hint: '键,如 hp',
                        autofocus: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 4,
                      child: _inlineField(
                        context,
                        key: const ValueKey('variable_value_field'),
                        controller: valueController,
                        hint: '值,如 8/10',
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: _kAccessColumnWidth,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: PopupMenuButton<VariableAccess>(
                          key: const ValueKey('variable_access_picker'),
                          tooltip: '后台权限',
                          onSelected: onAccessChanged,
                          itemBuilder: (context) => [
                            for (final a in VariableAccess.values)
                              PopupMenuItem<VariableAccess>(
                                value: a,
                                height: 54,
                                child: SizedBox(
                                  width: 250,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        a.label,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        a.description,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              VariableAccessBadge(
                                access: access,
                                showLabel: true,
                              ),
                              const Icon(Icons.expand_more, size: 16),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: _kActionsColumnWidth,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            key: const ValueKey('variable_save'),
                            tooltip: '保存',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.check, size: 20),
                            onPressed: canSave ? () => onSave() : null,
                          ),
                          IconButton(
                            key: const ValueKey('variable_cancel'),
                            tooltip: '取消',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: onCancelEdit,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (key.isEmpty || conflict || adding)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 2),
                    child: Text(
                      key.isEmpty
                          ? '键不能为空;保存后变量才会写入。'
                          : conflict
                          ? '已存在同名变量,保存将覆盖它的值。'
                          : '新增变量默认受保护:后台可改值,但不会删除。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: key.isEmpty
                            ? scheme.outline
                            : conflict
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _inlineField(
    BuildContext context, {
    required Key key,
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    bool autofocus = false,
  }) {
    return TextField(
      key: key,
      controller: controller,
      autofocus: autofocus,
      maxLines: maxLines,
      minLines: 1,
      style: const TextStyle(fontSize: 13),
      decoration: appInputDecoration(
        context,
        hintText: hint,
        isDense: true,
        fillColor: Theme.of(context).colorScheme.surface,
        borderAlpha: 0.6,
        radius: 10,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      ),
    );
  }
}
