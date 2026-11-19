/// 制卡审阅面板:头像 before/after、角色卡字段 diff、世界书条目 diff、
/// 逐项接受/拒绝/内联编辑与底部应用栏。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/image_codec.dart';
import '../../engine/card_studio/card_diff.dart';
import '../../models/worldbook_entry.dart';
import '../../state/card_studio_controller.dart';
import '../../state/card_studio_state.dart';
import '../../state/providers.dart';
import '../common/confirm_dialog.dart';
import '../common/section_header.dart';
import '../common/text_edit_sheet.dart';
import '../theme/app_theme.dart';
import '../widgets/image_viewer.dart';
import 'card_preview_sheet.dart';
import 'card_studio_layout.dart';
import 'diff_text_view.dart';

class CardReviewPanel extends ConsumerWidget {
  /// 「继续调整」:移动端切回对话 Tab,桌面端聚焦输入框。
  final VoidCallback onRequestAdjust;

  const CardReviewPanel({super.key, required this.onRequestAdjust});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cardStudioControllerProvider);
    if (!state.hasProposal) return _NoProposal(state: state);
    final diff = state.diff!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kCardStudioReviewPadding),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: AppSpacing.lg),
              children: [
                if (state.phase == CardStudioPhase.failed &&
                    state.error != null) ...[
                  _Banner(text: state.error!, isError: true),
                  const SizedBox(height: AppSpacing.md),
                ],
                _SummaryCard(state: state, diff: diff),
                if (diff.avatar != null || state.draftAvatarPrompt != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  const SectionHeader('角色卡头像', icon: Icons.image_outlined),
                  _AvatarCard(state: state, avatars: diff.avatar),
                ],
                if (diff.fields.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xl),
                  SectionHeader(
                    '角色卡 · ${diff.fields.length} 项修改',
                    icon: Icons.badge_outlined,
                  ),
                  for (final field in diff.fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _FieldCard(field: field),
                    ),
                ],
                if (diff.entries.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xl),
                  SectionHeader(
                    '世界书 · ${_entrySummary(diff.entries)}',
                    icon: Icons.menu_book_outlined,
                  ),
                  for (final entry in diff.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: _EntryCard(diff: entry),
                    ),
                ],
                if (!diff.hasChanges) ...[
                  const SizedBox(height: AppSpacing.lg),
                  const _Banner(text: '本轮没有产生变更。可以继续在对话里描述你想调整的内容。'),
                ],
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
          _ApplyBar(state: state, onRequestAdjust: onRequestAdjust),
        ],
      ),
    );
  }
}

String _entrySummary(List<WorldbookEntryDiff> entries) {
  var added = 0, modified = 0, removed = 0;
  for (final e in entries) {
    switch (e.kind) {
      case WorldbookChangeKind.added:
        added++;
      case WorldbookChangeKind.modified:
        modified++;
      case WorldbookChangeKind.removed:
        removed++;
    }
  }
  return [
    if (added > 0) '新增 $added',
    if (modified > 0) '修改 $modified',
    if (removed > 0) '删除 $removed',
  ].join(' · ');
}

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
                    if (decision.editedText != null) ...[
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

  static const Color _added = Color(0xFF2E7D32);

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
      WorldbookChangeKind.added => (Icons.add_circle_outline, _added, '新增'),
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
    final result = await showModalBottomSheet<WorldbookEntry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
    final oldAvatar = widget.avatars?.oldBase64 ?? state.baseCard.avatarBase64;
    final newAvatar = state.draftCard?.avatarBase64;
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
                    base64: current,
                    size: currentSize,
                    busy: generating,
                    previewKey: const ValueKey('card_avatar_preview_current'),
                  ),
                );
              }
              final tiles = [
                _AvatarTile(
                  label: '原头像',
                  base64: oldAvatar,
                  size: size,
                  previewKey: const ValueKey('card_avatar_preview_old'),
                ),
                _AvatarTile(
                  label: '新头像',
                  base64: newAvatar,
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
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
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

class _AvatarTile extends StatelessWidget {
  final String label;
  final String? base64;
  final bool busy;

  /// 正方形边长(由审阅区宽度推导)。
  final double size;

  /// 可点击预览时的稳定 key(widget 测试定位用)。
  final Key? previewKey;
  const _AvatarTile({
    required this.label,
    required this.size,
    this.base64,
    this.busy = false,
    this.previewKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = safeBase64Decode(base64);
    final tile = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        height: size,
        child: busy
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : bytes == null
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.person_outline,
                  color: scheme.onSurfaceVariant,
                  size: 32,
                ),
              )
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
    final withPreview = bytes == null || busy
        ? tile
        : Tooltip(
            message: '查看头像大图',
            child: InkWell(
              key: previewKey,
              borderRadius: BorderRadius.circular(12),
              onTap: () => showImageFullscreen(context, bytes: bytes),
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
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
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
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('常驻（无需关键词）'),
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
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('选择性触发'),
                    subtitle: const Text('主关键词与次关键词各命中一个才触发'),
                    value: _selective,
                    onChanged: (v) => setState(() => _selective = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用'),
                    subtitle: const Text('停用后条目不参与触发'),
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('后台锚定'),
                    subtitle: const Text('作为后台维护的固定上下文条目'),
                    value: _background,
                    onChanged: (v) => setState(() => _background = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('正则匹配'),
                    subtitle: const Text('关键词按 Dart 正则解释'),
                    value: _useRegex,
                    onChanged: (v) => setState(() => _useRegex = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('区分大小写'),
                    value: _caseSensitive,
                    onChanged: (v) => setState(() => _caseSensitive = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('整词匹配'),
                    subtitle: const Text('仅对纯 ASCII 词键生效'),
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
