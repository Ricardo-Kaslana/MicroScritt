import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../export/worldbook_exporter.dart';
import '../import/worldbook_importer.dart';
import '../models/worldbook_entry.dart';
import '../state/providers.dart';
import 'common/app_menu.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/export_helper.dart';
import 'common/form_field.dart';
import 'common/pick_file_bytes.dart';
import 'common/searchable_list.dart';
import 'common/section_header.dart';

/// 角色的世界书管理:条目触发(关键词/常驻)后拼进上下文。
/// 世界书自 v37 起不再有「规则/技能」类型之分 —— 全部条目统一按
/// 关键词命中(或常驻)触发;技能是独立的全局目录,在设置页管理。
///
/// 导入导出以**独立世界书文件**(ST World Info 形态)为准,见
/// [WorldbookExporter] / [WorldbookImporter]:导出可被 SillyTavern 直接读入,
/// 导入兼容 ST 世界书、纯条目数组与角色卡 JSON(取其 `character_book`)。
class WorldbookScreen extends ConsumerWidget {
  final int characterId;
  final String characterName;
  const WorldbookScreen({
    super.key,
    required this.characterId,
    required this.characterName,
  });

  Future<void> _toggle(
    WidgetRef ref,
    List<WorldbookEntry> all,
    WorldbookEntry entry,
  ) async {
    // 只翻 enabled,其余(含表单外的 caseSensitive/matchWholeWords/selective/
    // secondaryKeys 与 extra 透传字段)必须原样保留 —— 旧实现逐字段重建,
    // 表单没有的字段全被抹成默认值,启停一次就丢一串匹配语义(EJ 修)。
    final updated = all
        .map((e) => e.id == entry.id ? e.copyWith(enabled: !e.enabled) : e)
        .toList();
    await ref
        .read(worldbookRepositoryProvider)
        .replaceForCharacter(characterId, updated);
    ref.invalidate(worldbookProvider(characterId));
  }

