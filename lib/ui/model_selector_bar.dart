/// 模型选择条:当前模型 chip、上下文使用率圆环与推理等级入口。
///
/// 聊天页把 chip + 圆环内嵌在输入框右下角;独立条布局目前仅测试使用。
/// 用量口径优先服务端上报的真实 token,字符估算(÷3.2)只作兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_settings.dart';
import '../models/llm_provider.dart';
import '../models/llm_units.dart';
import '../state/app_config_sync.dart';
import '../state/providers.dart';

/// 输入区上方的"模型选择条":左侧是当前模型 chip(点击弹出模型选择器 +
/// 推理等级),右侧是当前上下文使用率的圆环(点击/悬停显示具体数值)。
/// 聊天页已把 chip + 圆环内嵌进输入框右下角;独立条当前仅测试引用,
/// 聊天页布局以内嵌分支为准。
class ModelSelectorBar extends ConsumerWidget {
  /// 上下文 token 口径(估算值 + 可选真实锚点)。
  final ContextLink usage;
  const ModelSelectorBar({super.key, required this.usage});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final reasoning = ref.watch(appSettingsProvider).reasoningLevel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          const ModelSelectorChip(),
          const SizedBox(width: 8),
          ContextUsageRing(usage: usage),
          const Spacer(),
          if (reasoning != ReasoningLevel.off)
            Text(
              '推理 ${reasoning.label}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.tertiary),
            ),
        ],
      ),
    );
  }
}

