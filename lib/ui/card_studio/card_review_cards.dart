/// 制卡审阅的展示卡:空提案、摘要、字段/条目 diff、头像前后对照与徽标。

part of 'card_review_panel.dart';

class _NoProposal extends StatelessWidget {
  final CardStudioState state;
  const _NoProposal({required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, title, message) = switch (state.phase) {
      CardStudioPhase.preparing => (
        Icons.hourglass_empty_rounded,
        '正在读取角色卡…',
        '读取完成后即可开始生成。',
      ),
      CardStudioPhase.running => (
        Icons.auto_awesome,
        'Agent 正在构思…',
        '生成完成后，角色卡、世界书与头像的变更会以 diff 形式出现在这里。',
      ),
      CardStudioPhase.failed => (
        Icons.error_outline_rounded,
        '暂时无法开始',
        state.error ?? '发生未知错误。',
      ),
      _ => (
        Icons.difference_outlined,
        '变更预览会出现在这里',
        '先在左侧描述你的想法，Agent 会生成可逐项审阅与修改的草稿。',
      ),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 42,
                color: scheme.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final CardStudioState state;
  final CardDiff diff;
  const _SummaryCard({required this.state, required this.diff});

  void _openPreview(BuildContext context) {
    final draftCard = state.draftCard;
    final draftEntries = state.draftEntries;
    if (draftCard == null || draftEntries == null) return;
    final submission = buildCardSubmission(
      baseCard: state.baseCard,
      baseEntries: state.baseEntries,
      draftCard: draftCard,
      draftEntries: draftEntries,
      decisions: state.decisions,
    );
    showCardPreview(
      context,
      card: submission.card,
      entries: submission.entries,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 320 级窄屏放不下计数徽标;接受数由底部应用栏兜底,优先保住标题。
          final showCount = constraints.maxWidth >= 250;
          return Row(
            children: [
              Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.targetName.isEmpty ? '新角色卡' : state.targetName,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (state.lastSummary != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          state.lastSummary!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                tooltip: '预览最终卡',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.visibility_outlined, size: 20),
                onPressed: () => _openPreview(context),
              ),
              if (showCount)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '接受 ${state.acceptedChangeCount} / 共 ${diff.changeCount} 项',
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: scheme.primary),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final bool isError;
  const _Banner({required this.text, this.isError = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldCard extends ConsumerWidget {
  final FieldDiff field;
  const _FieldCard({required this.field});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cardStudioControllerProvider);
    final decision = state.decisions.field(field.key);
    final scheme = Theme.of(context).colorScheme;
    final displayDiff = effectiveFieldDiff(field, decision);
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        field.label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (decision.editedText != null ||
                        decision.editedList != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      _Badge(text: '已手动修改', color: scheme.tertiary),
                    ],
                  ],
                ),
              ),
              Switch.adaptive(
                value: decision.accepted,
                onChanged: (v) => ref
                    .read(cardStudioControllerProvider.notifier)
                    .toggleField(field.key, v),
              ),
              IconButton(
                tooltip: '编辑',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _edit(context, ref, decision),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (displayDiff == null)
            Text(
              '与原文一致，应用时不会写入该项。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            )
          else
            Opacity(
              opacity: decision.accepted ? 1 : 0.45,
              child: DiffTextView(diff: displayDiff),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    FieldDecision decision,
  ) async {
    if (field.key == 'alternateGreetings' || field.key == 'tags') {
      final state = ref.read(cardStudioControllerProvider);
      final draft = state.draftCard;
      final isGreetings = field.key == 'alternateGreetings';
      final initial =
          decision.editedList ??
          (isGreetings ? draft?.alternateGreetings : draft?.tags) ??
          field.newText.split('\n');
      final values = await showListEditSheet(
        context,
        title: '编辑「${field.label}」',
        initialValues: initial,
        hintText: isGreetings ? '输入一条备用开场白…' : '输入一个标签…',
        description: '逐条编辑，每条内容原样保存，不会按换行或逗号拆分。',
        multiline: isGreetings,
      );
      if (values == null || !context.mounted) return;
      ref
          .read(cardStudioControllerProvider.notifier)
          .editListField(field.key, values);
      return;
    }
    // 移动端居中弹窗随键盘收缩后只剩几行可编辑区;改用底部编辑底单,
    // 随软键盘抬升且高度充裕,与消息/记忆编辑一致。
    final text = await showTextEditSheet(
      context,
      title: '编辑「${field.label}」',
      initialText: decision.editedText ?? field.newText,
      hintText: '输入新的${field.label}内容…',
      description: '修改后视为接受该字段，应用时使用你填写的文本。',
      // 角色卡字段常见长文,与记忆编辑同级的高度。
      editorHeightFactor: 0.7,
      maxEditorHeight: 620,
      // 显式清空字段(如删掉不需要的备注)是合法操作。
      allowEmpty: true,
    );
    if (text == null || !context.mounted) return;
    ref.read(cardStudioControllerProvider.notifier).editField(field.key, text);
  }
}

class _EntryCard extends ConsumerWidget {
  final WorldbookEntryDiff diff;
  const _EntryCard({required this.diff});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cardStudioControllerProvider);
    final decision = state.decisions.entry(diff.reviewKey);
    final scheme = Theme.of(context).colorScheme;
    final shownEntry = effectiveEntryValue(diff, decision);
    final shownDiffs = effectiveEntryFieldDiffs(diff, decision);
    FieldDiff? shownContent;
    for (final f in shownDiffs) {
      if (f.key == 'content') {
        shownContent = f;
        break;
      }
    }
    final displayName =
        shownEntry?.displayLabel ?? diff.oldEntry?.displayLabel ?? '(未命名条目)';
    final (icon, color, label) = switch (diff.kind) {
      WorldbookChangeKind.added => (
        Icons.add_circle_outline,
        DiffColors.added(scheme),
        '新增',
      ),
      WorldbookChangeKind.modified => (Icons.edit_note, scheme.primary, '修改'),
      WorldbookChangeKind.removed => (Icons.delete_outline, scheme.error, '删除'),
    };
    final enabledEdit =
        diff.kind != WorldbookChangeKind.removed && shownEntry != null;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: diff.kind == WorldbookChangeKind.added,
          tilePadding: const EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.sm,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          title: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$label · $displayName',
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _subtitle(diff, shownEntry, shownDiffs),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (decision.editedEntry != null)
                _Badge(text: '已修改', color: scheme.tertiary),
              Switch.adaptive(
                value: decision.accepted,
                onChanged: (v) => ref
                    .read(cardStudioControllerProvider.notifier)
                    .toggleEntry(diff.reviewKey, v),
              ),
            ],
          ),
          children: [
            Opacity(
              opacity: decision.accepted ? 1 : 0.45,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 新增/删除条目只在标题里展示元信息,正文 diff 已足够;
                  // 修改条目才逐项列出变化的元字段。
                  if (diff.kind == WorldbookChangeKind.modified)
                    for (final f in shownDiffs)
                      if (f.key != 'content')
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                          child: Text(
                            '${f.label}：${_short(f.oldText)} → ${_short(f.newText)}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                  if (shownContent != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: DiffTextView(diff: shownContent.diff),
                    )
                  else if (diff.kind != WorldbookChangeKind.removed)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(
                        '与原文一致，应用时不会写入该条目。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (enabledEdit)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _editEntry(context, ref, decision),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('编辑条目'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editEntry(
    BuildContext context,
    WidgetRef ref,
    EntryDecision decision,
  ) async {
    final base = decision.editedEntry ?? diff.newEntry ?? diff.oldEntry;
    if (base == null) return;
    final result = await showAppSheet<WorldbookEntry>(
      context,
      builder: (_) => _EntryEditSheet(entry: base),
    );
    if (result == null || !context.mounted) return;
    ref
        .read(cardStudioControllerProvider.notifier)
        .editEntry(diff.reviewKey, result);
  }

  static String _subtitle(
    WorldbookEntryDiff diff,
    WorldbookEntry? shownEntry,
    List<FieldDiff> shownDiffs,
  ) {
    if (diff.kind == WorldbookChangeKind.removed) return '删除该条目';
    final keys = shownEntry?.keys ?? const <String>[];
    final keyText = keys.isEmpty ? '常驻' : keys.take(4).join(', ');
    if (diff.kind == WorldbookChangeKind.added) return '关键词：$keyText';
    final changed = shownDiffs.map((f) => f.label).join('、');
    return changed.isEmpty ? '与原文一致' : '改动：$changed';
  }

  static String _short(String text) {
    final oneLine = text.replaceAll('\n', ' ');
    return oneLine.length <= 24 ? oneLine : '${oneLine.substring(0, 24)}…';
  }
}

class _AvatarCard extends ConsumerStatefulWidget {
  final CardStudioState state;
  final AvatarDiff? avatars;
  const _AvatarCard({required this.state, required this.avatars});

  @override
  ConsumerState<_AvatarCard> createState() => _AvatarCardState();
}

class _AvatarCardState extends ConsumerState<_AvatarCard> {
  /// 头像格边长:随审阅区宽度伸缩,双图并排仍保持可对比的大小。
  static const double _minTileSize = 96;
  static const double _maxTileSize = 200;

  /// 并排布局中方向图标与左右留白占用的宽度。
  static const double _connectorSpace = AppSpacing.lg * 2 + 20;

  late final TextEditingController _prompt;
  final FocusNode _promptFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController(text: widget.state.draftAvatarPrompt ?? '');
  }

  @override
  void didUpdateWidget(covariant _AvatarCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.state.draftAvatarPrompt ?? '';
    if (!_promptFocus.hasFocus && _prompt.text != next) {
      _prompt.text = next;
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final imageReady = ref.watch(imageBackendProvider) != null;
    final generating = state.avatarStatus == CardStudioAvatarStatus.generating;
    final oldAvatar = widget.avatars?.oldHash ?? state.baseCard.avatarHash;
    final newAvatar = state.draftCard?.avatarHash;
    final hasChange = widget.avatars?.hasChange ?? false;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('头像预览', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              if (hasChange)
                Switch.adaptive(
                  value: state.decisions.avatarAccepted,
                  onChanged: (v) => ref
                      .read(cardStudioControllerProvider.notifier)
                      .toggleAvatar(v),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final stacked = width < _minTileSize * 2 + _connectorSpace;
              final size = stacked
                  ? (width < _maxTileSize ? width : _maxTileSize)
                  : ((width - _connectorSpace) / 2)
                        .clamp(_minTileSize, _maxTileSize)
                        .toDouble();
              // 无头像变更时不能硬凑 before/after:应用后续轮会保留提示词,
              // 但草稿头像与基线相同,两格会显示同一张图并误导成"更新了"。
              if (!hasChange) {
                final current = oldAvatar ?? newAvatar;
                final currentSize = width < _maxTileSize ? width : _maxTileSize;
                return Center(
                  child: _AvatarTile(
                    label: current == null ? '暂无头像' : '当前头像',
                    hash: current,
                    size: currentSize,
                    busy: generating,
                    previewKey: const ValueKey('card_avatar_preview_current'),
                  ),
                );
              }
              final tiles = [
                _AvatarTile(
                  label: '原头像',
                  hash: oldAvatar,
                  size: size,
                  previewKey: const ValueKey('card_avatar_preview_old'),
                ),
                _AvatarTile(
                  label: '新头像',
                  hash: newAvatar,
                  size: size,
                  busy: generating,
                  previewKey: const ValueKey('card_avatar_preview_new'),
                ),
              ];
              if (stacked) {
                return Column(
                  children: [
                    tiles[0],
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Icon(Icons.south_rounded, size: 18),
                    ),
                    tiles[1],
                  ],
                );
              }
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  tiles[0],
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    child: Icon(Icons.arrow_forward_rounded, size: 20),
                  ),
                  tiles[1],
                ],
              );
            },
          ),
          if (state.avatarStatus == CardStudioAvatarStatus.failed &&
              state.avatarError != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              state.avatarError!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _prompt,
            focusNode: _promptFocus,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '头像提示词（英文 tag）',
              hintText:
                  '1girl, red hair, mechanic jacket, steampunk city, upper body',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              if (!imageReady)
                Expanded(
                  child: Text(
                    '未配置生图后端，无法生成头像。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                const Spacer(),
              TextButton.icon(
                onPressed: generating || !imageReady
                    ? null
                    : () => ref
                          .read(cardStudioControllerProvider.notifier)
                          .regenerateAvatar(_prompt.text),
                icon: generating
                    ? const InlineSpinner(size: 14)
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(generating ? '生成中…' : '按提示词重新生成'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvatarTile extends ConsumerWidget {
  final String label;
  final String? hash;
  final bool busy;

  /// 正方形边长(由审阅区宽度推导)。
  final double size;

  /// 可点击预览时的稳定 key(widget 测试定位用)。
  final Key? previewKey;
  const _AvatarTile({
    required this.label,
    required this.size,
    this.hash,
    this.busy = false,
    this.previewKey,
  });

  Future<void> _openFullscreen(BuildContext context, AppDatabase db) async {
    final assetHash = hash;
    if (assetHash == null) return;
    await showImageFullscreen(context, file: db.images.fileFor(assetHash));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final db = ref.read(databaseProvider);
    final assetHash = hash;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.person_outline,
        color: scheme.onSurfaceVariant,
        size: 32,
      ),
    );
    final image = assetHash == null
        ? null
        : hashImageProvider(db.images, assetHash, cacheWidth: kCardImageWidth);
    final tile = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        height: size,
        child: busy
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: const Center(child: InlineSpinner(size: 20)),
              )
            : image == null
            ? placeholder
            : Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => placeholder,
              ),
      ),
    );
    final withPreview = assetHash == null || busy
        ? tile
        : Tooltip(
            message: '查看头像大图',
            child: InkWell(
              key: previewKey,
              borderRadius: BorderRadius.circular(12),
              onTap: () => _openFullscreen(context, db),
              child: Stack(
                children: [
                  tile,
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.zoom_out_map_rounded,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        withPreview,
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
