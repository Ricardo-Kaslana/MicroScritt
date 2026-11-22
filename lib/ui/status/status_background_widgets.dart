/// 状态面板的后台引擎卡、模式按钮、参数选择与后台世界书条目弹层。

part of '../status_screen.dart';

/// 后台 agent 状态卡:合并的启停/模式按钮 + 最近一轮运行状态与一句话摘要。
class _BackgroundAgentCard extends StatelessWidget {
  final bool enabled;
  final BackgroundStatus status;
  final String summary;

  /// 当前后台运行模式与四态循环回调(关闭 → Legacy → Agentic → Hybrid → 关闭)。
  final BackgroundMode mode;
  final VoidCallback onCycle;
  const _BackgroundAgentCard({
    required this.enabled,
    required this.status,
    required this.summary,
    required this.mode,
    required this.onCycle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = enabled && status == BackgroundStatus.running;
    final label = enabled
        ? backgroundStatusLabel(status)
        : backgroundStatusLabel(BackgroundStatus.disabled);
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 图标、标题/状态与合并按钮固定在同一行;摘要另起一行放在下方。
          Row(
            children: [
              Icon(
                active ? Icons.autorenew : Icons.psychology_outlined,
                color: active
                    ? scheme.primary
                    : (enabled ? scheme.primary : scheme.outline),
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '后台引擎',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: enabled ? scheme.primary : scheme.outline,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _BackgroundEngineButton(
                enabled: enabled,
                mode: mode,
                onPressed: onCycle,
              ),
            ],
          ),
          if (summary.isNotEmpty)
            Padding(
              // 与「模型与参数」里的下拉框同宽:卡片内再缩进 14,
              // 叠加卡片左右 16/8 后,灰块左右边缘与模型选择框对齐。
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              // 成功摘要可能列出本轮全部变更(变量增删改、图片生成中…),
              // 很长时默认折叠到 3 行,需要时再展开;失败等其它状态的
              // 引擎诊断摘要保持全文,便于直接回看错误。
              child: BackgroundSummaryView(text: summary, status: status),
            ),
        ],
      ),
    );
  }
}

