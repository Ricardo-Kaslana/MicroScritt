/// 制卡对话面板:用户简报、Agent 正文流、工具步 chips、通知/错误与输入框。
///
/// 与聊天页同款气泡外壳;流式正文只让草稿气泡订阅独立 provider,避免每个
/// delta 重建整条对话。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/card_studio_controller.dart';
import '../../state/card_studio_state.dart';
import '../common/app_menu.dart';
import '../common/chat_layout.dart';
import '../common/text_edit_sheet.dart';
import '../model_selector_bar.dart';
import '../text_syntax.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_composer.dart';
import '../widgets/message_bubble.dart';
import '../widgets/rich_message_text.dart';

class CardStudioChatPanel extends ConsumerStatefulWidget {
  /// 输入框焦点(审阅页「继续调整」在桌面端也复用它)。
  final FocusNode composerFocus;

  const CardStudioChatPanel({super.key, required this.composerFocus});

  @override
  ConsumerState<CardStudioChatPanel> createState() => _CardStudioChatPanelState();
}

class _CardStudioChatPanelState extends ConsumerState<CardStudioChatPanel> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();

  /// 当前展开操作排的用户指令(按对象身份跟踪;撤回/重建后自动失效)。
  CardStudioEntry? _selectedEntry;

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _scheduleScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      // 用户上翻阅读时不抢滚动位置;只有接近底部才跟随新内容。
      if (position.maxScrollExtent - position.pixels > 160) return;
      _scroll.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _submit() {
    final state = ref.read(cardStudioControllerProvider);
    if (!state.loaded || state.busy) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final controller = ref.read(cardStudioControllerProvider.notifier);
    if (state.hasProposal) {
      controller.continueAdjust(text);
    } else {
      controller.run(text);
    }
    _input.clear();
  }

  /// 点选用户指令:再次点击同一气泡收起操作排。
  void _toggleEntrySelection(CardStudioEntry entry) {
    final selecting = !identical(_selectedEntry, entry);
    setState(() => _selectedEntry = selecting ? entry : null);
    if (selecting) _scheduleScroll();
  }

  Future<void> _copyEntry(CardStudioEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        width: chatSnackBarWidth(context),
        content: const Text('已复制到剪贴板'),
      ),
    );
  }

  Future<void> _editEntry(int index, CardStudioEntry entry) async {
    final controller = ref.read(cardStudioControllerProvider.notifier);
    // 行内按钮与菜单已按可编辑态置灰,这里兜住点开底单前的状态变化。
    if (controller.instructionEditBlockedReasonFor(index) != null) return;
    // 取消/失败/空结果轮没有实际修改,编辑只是换个说法重跑,不提示撤回。
    final discardsResults = controller.latestTurnProducedChanges;
    final saved = await showTextEditSheet(
      context,
      title: '编辑指令',
      initialText: entry.text,
      hintText: '描述希望 Agent 如何调整…',
      submitLabel: '保存并重新生成',
      description: discardsResults
          ? '将撤回该指令对应的本轮生成结果，并按新内容重新生成；'
              '更早的变更不受影响。'
          : '本轮尚未对角色卡产生实际修改，将直接按新内容重新生成。',
    );
    if (saved == null || !mounted) return;
    final error = await controller.editLastInstruction(saved);
    if (!mounted) return;
    if (error == null) {
      // 撤回会截断该轮条目,选中排随之收起。
      setState(() => _selectedEntry = null);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          width: chatSnackBarWidth(context),
          content: Text(error),
        ),
      );
    }
  }

  /// 选中气泡下方的操作排:复制 / 编辑(不可撤回时置灰并提示原因) / 更多。
  Widget _buildEntryActions(int index, CardStudioEntry entry) {
    final blocked = ref
        .read(cardStudioControllerProvider.notifier)
        .instructionEditBlockedReasonFor(index);
    return _EntryActionsRow(
      onCopy: () => _copyEntry(entry),
      onEdit: blocked == null ? () => _editEntry(index, entry) : null,
      editTooltip: blocked ?? '编辑',
      onMore: () => _showEntryActions(index, entry),
    );
  }

  /// 用户指令长按/右键菜单:复制恒可用;编辑仅最近一条未应用指令可用,
  /// 其余情况置灰并给出原因(与聊天页消息动作单同款)。
  Future<void> _showEntryActions(int index, CardStudioEntry entry) async {
    final blocked = ref
        .read(cardStudioControllerProvider.notifier)
        .instructionEditBlockedReasonFor(index);
    final picked = await showAppActionSheet<_InstructionAction>(
      context,
      actions: [
        const MenuAction(
          value: _InstructionAction.copy,
          label: '复制内容',
          icon: Icons.copy_outlined,
        ),
        MenuAction(
          value: _InstructionAction.edit,
          label: '编辑指令',
          icon: Icons.edit_outlined,
          enabled: blocked == null,
          subtitle: blocked,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case _InstructionAction.copy:
        await _copyEntry(entry);
      case _InstructionAction.edit:
        await _editEntry(index, entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cardStudioControllerProvider);
    ref.listen(
      cardStudioControllerProvider.select((s) => s.entries),
      (_, next) {
        _scheduleScroll();
        // 条目被撤回/重建后旧选中对象已不在列表里,收起操作排。
        final selected = _selectedEntry;
        if (selected != null && !next.contains(selected)) {
          setState(() => _selectedEntry = null);
        }
      },
    );
    ref.listen(cardStudioDraftProvider, (_, __) => _scheduleScroll());
    final selectedIndex =
        _selectedEntry == null ? -1 : state.entries.indexOf(_selectedEntry!);

    final hint = state.phase == CardStudioPhase.preparing
        ? '正在读取角色卡…'
        : state.hasProposal
            ? '继续调整（基于当前草稿）'
            : '描述你想要的角色、世界设定与画面风格…';
    final canType = state.loaded &&
        !state.busy &&
        state.phase != CardStudioPhase.done;
    // 基线加载失败的错误不在对话条目里(不是某轮 Agent 失败),单独补一条,
    // 否则移动端停在对话 Tab 只能看到空态。
    final inlineError = state.error != null &&
        !state.entries.any((e) =>
            e.kind == CardStudioEntryKind.error && e.text == state.error);
    final showEmpty = state.entries.isEmpty &&
        !inlineError &&
        state.phase != CardStudioPhase.running &&
        state.phase != CardStudioPhase.preparing;

    final usage = ContextLink(
      estimateTokens: state.contextEstimateTokens,
      actualInputTokens: state.lastRequestInputTokens,
      cachedInputTokens: state.lastRequestCachedInputTokens,
    );

    // 不再单独铺白色底:对话区与审阅区都跟随脚手架分组底色,移动端顶部
    // 「对话/变更」切换时按钮行不会与白色聊天面板之间夹出一条色差带。
    return Column(
      children: [
        Expanded(
          child: showEmpty
              ? const _ChatEmptyState()
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  children: [
                    if (inlineError)
                      _EntryTile(entry: CardStudioEntry.error(state.error!)),
                    for (var i = 0; i < state.entries.length; i++)
                      _EntryTile(
                        entry: state.entries[i],
                        selected: i == selectedIndex,
                        onTap: state.entries[i].kind == CardStudioEntryKind.user
                            ? () => _toggleEntrySelection(state.entries[i])
                            : null,
                        onLongPress:
                            state.entries[i].kind == CardStudioEntryKind.user
                                ? () => _showEntryActions(i, state.entries[i])
                                : null,
                        actionsRow:
                            i == selectedIndex &&
                                    state.entries[i].kind ==
                                        CardStudioEntryKind.user
                                ? _buildEntryActions(i, state.entries[i])
                                : null,
                      ),
                    if (state.phase == CardStudioPhase.running)
                      const _DraftBubble(),
                  ],
                ),
        ),
        ChatComposer(
          interruptible: state.phase == CardStudioPhase.running,
          inputController: _input,
          inputFocusNode: widget.composerFocus,
          usage: usage,
          hintText: hint,
          showCommands: false,
          enabled: canType,
          onSend: _submit,
          onSubmitted: _submit,
          onInterrupt:
              ref.read(cardStudioControllerProvider.notifier).cancel,
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  final CardStudioEntry entry;

  /// 是否选中(仅用户指令气泡;选中后气泡下方显示操作排)。
  final bool selected;

  /// 点击气泡(用户指令切换选中;其余条目为 null)。
  final VoidCallback? onTap;

  /// 长按/右键回调(仅用户指令气泡提供;null 时不响应)。
  final VoidCallback? onLongPress;

  /// 选中后气泡下方的操作排。
  final Widget? actionsRow;

  const _EntryTile({
    required this.entry,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.actionsRow,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (entry.kind) {
      case CardStudioEntryKind.user:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            GestureDetector(
              onTap: onTap,
              onLongPress: onLongPress,
              // 桌面用鼠标时没有长按,右键(次键点击)同样打开动作单。
              onSecondaryTap: onLongPress,
              behavior: HitTestBehavior.opaque,
              child: Align(
                alignment: Alignment.centerRight,
                child: ChatBubbleFrame(
                  isUser: true,
                  selected: selected,
                  groupStart: true,
                  groupEnd: true,
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: RichMessageText(
                    text: entry.text,
                    style: chatBubbleTextStyle(scheme.onPrimary, bold: true),
                    surface: SyntaxSurface.userBubble,
                    highlightDialogue: false,
                  ),
                ),
              ),
            ),
            if (actionsRow != null) actionsRow!,
          ],
        );
      case CardStudioEntryKind.agent:
        return Align(
          alignment: Alignment.centerLeft,
          child: ChatBubbleFrame(
            isUser: false,
            groupStart: true,
            groupEnd: true,
            constraints: const BoxConstraints(maxWidth: 360),
            child: RichMessageText(
              text: entry.text,
              style: chatBubbleTextStyle(scheme.onSurface),
            ),
          ),
        );
      case CardStudioEntryKind.toolStep:
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xs,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '第 ${entry.step} 步 · ${entry.text}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case CardStudioEntryKind.notice:
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.xs,
          ),
          child: Text(
            entry.text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        );
      case CardStudioEntryKind.error:
        return Container(
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 16, color: scheme.error),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  entry.text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// 选中用户指令后的气泡下操作排(与主聊天页消息操作排同款紧凑图标键)。
class _EntryActionsRow extends StatelessWidget {
  final VoidCallback onCopy;
  final VoidCallback? onEdit;
  final String editTooltip;
  final VoidCallback onMore;

  const _EntryActionsRow({
    required this.onCopy,
    required this.onEdit,
    required this.editTooltip,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button(
              context,
              Icons.copy_outlined,
              '复制',
              onCopy,
              key: const ValueKey('card-studio-action-copy'),
            ),
            _button(
              context,
              Icons.edit_outlined,
              editTooltip,
              onEdit,
              key: const ValueKey('card-studio-action-edit'),
            ),
            _button(
              context,
              Icons.more_horiz,
              '更多操作',
              onMore,
              key: const ValueKey('card-studio-action-more'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _button(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    Key? key,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: key,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      onPressed: onPressed,
      icon: Icon(
        icon,
        color: onPressed == null ? scheme.outline : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// 流式正文气泡:只订阅 [cardStudioDraftProvider],高频 delta 不重建对话。
class _DraftBubble extends ConsumerWidget {
  const _DraftBubble();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(cardStudioDraftProvider);
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: ChatBubbleFrame(
        isUser: false,
        groupStart: true,
        groupEnd: true,
        constraints: const BoxConstraints(maxWidth: 360),
        child: draft.isEmpty
            ? SizedBox(
                width: 72,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                  color: scheme.primary,
                  backgroundColor: scheme.primary.withValues(alpha: 0.15),
                ),
              )
            : RichMessageText(
                text: draft,
                style: chatBubbleTextStyle(scheme.onSurface),
              ),
      ),
    );
  }
}

enum _InstructionAction { copy, edit }

class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 40,
              color: scheme.primary.withValues(alpha: 0.7),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '用一句话描述你的角色',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '例如：「帮我设计一个蒸汽朋克机械师少女，性格嘴硬心软，'
              '再写一座蒸汽城的世界书」\n生成后可在这里逐项审阅、修改并应用。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
