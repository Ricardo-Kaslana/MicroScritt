/// 模型选择条:当前模型 chip、上下文使用率圆环与推理等级入口。
///
/// 聊天页把 chip + 圆环内嵌在输入框右下角;独立条布局目前仅测试使用。
/// 用量口径优先服务端上报的真实 token,字符估算(÷3.2)只作兜底。
///
/// 弹层形态按平台分流:移动端走底部抽屉(`showAppSheet`),桌面端走锚定
/// 弹卡(`AppFlyoutAnchor`,原地向上展开、点卡外/Esc 关闭)。两条路径共用
/// 同一份内容件([_ModelPickerBody]/[_UsagePanel]),选择与落库语义一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_settings.dart';
import '../models/llm_provider.dart';
import '../models/llm_units.dart';
import '../state/app_config_sync.dart';
import '../state/providers.dart';
import 'common/app_flyout.dart';
import 'common/app_sheet.dart';
import 'common/app_snack_bar.dart';
import 'common/empty_state.dart';
import 'common/layout_breakpoints.dart';
import 'common/sheet_header.dart';
import 'settings_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/reasoning_slider.dart';

/// 模型选择底单的最大高度占比:内容超出时列表在内部滚动,不占满屏高。
const double _kPickerMaxHeightFactor = 0.6;

/// 桌面弹卡定宽:模型卡放宽到能放下「上下文 · 输出」副标题,
/// 用量卡放下「已用/容量(百分比)」整行。
const double _kModelFlyoutWidth = 380;
const double _kUsageFlyoutWidth = 320;

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
  const ModelSelectorChip({super.key, this.embedded = false});

  /// 是否作为底栏「模型 | 推理」合并胶囊的一段嵌入。
  ///
  /// 嵌入时不自带底色与圆角:整颗胶囊由外层 Material 统一上色并裁切,
  /// 模型段只画内容与左半的点击涟漪。两段各自铺色会在接缝处留下一条
  /// 生硬的分界,合并成一层底色后再用发丝线分区更干净。
  final bool embedded;

  /// 胶囊内水平内边距:模型段与推理段共用,整颗胶囊左右留白对称。
  static const EdgeInsets _facePadding = EdgeInsets.symmetric(
    horizontal: 9,
    vertical: 6,
  );

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
    // 胶囊是整颗 pill:嵌入时只保留左半圆角,右缘由推理段补齐。
    final borderRadius = embedded
        ? const BorderRadius.horizontal(left: Radius.circular(26))
        : BorderRadius.circular(26);
    Widget chipFace() => _chipFace(context, scheme, activeModel);
    final Widget face = embedded
        ? Padding(padding: _facePadding, child: chipFace())
        : Container(
            padding: _facePadding,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: borderRadius,
            ),
            child: chipFace(),
          );
    // 独立 chip 的底色画在自己的 Container 上,涟漪会被盖住;只有嵌入
    // 合并胶囊(Material 提供底色)时才需要悬停/按下的反馈。
    final hoverColor = embedded ? scheme.primary.withValues(alpha: 0.06) : null;
    final highlightColor = embedded
        ? scheme.primary.withValues(alpha: 0.09)
        : null;
    if (isDesktopPlatformOf(context)) {
      // 桌面端:锚定弹卡,chip 即锚点;选中模型后由内容件回调关闭并落库。
      // 再次点击 chip 是 toggle(触发件与卡片同 TapRegion 组,点外关闭
      // 不会先吃掉这次点击,需要手动关)。
      return AppFlyoutAnchor(
        width: _kModelFlyoutWidth,
        builder: (context, handle) => InkWell(
          key: const ValueKey('model_selector'),
          borderRadius: borderRadius,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          onTap: () {
            if (handle.isOpen) {
              handle.close();
              return;
            }
            _openPicker(context, ref, providers, openFlyout: handle.open);
          },
          child: face,
        ),
        flyoutBuilder: (context, handle) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppFlyoutHeader(
              icon: Icons.smart_toy_outlined,
              title: '选择模型',
            ),
            Flexible(
              // 内容件与移动端底单共用,自身不带外边距(底单外壳负责);
              // 桌面弹卡这里补上与标题/其它弹卡行一致的水平留白。
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: _ModelPickerBody(
                  providers: providers,
                  reasoning: reasoning,
                  onPicked: (provider, model) {
                    handle.close();
                    _applyModelChoice(context, ref, provider, model);
                  },
                ),
              ),
            ),
          ],
        ),
      );
    }
    return InkWell(
      key: const ValueKey('model_selector'),
      borderRadius: borderRadius,
      hoverColor: hoverColor,
      highlightColor: highlightColor,
      onTap: () => _openPicker(context, ref, providers),
      child: face,
    );
  }

  /// chip 的视觉本体:图标 + 模型名,窄屏按模型名收缩省略。
  Widget _chipFace(
    BuildContext context,
    ColorScheme scheme,
    LlmModelEntry? activeModel,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.smart_toy_outlined, size: 15, color: scheme.primary),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            activeModel?.displayName ?? '未选择模型',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 还没有任何 provider:选择器里没有可选项,直接把用户送到设置页,
  /// 比打开一个只能看空列表的弹层少一步。
  Future<void> _openPicker(
    BuildContext context,
    WidgetRef ref,
    List<LlmProviderConfig> providers, {
    void Function()? openFlyout,
  }) async {
    if (providers.isEmpty) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
      return;
    }
    if (openFlyout != null) {
      openFlyout();
      return;
    }
    final reasoning = ref.read(appSettingsProvider).reasoningLevel;
    final picked = await showAppSheet<(LlmProviderConfig, LlmModelEntry)>(
      context,
      showDragHandle: true,
      builder: (_) =>
          ModelPickerSheet(providers: providers, reasoning: reasoning),
    );
    if (picked == null || !context.mounted) return;
    await _applyModelChoice(context, ref, picked.$1, picked.$2);
  }

  /// 选中模型后的落库链:落 active 标记、重载运行链路配置(`BackendConfig`
  /// 写入 `backendConfigProvider`)、刷新 provider 列表并回写文本配置文件。
  ///
  /// 落库与重载分两步:重载失败(`loadBackendConfig` 返回 null)时保留当前
  /// backendConfigProvider 旧值,用户可再选一次,不会把运行链路置空。
  Future<void> _applyModelChoice(
    BuildContext context,
    WidgetRef ref,
    LlmProviderConfig provider,
    LlmModelEntry model,
  ) async {
    await markAppConfigDirty(ref);
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

  /// 上轮实际输入中命中提示缓存的部分;仅在 [actualInputTokens] 非空时有意义,
  /// 供点击底单展示缓存命中率。
  final int cachedInputTokens;
  const ContextLink({
    required this.estimateTokens,
    this.actualInputTokens,
    this.cachedInputTokens = 0,
  });
}

