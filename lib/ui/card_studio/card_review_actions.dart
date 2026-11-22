/// 制卡审阅的操作面:逐项决策应用栏、审阅预览入口与条目内联编辑底单。

part of 'card_review_panel.dart';

class _ApplyBar extends ConsumerWidget {
  final CardStudioState state;
  final VoidCallback onRequestAdjust;
  const _ApplyBar({required this.state, required this.onRequestAdjust});

  void _setAll(WidgetRef ref, bool accepted) {
    final diff = state.diff;
    if (diff == null) return;
    final controller = ref.read(cardStudioControllerProvider.notifier);
    for (final field in diff.fields) {
      controller.toggleField(field.key, accepted);
    }
    for (final entry in diff.entries) {
      controller.toggleEntry(entry.reviewKey, accepted);
    }
    if (diff.avatar?.hasChange ?? false) controller.toggleAvatar(accepted);
  }

  Future<void> _apply(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(cardStudioControllerProvider.notifier);
    final ok = await controller.apply();
    if (ok || !context.mounted) return;
    final conflict = ref.read(cardStudioControllerProvider).conflictWarning;
    if (conflict == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '角色卡已被修改',
      message: '$conflict\n\n继续应用会覆盖其他页面的修改。',
      confirmLabel: '覆盖并应用',
    );
    if (!confirmed || !context.mounted) return;
    controller.clearConflict();
    await controller.apply(force: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final diff = state.diff;
    final generating = state.avatarStatus == CardStudioAvatarStatus.generating;
    final accepted = state.acceptedChangeCount;
    final applyLabel = state.applyErrors.isNotEmpty
        ? '重试应用'
        : '应用变更 ($accepted)';
    final applyButton = FilledButton(
      onPressed: state.canApply ? () => _apply(context, ref) : null,
      child: Text(applyLabel),
    );
    final tail = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (generating) ...[
          const InlineSpinner(size: 14),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '头像生成中…',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: AppSpacing.md),
        ],
        OutlinedButton(
          onPressed: state.busy ? null : onRequestAdjust,
          child: const Text('继续调整'),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.applyErrors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                state.applyErrors.join('\n'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          if (diff != null && diff.changeCount > 0 && accepted == 0)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                '尚未接受任何变更。请打开至少一项，或点击「全部接受」。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => _setAll(ref, true),
                            child: const Text('全部接受'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: TextButton(
                            onPressed: () => _setAll(ref, false),
                            child: const Text('全部拒绝'),
                          ),
                        ),
                      ],
                    ),
                    if (generating)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const InlineSpinner(size: 14),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              '头像生成中…',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: state.busy ? null : onRequestAdjust,
                            child: const Text('继续调整'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: applyButton),
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  TextButton(
                    onPressed: () => _setAll(ref, true),
                    child: const Text('全部接受'),
                  ),
                  TextButton(
                    onPressed: () => _setAll(ref, false),
                    child: const Text('全部拒绝'),
                  ),
                  const Spacer(),
                  tail,
                  const SizedBox(width: AppSpacing.sm),
                  applyButton,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _EntryEditSheet extends StatefulWidget {
  final WorldbookEntry entry;
  const _EntryEditSheet({required this.entry});

  @override
  State<_EntryEditSheet> createState() => _EntryEditSheetState();
}

class _EntryEditSheetState extends State<_EntryEditSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.entry.name,
  );
  late final TextEditingController _keys = TextEditingController(
    text: widget.entry.keys.join(', '),
  );
  late final TextEditingController _secondaryKeys = TextEditingController(
    text: widget.entry.secondaryKeys.join(', '),
  );
  late final TextEditingController _content = TextEditingController(
    text: widget.entry.content,
  );
  late bool _constant = widget.entry.constant;
  late bool _enabled = widget.entry.enabled;
  late bool _background = widget.entry.background;
  late bool _selective = widget.entry.selective;
  late bool _useRegex = widget.entry.useRegex;
  late bool _caseSensitive = widget.entry.caseSensitive;
  late bool _matchWholeWords = widget.entry.matchWholeWords;

  @override
  void dispose() {
    _name.dispose();
    _keys.dispose();
    _secondaryKeys.dispose();
    _content.dispose();
    super.dispose();
  }

  static List<String> _parseKeys(String text) => text
      .split(RegExp(r'[,，\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> get _parsedKeys => _parseKeys(_keys.text);

  List<String> get _parsedSecondaryKeys => _parseKeys(_secondaryKeys.text);

  bool get _valid =>
      _content.text.trim().isNotEmpty && (_parsedKeys.isNotEmpty || _constant);

  void _save() {
    final updated = widget.entry.copyWith(
      name: _name.text.trim(),
      keys: _parsedKeys,
      secondaryKeys: _parsedSecondaryKeys,
      content: _content.text,
      constant: _constant,
      enabled: _enabled,
      background: _background,
      selective: _selective,
      useRegex: _useRegex,
      caseSensitive: _caseSensitive,
      matchWholeWords: _matchWholeWords,
    );
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '编辑世界书条目',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _valid ? _save : null,
                  child: const Text('保存'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '列表显示名（留空时用首关键词）',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _keys,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '关键词（逗号分隔）'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _secondaryKeys,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '次关键词（逗号分隔）',
                helperText: '仅在「选择性触发」启用时参与判定',
              ),
            ),
            if (_selective && _parsedSecondaryKeys.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  '已启用选择性触发但没有次关键词，条目可能无法命中。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _content,
              minLines: 6,
              maxLines: 12,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '内容 *'),
            ),
            SettingsSwitchTile(
              contentPadding: EdgeInsets.zero,
              title: '常驻（无需关键词）',
              value: _constant,
              onChanged: (v) => setState(() => _constant = v),
            ),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  '高级选项',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                children: [
                  SettingsSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: '选择性触发',
                    description: '主关键词与次关键词各命中一个才触发',
                    value: _selective,
                    onChanged: (v) => setState(() => _selective = v),
                  ),
                  SettingsSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: '启用',
                    description: '停用后条目不参与触发',
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                  SettingsSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: '后台锚定',
                    description: '作为后台维护的固定上下文条目',
                    value: _background,
                    onChanged: (v) => setState(() => _background = v),
                  ),
                  SettingsSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: '正则匹配',
                    description: '关键词按 Dart 正则解释',
                    value: _useRegex,
                    onChanged: (v) => setState(() => _useRegex = v),
                  ),
                  SettingsSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: '区分大小写',
                    value: _caseSensitive,
                    onChanged: (v) => setState(() => _caseSensitive = v),
                  ),
                  SettingsSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: '整词匹配',
                    description: '仅对纯 ASCII 词键生效',
                    value: _matchWholeWords,
                    onChanged: (v) => setState(() => _matchWholeWords = v),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