/// 后台引擎合并按钮:胶囊同时承载启停与运行模式,点按循环四态
/// 关闭 → Legacy → Agentic → Hybrid → 关闭。
///
/// 胶囊高 32,密度显式取 standard,避免桌面主题默认 compact 再压低;
/// 关闭态转灰并换电源图标,悬停提示说明下一步动作。
class _BackgroundEngineButton extends StatelessWidget {
  final bool enabled;
  final BackgroundMode mode;
  final VoidCallback onPressed;
  const _BackgroundEngineButton({
    required this.enabled,
    required this.mode,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = enabled ? scheme.primary : scheme.onSurfaceVariant;
    final label = enabled ? mode.label : '已关闭';
    final nextAction = switch (mode) {
      BackgroundMode.legacy => '切换到 Agentic',
      BackgroundMode.agentic => '切换到 Hybrid',
      BackgroundMode.hybrid => '关闭后台引擎',
    };
    final tooltip = enabled
        ? '运行模式:${mode.label},${mode.hint};点击$nextAction'
        : '后台引擎已关闭;点击启用 Legacy 模式';
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: ValueKey('background_engine_${enabled ? mode.name : 'off'}'),
        onPressed: onPressed,
        icon: Icon(
          enabled ? Icons.swap_horiz : Icons.power_settings_new,
          size: 18,
        ),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          foregroundColor: foreground,
          iconColor: foreground,
          backgroundColor: foreground.withValues(alpha: enabled ? 0.12 : 0.06),
          side: BorderSide(
            color: foreground.withValues(alpha: enabled ? 0.5 : 0.35),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 后台 agent 设置卡:一张卡承载三个小节(维护功能 / 模型与参数 / 上下文
/// 锚定),小节间用细线分隔,相关控制彼此贴紧。
///
/// 维护功能只有变量与生图 —— 记忆与生图指导由用户主动维护,入口在上方
/// 各自区块,不属于这里的快状态功能。
class _BackgroundFeatureSelector extends ConsumerWidget {
  final BackgroundFeatures features;
  final void Function(String name) onToggle;

  /// 当前后台专用模型(llm_models 的整型 id);null = 跟随主写。
  final int? backgroundModelId;

  /// 用户选择了一个模型(id;null 表示切回"跟随主写")。
  final ValueChanged<int?> onModelSelected;

  /// 当前后台请求的推理强度;与主对话的推理等级互相独立。
  final ReasoningLevel backgroundReasoningLevel;

  /// 用户选择了推理强度。
  final ValueChanged<ReasoningLevel> onReasoningSelected;

  /// 角色卡/记忆是否进入后台上下文锚定段(后台 agent 区开关)。
  final bool characterAnchor;
  final bool memoryAnchor;

  /// 用户切换了锚定段开关([key]:'character' / 'memory')。
  final ValueChanged<String> onAnchorToggle;

  /// 变量删除前确认严格模式。
  final bool deletionConfirm;
  final ValueChanged<bool> onDeletionConfirmChanged;

  /// 当前后台运行模式(Agentic 增强依赖它)。
  final BackgroundMode mode;

  /// Agentic 变量注入主写附件开关。
  final bool variableInjection;
  final ValueChanged<bool> onVariableInjectionChanged;

  /// Agentic 下一步建议开关。
  final bool nextSuggestions;
  final ValueChanged<bool> onNextSuggestionsChanged;

  /// 当前会话所属角色 id(上下文锚定节的「后台世界书条目」按角色取数)。
  final int characterId;

  const _BackgroundFeatureSelector({
    required this.features,
    required this.onToggle,
    required this.backgroundModelId,
    required this.onModelSelected,
    required this.backgroundReasoningLevel,
    required this.onReasoningSelected,
    required this.characterAnchor,
    required this.memoryAnchor,
    required this.onAnchorToggle,
    required this.deletionConfirm,
    required this.onDeletionConfirmChanged,
    required this.mode,
    required this.variableInjection,
    required this.onVariableInjectionChanged,
    required this.nextSuggestions,
    required this.onNextSuggestionsChanged,
    required this.characterId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(llmProvidersProvider);
    final providers = providersAsync.maybeWhen(
      data: (p) => p,
      orElse: () => const <LlmProviderConfig>[],
    );
    final models = flattenLlmModels(providers);
    // 持久化的专用模型可能已被删除(设置页删 provider/模型):此时 value 不在
    // items 里会让 DropdownButton 断言崩溃。落到"跟随主写"并显示兜底;
    // ChatController 侧同样会因 loadConfigForModel 返回 null 而回退主写模型。
    final selected =
        backgroundModelId != null &&
            models.any((m) => m.id == backgroundModelId)
        ? backgroundModelId
        : null;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardSection(context, icon: Icons.tune, title: '维护功能'),
          _feature(
            context,
            name: 'variables',
            label: '变量',
            icon: Icons.data_object,
            value: features.variables,
          ),
          _feature(
            context,
            name: 'image',
            label: '生图',
            icon: Icons.image_outlined,
            value: features.image,
          ),
          SettingsSwitchTile(
            // 严格模式只作用于后台变量删除:标题点明对象,说明全部收进弹层。
            dense: true,
            contentPadding: EdgeInsets.zero,
            icon: Icons.fact_check_outlined,
            iconSize: 20,
            title: '变量删除前确认',
            titleStyle: Theme.of(context).textTheme.bodyMedium,
            titleTrailing: InfoButton(
              onTap: () => showDeletionConfirmHelpDialog(context),
            ),
            value: deletionConfirm,
            onChanged: onDeletionConfirmChanged,
          ),
          _cardDivider(context),
          _cardSection(
            context,
            icon: Icons.auto_awesome,
            title: 'Agentic 增强',
            trailing: InfoButton(
              onTap: () => showAgenticEnhancementsHelpDialog(context),
            ),
          ),
          SettingsSwitchTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            icon: Icons.input,
            iconSize: 20,
            title: '变量注入主写',
            titleStyle: Theme.of(context).textTheme.bodyMedium,
            value: variableInjection,
            enabled: mode == BackgroundMode.agentic && features.variables,
            onChanged: onVariableInjectionChanged,
          ),
          SettingsSwitchTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            icon: Icons.lightbulb_outline,
            iconSize: 20,
            title: '下一步建议',
            titleStyle: Theme.of(context).textTheme.bodyMedium,
            value: nextSuggestions,
            enabled: mode == BackgroundMode.agentic,
            onChanged: onNextSuggestionsChanged,
          ),
          _cardDivider(context),
          _cardSection(context, icon: Icons.memory, title: '模型与参数'),
          const SizedBox(height: 4),
          FormDropdownField<int?>(
            fieldKey: ValueKey(
              'background_model_${backgroundModelId?.toString() ?? 'follow'}',
            ),
            value: selected,
            label: '专用模型',
            helperText: '未选择时跟随主写引擎当前模型。',
            menuMaxHeight: 280,
            items: [null, for (final m in models) m.id],
            labelOf: (id) => id == null
                ? '跟随主写引擎'
                : models.firstWhere((m) => m.id == id).label,
            onChanged: onModelSelected,
          ),
          FormDropdownField<ReasoningLevel>(
            fieldKey: ValueKey(
              'background_reasoning_${backgroundReasoningLevel.name}',
            ),
            value: backgroundReasoningLevel,
            label: '推理强度',
            helperText: '仅影响后台请求,与主对话的推理等级互相独立;默认关闭。',
            items: ReasoningLevel.values,
            labelOf: (level) => level.label,
            onChanged: (level) {
              if (level != null) onReasoningSelected(level);
            },
          ),
          _cardDivider(context),
          _cardSection(context, icon: Icons.link, title: '上下文锚定'),
          _feature(
            context,
            name: 'character',
            label: '角色卡进入上下文',
            icon: Icons.person_outline,
            value: characterAnchor,
            onToggleOverride: onAnchorToggle,
          ),
          _feature(
            context,
            name: 'memory',
            label: '记忆进入上下文',
            icon: Icons.psychology_outlined,
            value: memoryAnchor,
            onToggleOverride: onAnchorToggle,
          ),
          // 后台世界书条目:同属"什么进后台上下文",与上方两开关并列一行。
          _BackgroundWorldbookRow(characterId: characterId),
        ],
      ),
    );
  }

  Widget _feature(
    BuildContext context, {
    required String name,
    required String label,
    required IconData icon,
    required bool value,
    ValueChanged<String>? onToggleOverride,
  }) {
    return SettingsSwitchTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      icon: icon,
      iconSize: 20,
      title: label,
      titleStyle: Theme.of(context).textTheme.bodyMedium,
      value: value,
      onChanged: (_) => (onToggleOverride ?? onToggle)(name),
    );
  }
}