/// 上下文使用率圆环:显示当前上下文 token 占模型上下文容量的比例。
/// 有上轮真实计数时一律用真实值,只有拿不到锚点才退回字符估算。
/// 悬停提示只显示已用百分比;点击弹层展示容量用量与缓存命中率。
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
    // 底单对估算值标 ≈,悬停提示只给百分比。
    final real = usage.actualInputTokens;
    final used = real ?? usage.estimateTokens;
    final capacity = activeModel?.contextCapacity ?? 0;
    final usable = capacity > 0;
    final fraction = usable
        ? (used / capacity).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final theme = Theme.of(context);
    final color = !usable
        ? theme.colorScheme.outline
        : fraction < 0.6
        ? theme.colorScheme.primary
        : fraction < 0.9
        ? theme.colorScheme.tertiary
        : theme.colorScheme.error;
    final percentLabel = usable
        ? '已用 ${(fraction * 100).toStringAsFixed(1)}%'
        : '未设置上下文容量';
    final cacheHitRate = real != null && real > 0
        ? usage.cachedInputTokens / real
        : null;

    final ringValue = usable ? fraction : 0.0;
    // Tooltip 的文案交给外层 Semantics 朗读,避免读屏重复播报;
    // InkWell 仍提供点击动作与按钮角色。
    Widget ringFace(VoidCallback? onTap) => Tooltip(
      message: percentLabel,
      excludeFromSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          // 32 的逻辑命中区:26 的圆环在小屏上贴着发送键,容易点空。
          width: 32,
          height: 32,
          alignment: Alignment.center,
          // 输入框底色是 surfaceContainerHighest,圆环轨道默认也是同色,叠上去
          // 几乎看不见;用页面底色(surface)垫一个圆形底,让轨道与进度弧对比出来。
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            shape: BoxShape.circle,
          ),
          child: SizedBox(
            width: 26,
            height: 26,
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
    if (isDesktopPlatformOf(context)) {
      // 桌面端:锚定弹卡,圆环即锚点;明细面板纯展示,点卡外/Esc 关闭。
      return AppFlyoutAnchor(
        width: _kUsageFlyoutWidth,
        alignment: AppFlyoutAlignment.end,
        builder: (context, handle) => Semantics(
          button: true,
          label: percentLabel,
          child: ringFace(handle.toggle),
        ),
        flyoutBuilder: (context, handle) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppFlyoutHeader(
              icon: Icons.query_stats_outlined,
              title: '上下文使用情况',
            ),
            _UsagePanel(
              usedTokens: used,
              capacity: capacity,
              fraction: ringValue,
              estimated: real == null,
              cacheHitRate: cacheHitRate,
              barColor: color,
            ),
          ],
        ),
      );
    }
    return Semantics(
      button: true,
      label: percentLabel,
      child: ringFace(
        () => showAppSheet<void>(
          context,
          isScrollControlled: false,
          showDragHandle: true,
          builder: (_) => _UsageSheet(
            usedTokens: used,
            capacity: capacity,
            fraction: ringValue,
            estimated: real == null,
            cacheHitRate: cacheHitRate,
            barColor: color,
          ),
        ),
      ),
    );
  }
}

