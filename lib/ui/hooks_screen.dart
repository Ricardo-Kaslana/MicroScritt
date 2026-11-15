/// Hooks 管理页与 Hook 编辑屏。
///
/// Hook 是绑定触发点的同步 JS 脚本,在 QuickJS 沙箱里改写上下文或回复;
/// 求值失败 / 超时按「本 hook 未生效」处理,绝不断掉发送管线。导出/导入走
/// 统一资源信封,导入按 name 去重、同名跳过,触发点非法则整份文件拒绝。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../export/resource_exporter.dart';
import '../import/resource_importer.dart';
import '../models/hook.dart';
import '../state/providers.dart';
import 'common/app_menu.dart';
import 'common/confirm_dialog.dart';
import 'common/edit_form_scaffold.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/list_page_scaffold.dart';
import 'common/resource_io.dart';
import 'common/section_header.dart';
import 'common/toggle_delete_tile.dart';

/// 触发点的中文标签(编辑页下拉共用);wire 值即枚举名,落库与导入都按它。
String hookPointLabel(HookTriggerPoint p) => switch (p) {
  HookTriggerPoint.beforeContextAssembly => '组装前(改写用户输入)',
  HookTriggerPoint.afterContextAssembly => '组装后(改写系统提示词)',
  HookTriggerPoint.beforeGenerate => '生成前(改写提示词/参数)',
  HookTriggerPoint.afterStream => '流式后(改写回复)',
  HookTriggerPoint.beforePersist => '落库前(改写回复)',
};

/// Hook 列表页(设置页「内容与扩展 · Hooks」入口)。
///
/// 脚本在 QuickJS 沙箱内运行,可改写用户输入、系统提示词与回复文本;开关
/// 只决定是否执行,删除后该脚本不再参与任何后续轮次。
class HooksScreen extends ConsumerWidget {
  const HooksScreen({super.key});

  /// 切换启用状态:整条重写(仓库走整行更新)后失效列表。
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

  /// 删除 Hook:确认后直接删行,后续轮次不再执行该脚本。
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

  /// 导出全部 Hook:统一资源信封,触发点写 wire 值,不含库内 id。
  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(hookRepositoryProvider).all();
    if (!context.mounted) return;
    await exportResourceFile(
      context,
      fileName: 'microscritt-hooks.json',
      content: ResourceExporter.hooks(items),
    );
  }

  /// 导入 Hook:先整体解析校验(触发点必须能对上枚举,否则整份拒绝),
  /// 再按 name 去重插入;同名跳过并计数。
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
    return ListPageScaffold<Hook>(
      title: 'Hooks',
      actions: [
        AppPopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: (action) {
            switch (action) {
              case 'export':
                _exportJson(context, ref);
              case 'import':
                _importJson(context, ref);
            }
          },
          actions: const [
            MenuAction(
              value: 'export',
              label: '导出 JSON',
              icon: Icons.file_download_outlined,
            ),
            MenuAction(
              value: 'import',
              label: '导入 JSON',
              icon: Icons.file_upload_outlined,
            ),
          ],
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const HookEditScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      loading: hooks.isLoading && !hooks.hasValue,
      error: hooks.hasError && !hooks.hasValue ? hooks.error : null,
      onRetry: () => ref.invalidate(hooksProvider),
      items: hooks.value,
      emptyState: const EmptyState(
        icon: Icons.code_outlined,
        title: '暂无 Hook',
        message: 'Hook 是在触发点上运行的 JS 脚本,可改写用户输入、系统提示词与回复文本。',
      ),
      searchHint: '搜索 Hook 名称/代码',
      searchText: (hook) => '${hook.name} ${hook.jsCode}',
      itemBuilder: (context, hook) => GroupCard(
        children: [
          ToggleDeleteTile(
            leading: const Icon(Icons.code),
            title: hook.name,
            enabled: hook.enabled,
            onToggle: (_) => _toggle(ref, hook),
            onDelete: () => _delete(context, ref, hook),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => HookEditScreen(hook: hook)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hook 新建/编辑屏:名字 + 触发点 + JS 代码(等宽字体)。
///
/// 保存只校验名字与代码非空,不做 JS 语法检查 —— 语法错误留到运行期由求值
/// 器按失败处理(该 hook 不生效,管线继续)。新建时预填一段 `__ctx` 示例;
/// 直接返回即丢弃未保存内容。
class HookEditScreen extends ConsumerStatefulWidget {
  /// null 表示新建;非 null 时以该行为初值编辑。
  final Hook? hook;
  const HookEditScreen({super.key, this.hook});

  @override
  ConsumerState<HookEditScreen> createState() => _HookEditScreenState();
}

class _HookEditScreenState extends ConsumerState<HookEditScreen> {
  /// 新建时的示例脚本:演示通过 `__ctx` 读改写的最小形态。
  static const _template =
      '// __ctx 是注入的上下文对象;改写后直接修改它即可。\n'
      '// 例: __ctx.text = __ctx.text.replace(/foo/g, "bar");\n';

  late final TextEditingController _name;
  late final TextEditingController _code;
  late HookTriggerPoint _point;
  late bool _enabled;
  bool _saving = false;

  /// 打开编辑器时的表单快照(未保存修改的判定基准)。
  late String _initialSignature;

  bool get _isNew => widget.hook == null;

  @override
  void initState() {
    super.initState();
    final hook = widget.hook;
    _name = TextEditingController(text: hook?.name ?? '');
    _code = TextEditingController(text: hook?.jsCode ?? _template);
    _point = hook?.triggerPoint ?? HookTriggerPoint.afterStream;
    _enabled = hook?.enabled ?? true;
    _initialSignature = _signature();
  }

  String _signature() =>
      '${_name.text}\u0000${_code.text}\u0000${_point.name}\u0000$_enabled';

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  /// 保存:名字与代码缺一即提示并中止;通过后整条写入(新建插入、编辑更新)
  /// 并失效列表,随后返回上一页。
  Future<void> _save() async {
    if (_saving) return;
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
    return EditFormScaffold(
      title: _isNew ? '新建 Hook' : '编辑 Hook',
      saving: _saving,
      onSave: _save,
      hasChanges: () => _signature() != _initialSignature,
      changes: [_name, _code],
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
      ],
    );
  }
}
