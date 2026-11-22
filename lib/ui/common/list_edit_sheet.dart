/// 通用底部列表编辑区:逐条编辑字符串列表,支持添加/删除。
///
/// 用于备用开场白/标签等数组字段:这些内容必须按元素保存,经整段文本投影
/// 往返会按换行/逗号拆条,元素内部的换行或逗号无法原样保留。
library;

import 'package:flutter/material.dart';

import 'app_sheet.dart';
import 'sheet_header.dart';
import 'unsaved_changes_guard.dart';

/// 弹出列表编辑器,返回用户保存的元素列表;取消返回 null。
///
/// 保存时逐条 trim 并丢弃空元素;全部删光返回空列表(合法清空)。
Future<List<String>?> showListEditSheet(
  BuildContext context, {
  required String title,
  required List<String> initialValues,
  required String hintText,
  String? description,
  bool multiline = true,
  String submitLabel = '保存',
}) {
  return showAppSheet<List<String>>(
    context,
    builder: (_) => _ListEditSheet(
      title: title,
      initialValues: initialValues,
      hintText: hintText,
      description: description,
      multiline: multiline,
      submitLabel: submitLabel,
    ),
  );
}

class _ListEditSheet extends StatefulWidget {
  final String title;
  final List<String> initialValues;
  final String hintText;
  final String? description;
  final bool multiline;
  final String submitLabel;

  const _ListEditSheet({
    required this.title,
    required this.initialValues,
    required this.hintText,
    this.description,
    required this.multiline,
    required this.submitLabel,
  });

  @override
  State<_ListEditSheet> createState() => _ListEditSheetState();
}

class _ListEditSheetState extends State<_ListEditSheet> {
  late final List<String> _initial = List.of(widget.initialValues);
  late final List<TextEditingController> _controllers = [
    for (final value in widget.initialValues)
      TextEditingController(text: value),
  ];

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _hasChanges() {
    if (_controllers.length != _initial.length) return true;
    for (var i = 0; i < _controllers.length; i++) {
      if (_controllers[i].text != _initial[i]) return true;
    }
    return false;
  }

  void _add() {
    setState(() => _controllers.add(TextEditingController()));
  }

  void _remove(int index) {
    setState(() => _controllers.removeAt(index).dispose());
  }

  void _submit() {
    final values = <String>[
      for (final controller in _controllers)
        if (controller.text.trim().isNotEmpty) controller.text.trim(),
    ];
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return UnsavedChangesGuard(
      hasChanges: _hasChanges,
      changes: List<Listenable>.of(_controllers),
      title: '放弃编辑?',
      message: '已输入的内容不会保存。',
      confirmLabel: '放弃',
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Material(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.9,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  12,
                  12,
                  bottomInset > 0 ? 12 : 20,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SheetHeader(title: widget.title, closeLabel: '取消'),
                    if (widget.description != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.description!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _controllers.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) => Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest
                                      .withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: scheme.outlineVariant.withValues(
                                      alpha: 0.5,
                                    ),
                                  ),
                                ),
                                child: TextField(
                                  controller: _controllers[index],
                                  minLines: 1,
                                  maxLines: widget.multiline ? 4 : 1,
                                  keyboardType: widget.multiline
                                      ? TextInputType.multiline
                                      : TextInputType.text,
                                  textInputAction: widget.multiline
                                      ? TextInputAction.newline
                                      : TextInputAction.next,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    height: 1.4,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: widget.hintText,
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.all(12),
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '删除这一条',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _remove(index),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _add,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加一条'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          '${_controllers.length} 条',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Expanded(child: SizedBox.shrink()),
                        FilledButton.icon(
                          onPressed: _submit,
                          icon: const Icon(Icons.check, size: 18),
                          label: Text(widget.submitLabel),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