/// 上下文用量的明细底单(移动端薄壳):标题 + 共享明细面板。
class _UsageSheet extends StatelessWidget {
  final int usedTokens;
  final int capacity;
  final double fraction;

  /// 无真实锚点时为 true,[usedTokens] 来自字符估算,数值前标 ≈。
  final bool estimated;

  /// 上轮缓存命中率;null = 尚无服务端计量,显示"—"。
  final double? cacheHitRate;

  /// 与圆环同色的进度条:占用越高越早切换到强调/错误色。
  final Color barColor;
  const _UsageSheet({
    required this.usedTokens,
    required this.capacity,
    required this.fraction,
    required this.estimated,
    required this.cacheHitRate,
    required this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ChatSheetHeader(
            icon: Icons.query_stats_outlined,
            title: '上下文使用情况',
          ),
          const SizedBox(height: 4),
          _UsagePanel(
            usedTokens: usedTokens,
            capacity: capacity,
            fraction: fraction,
            estimated: estimated,
            cacheHitRate: cacheHitRate,
            barColor: barColor,
          ),
        ],
      ),
    );
  }
}

/// 上下文用量的共享明细面板:左指标名、右「已用/容量(百分比)」,通栏
/// 进度条,再补一行缓存命中率。数值口径与圆环一致(真实锚点优先)。
/// 移动端由 [_UsageSheet] 包标题,桌面端由弹卡包 [AppFlyoutHeader]。
class _UsagePanel extends StatelessWidget {
  final int usedTokens;
  final int capacity;
  final double fraction;
  final bool estimated;
  final double? cacheHitRate;
  final Color barColor;
  const _UsagePanel({
    required this.usedTokens,
    required this.capacity,
    required this.fraction,
    required this.estimated,
    required this.cacheHitRate,
    required this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _metricRow(context, label: '上下文容量', value: _capacityText()),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              color: barColor,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 16),
          _metricRow(
            context,
            label: '缓存命中率',
            value: cacheHitRate == null
                ? '—'
                : '${(cacheHitRate! * 100).toStringAsFixed(1)}%',
          ),
        ],
      ),
    );
  }

  /// 指标行:左侧名称 + 右侧数值(等宽数字,长数值自动换行靠右)。
  Widget _metricRow(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodyLarge),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  String _capacityText() {
    if (capacity <= 0) return '未设置';
    final used = '${estimated ? '≈' : ''}${formatTokenCountZh(usedTokens)}';
    return '$used/${formatTokenCountZh(capacity)}'
        '（${(fraction * 100).toStringAsFixed(1)}%）';
  }
}