/// 当前模型选择 chip:点击弹出模型选择器 + 推理等级设置。聊天页内嵌在
/// 输入框右下角时与独立条共用,保证交互与外观一致。
class ModelSelectorChip extends ConsumerWidget {
  const ModelSelectorChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final providersAsync = ref.watch(llmProvidersProvider);
    final reasoning = ref.watch(appSettingsProvider).reasoningLevel;
    final providers = providersAsync.maybeWhen(
      data: (p) => p,
      orElse: () => const <LlmProviderConfig>[],
    );
    final activeProvider = providers.where((p) => p.isActive).firstOrNull;
    final activeModel = activeProvider?.activeModel;
    return InkWell(
      key: const ValueKey('model_selector'),
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openPicker(context, ref, providers, reasoning),
      child: Container(
        // 紧凑内边距、去掉尾部下拉箭头:窄屏上 chip 被压到很窄时也不会因
        // 固定宽度图标溢出,文本横向省略。
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined, size: 15, color: scheme.primary),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                activeModel?.displayName ?? '未选择模型',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出模型选择器;选中后落库 active 标记、重载运行链路配置(`BackendConfig`
  /// 写入 `backendConfigProvider`)、刷新 provider 列表并回写文本配置文件。
  /// 关闭底单或未选中时不写入任何状态。
  ///
  /// 落库与重载分两步:重载失败(`loadBackendConfig` 返回 null)时保留当前
  /// backendConfigProvider 旧值,用户可再选一次,不会把运行链路置空。
  Future<void> _openPicker(
    BuildContext context,
    WidgetRef ref,
    List<LlmProviderConfig> providers,
    ReasoningLevel reasoning,
  ) async {
    final picked =
        await showModalBottomSheet<(LlmProviderConfig, LlmModelEntry)>(
          context: context,
          isScrollControlled: true,
          builder: (_) =>
              ModelPickerSheet(providers: providers, reasoning: reasoning),
        );
    if (picked == null || !context.mounted) return;
    final (provider, model) = picked;
    await ref
        .read(llmProviderRepositoryProvider)
        .setActive(providerId: provider.id, modelId: model.id);
    final backend = await ref
        .read(llmProviderRepositoryProvider)
        .loadBackendConfig();
    if (backend != null) {
      ref.read(backendConfigProvider.notifier).state = backend;
    }
    ref.invalidate(llmProvidersProvider);
    await syncAppConfigFile(ref);
  }
}

/// 已组装上下文的桥接数据:由 ChatScreen 传入估算 token 与(若有)最近一次
/// 主写请求的实际输入 token(服务端 UsageEvent 精确计数)。
class ContextLink {
  /// 字符估算(÷3.2)的输入 token;**仅在无真实锚点时**作为圆环口径。
  final int estimateTokens;

  /// 上轮实际输入 token(精确);null = 尚无真实锚点(未发送过/网关未上报)。
  final int? actualInputTokens;
  const ContextLink({required this.estimateTokens, this.actualInputTokens});
}

/// 上下文使用率圆环:显示当前上下文 token 占模型上下文容量的比例。
/// 有上轮真实计数时一律用真实值,只有拿不到锚点才退回字符估算。
/// 鼠标悬停(Tooltip)显示精确数值;点击弹一个对话框显示精确明细。
/// 从当前 active model 读取容量,聊天页内嵌进输入框时与独立条共用。
class ContextUsageRing extends ConsumerWidget {
  /// 上下文 token 口径(估算值 + 可选真实锚点)。
  final ContextLink usage;
  const ContextUsageRing({super.key, required this.usage});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(llmProvidersProvider);
    final providers = providersAsync.maybeWhen(
      data: (p) => p,
      orElse: () => const <LlmProviderConfig>[],
    );
    final activeModel = providers
        .where((p) => p.isActive)
        .firstOrNull
        ?.activeModel;
    // 优先真实口径:上轮主写请求的服务端精确输入计数;仅当无有效锚点
    // (未发送过/历史被改写后未再发送)时退回字符估算。两者都可能偏离
    // "下一次请求"(真实值未计新增的下一轮内容,估算有 tokenizer 漂移),
    // 以 tooltip/弹窗标注口径,各取所长:真实值锚定 provider 计数,估算值
    // 跟随最新组装。
    final real = usage.actualInputTokens;
    final used = real ?? usage.estimateTokens;
    final capacity = activeModel?.contextCapacity ?? 0;
    final usable = capacity > 0;
    final fraction = usable ? (used / capacity).clamp(0.0, 1.0) : 0.0;
    final theme = Theme.of(context);
    final color = !usable
        ? theme.colorScheme.outline
        : fraction < 0.6
        ? theme.colorScheme.primary
        : fraction < 0.9
        ? theme.colorScheme.tertiary
        : theme.colorScheme.error;
    final tooltipText = usable
        ? (real != null
              ? '上下文 ${formatTokenCount(real)} / ${formatTokenCount(capacity)} token(按上轮实际请求)'
              : '上下文 ≈${formatTokenCount(used)} / ${formatTokenCount(capacity)} token(按字符估算)')
        : (real != null
              ? '上轮实际输入 ${formatTokenCount(real)} token(模型未设置容量)'
              : '上下文 ≈${formatTokenCount(used)} token(按字符估算,模型未设置容量)');

    final ringValue = usable ? fraction : 0.0;
    final ring = Tooltip(
      message: tooltipText,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => _usageDialog(context, used, capacity, real),
        ),
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          // 输入框底色是 surfaceContainerHighest,圆环轨道默认也是同色,叠上去
          // 几乎看不见;用页面底色(surface)垫一个圆形底,让轨道与进度弧对比出来。
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            shape: BoxShape.circle,
          ),
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              // 恒为 determinate:无容量时给 0(空轨道),避免无限动画卡住 pumpAndSettle。
              value: ringValue,
              strokeWidth: 3,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              strokeCap: StrokeCap.round,
            ),
          ),
        ),
      ),
    );
    return ring;
  }

  Widget _usageDialog(
    BuildContext context,
    int used,
    int capacity,
    int? real,
  ) => AlertDialog(
    title: const Text('上下文使用情况'),
    content: Text(_dialogBody(used, capacity, real)),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('知道了'),
      ),
    ],
  );

  String _dialogBody(int used, int capacity, int? real) {
    final buffer = StringBuffer();
    if (real != null) {
      // 已有服务端精确计数时不再并列字符估算:两种口径同屏只会让人来回对照,
      // 而估算(÷3.2)在真实值面前没有展示价值。
      buffer.writeln('上轮实际输入:${formatTokenCount(real)} token($real)');
    } else {
      buffer.writeln('当前上下文(按字符估算):≈${formatTokenCount(used)} token');
    }
    if (capacity > 0) {
      buffer
        ..writeln('模型上下文容量:${formatTokenCount(capacity)} token($capacity)')
        ..write(
          '已用 ${((used / capacity) * 100).clamp(0, 100).toStringAsFixed(1)}%',
        );
    } else {
      buffer.write('(该模型未设置上下文容量)');
    }
    return buffer.toString();
  }
}

