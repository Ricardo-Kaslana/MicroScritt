/// LLM provider 编辑屏:身份、地址、协议、密钥、模型目录与自定义请求头。
///
/// 端点兼容选项与「官方 OpenAI 参数风格」只对 OpenAI 兼容协议显示;保存后
/// 同步文本配置文件,若编辑的是当前 provider 还会重解析运行时配置。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/backend_config.dart';
import '../backend/llm_probe.dart';
import '../data/llm_provider_repository.dart';
import '../models/endpoint_compat.dart';
import '../models/llm_provider.dart';
import '../state/app_config_sync.dart';
import '../state/providers.dart';
import 'model_edit_sheet.dart';
import 'common/form_field.dart';
import 'common/info_button.dart';
import 'common/section_header.dart';

/// 新建/编辑一个 LLM provider(Provider ID / 显示名 / API 地址 / 协议 / 密钥 +
/// 模型目录),从设置页「LLM 后端」的添加或编辑动作进入。
///
/// - [existing] 为空表示新建自定义 provider;否则编辑已有 provider
///   (内置与自定义都可编辑)。
/// - 保存时把整份 provider(含模型目录)经 [LlmProviderRepository] 持久化。
///   当前在用 provider/模型的选择在对话输入框的模型选择器里,不在这里设置。
/// - 协议切到 Anthropic 时隐藏兼容选项与官方参数风格;这些开关本来也只被
///   OpenAI 兼容后端消费。
///
/// 端点兼容选项是通用请求整形,按端点怪癖声明式开启、默认全关:
/// `replyViaTool` 让回复经工具参数输出(正文流会被截断的端点),`noncePrefix`
/// 在 system 头部加随机前缀使每轮请求字节不同;普通端点请保持全关 ——
/// `replyViaTool` 会让部分端点因未知 `tools` 字段回 400。
class ProviderEditScreen extends ConsumerStatefulWidget {
  final LlmProviderConfig? existing;
  const ProviderEditScreen({super.key, this.existing});

  @override
  ConsumerState<ProviderEditScreen> createState() => _ProviderEditScreenState();
}

class _ProviderEditScreenState extends ConsumerState<ProviderEditScreen> {
  late final TextEditingController _providerId;
  late final TextEditingController _displayName;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late LlmProtocol _protocol;
  late List<LlmModelEntry> _models;
  late final List<_HeaderRow> _headerRows;

  /// 官方 OpenAI 参数风格:max_completion_tokens + stream_options 用量。
  late bool _modernParams;

  /// 端点兼容选项:replyViaTool / noncePrefix 两个开关。
  late EndpointCompat _compat;

  /// 「测试连接」探测中/结果/异常三态。
  bool _probing = false;
  LlmProbeReport? _probeReport;
  String? _probeError;

  bool get _isNew => widget.existing == null;

  /// API Key 眼睛切换(与设置页生图区同一套显示/隐藏)。
  bool _showApiKey = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _providerId = TextEditingController(text: e?.providerId ?? '');
    _modernParams = e?.modernParams ?? false;
    _compat = e?.compat ?? EndpointCompat.standard;
    _displayName = TextEditingController(text: e?.displayName ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _protocol = e?.protocol ?? LlmProtocol.openaiCompat;
    _models = [...?e?.models];
    _headerRows = [
      for (final entry in (e?.extraHeaders ?? const <String, String>{}).entries)
        _HeaderRow(name: entry.key, value: entry.value),
    ];
  }

  @override
  void dispose() {
    _providerId.dispose();
    _displayName.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    for (final row in _headerRows) {
      row.dispose();
    }
    super.dispose();
  }

