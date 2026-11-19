/// 桌面状态工作台:分区导航壳、概览与后台引擎设置。
///
/// 宽窗(≥1000)使用本页;窄窗由 `StatusScreen` 分发到移动单列页。设置与
/// 引擎控制全部即时落库,复用 state/providers.dart 的 persistBackground*。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/background_status.dart';
import '../../models/app_settings.dart';
import '../../models/llm_provider.dart';
import '../../models/worldbook_entry.dart';
import '../../state/chat_controller.dart';
import '../../state/providers.dart';
import '../common/form_field.dart';
import '../common/section_header.dart';
import '../common/info_button.dart';
import 'status_dialogs.dart';
import 'status_layout.dart';
import 'status_memory_workspace.dart';
import 'status_variables_workspace.dart';
import 'status_widgets.dart';

/// 桌面工作台的分区。
enum StatusDesktopSection {
  overview,
  variables,
  memory,
  imageGuide;

  String get label => switch (this) {
    StatusDesktopSection.overview => '概览',
    StatusDesktopSection.variables => '变量',
    StatusDesktopSection.memory => '记忆',
    StatusDesktopSection.imageGuide => '生图指导',
  };

  IconData get icon => switch (this) {
    StatusDesktopSection.overview => Icons.dashboard_outlined,
    StatusDesktopSection.variables => Icons.data_object,
    StatusDesktopSection.memory => Icons.psychology_outlined,
    StatusDesktopSection.imageGuide => Icons.palette_outlined,
  };
}

class StatusDesktopScreen extends ConsumerStatefulWidget {
  final int sessionId;
  const StatusDesktopScreen({super.key, required this.sessionId});

  @override
  ConsumerState<StatusDesktopScreen> createState() =>
      _StatusDesktopScreenState();
}

class _StatusDesktopScreenState extends ConsumerState<StatusDesktopScreen> {
  StatusDesktopSection _section = StatusDesktopSection.overview;

  /// 已访问过的分区保留自身状态(滚动位置、未提交的行内编辑),
  /// 切区不重建;首次访问时才构建。
  final Set<StatusDesktopSection> _visited = {StatusDesktopSection.overview};

  void _openSection(StatusDesktopSection section) {
    if (_section == section) return;
    setState(() {
      _section = section;
      _visited.add(section);
    });
  }

