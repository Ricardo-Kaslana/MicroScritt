import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'common/form_field.dart';
import 'common/section_header.dart';
import '../backend/plugin_image_backend.dart';
import '../models/image_config.dart';
import '../models/image_plugin.dart';
import '../models/image_style_preset.dart';
import '../state/providers.dart';
import 'image_plugins_screen.dart';
import 'image_styles_screen.dart';

/// 生图「尺寸」的全局默认:竖图。缺省按竖图,除非用户在高级参数里显式另选。
const _kDefaultImageSize = '竖图';

/// 新建/编辑一套生图 provider 配置。2.3 起统一走插件路径:选一个已启用插件
/// (内置协议亦是仓库自带插件),填核心地址/密钥/模型 + 该插件 manifest 声明的
/// 动态字段;`usesStandardParams` 的插件额外渲染尺寸、步数与画面风格 —— 前三者
/// 与模型/每次生图数量同级平铺。画师串/采样器/噪声调度/scale/cfg/负面词统一由
/// 「画面风格」管理,此处不再单独展开,选择风格即回填这六项并随配置落库。
class ImageProviderEditScreen extends ConsumerStatefulWidget {
  final ImageProviderRecord? existing;
  const ImageProviderEditScreen({super.key, this.existing});

  @override
  ConsumerState<ImageProviderEditScreen> createState() =>
      _ImageProviderEditScreenState();
}