  /// 保存 provider:必填 Provider ID/显示名/API 地址与至少一个模型;是否在用
  /// 沿用原状态(由聊天页模型选择器决定)。写库后刷新列表、回写文本配置并
  /// 关闭页面。
  Future<void> _save() async {
    final providerId = _providerId.text.trim();
    final displayName = _displayName.text.trim();
    final baseUrl = _baseUrl.text.trim();
    if (providerId.isEmpty || displayName.isEmpty || baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写 Provider ID、显示名称与 API 地址')));
      return;
    }
    if (_models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请至少添加一个模型')));
      return;
    }

    final repo = ref.read(llmProviderRepositoryProvider);
    final config = LlmProviderConfig(
      id: widget.existing?.id ?? 0,
      providerId: providerId,
      displayName: displayName,
      baseUrl: baseUrl,
      protocol: _protocol,
      apiKey: _apiKey.text.trim(),
      // 是否在用由对话输入框的模型选择器决定,这里只保留已有状态。
      isActive: widget.existing?.isActive ?? false,
      position: widget.existing?.position ?? 0,
      models: _models,
      extraHeaders: _collectHeaders(),
      modernParams: _modernParams,
      compat: _compat,
    );

    await repo.saveProvider(config);

    // 若编辑的是当前在用的 provider,编辑后重解析运行时配置(如换了密钥/地址)。
    if (config.isActive) {
      final backend = await repo.loadBackendConfig();
      if (backend != null) {
        ref.read(backendConfigProvider.notifier).state = backend;
      }
    }

    ref.invalidate(llmProvidersProvider);
    await syncAppConfigFile(ref);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('LLM 配置已保存')));
    Navigator.pop(context);
  }

  Future<void> _addModel() async {
    final result = await showModalBottomSheet<LlmModelEntry>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ModelEditSheet(),
    );
    if (result == null || !mounted) return;
    setState(() {
      // 是否设为当前模型由对话输入框的模型选择器决定,新增项一律不自动启用。
      _models = [..._models, result.copyWith(isActive: false)];
    });
  }

  Future<void> _editModel(LlmModelEntry entry) async {
    final result = await showModalBottomSheet<LlmModelEntry>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ModelEditSheet(existing: entry),
    );
    if (result == null || !mounted) return;
    setState(() {
      _models = [
        for (final m in _models)
          m.id == result.id || (m == entry && m.modelId == entry.modelId)
              ? result.copyWith(id: m.id, position: m.position)
              : m,
      ];
    });
  }

  void _removeModel(LlmModelEntry entry) {
    setState(() {
      _models = _models.where((m) => !(m.id == entry.id)).toList();
    });
  }

  void _addHeader() {
    setState(() {
      _headerRows.add(_HeaderRow());
    });
  }

  void _removeHeader(int index) {
    setState(() {
      _headerRows.removeAt(index).dispose();
    });
  }

  /// 收集编辑中的自定义请求头:跳过未填名称的行,键归一化小写(与 dart:io
  /// 发送行为及落库格式一致),值仅 trim。同名的后一行覆盖前一行 —— 与用户
  /// 「改了值想覆盖」的直觉一致。host / content-length 由 HTTP 栈托管,用户
  /// 误填只会破坏请求,直接丢弃。
  Map<String, String> _collectHeaders() {
    final collected = LlmProviderConfig.normalizeExtraHeaders({
      for (final row in _headerRows) row.name.text: row.value.text,
    });
    return Map.from(collected)..removeWhere((k, _) => _kManagedHeaderNames.contains(k));
  }

  /// 「官方 OpenAI 参数风格」的详细说明弹层(表单行只留一行短文案,细节
  /// 经标题旁的信息按钮进入这里)。
  void _showModernParamsHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('官方 OpenAI 参数风格 · 说明'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• 开启后改发 max_completion_tokens(o 系列推理模型必需),并请求流式 usage(否则用量统计为 0)'),
            SizedBox(height: 6),
            Text('• 适用:直连 api.openai.com 或严格兼容官方协议的网关'),
            SizedBox(height: 10),
            Text('部分宽松网关不认识这些字段会报错,默认关闭。'),
          ],
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 「自定义请求头」的详细说明弹层。
  void _showCustomHeaderHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义请求头 · 说明'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• 部分网关校验 Origin / Referer / User-Agent 或特定客户端标识请求头,不匹配会被拒绝'),
            SizedBox(height: 6),
            Text('• 此处配置的头随每次对话请求一并发送;与内置头同名的覆盖内置值'),
            SizedBox(height: 10),
            Text('host / content-length 由 HTTP 栈托管,配置了也会被忽略。'),
          ],
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 「端点兼容选项」的详细说明弹层(全部为通用请求整形选项,按端点怪癖
  /// 声明式开启,不针对任何特定服务)。
  void _showCompatHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('端点兼容选项 · 说明'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('【工具通道回复】', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('• 适用:对普通正文流式截断/丢块,但工具调用参数能完整送达的端点'),
              SizedBox(height: 4),
              Text('• 整条回复改经 output_reply 工具参数输出;空回自动重试(至多 3 次尝试)'),
              SizedBox(height: 10),
              Text('【提示词随机前缀】', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('• 每次请求在 system 头部前置 6–8 位随机字符,使每轮请求字节不同'),
              SizedBox(height: 4),
              Text('• 只在端点明确需要时开启;请确认符合所配置服务的条款'),
              SizedBox(height: 10),
              Text('• 各端点要求的请求头仍需在「自定义请求头」中配置;普通端点请保持全部关闭 —— 部分端点对未知的 tools 字段回 400。'),
            ],
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 「测试连接」:使用**当前表单值**(未保存的修改也参与探测,便于保存前
  /// 验证)。
  Future<void> _runProbe() async {
    final config = BackendConfig(
      provider: _protocol == LlmProtocol.anthropic ? BackendProvider.anthropic : BackendProvider.openai,
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _models.first.modelId,
      extraHeaders: _collectHeaders(),
      modernParams: _modernParams,
      compat: _compat,
    );
    setState(() {
      _probing = true;
      _probeReport = null;
      _probeError = null;
    });
    try {
      final report = await LlmProbe(config: config).run();
      if (!mounted) return;
      setState(() {
        _probeReport = report;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _probeError = '探测失败:$e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? '新建 Provider' : '编辑 Provider')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FormTextField(controller: _providerId, label: 'Provider ID', hint: '逻辑标识,如 openai / anthropic / my-proxy'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FormTextField(controller: _displayName, label: '显示名称'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FormTextField(controller: _baseUrl, label: 'API 地址', hint: '如 https://api.openai.com/v1'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FormDropdownField<LlmProtocol>(
                  value: _protocol,
                  label: '协议',
                  hint: '选择 API 协议',
                  items: const [LlmProtocol.openaiCompat, LlmProtocol.anthropic],
                  labelOf: (p) => switch (p) {
                    LlmProtocol.openaiCompat => 'OpenAI 兼容',
                    LlmProtocol.anthropic => 'Anthropic',
                  },
                  onChanged: (v) => setState(() => _protocol = v ?? LlmProtocol.openaiCompat),
                ),
              ),
              if (_protocol == LlmProtocol.openaiCompat)
                Padding(
                  // 与各表单字段同一套节奏:FieldLabel 灰色小标题 + 行尾开关 +
                  // 12px 灰 hint,字段细节收进标题旁的 info 按钮弹层。
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const FieldLabel('官方 OpenAI 参数风格'),
                          const SizedBox(width: 2),
                          InfoButton(onTap: () => _showModernParamsHelp(context)),
                          const Spacer(),
                          Switch(value: _modernParams, onChanged: (v) => setState(() => _modernParams = v)),
                        ],
                      ),
                      Text(
                        '直连官方 OpenAI 或严格兼容网关时开启,默认关闭。',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              if (_protocol == LlmProtocol.openaiCompat)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const FieldLabel('端点兼容选项'),
                          const SizedBox(width: 2),
                          InfoButton(onTap: () => _showCompatHelp(context)),
                          const Spacer(),
                        ],
                      ),
                      Row(
                        children: [
                          const Expanded(child: Text('工具通道回复(正文被截断时)')),
                          Switch(
                            value: _compat.replyViaTool,
                            onChanged: (v) => setState(() => _compat = _compat.copyWith(replyViaTool: v)),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const Expanded(child: Text('提示词随机前缀')),
                          Switch(
                            value: _compat.noncePrefix,
                            onChanged: (v) => setState(() => _compat = _compat.copyWith(noncePrefix: v)),
                          ),
                        ],
                      ),
                      Text(
                        '按端点怪癖开启,默认全关;说明见右上问号。',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: FormTextField(
                  controller: _apiKey,
                  label: 'API Key',
                  hint: '粘贴你的 API Key',
                  obscureText: !_showApiKey,
                  onChanged: (_) => setState(() {}),
                  suffixIcon: IconButton(
                    tooltip: _showApiKey ? '隐藏' : '显示',
                    icon: Icon(_showApiKey ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showApiKey = !_showApiKey),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('自定义请求头', style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(width: 2),
              InfoButton(onTap: () => _showCustomHeaderHelp(context)),
              const Spacer(),
              TextButton.icon(onPressed: _addHeader, icon: const Icon(Icons.add), label: const Text('添加')),
            ],
          ),
          Text(
            '部分网关按请求头放行;同名的会覆盖内置头。',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
          if (_headerRows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('无自定义请求头;站点要求时再添加即可。', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            )
          else
            GroupCard(
              children: [
                for (var i = 0; i < _headerRows.length; i++)
                  _HeaderTile(
                    key: ValueKey('header_row_$i'),
                    row: _headerRows[i],
                    onDelete: () => _removeHeader(i),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('模型目录', style: Theme.of(context).textTheme.bodyLarge),
              const Spacer(),
              TextButton.icon(onPressed: _addModel, icon: const Icon(Icons.add), label: const Text('添加模型')),
            ],
          ),
          if (_models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('还没有模型,点击"添加模型"加入第一个。', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            )
          else
            GroupCard(
              children: [
                for (final m in _models)
                  _ModelTile(entry: m, onEdit: () => _editModel(m), onDelete: () => _removeModel(m)),
              ],
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('测试连接', style: Theme.of(context).textTheme.bodyLarge),
              const Spacer(),
              TextButton.icon(
                // 探测用当前表单值;模型目录为空无从选模型。
                onPressed: (_models.isEmpty || _probing) ? null : _runProbe,
                icon: _probing
                    ? const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check),
                label: Text(_probing ? '探测中…' : '开始探测'),
              ),
            ],
          ),
          Text(
            '发一次最小请求验证端点,精确归因「为什么不通」。',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
          ),
          if (_probeError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_probeError!, style: const TextStyle(color: Colors.red)),
            )
          else if (_probeReport != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                _probeReport!.summary,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final LlmModelEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _ModelTile({required this.entry, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.smart_toy_outlined),
      title: Text(entry.displayName),
      // 只显示模型名称;模型 id / 上下文 / 最大输出进了编辑弹层。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(icon: const Icon(Icons.edit_outlined), tooltip: '编辑', onPressed: onEdit),
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: '删除', onPressed: onDelete),
        ],
      ),
      onTap: onEdit,
    );
  }
}

/// 一行自定义请求头的编辑态:名称/值两个输入控制器,离开页面时随 state 释放。
class _HeaderRow {
  final TextEditingController name;
  final TextEditingController value;

  _HeaderRow({String name = '', String value = ''})
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

/// HTTP 栈托管、不允许用户配置的头:配置了也会被连接层接管/拒绝,直接过滤。
const _kManagedHeaderNames = {'host', 'content-length'};

/// 自定义请求头的单行编辑块:名称与值上下两行、各占整行宽 —— 请求头的值常
/// 是完整 URL / User-Agent 级别的长串,并排布局在窄屏上每格只剩几字符宽,
/// 光标无处落、编辑困难;纵向堆叠后两格都有完整宽度可输入可检视。行尾删除
/// 按钮悬于首行右缘。
class _HeaderTile extends StatelessWidget {
  final _HeaderRow row;
  final VoidCallback onDelete;
  const _HeaderTile({super.key, required this.row, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormTextField(controller: row.name, label: '名称', hint: '如 Origin'),
                const SizedBox(height: 2),
                FormTextField(controller: row.value, label: '值', hint: '如 https://example.com'),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
