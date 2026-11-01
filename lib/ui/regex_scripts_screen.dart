/// 显示层正则脚本管理页与编辑屏(含「试一试」实时预览)。
///
/// 脚本只对气泡显示文本做查找替换,替换串可带样式标记(``<i>``、
/// ``<c=ff8800>`` 等)渲染成富文本;落库正文与发给 LLM 的内容永不改写。
/// 导入按 name 去重、同名跳过,position 按文件保留。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../engine/display_regex.dart';
import '../export/resource_exporter.dart';
import '../import/resource_importer.dart';
import '../models/regex_script.dart';
import '../models/regex_script_seeds.dart';
import '../state/providers.dart';
import '../ui/widgets/rich_message_text.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/resource_io.dart';
import 'common/searchable_list.dart';
import 'common/section_header.dart';

/// 正则脚本列表页(设置页「内容与扩展 · 正则脚本」入口)。
///
/// 对气泡显示文本做查找替换,替换串可带样式标记(``<i>``、``<c=ff8800>``
/// 等)渲染成富文本。仅影响显示,不改写落库与发给 LLM 的内容。页首另有
/// 内置对话高亮总开关 —— 那是渲染管线内建行为,不是正则脚本。
class RegexScriptsScreen extends ConsumerWidget {
  const RegexScriptsScreen({super.key});

  /// 切换脚本启用状态:整条更新后失效列表(停用脚本不再参与替换)。
  Future<void> _toggle(WidgetRef ref, RegexScript s) async {
    final id = s.id;
    if (id == null) return;
    await ref
        .read(regexScriptRepositoryProvider)
        .update(s.copyWith(enabled: !s.enabled));
    ref.invalidate(regexScriptsProvider);
  }