/// 模型选择器底单:列出所有 provider 及其模型(单选当前模型),并让用户设置
/// 推理等级。选择模型后以 `(provider, model)` 记录返回,落库由调用方完成。
///
/// 推理四档(关/低/中/高)只改设置、不关闭底单;后端各自映射为请求参数
/// (OpenAI 兼容为 `reasoning_effort`,anthropic 为 thinking 预算),off 时
/// 两者都不发送相关字段。列表行按需懒构建,模型较多的 provider 不会在
/// 打开底单时一次性构建全部行。
class ModelPickerSheet extends ConsumerStatefulWidget {
  /// 可选 provider 目录快照;底单自身不刷新列表。
  final List<LlmProviderConfig> providers;

  /// 打开时的推理等级;底单内的改动即时落库。
  final ReasoningLevel reasoning;
  const ModelPickerSheet({
    super.key,
    required this.providers,
    required this.reasoning,
  });

  @override
  ConsumerState<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<ModelPickerSheet> {
  late ReasoningLevel _reasoning;

  @override
  void initState() {
    super.initState();
    _reasoning = widget.reasoning;
  }

  /// 切换推理等级:同步 `appSettingsProvider` 与库(该设置不进文本配置文件,
  /// 文件只承载用户名与 provider 目录);完成后刷新选中态。
  ///
  /// 持久化异常不在此吞掉;setState 只在完成后且仍挂载时执行 —— 弹层已关闭
  /// 时不再触碰状态。
  Future<void> _saveReasoning(ReasoningLevel level) async {
    _reasoning = level;
    final settings = ref.read(appSettingsProvider);
    await persistReasoningLevel(
      level: level,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: settings,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          // 扁平化成「标题 / provider 分组头 / 模型行 / 底部推理设置」,
          // 用 builder 懒构建。模型较多的 provider 不再一打开底单就构建全部行。
          final rows = <(LlmProviderConfig, LlmModelEntry?)>[
            for (final p in widget.providers) ...[
              (p, null),
              for (final m in p.models) (p, m),
            ],
          ];
          final footer = <Widget>[
            const Divider(height: 28),
            Text(
              '推理等级',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ReasoningLevel>(
              segments: const [
                ButtonSegment(value: ReasoningLevel.off, label: Text('关闭')),
                ButtonSegment(value: ReasoningLevel.low, label: Text('低')),
                ButtonSegment(value: ReasoningLevel.medium, label: Text('中')),
                ButtonSegment(value: ReasoningLevel.high, label: Text('高')),
              ],
              selected: {_reasoning},
              onSelectionChanged: (sel) => _saveReasoning(sel.first),
            ),
            const SizedBox(height: 4),
            Text(
              '推理等级会透传到请求;OpenAI 兼容后端映射为 reasoning_effort。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ];
          return ListView.builder(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            itemCount:
                1 +
                (widget.providers.isEmpty ? 1 : rows.length) +
                footer.length,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Text(
                  '选择模型',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                );
              }
              if (widget.providers.isEmpty) {
                // 标题之后是空态提示,再之后才是底部推理设置。
                if (index == 1) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '还没有配置任何 provider,请先到设置里添加。',
                      style: TextStyle(color: scheme.outline),
                    ),
                  );
                }
                return footer[index - 2];
              }
              final rowIndex = index - 1;
              if (rowIndex < rows.length) {
                final (p, m) = rows[rowIndex];
                if (m == null) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.dns_outlined,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          p.displayName,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        if (p.isActive)
                          Text(
                            ' · 当前',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.primary),
                          ),
                      ],
                    ),
                  );
                }
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 16),
                  leading: Icon(
                    (p.isActive && m.isActive)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: (p.isActive && m.isActive)
                        ? scheme.primary
                        : scheme.outline,
                  ),
                  title: Text(m.displayName),
                  subtitle: Text(
                    '${m.modelId} · 上下文 ${formatTokenCount(m.contextCapacity)} tok'
                    '${m.maxOutput != null ? ' · 输出 ${formatTokenCount(m.maxOutput!)} tok' : ''}',
                  ),
                  onTap: () => Navigator.pop(context, (p, m)),
                );
              }
              return footer[rowIndex - rows.length];
            },
          );
        },
      ),
    );
  }
}
