import 'package:flutter/material.dart';
import '../models/llm_provider.dart';
import '../models/llm_units.dart';
import 'common/form_field.dart';

/// 编辑/新建一个模型目录条目(模型 id / 展示名 / 上下文容量 / 最大输出 / 采样温度)。
///
/// 直接在当前页表单内编辑,不单独弹页 —— 作为 [ProviderEditScreen] 里的
/// `showModalBottomSheet` 承载的独立表单。上下文容量与最大输出支持简写,
/// 如 `128k`、`1m`(见 [parseTokenShorthand])。temperature 为 0–2 之间的浮点
/// (v56 起),留空 = 走主写默认 0.7。
class ModelEditSheet extends StatefulWidget {
  final LlmModelEntry? existing;
  const ModelEditSheet({super.key, this.existing});

  @override
  State<ModelEditSheet> createState() => _ModelEditSheetState();
}

class _ModelEditSheetState extends State<ModelEditSheet> {
  late final TextEditingController _modelId;
  late final TextEditingController _displayName;
  late final TextEditingController _context;
  late final TextEditingController _maxOutput;
  late final TextEditingController _temperature;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final mo = e?.maxOutput;
    final t = e?.temperature;
    _modelId = TextEditingController(text: e?.modelId ?? '');
    _displayName = TextEditingController(text: e?.displayName ?? '');
    _context = TextEditingController(text: e != null ? _displayValue(e.contextCapacity) : '');
    _maxOutput = TextEditingController(text: mo != null ? _displayValue(mo) : '');
    // 尾零去净(0.70 → 0.7,1.00 → 1),避免用户看到多余的 0。
    _temperature = TextEditingController(text: t == null ? '' : _displayTemp(t));
  }

  static String _displayTemp(double v) {
    final s = v.toStringAsFixed(2);
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }

  @override
  void dispose() {
    _modelId.dispose();
    _displayName.dispose();
    _context.dispose();
    _maxOutput.dispose();
    _temperature.dispose();
    super.dispose();
  }

  /// 回填时把完整数值显示为带后缀的简写(128000→128K,1000000→1M)。
  static String _displayValue(int v) => v >= 1000000
      ? '${v ~/ 1000000}M'
      : v >= 1000
      ? formatTokenCount(v)
      : '$v';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null ? '添加模型' : '编辑模型',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            FormTextField(
              controller: _modelId,
              label: '模型 ID(发送给 API 的标识)',
              lines: 1,
            ),
            const SizedBox(height: 12),
            FormTextField(
              controller: _displayName,
              label: '展示名称',
              lines: 1,
            ),
            const SizedBox(height: 12),
            FormTextField(
              controller: _context,
              label: '上下文容量 (tokens)',
              hint: '例如 128k、1m、128000',
              keyboardType: TextInputType.text,
              lines: 1,
            ),
            const SizedBox(height: 12),
            FormTextField(
              controller: _maxOutput,
              label: '最大输出 tokens(留空用后端默认)',
              hint: '例如 256k、16k、4096',
              keyboardType: TextInputType.text,
              lines: 1,
            ),
            const SizedBox(height: 12),
            FormTextField(
              controller: _temperature,
              label: 'Temperature(留空 = 0.7 默认)',
              hint: '0.0 – 2.0,越低越确定、越高越发散',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              lines: 1,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final modelId = _modelId.text.trim();
                final displayName = _displayName.text.trim();
                final contextCap = parseTokenShorthand(_context.text) ?? 0;
                if (modelId.isEmpty || displayName.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写模型 ID 与展示名称')));
                  return;
                }
                if (contextCap <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写有效的上下文容量(如 128k、1m)')));
                  return;
                }
                final maxOut = parseTokenShorthand(_maxOutput.text);
                final tempRaw = _temperature.text.trim();
                double? temp;
                if (tempRaw.isNotEmpty) {
                  final parsed = double.tryParse(tempRaw);
                  if (parsed == null || parsed < 0 || parsed > 2) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Temperature 需为 0.0 – 2.0 之间的数字')));
                    return;
                  }
                  temp = parsed;
                }
                final base = widget.existing;
                final entry = LlmModelEntry(
                  id: base?.id ?? 0,
                  providerId: base?.providerId ?? 0,
                  modelId: modelId,
                  displayName: displayName,
                  contextCapacity: contextCap,
                  maxOutput: maxOut,
                  temperature: temp,
                  isActive: base?.isActive ?? false,
                  position: base?.position ?? 0,
                );
                Navigator.pop(context, entry);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }
}
