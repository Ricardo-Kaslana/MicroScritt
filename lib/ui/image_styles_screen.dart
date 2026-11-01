import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../export/resource_exporter.dart';
import '../import/resource_importer.dart';
import '../models/image_style_preset.dart';
import '../state/providers.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/resource_io.dart';
import 'common/searchable_list.dart';
import 'common/section_header.dart';

/// 自定义生图风格管理:新建/编辑/删除。内置预设(kImageStylePresets)不在此
/// 列出、不可删改;新建时用当前配置生效的风格参数 [prefill] 预填表单。
class ImageStylesScreen extends ConsumerWidget {
  final ImageStylePreset prefill;
  const ImageStylesScreen({super.key, required this.prefill});

  Future<void> _delete(BuildContext context, WidgetRef ref, ImageStylePreset s) async {
    final id = s.id;
    if (id == null) return;
    final confirmed = await showConfirmDialog(context, title: '删除风格?', message: s.name);
    if (!confirmed) return;
    await ref.read(imageStyleRepositoryProvider).delete(id);
    ref.invalidate(imageStylesProvider);
  }

  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(imageStyleRepositoryProvider).all();
    if (!context.mounted) return;
    await exportResourceFile(
      context,
      fileName: 'microscritt-image-styles.json',
      content: ResourceExporter.imageStyles(items),
    );
  }

  Future<void> _importJson(BuildContext context, WidgetRef ref) async {
    await importResourceFile(
      context,
      label: '生图风格',
      importer: (bytes) => ResourceImporter.importImageStyles(ref.read(databaseProvider), bytes),
      onImported: () => ref.invalidate(imageStylesProvider),
    );
  }

  /// 列表副标题:采样器/噪声调度/scale/cfg 摘要,画师串太长只显示有无。
  static String _summary(ImageStylePreset s) {
    final parts = <String>[
      if (s.sampler != null) s.sampler!,
      if (s.noiseSchedule != null) s.noiseSchedule!,
      if (s.scale != null) 'scale ${s.scale}',
      if (s.cfg != null) 'cfg ${formatCfg(s.cfg)}',
      if (s.artist != null && s.artist!.isNotEmpty) '含画师串',
      if (s.negative != null && s.negative!.isNotEmpty) '含负面词',
    ];
    return parts.isEmpty ? '(空参数)' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stylesAsync = ref.watch(imageStylesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('自定义生图风格'),
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
          MaterialPageRoute(builder: (_) => ImageStyleEditScreen(prefill: prefill)),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: stylesAsync.when(
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.palette_outlined,
                title: '暂无自定义风格',
                message: '新建风格并填写画师串、采样器等参数,之后可在「画面风格」下拉里一键套用。',
              )
            : SearchableList<ImageStylePreset>(
                items: list,
                searchHint: '搜索风格名称/画师串',
                searchText: (s) => '${s.name} ${s.artist ?? ''}',
                itemBuilder: (context, s) => GroupCard(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_summary(s), maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(context, ref, s),
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ImageStyleEditScreen(style: s)),
                      ),
                    ),
                  ],
                ),
              ),
        error: (e, _) => EmptyState(icon: Icons.error_outline, title: '加载失败', message: '$e'),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

/// 自定义风格新建/编辑屏。新建时以 [prefill] 为初值(设置页当前生效的风格
/// 参数);编辑时以 [style] 为初值。
class ImageStyleEditScreen extends ConsumerStatefulWidget {
  final ImageStylePreset? style;
  final ImageStylePreset? prefill;
  const ImageStyleEditScreen({super.key, this.style, this.prefill});

  @override
  ConsumerState<ImageStyleEditScreen> createState() => _ImageStyleEditScreenState();
}

class _ImageStyleEditScreenState extends ConsumerState<ImageStyleEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _artist;
  late final TextEditingController _sampler;
  late final TextEditingController _noise;
  late final TextEditingController _scale;
  late final TextEditingController _cfg;
  late final TextEditingController _negative;
  bool _saving = false;

  bool get _isNew => widget.style == null;

  @override
  void initState() {
    super.initState();
    final src = widget.style ?? widget.prefill;
    _name = TextEditingController(text: src?.name ?? '');
    _artist = TextEditingController(text: src?.artist ?? '');
    _sampler = TextEditingController(text: src?.sampler ?? '');
    _noise = TextEditingController(text: src?.noiseSchedule ?? '');
    _scale = TextEditingController(text: src?.scale?.toString() ?? '');
    _cfg = TextEditingController(text: formatCfg(src?.cfg));
    _negative = TextEditingController(text: src?.negative ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _artist.dispose();
    _sampler.dispose();
    _noise.dispose();
    _scale.dispose();
    _cfg.dispose();
    _negative.dispose();
    super.dispose();
  }

  void _reject(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _reject('名称不能为空');
      return;
    }
    // 库层 UNIQUE(name) 只管自定义风格互不重名;与内置预设的重名必须 UI 拦。
    if (kImageStylePresets.any((p) => p.name == name)) {
      _reject('名称与内置预设「$name」冲突');
      return;
    }
    setState(() => _saving = true);
    try {
      final others = await ref.read(imageStylesProvider.future);
      if (others.any((s) => s.name == name && s.id != widget.style?.id)) {
        if (mounted) _reject('已存在同名自定义风格「$name」');
        return;
      }
      final style = ImageStylePreset(
        id: widget.style?.id,
        name: name,
        artist: _nullIfBlank(_artist.text.trim()),
        sampler: _nullIfBlank(_sampler.text.trim()),
        noiseSchedule: _nullIfBlank(_noise.text.trim()),
        scale: int.tryParse(_scale.text.trim()),
        cfg: double.tryParse(_cfg.text.trim()),
        negative: _nullIfBlank(_negative.text.trim()),
      );
      final repo = ref.read(imageStyleRepositoryProvider);
      if (_isNew) {
        await repo.insert(style);
      } else {
        await repo.update(style);
      }
      ref.invalidate(imageStylesProvider);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String? _nullIfBlank(String s) => s.isEmpty ? null : s;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建风格' : '编辑风格'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GroupCard(
            children: [
              FormTextField(controller: _name, label: '名称 *', hint: '在「画面风格」下拉里显示,不可与内置预设重名'),
              FormTextField(
                controller: _artist,
                label: '画师串 (artist)',
                lines: 4,
                hint: '质量/画师前缀,留空不覆盖',
              ),
              FormTextField(
                controller: _sampler,
                label: '采样器 (sampler)',
                hint: '如 k_dpmpp_2m_sde / k_euler_ancestral',
              ),
              FormTextField(
                controller: _noise,
                label: '噪声调度 (noise_schedule)',
                hint: 'native / karras / exponential',
              ),
              FormTextField(
                controller: _scale,
                label: '提示词引导值 (scale)',
                keyboardType: TextInputType.number,
                hint: '5–7',
              ),
              FormTextField(
                controller: _cfg,
                label: '缩放引导值 (cfg)',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                hint: '0–2,可填小数,如 0.5',
              ),
              FormTextField(
                controller: _negative,
                label: '负面提示词 (negative)',
                lines: 2,
                hint: '留空用服务端内置默认',
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
        ],
      ),
    );
  }
}
