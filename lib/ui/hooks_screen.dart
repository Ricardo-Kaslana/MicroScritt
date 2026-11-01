import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../export/resource_exporter.dart';
import '../import/resource_importer.dart';
import '../models/hook.dart';
import '../state/providers.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/resource_io.dart';
import 'common/searchable_list.dart';
import 'common/section_header.dart';

String hookPointLabel(HookTriggerPoint p) => switch (p) {
  HookTriggerPoint.beforeContextAssembly => '组装前(改写用户输入)',
  HookTriggerPoint.afterContextAssembly => '组装后(改写系统提示词)',
  HookTriggerPoint.beforeGenerate => '生成前(改写提示词/参数)',
  HookTriggerPoint.afterStream => '流式后(改写回复)',
  HookTriggerPoint.beforePersist => '落库前(改写回复)',
};

/// Hook 管理:JS 代码在 QuickJS 沙箱内运行,可改写上下文与回复。
class HooksScreen extends ConsumerWidget {
  const HooksScreen({super.key});

  Future<void> _toggle(WidgetRef ref, Hook hook) async {
    final id = hook.id;
    if (id == null) return;
    await ref
        .read(hookRepositoryProvider)
        .update(
          Hook(
            id: id,
            name: hook.name,
            triggerPoint: hook.triggerPoint,
            jsCode: hook.jsCode,
            enabled: !hook.enabled,
          ),
        );
    ref.invalidate(hooksProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Hook hook) async {
    final id = hook.id;
    if (id == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除 Hook?',
      message: hook.name,
    );
    if (!confirmed) return;
    await ref.read(hookRepositoryProvider).delete(id);
    ref.invalidate(hooksProvider);
  }

  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(hookRepositoryProvider).all();
    if (!context.mounted) return;
    await exportResourceFile(
      context,
      fileName: 'microscritt-hooks.json',
      content: ResourceExporter.hooks(items),
    );
  }

  Future<void> _importJson(BuildContext context, WidgetRef ref) async {
    await importResourceFile(
      context,
      label: ' Hook',
      importer: (bytes) =>
          ResourceImporter.importHooks(ref.read(databaseProvider), bytes),
      onImported: () => ref.invalidate(hooksProvider),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hooks = ref.watch(hooksProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hooks'),
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
          MaterialPageRoute(builder: (_) => const HookEditScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: hooks.when(
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.code_outlined,
                title: '暂无 Hook',
                message: 'Hook 是在触发点上运行的 JS 脚本,可改写用户输入、系统提示词与回复文本。',
              )
            : SearchableList<Hook>(
                items: list,
                searchHint: '搜索 Hook 名称/代码',
                searchText: (hook) => '${hook.name} ${hook.jsCode}',
                itemBuilder: (context, hook) => GroupCard(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.code),
                      title: Text(hook.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, ref, hook),
                          ),
                          Switch(
                            value: hook.enabled,
                            onChanged: (_) => _toggle(ref, hook),
                          ),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => HookEditScreen(hook: hook),
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

/// Hook 新建/编辑屏:名字 + 触发点 + JS 代码(等宽字体)。
class HookEditScreen extends ConsumerStatefulWidget {
  final Hook? hook;
  const HookEditScreen({super.key, this.hook});

  @override
  ConsumerState<HookEditScreen> createState() => _HookEditScreenState();
}

class _HookEditScreenState extends ConsumerState<HookEditScreen> {
  static const _template =
      '// __ctx 是注入的上下文对象;改写后直接修改它即可。\n'
      '// 例: __ctx.text = __ctx.text.replace(/foo/g, "bar");\n';

  late final TextEditingController _name;
  late final TextEditingController _code;
  late HookTriggerPoint _point;
  late bool _enabled;
  bool _saving = false;

  bool get _isNew => widget.hook == null;

  @override
  void initState() {
    super.initState();
    final hook = widget.hook;
    _name = TextEditingController(text: hook?.name ?? '');
    _code = TextEditingController(text: hook?.jsCode ?? _template);
    _point = hook?.triggerPoint ?? HookTriggerPoint.afterStream;
    _enabled = hook?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名字不能为空')));
      return;
    }
    if (_code.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('JS 代码不能为空')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(hookRepositoryProvider);
      final hook = Hook(
        id: widget.hook?.id,
        name: _name.text.trim(),
        triggerPoint: _point,
        jsCode: _code.text,
        enabled: _enabled,
      );
      if (_isNew) {
        await repo.insert(hook);
      } else {
        await repo.update(hook);
      }
      ref.invalidate(hooksProvider);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建 Hook' : '编辑 Hook'),
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
          FormTextField(controller: _name, label: '名字 *', hint: 'Hook 名称'),
          const SizedBox(height: 14),
          FormDropdownField<HookTriggerPoint>(
            value: _point,
            label: '触发点',
            items: HookTriggerPoint.values.toList(),
            labelOf: hookPointLabel,
            onChanged: (v) => setState(() => _point = v ?? _point),
          ),
          const SizedBox(height: 14),
          FormTextField(
            controller: _code,
            label: 'JS 代码 *',
            lines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            hint: '改写脚本...',
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