class _ImageProviderEditScreenState
    extends ConsumerState<ImageProviderEditScreen> {
  late final TextEditingController _displayName;
  late final TextEditingController _imgApiKey;
  late final TextEditingController _imgModel;
  late final TextEditingController _imgSteps;
  late final TextEditingController _imgBaseUrl;
  String? _imgSize;

  /// 画面风格六参数:设置页没有独立输入框,由「画面风格」下拉回填;
  /// 未匹配任何风格时保留配置里的原值,保存时原样写回。
  String? _imgArtist;
  String? _imgSampler;
  String? _imgNoise;
  int? _imgScale;
  double? _imgCfg;
  String? _imgNegative;
  int _imgCount = 1;
  bool _showImgApiKey = false;

  String? _pluginId;
  final Map<String, TextEditingController> _pluginControllers = {};
  final Map<String, dynamic> _pluginValues = {};

  List<String> _fetchedImageModels = const [];
  String? _styleName;
  bool _customStyleMatched = false;
  bool _hasSavedConfig = false;
  bool _refreshingModels = false;
  bool _testingImage = false;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final img = widget.existing?.config;
    _pluginId = img?.pluginId;
    // 新建且未指定插件:预选第一个已启用插件(须在默认名计算之前)。
    _pluginId ??= ref
        .read(imagePluginsProvider)
        .where((plugin) => plugin.enabled)
        .firstOrNull
        ?.id;
    _displayName = TextEditingController(
      text:
          widget.existing?.displayName ??
          _pluginById(ref.read(imagePluginsProvider), _pluginId)?.name ??
          '生图插件',
    );
    _imgApiKey = TextEditingController(text: img?.apiKey ?? '');
    _imgBaseUrl = TextEditingController(text: img?.baseUrl ?? '');
    _imgModel = TextEditingController(text: img?.model ?? '');
    _imgSize = img?.size ?? _kDefaultImageSize;
    _imgScale = img?.scale;
    _imgCfg = img?.cfg;
    _imgSampler = img?.sampler;
    _imgNegative = img?.negative;
    _imgArtist = img?.artist;
    _imgNoise = img?.noiseSchedule;
    _imgSteps = TextEditingController(text: img?.steps?.toString() ?? '');
    _imgCount = (img?.count ?? 1).clamp(1, 6);
    _initializePluginFields(
      _pluginById(ref.read(imagePluginsProvider), _pluginId),
      existing: img?.pluginSettings,
    );
    _hasSavedConfig = img != null;
    _styleName = img == null ? null : _matchStyleIn(kImageStylePresets);
  }

  @override
  void dispose() {
    _displayName.dispose();
    _imgApiKey.dispose();
    _imgBaseUrl.dispose();
    _imgModel.dispose();
    _imgSteps.dispose();
    for (final controller in _pluginControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _initializePluginFields(
    ImagePlugin? plugin, {
    Map<String, dynamic>? existing,
  }) {
    for (final controller in _pluginControllers.values) {
      controller.dispose();
    }
    _pluginControllers.clear();
    _pluginValues.clear();
    if (plugin == null) return;
    for (final field in plugin.fields) {
      final value = existing?.containsKey(field.key) == true
          ? existing![field.key]
          : field.defaultValue;
      if (field.type == ImagePluginFieldType.boolean) {
        _pluginValues[field.key] = value is bool
            ? value
            : field.defaultValue is bool
            ? field.defaultValue
            : false;
      } else if (field.type == ImagePluginFieldType.select) {
        _pluginValues[field.key] =
            value is String &&
                field.options.any((option) => option.value == value)
            ? value
            : null;
      } else {
        _pluginControllers[field.key] = TextEditingController(
          text: value?.toString() ?? '',
        );
      }
    }
  }

  ImagePlugin? _pluginById(List<ImagePlugin> plugins, String? id) {
    return plugins.where((plugin) => plugin.id == id).firstOrNull;
  }

  void _onPluginChanged(String? id) {
    setState(() {
      _pluginId = id;
      _fetchedImageModels = const [];
      final plugin = _pluginById(ref.read(imagePluginsProvider), id);
      _initializePluginFields(plugin);
      // 名字仍是插件默认名(用户没自定义过)则跟随更新。
      final previousName = _pluginById(
        ref.read(imagePluginsProvider),
        _pluginId,
      )?.name;
      if (plugin != null &&
          (_displayName.text.trim().isEmpty ||
              _displayName.text.trim() == previousName ||
              _displayName.text.trim() == '生图插件')) {
        _displayName.text = plugin.name;
      }
    });
  }

  Map<String, dynamic> _pluginSettingsForSave(ImagePlugin plugin) {
    final settings = <String, dynamic>{};
    for (final field in plugin.fields) {
      Object? value;
      if (field.type == ImagePluginFieldType.boolean) {
        value = _pluginValues[field.key] ?? field.defaultValue ?? false;
      } else if (field.type == ImagePluginFieldType.select) {
        value = _pluginValues[field.key];
      } else {
        final text = _pluginControllers[field.key]?.text.trim() ?? '';
        if (field.type == ImagePluginFieldType.integer) {
          value = text.isEmpty ? null : int.tryParse(text);
          if (value == null && text.isNotEmpty) {
            throw FormatException('「${field.label}」必须是整数');
          }
        } else if (field.type == ImagePluginFieldType.number) {
          value = text.isEmpty ? null : num.tryParse(text);
          if (value == null && text.isNotEmpty) {
            throw FormatException('「${field.label}」必须是数字');
          }
        } else {
          value = text;
        }
      }
      if (field.required &&
          (value == null || (value is String && value.isEmpty))) {
        throw FormatException('请填写「${field.label}」');
      }
      if (field.type == ImagePluginFieldType.url &&
          value is String &&
          value.isNotEmpty) {
        final uri = Uri.parse(value);
        if (!(uri.isScheme('http') || uri.isScheme('https')) ||
            uri.host.isEmpty) {
          throw FormatException('「${field.label}」必须是有效的 HTTP(S) 地址');
        }
      }
      settings[field.key] = value;
    }
    return settings;
  }

  /// 用当前表单值构造一份临时配置(不落库),供连接测试/模型刷新使用。
  ImageConfig _formConfig(ImagePlugin plugin) {
    return ImageConfig(
      kind: ImageBackendKind.plugin,
      baseUrl: _imageUrlOrDefault(),
      apiKey: _imgApiKey.text.trim(),
      model: _imgModel.text.trim(),
      size: _imgSize ?? _kDefaultImageSize,
      scale: _imgScale,
      cfg: _imgCfg,
      sampler: _imgSampler,
      negative: _imgNegative,
      artist: _imgArtist,
      noiseSchedule: _imgNoise,
      steps: int.tryParse(_imgSteps.text.trim()),
      count: _imgCount.clamp(1, 6),
      pluginId: plugin.id,
      pluginSettings: _pluginSettingsForSave(plugin),
    );
  }

  PluginImageBackend? _transientBackend(ImagePlugin plugin) {
    final runtime = ref.read(hookRuntimeProvider);
    if (runtime == null) return null;
    return PluginImageBackend(
      config: _formConfig(plugin),
      plugin: plugin,
      evaluator: runtime.evaluate,
    );
  }

  Widget _buildPluginField(ImagePluginField field) {
    final label = field.required ? '${field.label} *' : field.label;
    if (field.type == ImagePluginFieldType.boolean) {
      return SwitchListTile(
        key: ValueKey('plugin_field_${field.key}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        title: Text(label),
        subtitle: field.hint.isEmpty ? null : Text(field.hint),
        value:
            _pluginValues[field.key] as bool? ??
            field.defaultValue as bool? ??
            false,
        onChanged: (value) => setState(() => _pluginValues[field.key] = value),
      );
    }
    if (field.type == ImagePluginFieldType.select) {
      final current = _pluginValues[field.key];
      return FormDropdownField<String>(
        fieldKey: ValueKey('plugin_field_${field.key}'),
        value: current is String ? current : null,
        label: label,
        hint: field.hint,
        items: field.options.map((option) => option.value).toList(),
        labelOf: (value) =>
            field.options.firstWhere((option) => option.value == value).label,
        onChanged: (value) => setState(() => _pluginValues[field.key] = value),
      );
    }
    final controller = _pluginControllers.putIfAbsent(
      field.key,
      () => TextEditingController(text: field.defaultValue?.toString() ?? ''),
    );
    return FormTextField(
      innerKey: ValueKey('plugin_field_${field.key}'),
      controller: controller,
      label: label,
      hint: field.hint,
      obscureText: field.type == ImagePluginFieldType.password,
      keyboardType: switch (field.type) {
        ImagePluginFieldType.url => TextInputType.url,
        ImagePluginFieldType.integer => TextInputType.number,
        ImagePluginFieldType.number => const TextInputType.numberWithOptions(
          decimal: true,
        ),
        _ => null,
      },
    );
  }

  String? _matchStyleIn(List<ImageStylePreset> styles) {
    for (final p in styles) {
      if (p.artist == _imgArtist &&
          p.sampler == _imgSampler &&
          p.noiseSchedule == _imgNoise &&
          p.scale == _imgScale &&
          p.cfg == _imgCfg &&
          p.negative == _imgNegative) {
        return p.name;
      }
    }
    return null;
  }

  void _applyImageStyle(ImageStylePreset p) {
    setState(() {
      _styleName = p.name;
      _imgArtist = p.artist;
      _imgSampler = p.sampler;
      _imgNoise = p.noiseSchedule;
      _imgScale = p.scale;
      _imgCfg = p.cfg;
      _imgNegative = p.negative;
    });
  }

  ImageStylePreset get _stylePrefill => ImageStylePreset(
    name: '',
    artist: _imgArtist,
    sampler: _imgSampler,
    noiseSchedule: _imgNoise,
    scale: _imgScale,
    cfg: _imgCfg,
    negative: _imgNegative,
  );

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _imageUrlOrDefault() {
    final text = _imgBaseUrl.text.trim();
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }

  Future<void> _refreshImageModels() async {
    final plugin = _pluginById(ref.read(imagePluginsProvider), _pluginId);
    if (plugin == null) return _showSnack('请先选择生图插件');
    if (_imageUrlOrDefault().isEmpty) return _showSnack('请先填写服务地址');
    final PluginImageBackend backend;
    try {
      final built = _transientBackend(plugin);
      if (built == null) return _showSnack('当前平台无法运行 JS 生图插件');
      backend = built;
    } on FormatException catch (error) {
      return _showSnack(error.message);
    }
    setState(() => _refreshingModels = true);
    try {
      final models = await backend.listModels();
      if (!mounted) return;
      setState(() => _fetchedImageModels = models);
      if (models.isNotEmpty && !models.contains(_imgModel.text.trim())) {
        _imgModel.text = models.first;
      }
      _showSnack(models.isEmpty ? '连接成功,但未找到可用模型' : '已获取 ${models.length} 个模型');
    } catch (e) {
      if (mounted) _showSnack('获取模型列表失败:$e');
    } finally {
      if (mounted) setState(() => _refreshingModels = false);
    }
  }

  Future<void> _testImageConnection() async {
    final plugin = _pluginById(ref.read(imagePluginsProvider), _pluginId);
    if (plugin == null) return _showSnack('请先选择生图插件');
    if (_imageUrlOrDefault().isEmpty) return _showSnack('请先填写服务地址');
    final PluginImageBackend backend;
    try {
      final built = _transientBackend(plugin);
      if (built == null) return _showSnack('当前平台无法运行 JS 生图插件');
      backend = built;
    } on FormatException catch (error) {
      return _showSnack(error.message);
    }
    setState(() => _testingImage = true);
    try {
      final probe = await backend.probe();
      if (!mounted) return;
      if (probe == null) {
        _showSnack('该插件未提供连接测试');
      } else {
        final extra = probe.defaultModel == null
            ? ''
            : ',默认模型 ${probe.defaultModel}';
        _showSnack('${probe.summary}$extra');
      }
    } catch (e) {
      if (mounted) _showSnack('连接失败:$e');
    } finally {
      if (mounted) setState(() => _testingImage = false);
    }
  }

  Future<void> _save() async {
    final name = _displayName.text.trim();
    if (name.isEmpty) return _showSnack('请填写配置名称');
    final plugin = _pluginById(ref.read(imagePluginsProvider), _pluginId);
    if (plugin == null) return _showSnack('请先选择已导入的生图插件');
    if (_imageUrlOrDefault().isEmpty) return _showSnack('请填写服务地址');
    final Map<String, dynamic> settings;
    try {
      settings = _pluginSettingsForSave(plugin);
    } on FormatException catch (error) {
      return _showSnack(error.message);
    }
    final config = ImageConfig(
      kind: ImageBackendKind.plugin,
      baseUrl: _imageUrlOrDefault(),
      apiKey: _imgApiKey.text.trim(),
      model: _imgModel.text.trim(),
      size: _imgSize ?? _kDefaultImageSize,
      scale: _imgScale,
      cfg: _imgCfg,
      sampler: _imgSampler,
      negative: _imgNegative,
      artist: _imgArtist,
      noiseSchedule: _imgNoise,
      steps: int.tryParse(_imgSteps.text.trim()),
      count: _imgCount.clamp(1, 6),
      pluginId: plugin.id,
      pluginSettings: settings,
    );
    final repo = ref.read(imageConfigRepositoryProvider);
    await repo.saveProvider(
      ImageProviderRecord(
        id: widget.existing?.id ?? 0,
        displayName: name,
        isActive: widget.existing?.isActive ?? false,
        position: widget.existing?.position ?? 0,
        config: config,
      ),
    );
    ref.read(imageConfigProvider.notifier).state = await repo
        .loadActiveConfig();
    ref.invalidate(imageProvidersProvider);
    if (!mounted) return;
    _showSnack('生图配置已保存');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final imagePlugins = ref.watch(imagePluginsProvider);
    final selected = _pluginById(imagePlugins, _pluginId);
    final customStyles =
        ref.watch(imageStylesProvider).value ?? const <ImageStylePreset>[];
    final allStyles = <ImageStylePreset>[
      ...customStyles,
      ...kImageStylePresets,
    ];
    if (selected?.usesStandardParams == true &&
        !_customStyleMatched &&
        customStyles.isNotEmpty) {
      _customStyleMatched = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _styleName != null || !_hasSavedConfig) return;
        final matched = _matchStyleIn(customStyles);
        if (matched != null) setState(() => _styleName = matched);
      });
    }
    final pluginIds = <String>{
      for (final plugin in imagePlugins.where((plugin) => plugin.enabled))
        plugin.id,
      if (_pluginId != null) _pluginId!,
    }.toList();

    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? '新建生图配置' : '编辑生图配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionHeader('配置', icon: Icons.image_outlined),
          GroupCard(
            children: [
              FormTextField(
                controller: _displayName,
                label: '配置名称',
                hint: '如 我的生图网关 / Nai2API',
                onChanged: (_) => setState(() {}),
              ),
              FormDropdownField<String>(
                fieldKey: ValueKey('image_plugin_${_pluginId ?? 'none'}'),
                value: _pluginId,
                label: '生图插件',
                hint: imagePlugins.isEmpty ? '请先导入生图插件' : '选择生图插件',
                items: pluginIds,
                labelOf: (id) {
                  final plugin = _pluginById(imagePlugins, id);
                  if (plugin == null) return '缺失插件 ($id)';
                  return plugin.enabled ? plugin.name : '${plugin.name} (已停用)';
                },
                onChanged: _onPluginChanged,
              ),
              if (imagePlugins.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  child: TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ImagePluginsScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.extension_outlined),
                    label: const Text('管理生图插件'),
                  ),
                ),
              FormTextField(
                controller: _imgApiKey,
                label: 'API Key / Token',
                hint: '粘贴该服务的密钥',
                obscureText: !_showImgApiKey,
                onChanged: (_) => setState(() {}),
                suffixIcon: IconButton(
                  tooltip: _showImgApiKey ? '隐藏' : '显示',
                  icon: Icon(
                    _showImgApiKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _showImgApiKey = !_showImgApiKey),
                ),
              ),
              FormTextField(
                controller: _imgBaseUrl,
                label: '服务地址 (base URL)',
                hint: '如 https://your-service.example.com/v1',
                onChanged: (_) => setState(() {}),
              ),
              if (selected != null &&
                  (selected.supportsListModels || selected.supportsTest))
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
                  child: Row(
                    children: [
                      if (selected.supportsListModels) ...[
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _testingImage
                                ? null
                                : _refreshImageModels,
                            icon: _refreshingModels
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh, size: 18),
                            label: const Text('刷新模型列表'),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (selected.supportsTest)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _refreshingModels
                                ? null
                                : _testImageConnection,
                            icon: _testingImage
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.cable, size: 18),
                            label: const Text('测试连接'),
                          ),
                        ),
                    ],
                  ),
                ),
              FormTextField(
                innerKey: const ValueKey('image_model_field'),
                controller: _imgModel,
                label: '模型',
                hint: '输入模型 id;支持列表的插件可点「刷新模型列表」拉取候选',
                onChanged: (_) => setState(() {}),
              ),
              if (_fetchedImageModels.isNotEmpty)
                FormDropdownField<String>(
                  fieldKey: const ValueKey('image_model_picker'),
                  value: null,
                  label: '从已获取的模型中选择',
                  items: _fetchedImageModels,
                  labelOf: (m) => m,
                  onChanged: (v) => setState(() => _imgModel.text = v ?? ''),
                ),
              if (selected != null)
                for (final field in selected.fields) _buildPluginField(field),
              // 尺寸 / 步数与模型、每次生图数量同级平铺,不再收进折叠区。
              if (selected?.usesStandardParams == true) ...[
                FormDropdownField<String?>(
                  value: _imgSize,
                  label: '尺寸',
                  hint: '留空用服务端默认',
                  items: const [null, '竖图', '横图', '方图'],
                  labelOf: (v) => v ?? '(服务端默认)',
                  onChanged: (v) => setState(() => _imgSize = v),
                ),
                FormTextField(
                  controller: _imgSteps,
                  label: '步数 (steps)',
                  hint: '留空用服务端默认',
                  keyboardType: TextInputType.number,
                ),
              ],
              FormDropdownField<int>(
                fieldKey: ValueKey('image_count_$_imgCount'),
                value: _imgCount,
                label: '每次生图数量',
                helperText: '一次请求生成 1-6 张,逐张进入聊天流',
                items: const [1, 2, 3, 4, 5, 6],
                labelOf: (n) => '$n 张',
                onChanged: (v) => setState(() => _imgCount = v ?? 1),
              ),
              if (selected?.usesStandardParams == true) ...[
                FormDropdownField<String>(
                  fieldKey: ValueKey('image_style_${_styleName ?? '自定义'}'),
                  value: _styleName,
                  label: '画面风格',
                  hint: '选择预设或自定义风格,风格参数在管理入口维护',
                  items: [for (final p in allStyles) p.name],
                  labelOf: (s) => s,
                  onChanged: (v) {
                    final preset = allStyles
                        .where((p) => p.name == v)
                        .firstOrNull;
                    if (preset != null) _applyImageStyle(preset);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ImageStylesScreen(prefill: _stylePrefill),
                        ),
                      ),
                      icon: const Icon(Icons.palette_outlined, size: 18),
                      label: const Text('管理自定义风格'),
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _save,
                    child: const Text('保存生图配置'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
