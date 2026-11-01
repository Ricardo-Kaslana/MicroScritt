import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../export/resource_exporter.dart';
import '../import/resource_importer.dart';
import '../models/prompt_item.dart';
import '../state/providers.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/resource_io.dart';
import 'common/searchable_list.dart';
import 'common/section_header.dart';

/// 全局提示词项管理:预设/规则两类,按 kind+position 进上下文。
class PromptItemsScreen extends ConsumerWidget {
  const PromptItemsScreen({super.key});

  Future<void> _toggle(WidgetRef ref, PromptItem item) async {
    final repo = ref.read(promptItemRepositoryProvider);
    await repo.update(
      PromptItem(
        id: item.id,
        kind: item.kind,
        name: item.name,
        text: item.text,
        enabled: !item.enabled,
        position: item.position,
      ),
    );
    ref.invalidate(promptItemsProvider);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    PromptItem item,
  ) async {
    final id = item.id;
    if (id == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除提示词项?',
      message: _clip(item.text),
    );
    if (!confirmed) return;
    await ref.read(promptItemRepositoryProvider).delete(id);
    ref.invalidate(promptItemsProvider);
  }

  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(promptItemRepositoryProvider).all();
    if (!context.mounted) return;
    await exportResourceFile(
      context,
      fileName: 'microscritt-prompt-items.json',
      content: ResourceExporter.promptItems(items),
    );
  }

  Future<void> _importJson(BuildContext context, WidgetRef ref) async {
    await importResourceFile(
      context,
      label: '提示词',
      importer: (bytes) =>
          ResourceImporter.importPromptItems(ref.read(databaseProvider), bytes),
      onImported: () => ref.invalidate(promptItemsProvider),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(promptItemsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('全局提示词'),
        actions: [
          IconButton(
            tooltip: '导出 JSON',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => _exportJson(context, ref),
          ),
          IconButton(
            tooltip: '导入 JSON',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: () => _importJson(context, ref),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PromptItemEditScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: items.when(
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.notes_outlined,
                title: '暂无提示词项',
                message: '提示词项会按顺序拼进每次对话的系统提示词(预设/规则)。',
              )
            : SearchableList<PromptItem>(
                items: list,
                searchHint: '搜索提示词名称/内容',
                searchText: (item) => '${item.name} ${item.text}',
                itemBuilder: (context, item) => GroupCard(
                  children: [
                    ListTile(
                      leading: _KindBadge(kind: item.kind),
                      title: Text(
                        item.name.isNotEmpty ? item.name : _clip(item.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, ref, item),
                          ),
                          Switch(
                            value: item.enabled,
                            onChanged: (_) => _toggle(ref, item),
                          ),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PromptItemEditScreen(item: item),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        error: (e, _) =>
            EmptyState(icon: Icons.error_outline, title: '加载失败', message: '$e'),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  static final _whitespace = RegExp(r'\s+');

  static String _clip(String s) {
    final oneLine = s.replaceAll(_whitespace, ' ').trim();
    return oneLine.length <= 60 ? oneLine : '${oneLine.substring(0, 60)}…';
  }
}

class _KindBadge extends StatelessWidget {
  final PromptItemKind kind;
  const _KindBadge({required this.kind});

  static String label(PromptItemKind k) => switch (k) {
    PromptItemKind.preset => '预设',
    PromptItemKind.rule => '规则',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label(kind),
        style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12),
      ),
    );
  }
}

/// 提示词项新建/编辑屏。
class PromptItemEditScreen extends ConsumerStatefulWidget {
  final PromptItem? item;
  const PromptItemEditScreen({super.key, this.item});

  @override
  ConsumerState<PromptItemEditScreen> createState() =>
      _PromptItemEditScreenState();
}

class _PromptItemEditScreenState extends ConsumerState<PromptItemEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _text;
  late final TextEditingController _position;
  late PromptItemKind _kind;
  late bool _enabled;
  bool _saving = false;

  bool get _isNew => widget.item == null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item?.name ?? '');
    _text = TextEditingController(text: item?.text ?? '');
    _position = TextEditingController(text: (item?.position ?? 0).toString());
    _kind = item?.kind ?? PromptItemKind.rule;
    _enabled = item?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    _position.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_text.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('内容不能为空')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(promptItemRepositoryProvider);
      final item = PromptItem(
        id: widget.item?.id,
        kind: _kind,
        name: _name.text.trim(),
        text: _text.text,
        enabled: _enabled,
        position: int.tryParse(_position.text.trim()) ?? 0,
      );
      if (_isNew) {
        await repo.insert(item);
      } else {
        await repo.update(item);
      }
      ref.invalidate(promptItemsProvider);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建提示词' : '编辑提示词'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GroupCard(
            children: [
              FormDropdownField<PromptItemKind>(
                value: _kind,
                label: '类型',
                items: PromptItemKind.values.toList(),
                labelOf: _KindBadge.label,
                onChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
              FormTextField(
                controller: _name,
                label: '名称',
                hint: '列表里显示的标题(可不填)',
              ),
              FormTextField(
                controller: _text,
                label: '内容 *',
                lines: 6,
                hint: '写进系统提示词的文本',
              ),
              FormTextField(
                controller: _position,
                label: '位置(越小越靠前)',
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('启用'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