/// 设置卡内的小节头:主色小图标 + 灰底标题,可带行尾说明按钮。
Widget _cardSection(
  BuildContext context, {
  required IconData icon,
  required String title,
  Widget? trailing,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
    child: Row(
      children: [
        Icon(icon, size: 14, color: scheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );
}

/// 设置卡内的细分隔线:hairline 高度,左右缩进与开关行齐。
Widget _cardDivider(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return Divider(
    height: 20,
    thickness: 0.5,
    color: scheme.outlineVariant.withValues(alpha: 0.5),
  );
}

/// 选择进入后台上下文的世界书条目(角色级):多选当前角色的条目,选定的
/// 进快状态轮的锚定段,落 [WorldbookEntry.background] 列;空选 = 不注入
/// 该锚定段。
///
/// 它排在设置卡「上下文锚定」小节的尾行,与角色卡 / 记忆两开关并列 ——
/// 三项同属「什么进后台上下文」这一维度。
class _BackgroundWorldbookRow extends ConsumerWidget {
  final int characterId;
  const _BackgroundWorldbookRow({required this.characterId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries =
        ref.watch(worldbookProvider(characterId)).value ??
        const <WorldbookEntry>[];
    // 生效口径必须与引擎一致:后台锚定段取 `background && enabled`,停用条目勾了也不进
    // 上下文(BackgroundEngine._backgroundWorldbookText 静默过滤,不报错)。这里只把
    // **已选且启用**的条数进「进入后台上下文」的计数,否则用户勾了几条停用条目会看到
    // "已选 4 / 4 条进入后台上下文",而实际进上下文的是 0 条 —— 排查时被带偏。
    final selected = entries.where((e) => e.background).toList();
    final effective = selected.where((e) => e.enabled).length;
    final inert = selected.length - effective;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      dense: true,
      leading: const Icon(Icons.menu_book_outlined, size: 20),
      title: Text('后台世界书条目', style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(
        entries.isEmpty
            ? '该角色暂无世界书条目'
            : '已选 $effective / ${entries.length} 条进入后台上下文'
                  '${inert > 0 ? ' · $inert 条已停用不生效' : ''}',
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
    // 底部弹层(移动端友好):返回选定的 id 集合;取消/下滑关闭返回 null。
    final selected = await showAppSheet<Set<int?>>(
      context,
      builder: (_) => _BackgroundWorldbookSheet(entries),
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

/// 后台世界书条目多选底单:拖拽把手 + 标题 + 取消,圆角顶,高度封顶 85%。
/// 每行 = 勾选圆标 + 名称 + 两行内容预览,行尾箭头展开/收起完整内容
/// (长文内滚);标题行下带实时已选计数与全选/取消全选,底部保存键同样
/// 带计数。
class _BackgroundWorldbookSheet extends StatefulWidget {
  final List<WorldbookEntry> entries;
  const _BackgroundWorldbookSheet(this.entries);

  @override
  State<_BackgroundWorldbookSheet> createState() =>
      _BackgroundWorldbookSheetState();
}

class _BackgroundWorldbookSheetState extends State<_BackgroundWorldbookSheet> {
  late final Set<int?> _selected = {
    for (final e in widget.entries)
      if (e.background) e.id,
  };

  /// 展开完整内容预览的条目(行尾箭头切换)。
  final Set<int?> _expanded = {};

  /// 已勾选但处于停用的条目数:引擎取数 `background && enabled`,这些勾了也不会
  /// 进入后台上下文。选择处当场提示,别让用户带着"勾了就生效"的错觉保存。
  int get _inertSelected => widget.entries
      .where((e) => _selected.contains(e.id) && !e.enabled)
      .length;

  void _toggleSelected(int? id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _toggleExpanded(int? id) => setState(() {
    if (!_expanded.remove(id)) _expanded.add(id);
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.bottomCenter,
      // heightFactor=1:按内容高度收缩,不撑满整屏(与文本编辑底单同款)。
      heightFactor: 1,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHeader(title: '后台世界书条目', closeLabel: '取消'),
                // 实时已选计数 + 全选/取消全选。
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 0, 2),
                  child: Row(
                    children: [
                      Text(
                        '已选 ${_selected.length} / ${widget.entries.length} 条',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Expanded(child: SizedBox.shrink()),
                      TextButton(
                        onPressed: () => setState(
                          () =>
                              _selected.addAll(widget.entries.map((e) => e.id)),
                        ),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: () => setState(_selected.clear),
                        child: const Text('取消全选'),
                      ),
                    ],
                  ),
                ),
                // 勾了停用条目时点明"不会生效"(行内已有红色「已停用」徽章,但徽章
                // 说的是条目状态,这里说的是本次勾选的后果 —— 后者才会被误解成生效)。
                if (_inertSelected > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                    child: Text(
                      '其中 $_inertSelected 条已停用,勾选也不会进入后台上下文',
                      style: text.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: widget.entries.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    itemBuilder: (_, i) {
                      final e = widget.entries[i];
                      final selected = _selected.contains(e.id);
                      final expanded = _expanded.contains(e.id);
                      return Semantics(
                        button: true,
                        checked: selected,
                        child: InkWell(
                          onTap: () => _toggleSelected(e.id),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Icon(
                                    selected
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    size: 22,
                                    color: selected
                                        ? scheme.primary
                                        : scheme.outline,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              e.displayLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: text.bodyLarge,
                                            ),
                                          ),
                                          if (!e.enabled) ...[
                                            const SizedBox(width: 6),
                                            Text(
                                              '已停用',
                                              style: text.labelSmall?.copyWith(
                                                color: scheme.error,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      // 内容预览:默认两行摘要,展开后完整内容内滚。
                                      if (expanded)
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxHeight: 240,
                                          ),
                                          child: SingleChildScrollView(
                                            child: Text(
                                              e.content,
                                              style: text.bodySmall,
                                            ),
                                          ),
                                        )
                                      else
                                        Text(
                                          e.content,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: text.bodySmall?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: expanded ? '收起预览' : '展开预览',
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    expanded
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 20,
                                  ),
                                  onPressed: () => _toggleExpanded(e.id),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, Set<int?>.of(_selected)),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text('保存(${_selected.length})'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