  /// 删除脚本:确认后直接删行,不再参与任何气泡的显示层替换。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    RegexScript s,
  ) async {
    final id = s.id;
    if (id == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除脚本?',
      message: s.name,
    );
    if (!confirmed) return;
    await ref.read(regexScriptRepositoryProvider).delete(id);
    ref.invalidate(regexScriptsProvider);
  }

  /// 内置对话高亮开关落库:同步 appSettingsProvider(单一真相)再持久化。
  Future<void> _toggleDialogueHighlight(WidgetRef ref, bool enabled) async {
    final current = ref.read(appSettingsProvider);
    final updated = current.copyWith(dialogueHighlightEnabled: enabled);
    ref.read(appSettingsProvider.notifier).state = updated;
    await ref.read(appSettingsRepositoryProvider).save(updated);
  }

  /// 导出全部脚本:信封保留 position(应用顺序),不含库内 id。
  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(regexScriptRepositoryProvider).all();
    if (!context.mounted) return;
    await exportResourceFile(
      context,
      fileName: 'microscritt-regex-scripts.json',
      content: ResourceExporter.regexScripts(items),
    );
  }

  /// 导入脚本:结构错误整份拒绝;按 name 去重、同名跳过,position 按文件
  /// 保留(直写表,绕过仓库「新脚本排到末尾」的语义)。
  Future<void> _importJson(BuildContext context, WidgetRef ref) async {
    await importResourceFile(
      context,
      label: '正则脚本',
      importer: (bytes) => ResourceImporter.importRegexScripts(
        ref.read(databaseProvider),
        bytes,
      ),
      onImported: () => ref.invalidate(regexScriptsProvider),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final scripts = ref.watch(regexScriptsProvider);
    final dialogueHighlight = ref
        .watch(appSettingsProvider)
        .dialogueHighlightEnabled;
    return Scaffold(
      appBar: AppBar(
        title: const Text('正则脚本'),
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
          MaterialPageRoute(builder: (_) => const RegexScriptEditScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: Column(
        children: [
          // 引号台词的斜体+强调色是渲染管线内建行为而非正则脚本 —— 关掉全部
          // 脚本关不掉它,故在此单独提供总开关(随 app_settings 持久化)。
          GroupCard(
            children: [
              SwitchListTile(
                secondary: Icon(
                  Icons.format_quote,
                  color: scheme.onSurfaceVariant,
                ),
                title: const Text('内置对话高亮'),
                subtitle: const Text('引号台词(“…”/「…」)斜体+强调色;非正则脚本,独立开关'),
                value: dialogueHighlight,
                onChanged: (v) => _toggleDialogueHighlight(ref, v),
              ),
            ],
          ),
          Expanded(
            child: scripts.when(
              data: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.manage_search_outlined,
                      title: '暂无脚本',
                      message: '脚本对气泡显示文本做查找替换(如把 *动作* 变斜体、给关键词上色),不影响对话内容本身。',
                    )
                  : SearchableList<RegexScript>(
                      items: list,
                      searchHint: '搜索脚本名称/正则/替换串',
                      searchText: (s) =>
                          '${s.name} ${s.findRegex} ${s.replace}',
                      itemBuilder: (context, s) => GroupCard(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.manage_search),
                            title: Text(s.name),
                            subtitle: Text(
                              '${s.findRegex} → ${s.replace}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
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
                                  onChanged: (_) => _toggle(ref, s),
                                ),
                              ],
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    RegexScriptEditScreen(script: s),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline,
                title: '加载失败',
                message: '$e',
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}

/// 脚本新建/编辑屏:查找正则 + 替换串 + 样式标记提示 + 试一试预览。
///
/// 预览用当前表单值实时编译,正则非法时显示错误而不渲染;保存前再次校验
/// 正则可编译,非法则拒绝落库(运行期同样会静默跳过坏脚本,不让一条脚本
/// 拖垮整个气泡渲染)。直接返回即丢弃未保存内容。
class RegexScriptEditScreen extends ConsumerStatefulWidget {
  /// null 表示新建;非 null 时以该行为初值编辑。
  final RegexScript? script;
  const RegexScriptEditScreen({super.key, this.script});

  @override
  ConsumerState<RegexScriptEditScreen> createState() =>
      _RegexScriptEditScreenState();
}

class _RegexScriptEditScreenState extends ConsumerState<RegexScriptEditScreen> {
  // 新建脚本的默认预填与模板 chip 全部直接引用默认种子常量,种子再改版时
  // 页面自动跟随,不会出现「手写副本与种子脱节」的漂移。
  static RegexScript get _templateSeed =>
      kDefaultRegexScriptSeeds.firstWhere((s) => s.name == '斜体动作');
  static String get _templateFind => _templateSeed.findRegex;
  static String get _templateReplace => _templateSeed.replace;

  late final TextEditingController _name;
  late final TextEditingController _find;
  late final TextEditingController _replace;
  late final TextEditingController _sample;
  late bool _enabled;
  bool _saving = false;

  bool get _isNew => widget.script == null;

  @override
  void initState() {
    super.initState();
    final s = widget.script;
    _name = TextEditingController(text: s?.name ?? '');
    _find = TextEditingController(text: s?.findRegex ?? _templateFind);
    _replace = TextEditingController(text: s?.replace ?? _templateReplace);
    _sample = TextEditingController(
      text: _defaultSample(s?.replace ?? _templateReplace),
    );
    _enabled = s?.enabled ?? true;
  }

  /// 示例文本随脚本类型走:替换串输出什么标记,示例就给能命中该脚本的原文,
  /// 让「试一试」预览打开即有结果,而不是写死斜体示例让加粗/胶囊脚本空跑。
  static String _defaultSample(String replace) {
    if (replace.contains('<b>')) return '她**重重地**拍下杯子:“够了!”';
    if (replace.contains('<chip>')) return '【2024年·秋·晴 17:42】\n她推门而入。';
    return '她*低下头*说:“你好。”';
  }

  @override
  void dispose() {
    _name.dispose();
    _find.dispose();
    _replace.dispose();
    _sample.dispose();
    super.dispose();
  }

  /// 当前表单值的实时编译:正则非法时返回 null(预览区显示错误)。
  List<CompiledRegexScript>? get _liveCompiled {
    if (validateRegexPattern(_find.text) != null) return null;
    return [
      CompiledRegexScript(
        RegexScript(
          name: _name.text,
          findRegex: _find.text,
          replace: _replace.text,
          enabled: true,
        ),
        RegExp(_find.text),
      ),
    ];
  }

  /// 套用模板:填充查找/替换,并换上配套的示例文本让预览即刻可看。
  void _applyTemplate(String find, String replace, String sample) {
    setState(() {
      _find.text = find;
      _replace.text = replace;
      _sample.text = sample;
    });
  }

  /// 保存前校验名字非空与正则可编译;position 沿用既有行(新脚本由仓库
  /// 排到列表末尾),保存后失效列表并返回。
  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名字不能为空')));
      return;
    }
    if (validateRegexPattern(_find.text) != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('查找正则无效,请先修正')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(regexScriptRepositoryProvider);
      final script = RegexScript(
        id: widget.script?.id,
        name: _name.text.trim(),
        findRegex: _find.text,
        replace: _replace.text,
        enabled: _enabled,
        position: widget.script?.position ?? 0,
      );
      if (_isNew) {
        await repo.insert(script);
      } else {
        await repo.update(script);
      }
      ref.invalidate(regexScriptsProvider);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compiled = _liveCompiled;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建脚本' : '编辑脚本'),
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
          FormTextField(controller: _name, label: '名字 *', hint: '脚本名称'),
          FormTextField(
            controller: _find,
            label: '查找正则 * (Dart RegExp)',
            hint: r'如 \*([\s\S]+?)\*',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            onChanged: (_) => setState(() {}),
          ),
          FormTextField(
            controller: _replace,
            label: '替换为 *',
            hint: '支持 \$1–\$9、\$& 与样式标记',
            lines: 2,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            onChanged: (_) => setState(() {}),
          ),
          if (compiled == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(
                '正则无效:${validateRegexPattern(_find.text)}',
                style: TextStyle(color: scheme.error, fontSize: 13),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(
              '样式标记:<i>斜体</i> <b>加粗</b> <u>下划线</u> <s>删除线</s> '
              '<c=RRGGBB>颜色</c> <mark>高亮</mark> <chip>居中胶囊</chip>'
              '(写在替换串里,标记本身不显示)',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Wrap(
              spacing: 8,
              children: [
                for (final seed in kDefaultRegexScriptSeeds)
                  ActionChip(
                    avatar: Icon(
                      seed.replace.startsWith('<b>')
                          ? Icons.format_bold
                          : seed.replace.startsWith('<chip>')
                          ? Icons.schedule
                          : Icons.auto_awesome,
                      size: 16,
                    ),
                    label: Text('${seed.name}模板'),
                    onPressed: () => _applyTemplate(
                      seed.findRegex,
                      seed.replace,
                      _defaultSample(seed.replace),
                    ),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('启用'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 8),
          SectionHeader('试一试'),
          FormTextField(
            controller: _sample,
            label: '示例文本',
            lines: 3,
            onChanged: (_) => setState(() {}),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: compiled == null
                  ? Text(
                      '修正查找正则后这里显示预览',
                      style: TextStyle(color: scheme.outline, fontSize: 14),
                    )
                  : RichMessageText(
                      key: ValueKey(
                        'preview-${_find.text}|${_replace.text}|${_sample.text}',
                      ),
                      text: _sample.text,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        color: Colors.black,
                      ),
                      scripts: compiled,
                    ),
            ),
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