  Widget _sectionBody(StatusDesktopSection section) {
    return switch (section) {
      StatusDesktopSection.overview => _OverviewWorkspace(
        sessionId: widget.sessionId,
      ),
      StatusDesktopSection.variables => StatusVariablesWorkspace(
        sessionId: widget.sessionId,
      ),
      StatusDesktopSection.memory => StatusMemoryWorkspace(
        sessionId: widget.sessionId,
      ),
      StatusDesktopSection.imageGuide => StatusImageGuideWorkspace(
        sessionId: widget.sessionId,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final characterName = ref.watch(
      chatControllerProvider.select((s) => s.character?.name),
    );
    final title = characterName == null || characterName.isEmpty
        ? '状态面板'
        : '状态面板 · $characterName';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('status_desktop_sidebar'),
            width: kStatusDesktopSidebarWidth,
            child: _DesktopSidebar(
              sessionId: widget.sessionId,
              section: _section,
              onSelect: _openSection,
            ),
          ),
          Expanded(
            key: const ValueKey('status_desktop_workspace'),
            child: IndexedStack(
              index: _section.index,
              children: [
                for (final section in StatusDesktopSection.values)
                  KeyedSubtree(
                    key: ValueKey('status_section_${section.name}'),
                    child: _visited.contains(section)
                        ? _sectionBody(section)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopSidebar extends ConsumerWidget {
  final int sessionId;
  final StatusDesktopSection section;
  final ValueChanged<StatusDesktopSection> onSelect;

  const _DesktopSidebar({
    required this.sessionId,
    required this.section,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = ref.watch(variableRowsProvider(sessionId));
    final pendingDeletions = ref.watch(
      pendingVariableDeletionsProvider(sessionId),
    );
    final memories = ref.watch(memoriesProvider(sessionId));
    final chatState = ref.watch(chatControllerProvider);
    final memoryPending = isMemoryPendingApply(chatState, sessionId, memories);
    final variableCount = rows.maybeWhen(
      data: (list) => list.length,
      orElse: () => null,
    );
    final pendingDeleteCount = pendingDeletions.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              '工作区',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ),
          for (final item in StatusDesktopSection.values)
            _StatusNavTile(
              key: ValueKey('status_nav_${item.name}'),
              icon: item.icon,
              label: item.label,
              selected: section == item,
              onTap: () => onSelect(item),
              trailing: switch (item) {
                StatusDesktopSection.variables =>
                  variableCount == null
                      ? null
                      : _VariableNavBadges(
                          count: variableCount,
                          pending: pendingDeleteCount,
                        ),
                StatusDesktopSection.memory =>
                  memoryPending
                      ? const _NavBadge(label: '待应用', primary: true)
                      : null,
                _ => null,
              },
            ),
          const Spacer(),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          _EngineFooter(
            onOpenOverview: () => onSelect(StatusDesktopSection.overview),
          ),
        ],
      ),
    );
  }
}

class _StatusNavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  const _StatusNavTile({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          hoverColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 19,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected ? scheme.primary : scheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VariableNavBadges extends StatelessWidget {
  final int count;
  final int pending;
  const _VariableNavBadges({required this.count, required this.pending});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NavBadge(label: '$count'),
        if (pending > 0) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: '$pending 条待确认删除',
            child: _NavBadge(label: '$pending', error: true),
          ),
        ],
      ],
    );
  }
}

class _NavBadge extends StatelessWidget {
  final String label;
  final bool primary;
  final bool error;
  const _NavBadge({
    required this.label,
    this.primary = false,
    this.error = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = error
        ? scheme.error
        : primary
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final fill = error
        ? scheme.errorContainer.withValues(alpha: 0.5)
        : primary
        ? scheme.primary.withValues(alpha: 0.12)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.7);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _EngineFooter extends ConsumerWidget {
  final VoidCallback onOpenOverview;
  const _EngineFooter({required this.onOpenOverview});

  Future<void> _setEnabled(WidgetRef ref, AppSettings current, bool enabled) {
    return persistBackgroundEngineState(
      enabled: enabled,
      mode: current.backgroundMode,
      enabledSetter: (v) =>
          ref.read(backgroundEnabledProvider.notifier).state = v,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: current,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final chatState = ref.watch(chatControllerProvider);
    final enabled = settings.backgroundEnabled;
    final status = enabled
        ? chatState.backgroundStatus
        : BackgroundStatus.disabled;
    final color = _backgroundStatusColor(status, scheme);
    return Padding(
      key: const ValueKey('status_engine_footer'),
      padding: const EdgeInsets.all(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onOpenOverview,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '后台引擎',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${backgroundStatusLabel(status)} · ${settings.backgroundMode.label}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Switch(
              key: const ValueKey('engine_footer_switch'),
              value: enabled,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => _setEnabled(ref, settings, v),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewWorkspace extends ConsumerWidget {
  final int sessionId;
  const _OverviewWorkspace({required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final characterId =
        ref.watch(chatControllerProvider.select((s) => s.characterId)) ?? -1;
    return StatusWorkspaceFrame(
      header: const StatusWorkspaceHeader(
        title: '概览',
        description: '后台引擎状态与维护设置;修改即时保存,不需要额外的保存按钮。',
      ),
      child: ListView(
        primary: false,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _EngineStatusCard(),
          const SizedBox(height: 16),
          _SettingsGrid(characterId: characterId),
        ],
      ),
    );
  }
}

class _EngineStatusCard extends ConsumerWidget {
  const _EngineStatusCard();

  Future<void> _setEngine(
    WidgetRef ref,
    AppSettings current, {
    required bool enabled,
    required BackgroundMode mode,
  }) {
    return persistBackgroundEngineState(
      enabled: enabled,
      mode: mode,
      enabledSetter: (v) =>
          ref.read(backgroundEnabledProvider.notifier).state = v,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: current,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final chatState = ref.watch(chatControllerProvider);
    final enabled = settings.backgroundEnabled;
    final status = enabled
        ? chatState.backgroundStatus
        : BackgroundStatus.disabled;
    final statusColor = _backgroundStatusColor(status, scheme);
    final summary = chatState.backgroundSummary;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  status == BackgroundStatus.running
                      ? Icons.autorenew
                      : Icons.psychology_outlined,
                  size: 22,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '后台引擎',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            backgroundStatusLabel(status),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: statusColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      enabled
                          ? '主回复落库后串行维护变量与生图,行为由运行模式决定。'
                          : '引擎已关闭,后台不会在回复后运行维护。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                key: const ValueKey('engine_power_switch'),
                value: enabled,
                onChanged: (v) => _setEngine(
                  ref,
                  settings,
                  enabled: v,
                  mode: settings.backgroundMode,
                ),
              ),
            ],
          ),
          if (status == BackgroundStatus.running) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: const LinearProgressIndicator(minHeight: 3),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                '运行模式',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 14),
              SegmentedButton<BackgroundMode>(
                segments: [
                  for (final mode in BackgroundMode.values)
                    ButtonSegment<BackgroundMode>(
                      value: mode,
                      label: Text(mode.label),
                      tooltip: mode.hint,
                    ),
                ],
                selected: {settings.backgroundMode},
                showSelectedIcon: false,
                onSelectionChanged: enabled
                    ? (selection) => _setEngine(
                        ref,
                        settings,
                        enabled: true,
                        mode: selection.first,
                      )
                    : null,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '${settings.backgroundMode.hint}。切换模式即时生效。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (summary.isNotEmpty)
            BackgroundSummaryView(text: summary, status: status)
          else
            Text(
              '尚无运行摘要;主回复落库后会在这里显示本轮维护结果。',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
        ],
      ),
    );
  }
}

/// 设置卡网格:宽屏三列(维护 / 模型 / 锚定),中屏两列同行等高并让
/// 锚定卡独占一行,窄屏单列。
class _SettingsGrid extends StatelessWidget {
  final int characterId;
  const _SettingsGrid({required this.characterId});

  @override
  Widget build(BuildContext context) {
    const gap = 16.0;
    final anchor = _AnchorSettingsCard(characterId: characterId);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (maxWidth >= 1000) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Expanded(child: _MaintenanceSettingsCard()),
                const SizedBox(width: gap),
                const Expanded(child: _ModelSettingsCard()),
                const SizedBox(width: gap),
                Expanded(child: anchor),
              ],
            ),
          );
        }
        if (maxWidth >= 640) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _MaintenanceSettingsCard()),
                    SizedBox(width: gap),
                    Expanded(child: _ModelSettingsCard()),
                  ],
                ),
              ),
              const SizedBox(height: gap),
              anchor,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _MaintenanceSettingsCard(),
            const SizedBox(height: gap),
            const _ModelSettingsCard(),
            const SizedBox(height: gap),
            anchor,
          ],
        );
      },
    );
  }
}

