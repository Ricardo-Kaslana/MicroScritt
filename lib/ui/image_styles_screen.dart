/// 自定义生图风格管理页与编辑屏。
///
/// 内置预设(`kImageStylePresets`)只读、不落表、不在此列出;本页只管
/// `image_styles` 表的自定义行。新建时以当前生效参数预填;导入按名称去重,
/// 与内置预设重名同样跳过。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../export/resource_exporter.dart';
import '../import/resource_importer.dart';
import '../models/image_style_preset.dart';
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

/// 自定义生图风格列表页(入口:生图配置编辑页「管理自定义风格」)。
///
/// 内置预设不在此列出、不可删改;新建时用当前配置生效的风格参数 [prefill]
/// 预填表单。风格只是参数来源,套用到配置后即成为配置自身的值,删除风格
/// 不影响已保存的配置。
class ImageStylesScreen extends ConsumerWidget {
  /// 新建风格的预填参数(生图配置当前生效的风格值)。
  final ImageStylePreset prefill;
  const ImageStylesScreen({super.key, required this.prefill});

  /// 删除自定义风格:确认后直接删行,已套用该参数的配置保持不变。
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ImageStylePreset s,
  ) async {
    final id = s.id;
    if (id == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除风格?',
      message: s.name,
    );
    if (!confirmed) return;
    await ref.read(imageStyleRepositoryProvider).delete(id);
    ref.invalidate(imageStylesProvider);
  }

  /// 导出全部自定义风格:统一资源信封,不含库内 id。
  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    final items = await ref.read(imageStyleRepositoryProvider).all();
    if (!context.mounted) return;
    await exportResourceFile(
      context,
      fileName: 'microscritt-image-styles.json',
      content: ResourceExporter.imageStyles(items),
    );
  }

  /// 导入自定义风格:与内置预设或已有自定义同名即跳过 —— 下拉按名称选取,
  /// 重名会让「快捷填充」指向歧义。
  Future<void> _importJson(BuildContext context, WidgetRef ref) async {
    await importResourceFile(
      context,
      label: '生图风格',
      importer: (bytes) =>
          ResourceImporter.importImageStyles(ref.read(databaseProvider), bytes),
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
    return ListPageScaffold<ImageStylePreset>(
      title: '自定义生图风格',
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
          MaterialPageRoute(
            builder: (_) => ImageStyleEditScreen(prefill: prefill),
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      loading: stylesAsync.isLoading && !stylesAsync.hasValue,
      error: stylesAsync.hasError && !stylesAsync.hasValue
          ? stylesAsync.error
          : null,
      onRetry: () => ref.invalidate(imageStylesProvider),
      items: stylesAsync.value,
      emptyState: const EmptyState(
        icon: Icons.palette_outlined,
        title: '暂无自定义风格',
        message: '新建风格并填写画师串、采样器等参数,之后可在「画面风格」下拉里一键套用。',
      ),
      searchHint: '搜索风格名称/画师串',
      searchText: (s) => '${s.name} ${s.artist ?? ''}',
      itemBuilder: (context, s) => GroupCard(
        children: [
          ToggleDeleteTile(
            leading: const Icon(Icons.palette_outlined),
            title: s.name,
            subtitle: _summary(s),
            onDelete: () => _delete(context, ref, s),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ImageStyleEditScreen(style: s)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 自定义风格新建/编辑屏。新建时以 [prefill] 为初值(生图配置当前生效的
/// 风格参数);编辑时以 [style] 为初值。
///
/// 保存校验:名称非空、不得与内置预设重名、不得与其它自定义风格重名;
/// scale / cfg 解析失败与留空的文本字段一律写 null —— 采样器 / 噪声调度
/// 沿用协议默认,artist 不加前缀,negative 用默认负面词。直接返回即丢弃
/// 未保存内容。
class ImageStyleEditScreen extends ConsumerStatefulWidget {
  /// 编辑对象;null 表示新建。
  final ImageStylePreset? style;

  /// 新建时的预填来源(生图配置当前生效的风格值)。
  final ImageStylePreset? prefill;
  const ImageStyleEditScreen({super.key, this.style, this.prefill});

  @override
  ConsumerState<ImageStyleEditScreen> createState() =>
      _ImageStyleEditScreenState();
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

  /// 打开编辑器时的表单快照(未保存修改的判定基准)。
  late String _initialSignature;

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
    _initialSignature = _signature();
  }

  String _signature() => [
    _name.text,
    _artist.text,
    _sampler.text,
    _noise.text,
    _scale.text,
    _cfg.text,
    _negative.text,
  ].join('\u0000');

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

  /// 统一的拒绝提示出口(名称冲突等前置校验失败)。
  void _reject(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 保存前依次校验:名称非空、不与内置预设重名、不与其它自定义重名。
  /// 任一失败只提示不写库;编辑时判重排除自身。
  Future<void> _save() async {
    if (_saving) return;
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
    return EditFormScaffold(
      title: _isNew ? '新建风格' : '编辑风格',
      saving: _saving,
      onSave: _save,
      hasChanges: () => _signature() != _initialSignature,
      changes: [_name, _artist, _sampler, _noise, _scale, _cfg, _negative],
      children: [
        GroupCard(
          children: [
            FormTextField(
              controller: _name,
              label: '名称 *',
              hint: '在「画面风格」下拉里显示,不可与内置预设重名',
            ),
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
      ],
    );
  }
}