/// 模型选择器底单(移动端薄壳):标题 + 共享选择面板。桌面端不经此类,
/// 直接由 [ModelSelectorChip] 打开 [_ModelPickerBody] 弹卡。
///
/// 选择模型后以 `(provider, model)` 记录返回,落库由调用方完成。
class ModelPickerSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // 内容少时底单贴合内容(模型只有一两个时不再留半屏空白);
      // 模型多时封顶 0.6 屏高,列表在封顶内滚动。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * _kPickerMaxHeightFactor,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ChatSheetHeader(
              icon: Icons.smart_toy_outlined,
              title: '选择模型',
            ),
            const SizedBox(height: 4),
            Flexible(
              child: _ModelPickerBody(
                providers: providers,
                reasoning: reasoning,
                onPicked: (provider, model) =>
                    Navigator.pop(context, (provider, model)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 模型选择器的共享选择面板:provider 分组模型列表(单选当前模型)+
/// 底部推理等级滑块(改动即时落库,不关闭弹层)。选中后经 [onPicked] 交
/// 宿主处理(移动端 pop 底单,桌面端关弹卡),落库由调用方完成。
///
/// 推理七档(关/最低/低/中/高/极高/最高)只改设置、不关闭弹层;后端各自映射为请求参数
/// (OpenAI 兼容为 `reasoning_effort`,anthropic 为 thinking 预算),off 时
/// 两者都不发送相关字段。模型多时列表在弹层封顶内滚动,行按需懒构建。
class _ModelPickerBody extends ConsumerStatefulWidget {
  final List<LlmProviderConfig> providers;
  final ReasoningLevel reasoning;
  final void Function(LlmProviderConfig provider, LlmModelEntry model) onPicked;
  const _ModelPickerBody({
    required this.providers,
    required this.reasoning,
    required this.onPicked,
  });

  @override
  ConsumerState<_ModelPickerBody> createState() => _ModelPickerBodyState();
}

class _ModelPickerBodyState extends ConsumerState<_ModelPickerBody> {
  late ReasoningLevel _reasoning = widget.reasoning;

  /// 切换推理等级:先落库,成功后才更新 provider 与弹层选中态(该设置不进
  /// 文本配置文件,文件只承载用户名与 provider 目录)。
  ///
  /// 写库失败时保留原值并提示,不留下"界面已切换、重启后又变回去"的假成功。
  Future<void> _saveReasoning(ReasoningLevel level) async {
    final settings = ref.read(appSettingsProvider);
    try {
      await persistReasoningLevel(
        level: level,
        appSettingsSetter: (s) =>
            ref.read(appSettingsProvider.notifier).state = s,
        repo: ref.read(appSettingsRepositoryProvider),
        current: settings,
      );
    } catch (_) {
      if (!mounted) return;
      showAppSnack(context, '保存推理等级失败,请重试');
      return;
    }
    if (mounted) setState(() => _reasoning = level);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 扁平化成「provider 分组头 / 模型行」,用 builder 懒构建。
    final rows = <(LlmProviderConfig, LlmModelEntry?)>[
      for (final p in widget.providers) ...[
        (p, null),
        for (final m in p.models) (p, m),
      ],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: widget.providers.isEmpty ? 1 : rows.length,
            itemBuilder: (context, index) {
              if (widget.providers.isEmpty) {
                return const EmptyState(
                  compact: true,
                  icon: Icons.dns_outlined,
                  title: '还没有配置 Provider',
                  message: '请先到设置里添加一个 LLM Provider。',
                );
              }
              final (p, m) = rows[index];
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
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (p.isActive)
                        Text(
                          ' · 当前',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.primary,
                          ),
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
                  '上下文 ${formatTokenCount(m.contextCapacity)} tok'
                  '${m.maxOutput != null ? ' · 输出 ${formatTokenCount(m.maxOutput!)} tok' : ''}',
                ),
                onTap: () => widget.onPicked(p, m),
              );
            },
          ),
        ),
        const Divider(height: 24),
        Text(
          '推理等级',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        ReasoningSlider(value: _reasoning, onSelected: _saveReasoning),
      ],
    );
  }
}
