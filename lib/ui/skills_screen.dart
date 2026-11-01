import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/character_repository.dart';
import '../export/resource_exporter.dart';
import '../import/resource_importer.dart';
import '../models/skill.dart';
import '../models/worldbook_entry.dart';
import '../state/providers.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/resource_io.dart';
import 'common/searchable_list.dart';
import 'common/section_header.dart';

/// 全局技能管理(设置页入口)。技能是 Anthropic skills 风格的提示词资产:
/// `name` + `description` + 实际内容,全局共享、手动控制启用;启用中的技能
/// 在所有会话拼进上下文稳定段。支持自由创建/编辑,以及从已导入角色卡的世界书
/// 条目按需导入(导入产生的技能没有描述)。
class SkillsScreen extends ConsumerWidget {
  const SkillsScreen({super.key});

  Future<void> _delete(BuildContext context, WidgetRef ref, Skill s) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除技能?',
      message: s.name,
    );
    if (!confirmed) return;
    await ref.read(skillRepositoryProvider).delete(s.id!);
    ref.invalidate(skillsProvider);
  }

  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(skillRepositoryProvider).all();
    if (!context.mounted) return;
    await exportResourceFile(
      context,
      fileName: 'microscritt-skills.json',
      content: ResourceExporter.skills(items),
    );
  }

  Future<void> _importJson(BuildContext context, WidgetRef ref) async {
    await importResourceFile(
      context,
      label: '技能',
      importer: (bytes) =>
          ResourceImporter.importSkills(ref.read(databaseProvider), bytes),
      onImported: () => ref.invalidate(skillsProvider),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skills = ref.watch(skillsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('技能'),
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
          IconButton(
            tooltip: '从世界书导入',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SkillImportScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SkillEditScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建技能'),
      ),
      body: skills.when(
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.extension_outlined,
                title: '暂无技能',
                message: '技能由名称 + 描述 + 内容组成,启用后全局生效;也可从角色卡的世界书条目一键导入。',
              )
            : SearchableList<Skill>(
                items: list,
                searchHint: '搜索技能名称/描述/内容',
                searchText: (s) => '${s.name} ${s.description} ${s.content}',
                itemBuilder: (context, s) => GroupCard(
                  children: [
                    ListTile(
                      leading: Icon(
                        Icons.extension_outlined,
                        color: s.enabled
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        s.description.isEmpty ? '(无描述)' : s.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, ref, s),
                          ),
                          Switch(
                            value: s.enabled,
                            onChanged: (v) async {
                              await ref
                                  .read(skillRepositoryProvider)
                                  .setEnabled(s.id!, v);
                              ref.invalidate(skillsProvider);
                            },
                          ),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SkillEditScreen(existing: s),
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
}

/// 技能新建/编辑屏:name / description / content(Anthropic skills 三要素)+
/// 启用开关。
class SkillEditScreen extends ConsumerStatefulWidget {
  final Skill? existing;
  const SkillEditScreen({super.key, this.existing});

  @override
  ConsumerState<SkillEditScreen> createState() => _SkillEditScreenState();
}

class _SkillEditScreenState extends ConsumerState<SkillEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _content;
  late bool _enabled;
  bool _saving = false;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _name = TextEditingController(text: s?.name ?? '');
    _description = TextEditingController(text: s?.description ?? '');
    _content = TextEditingController(text: s?.content ?? '');
    _enabled = s?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名称不能为空')));
      return;
    }
    if (_content.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('内容不能为空')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(skillRepositoryProvider);
      if (_isNew) {
        await repo.insert(
          Skill(
            name: name,
            description: _description.text.trim(),
            content: _content.text,
            enabled: _enabled,
          ),
        );
      } else {
        await repo.update(
          Skill(
            id: widget.existing!.id,
            name: name,
            description: _description.text.trim(),
            content: _content.text,
            enabled: _enabled,
          ),
        );
      }
      ref.invalidate(skillsProvider);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建技能' : '编辑技能'),
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
              FormTextField(
                controller: _name,
                label: '名称 *',
                hint: '技能名,如「战斗描写」',
              ),
              const SizedBox(height: 16),
              FormTextField(
                controller: _description,
                label: '描述',
                hint: '一句话说明技能的用途(可留空)',
                lines: 2,
              ),
              const SizedBox(height: 16),
              FormTextField(
                controller: _content,
                label: '内容 *',
                hint: '技能的实际内容,启用后拼进上下文',
                lines: 8,
              ),
            ],
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('启用'),
            subtitle: const Text('启用中的技能在所有会话全局生效'),
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

/// 从角色卡世界书导入技能:选角色 → 勾选世界书条目 → 以**无描述**技能落库
/// (name 取条目显示名,content 取条目内容,同名技能自动跳过)。条目页支持
/// 全选/取消全选;点击条目可在底部弹层查看完整内容(可复制)。
class SkillImportScreen extends ConsumerStatefulWidget {
  const SkillImportScreen({super.key});

  @override
  ConsumerState<SkillImportScreen> createState() => _SkillImportScreenState();
}

class _SkillImportScreenState extends ConsumerState<SkillImportScreen> {
  CharacterRecord? _character;
  List<WorldbookEntry> _entries = const [];
  final Set<int> _selectedIds = {};
  bool _loadingEntries = false;
  bool _importing = false;
  String? _error;

  Future<void> _pickCharacter(CharacterRecord record) async {
    setState(() {
      _character = record;
      _loadingEntries = true;
      _error = null;
      _selectedIds.clear();
    });
    try {
      final entries = await ref
          .read(worldbookRepositoryProvider)
          .byCharacter(record.id);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loadingEntries = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingEntries = false;
      });
    }
  }

  Future<void> _importSelected() async {
    final character = _character;
    if (character == null || _importing) return;
    final selected = _entries
        .where((e) => e.id != null && _selectedIds.contains(e.id))
        .toList();
    if (selected.isEmpty) return;
    setState(() => _importing = true);
    try {
      final (imported, skipped) = await ref
          .read(skillRepositoryProvider)
          .importAll([
            for (final e in selected)
              // 世界书导入的技能没有描述(Anthropic skills 的 description 留空)。
              Skill(name: e.displayLabel, description: '', content: e.content),
          ]);
      ref.invalidate(skillsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            skipped > 0
                ? '已导入 $imported 个技能,$skipped 个与现有技能同名已跳过'
                : '已导入 $imported 个技能',
          ),
        ),
      );
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _character == null
              ? '从世界书导入 · 选择角色'
              : '从世界书导入 · ${_character!.card.name}',
        ),
      ),
      floatingActionButton: _character == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _selectedIds.isEmpty || _importing
                  ? null
                  : _importSelected,
              icon: _importing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined),
              label: Text(
                _importing ? '导入中…' : '导入选中 (${_selectedIds.length})',
              ),
            ),
      body: _character == null ? _buildCharacterPicker() : _buildEntryPicker(),
    );
  }

  Widget _buildCharacterPicker() {
    final charactersAsync = ref.watch(charactersProvider);
    return charactersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(icon: Icons.error_outline, title: '加载失败', message: '$e'),
      data: (records) => records.isEmpty
          ? const EmptyState(
              icon: Icons.person_off_outlined,
              title: '暂无角色卡',
              message: '先在首页导入或创建角色卡。',
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8),
              itemCount: records.length,
              itemBuilder: (context, i) {
                final r = records[i];
                return GroupCard(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(r.card.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pickCharacter(r),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildEntryPicker() {
    if (_loadingEntries) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: '加载失败',
        message: _error!,
      );
    }
    if (_entries.isEmpty) {
      return EmptyState(
        icon: Icons.book_outlined,
        title: '该角色没有世界书条目',
        message: '世界书条目随角色卡导入;也可以回到上一步选择其它角色。',
      );
    }
    final selectableIds = [
      for (final e in _entries)
        if (e.id != null) e.id!,
    ];
    final allSelected =
        selectableIds.isNotEmpty && selectableIds.every(_selectedIds.contains);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 提示 + 全选/取消全选(有选中项时按钮变为「取消全选」一键清空)。
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '勾选条目导入为技能(无描述、同名跳过);点条目查看完整内容。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: selectableIds.isEmpty
                    ? null
                    : () => setState(() {
                        if (allSelected) {
                          _selectedIds.clear();
                        } else {
                          _selectedIds.addAll(selectableIds);
                        }
                      }),
                icon: Icon(
                  allSelected ? Icons.deselect : Icons.select_all,
                  size: 18,
                ),
                label: Text(allSelected ? '取消全选' : '全选'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 96),
            itemCount: _entries.length,
            itemBuilder: (context, i) {
              final e = _entries[i];
              final selected = e.id != null && _selectedIds.contains(e.id);
              return GroupCard(
                children: [
                  // 布局对齐世界书管理页:图标(常驻锚/关键词书)+ 显示名;
                  // 复选框只管勾选,点行查看完整内容。
                  ListTile(
                    leading: Checkbox(
                      value: selected,
                      onChanged: (v) => setState(() {
                        if (e.id == null) return;
                        if (v == true) {
                          _selectedIds.add(e.id!);
                        } else {
                          _selectedIds.remove(e.id!);
                        }
                      }),
                    ),
                    title: Text(
                      e.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Icon(
                      Icons.visibility_outlined,
                      size: 20,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    onTap: () => _showEntryContent(context, e),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 底部弹层查看条目完整内容:名称 + 触发方式(常驻/关键词/正则)+ 可复制全文。
  void _showEntryContent(BuildContext context, WorldbookEntry e) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    e.constant
                        ? Icons.anchor_outlined
                        : Icons.menu_book_outlined,
                    size: 20,
                    color: Theme.of(sheetContext).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                e.constant
                    ? '常驻 · 无需关键词'
                    : e.useRegex
                    ? '正则匹配:${e.keys.join(', ')}'
                    : '关键词:${e.keys.join(', ')}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(sheetContext).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    e.content,
                    style: const TextStyle(fontSize: 15, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