  Future<void> _setAllEnabled(
    WidgetRef ref,
    List<WorldbookEntry> all,
    bool enabled,
  ) async {
    // 与 _toggle 同理:copyWith 只动 enabled,其余字段原样保留。
    final updated = all.map((e) => e.copyWith(enabled: enabled)).toList();
    await ref
        .read(worldbookRepositoryProvider)
        .replaceForCharacter(characterId, updated);
    ref.invalidate(worldbookProvider(characterId));
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    List<WorldbookEntry> all,
    WorldbookEntry entry,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除条目?',
      message: entry.displayLabel,
    );
    if (!confirmed) return;
    final updated = all.where((e) => e.id != entry.id).toList();
    await ref
        .read(worldbookRepositoryProvider)
        .replaceForCharacter(characterId, updated);
    ref.invalidate(worldbookProvider(characterId));
  }

  /// 导出为独立世界书文件(ST World Info 形态)。
  Future<void> _export(BuildContext context, List<WorldbookEntry> all) async {
    await saveJsonFile(
      context,
      fileName: '世界书_${_safeFileName(characterName)}.json',
      content: WorldbookExporter.export(all),
    );
  }

  /// 从文件导入条目。已有条目时先问「追加 / 替换」—— 替换会整组覆盖、不可撤销,
  /// 不能在用户没表态的情况下替他决定。
  Future<void> _import(
    BuildContext context,
    WidgetRef ref,
    List<WorldbookEntry> current,
  ) async {
    _snack(context, '正在导入…');
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final bytes = await pickedFileBytes(result?.files.single);
      if (bytes == null) {
        if (context.mounted) _snack(context, '导入失败:未读取到所选文件');
        return;
      }
      final imported = WorldbookImporter.fromBytes(bytes);
      if (!context.mounted) return;
      final mode = current.isEmpty
          ? _ImportMode.append
          : await _askImportMode(context, imported.length, current.length);
      if (!context.mounted) return;
      if (mode == null) {
        _snack(context, '已取消导入');
        return;
      }
      // 并入现有条目(position 顺延见 mergeInto);replace 是整组覆盖。
      final entries = WorldbookImporter.mergeInto(
        current,
        imported,
        replace: mode == _ImportMode.replace,
      );
      await ref
          .read(worldbookRepositoryProvider)
          .replaceForCharacter(characterId, entries);
      ref.invalidate(worldbookProvider(characterId));
      if (!context.mounted) return;
      _snack(
        context,
        mode == _ImportMode.append
            ? '已导入 ${imported.length} 条条目(追加)'
            : '已导入 ${imported.length} 条条目(替换原 ${current.length} 条)',
      );
    } on FormatException catch (e) {
      if (context.mounted) _snack(context, '导入失败:${e.message}');
    } catch (e) {
      if (context.mounted) _snack(context, '导入失败:$e');
    }
  }

  Future<_ImportMode?> _askImportMode(
    BuildContext context,
    int incoming,
    int existing,
  ) => showDialog<_ImportMode>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('导入方式'),
      content: Text(
        '文件里有 $incoming 条条目,当前已有 $existing 条。追加到现有条目后,还是替换掉全部现有条目?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, _ImportMode.replace),
          child: const Text('替换'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, _ImportMode.append),
          child: const Text('追加'),
        ),
      ],
    ),
  );

  static void _snack(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 文件名里不能出现路径分隔符等字符;名字为空时兜底占位。
  static String _safeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    return cleaned.isEmpty ? '未命名' : cleaned;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(worldbookProvider(characterId));
    final list = entries.value ?? const <WorldbookEntry>[];
    return Scaffold(
      appBar: AppBar(
        title: Text('世界书 · $characterName'),
        actions: [
          AppPopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (action) {
              switch (action) {
                case 'import':
                  _import(context, ref, list);
                case 'export':
                  _export(context, list);
                case 'enableAll':
                  _setAllEnabled(ref, list, true);
                case 'disableAll':
                  _setAllEnabled(ref, list, false);
              }
            },
            actions: [
              const MenuAction(
                value: 'import',
                label: '导入条目',
                icon: Icons.file_upload_outlined,
              ),
              if (list.isNotEmpty) ...[
                const MenuAction(
                  value: 'export',
                  label: '导出条目(JSON)',
                  icon: Icons.file_download_outlined,
                ),
                const MenuAction(
                  value: 'enableAll',
                  label: '全部启用',
                  icon: Icons.done_all,
                ),
                const MenuAction(
                  value: 'disableAll',
                  label: '全部停用',
                  icon: Icons.block,
                ),
              ],
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => WorldbookEntryEditScreen(characterId: characterId),
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建条目'),
      ),
      body: entries.when(
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.book_outlined,
                title: '暂无世界书条目',
                message: '条目在消息命中关键词(或设为常驻)时拼进上下文。导入角色卡时会自动带入,也可以直接导入世界书文件。',
                action: FilledButton.tonalIcon(
                  onPressed: () => _import(context, ref, const []),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('导入条目'),
                ),
              )
            : SearchableList<WorldbookEntry>(
                items: list,
                searchHint: '搜索条目名称/关键词/内容',
                searchText: (e) =>
                    '${e.displayLabel} ${e.keys.join(' ')} ${e.content}',
                itemBuilder: (context, e) => GroupCard(
                  children: [
                    ListTile(
                      leading: Icon(
                        e.constant
                            ? Icons.anchor_outlined
                            : Icons.menu_book_outlined,
                      ),
                      title: Text(
                        e.displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, ref, list, e),
                          ),
                          Switch(
                            value: e.enabled,
                            onChanged: (_) => _toggle(ref, list, e),
                          ),
                        ],
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => WorldbookEntryEditScreen(
                            characterId: characterId,
                            entry: e,
                          ),
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

/// 导入已有条目时的落库方式:追加到现有条目后,或整组替换。
enum _ImportMode { append, replace }

/// 世界书条目新建/编辑屏。保存走 replaceForCharacter(整组重写)。
class WorldbookEntryEditScreen extends ConsumerStatefulWidget {
  final int characterId;
  final WorldbookEntry? entry;
  const WorldbookEntryEditScreen({
    super.key,
    required this.characterId,
    this.entry,
  });

  @override
  ConsumerState<WorldbookEntryEditScreen> createState() =>
      _WorldbookEntryEditScreenState();
}

class _WorldbookEntryEditScreenState
    extends ConsumerState<WorldbookEntryEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _keys;
  late final TextEditingController _content;
  late final TextEditingController _position;
  late bool _useRegex;
  late bool _constant;
  late bool _enabled;
  bool _saving = false;

  bool get _isNew => widget.entry == null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _name = TextEditingController(text: e?.name ?? '');
    _keys = TextEditingController(text: e?.keys.join(', ') ?? '');
    _content = TextEditingController(text: e?.content ?? '');
    _position = TextEditingController(text: (e?.position ?? 0).toString());
    _useRegex = e?.useRegex ?? false;
    _constant = e?.constant ?? false;
    _enabled = e?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _keys.dispose();
    _content.dispose();
    _position.dispose();
    super.dispose();
  }

  List<String> get _parsedKeys => _keys.text
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _save() async {
    if (_content.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('内容不能为空')));
      return;
    }
    if (_parsedKeys.isEmpty && !_constant) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填关键词,或勾选常驻')));
      return;
    }
    setState(() => _saving = true);
    try {
      // 整组重写:保留其他条目,替换/追加当前条目。编辑时基于原条目 copyWith
      // —— 表单只覆盖可编辑字段,caseSensitive/matchWholeWords/selective/
      // secondaryKeys 与 extra 透传字段原样携带(旧实现重建即抹掉,EJ 修)。
      final current = await ref
          .read(worldbookRepositoryProvider)
          .byCharacter(widget.characterId);
      final entry =
          (widget.entry ??
                  WorldbookEntry(characterId: widget.characterId, content: ''))
              .copyWith(
                id: widget.entry?.id,
                characterId: widget.characterId,
                name: _name.text.trim(),
                keys: _parsedKeys,
                useRegex: _useRegex,
                constant: _constant,
                content: _content.text,
                position: int.tryParse(_position.text.trim()) ?? 0,
                enabled: _enabled,
              );
      final updated = _isNew
          ? [...current, entry]
          : current.map((e) => e.id == widget.entry!.id ? entry : e).toList();
      await ref
          .read(worldbookRepositoryProvider)
          .replaceForCharacter(widget.characterId, updated);
      ref.invalidate(worldbookProvider(widget.characterId));
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建条目' : '编辑条目'),
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
                label: '名称',
                hint: '列表里显示的标题(可不填;留空时用首关键词)',
              ),
              const SizedBox(height: 16),
              FormTextField(
                controller: _keys,
                label: '关键词(逗号分隔)',
                hint: '消息中出现任一关键词即触发',
              ),
              const SizedBox(height: 16),
              FormTextField(controller: _content, label: '内容 *', lines: 6),
              const SizedBox(height: 16),
              FormTextField(
                controller: _position,
                label: '位置',
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('常驻(无需关键词)'),
            value: _constant,
            onChanged: (v) => setState(() => _constant = v),
          ),
          SwitchListTile(
            title: const Text('关键词按正则匹配'),
            value: _useRegex,
            onChanged: (v) => setState(() => _useRegex = v),
          ),
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