class _MaintenanceSettingsCard extends ConsumerWidget {
  const _MaintenanceSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final features = ref.watch(backgroundFeaturesProvider);
    final settings = ref.watch(appSettingsProvider);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StatusCardSectionTitle(icon: Icons.tune, title: '维护功能'),
          const SizedBox(height: 4),
          _SwitchRow(
            icon: Icons.data_object,
            label: '变量',
            value: features.variables,
            onChanged: (_) => _toggleFeature(ref, 'variables'),
          ),
          _SwitchRow(
            icon: Icons.image_outlined,
            label: '生图',
            value: features.image,
            onChanged: (_) => _toggleFeature(ref, 'image'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            secondary: const Icon(Icons.fact_check_outlined, size: 20),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('变量删除前确认', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 2),
                InfoButton(onTap: () => showDeletionConfirmHelpDialog(context)),
              ],
            ),
            value: settings.backgroundDeletionConfirm,
            onChanged: (v) => _setDeletionConfirm(ref, v),
          ),
          const SizedBox(height: 4),
          Text(
            '严格模式只影响后台删除:请求先进入待确认,确认后才移入回收站。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelSettingsCard extends ConsumerWidget {
  const _ModelSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final providersAsync = ref.watch(llmProvidersProvider);
    final providers = providersAsync.maybeWhen(
      data: (p) => p,
      orElse: () => const <LlmProviderConfig>[],
    );
    final models = flattenLlmModels(providers);
    final selected =
        settings.backgroundModelId != null &&
            models.any((m) => m.id == settings.backgroundModelId)
        ? settings.backgroundModelId
        : null;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StatusCardSectionTitle(icon: Icons.memory, title: '模型与参数'),
          const SizedBox(height: 6),
          FormDropdownField<int?>(
            fieldKey: ValueKey(
              'desktop_background_model_${selected?.toString() ?? 'follow'}',
            ),
            value: selected,
            label: '专用模型',
            helperText: '未选择时跟随主写引擎当前模型。',
            menuMaxHeight: 280,
            items: [null, for (final m in models) m.id],
            labelOf: (id) => id == null
                ? '跟随主写引擎'
                : models.firstWhere((m) => m.id == id).label,
            onChanged: (id) => _setModel(ref, id),
          ),
          FormDropdownField<ReasoningLevel>(
            fieldKey: ValueKey(
              'desktop_background_reasoning_${settings.backgroundReasoningLevel.name}',
            ),
            value: settings.backgroundReasoningLevel,
            label: '推理强度',
            helperText: '独立于主对话的推理等级,默认关闭。',
            items: ReasoningLevel.values,
            labelOf: (level) => level.label,
            onChanged: (level) {
              if (level != null) _setReasoning(ref, level);
            },
          ),
        ],
      ),
    );
  }
}

class _AnchorSettingsCard extends ConsumerWidget {
  final int characterId;
  const _AnchorSettingsCard({required this.characterId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = ref.watch(appSettingsProvider);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StatusCardSectionTitle(icon: Icons.link, title: '上下文锚定'),
          const SizedBox(height: 4),
          _SwitchRow(
            icon: Icons.person_outline,
            label: '角色卡进入上下文',
            value: settings.backgroundCharacterAnchor,
            onChanged: (_) => _toggleAnchor(ref, 'character'),
          ),
          _SwitchRow(
            icon: Icons.psychology_outlined,
            label: '记忆进入上下文',
            value: settings.backgroundMemoryAnchor,
            onChanged: (_) => _toggleAnchor(ref, 'memory'),
          ),
          const SizedBox(height: 4),
          _WorldbookRow(characterId: characterId),
          const SizedBox(height: 4),
          Text(
            '以上开关决定后台维护请求能读到的会话背景;变量板始终可读。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      secondary: Icon(icon, size: 20),
      title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _WorldbookRow extends ConsumerWidget {
  final int characterId;
  const _WorldbookRow({required this.characterId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries =
        ref.watch(worldbookProvider(characterId)).value ??
        const <WorldbookEntry>[];
    final selected = entries.where((e) => e.background).toList();
    final effective = selected.where((e) => e.enabled).length;
    final inert = selected.length - effective;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.menu_book_outlined, size: 20),
      title: Text('后台世界书条目', style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(
        entries.isEmpty
            ? '该角色暂无世界书条目'
            : '已选 ${selected.length} 条 · $effective 条生效'
                  '${inert > 0 ? ' · $inert 条停用' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: entries.isEmpty
          ? null
          : const Icon(Icons.chevron_right, size: 20),
      onTap: entries.isEmpty ? null : () => _pick(context, ref, entries),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    List<WorldbookEntry> entries,
  ) async {
    final selected = await showWorldbookPickerDialog(
      context,
      entries: entries,
      initialSelected: {
        for (final e in entries)
          if (e.background) e.id,
      },
    );
    if (selected == null) return;
    final updated = entries
        .map((e) => e.copyWith(background: selected.contains(e.id)))
        .toList();
    await ref
        .read(worldbookRepositoryProvider)
        .replaceForCharacter(characterId, updated);
    ref.invalidate(worldbookProvider(characterId));
  }
}

Color _backgroundStatusColor(BackgroundStatus status, ColorScheme scheme) {
  return switch (status) {
    BackgroundStatus.running || BackgroundStatus.succeeded => scheme.primary,
    BackgroundStatus.failed || BackgroundStatus.interrupted => scheme.error,
    BackgroundStatus.idle ||
    BackgroundStatus.skipped ||
    BackgroundStatus.disabled => scheme.outline,
  };
}

Future<void> _toggleFeature(WidgetRef ref, String name) {
  return persistBackgroundFeature(
    mutate: (f) => f.toggle(name),
    featureSetter: (f) =>
        ref.read(backgroundFeaturesProvider.notifier).state = f,
    appSettingsSetter: (s) => ref.read(appSettingsProvider.notifier).state = s,
    repo: ref.read(appSettingsRepositoryProvider),
    current: ref.read(appSettingsProvider),
  );
}

Future<void> _toggleAnchor(WidgetRef ref, String key) {
  return persistBackgroundAnchor(
    key: key,
    appSettingsSetter: (s) => ref.read(appSettingsProvider.notifier).state = s,
    repo: ref.read(appSettingsRepositoryProvider),
    current: ref.read(appSettingsProvider),
  );
}

Future<void> _setDeletionConfirm(WidgetRef ref, bool enabled) {
  return persistBackgroundDeletionConfirm(
    enabled: enabled,
    appSettingsSetter: (s) => ref.read(appSettingsProvider.notifier).state = s,
    repo: ref.read(appSettingsRepositoryProvider),
    current: ref.read(appSettingsProvider),
  );
}

Future<void> _setModel(WidgetRef ref, int? modelId) {
  return persistBackgroundModel(
    modelId: modelId,
    appSettingsSetter: (s) => ref.read(appSettingsProvider.notifier).state = s,
    repo: ref.read(appSettingsRepositoryProvider),
    current: ref.read(appSettingsProvider),
  );
}

Future<void> _setReasoning(WidgetRef ref, ReasoningLevel level) {
  return persistBackgroundReasoningLevel(
    level: level,
    appSettingsSetter: (s) => ref.read(appSettingsProvider.notifier).state = s,
    repo: ref.read(appSettingsRepositoryProvider),
    current: ref.read(appSettingsProvider),
  );
}
