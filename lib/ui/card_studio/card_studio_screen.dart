/// AI 制卡工作台入口:断点分发、移动双 Tab / 桌面双栏、退出防护与完成态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/card_studio_controller.dart';
import '../../state/card_studio_state.dart';
import '../../state/providers.dart';
import '../character_edit_screen.dart';
import '../common/confirm_dialog.dart';
import '../common/section_header.dart';
import '../common/unsaved_changes_guard.dart';
import '../theme/app_theme.dart';
import 'card_review_panel.dart';
import 'card_studio_chat_panel.dart';
import 'card_studio_layout.dart';

class CardStudioScreen extends ConsumerStatefulWidget {
  /// null = 新建;非空 = 优化既有角色卡。
  final int? characterId;

  const CardStudioScreen({super.key, this.characterId});

  @override
  ConsumerState<CardStudioScreen> createState() => _CardStudioScreenState();
}

class _CardStudioScreenState extends ConsumerState<CardStudioScreen> {
  final FocusNode _composerFocus = FocusNode();
  int _tab = 0;

  /// Riverpod 禁止在 State.dispose 里用 ref;提前保存 notifier 供退出清理。
  CardStudioController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(cardStudioControllerProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller?.start(widget.characterId);
    });
  }

  @override
  void dispose() {
    _controller?.detach();
    _composerFocus.dispose();
    super.dispose();
  }

  void _requestAdjust() {
    setState(() => _tab = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  void _continueAfterApply() {
    ref.read(cardStudioControllerProvider.notifier).continueAfterApply();
    _requestAdjust();
  }

  Future<void> _discardDraft() async {
    final state = ref.read(cardStudioControllerProvider);
    if (state.busy || !state.hasSession) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '丢弃当前草稿？',
      message: '未应用的变更与本次制卡对话会被清除，且无法恢复。',
      confirmLabel: '丢弃',
    );
    if (!confirmed || !mounted) return;
    ref.read(cardStudioControllerProvider.notifier).discardDraft();
    setState(() => _tab = 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cardStudioControllerProvider);
    ref.listen(cardStudioControllerProvider, (prev, next) {
      // 移动端:一轮生成完成且有变更时自动切到「变更」Tab。
      if (prev?.phase != next.phase &&
          next.phase == CardStudioPhase.review &&
          next.changeCount > 0 &&
          _tab == 0) {
        setState(() => _tab = 1);
      }
    });
    final persisted = ref.watch(cardStudioDraftFileProvider) != null;
    final busy =
        state.phase == CardStudioPhase.running ||
        state.phase == CardStudioPhase.applying;
    final dirty =
        busy ||
        (!persisted &&
            state.hasProposal &&
            state.phase != CardStudioPhase.done);
    final title = state.targetName.isEmpty
        ? 'AI 制卡'
        : 'AI 制卡 · ${state.targetName}';
    final wide =
        MediaQuery.sizeOf(context).width >= kCardStudioDesktopBreakpoint;

    return UnsavedChangesGuard(
      hasChanges: () => dirty,
      title: busy ? '中断当前操作？' : '放弃本次制卡？',
      message: busy ? '退出会中断正在进行的生成或保存。' : '退出后，未应用的草稿与修改不会保存。',
      confirmLabel: busy ? '中断并退出' : '放弃草稿',
      child: Scaffold(
        appBar: AppBar(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (state.phase == CardStudioPhase.running)
              IconButton(
                tooltip: '停止',
                icon: const Icon(Icons.stop_rounded),
                onPressed: ref
                    .read(cardStudioControllerProvider.notifier)
                    .cancel,
              ),
            if (state.hasSession &&
                !state.busy &&
                state.phase != CardStudioPhase.done)
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  if (value == 'discard') _discardDraft();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'discard', child: Text('丢弃当前草稿')),
                ],
              ),
          ],
        ),
        body: _buildBody(state, wide),
      ),
    );
  }

  Widget _buildBody(CardStudioState state, bool wide) {
    if (state.phase == CardStudioPhase.preparing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.phase == CardStudioPhase.done &&
        state.appliedCharacterId != null) {
      return _DoneView(
        characterId: state.appliedCharacterId!,
        name: state.draftCard?.name ?? state.targetName,
        onContinue: _continueAfterApply,
      );
    }
    if (wide) {
      return _desktop(state);
    }
    return _mobile(state);
  }

  Widget _desktop(CardStudioState state) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: kCardStudioChatWidth,
          child: CardStudioChatPanel(composerFocus: _composerFocus),
        ),
        VerticalDivider(
          width: 0.5,
          thickness: 0.5,
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: kCardStudioReviewMaxWidth,
              ),
              child: CardReviewPanel(
                onRequestAdjust: () => _composerFocus.requestFocus(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _mobile(CardStudioState state) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(
                value: 0,
                icon: Icon(Icons.chat_bubble_outline, size: 16),
                label: Text('对话'),
              ),
              ButtonSegment(
                value: 1,
                icon: const Icon(Icons.difference_outlined, size: 16),
                label: Text(
                  state.changeCount > 0 ? '变更 (${state.changeCount})' : '变更',
                ),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (selection) =>
                setState(() => _tab = selection.first),
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              CardStudioChatPanel(composerFocus: _composerFocus),
              CardReviewPanel(onRequestAdjust: _requestAdjust),
            ],
          ),
        ),
      ],
    );
  }
}

class _DoneView extends StatelessWidget {
  final int characterId;
  final String name;
  final VoidCallback onContinue;
  const _DoneView({
    required this.characterId,
    required this.name,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final backButton = OutlinedButton(
      onPressed: () => Navigator.pop(context),
      child: const Text('返回列表'),
    );
    final continueButton = FilledButton.tonal(
      onPressed: onContinue,
      child: const Text('继续打磨'),
    );
    final openButton = FilledButton(
      onPressed: () => Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => CharacterEditScreen(characterId: characterId),
        ),
      ),
      child: const Text('打开角色卡'),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SurfaceCard(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 48,
                  color: scheme.primary,
                ),
                const SizedBox(height: AppSpacing.md),
                Text('已应用到角色卡', style: Theme.of(context).textTheme.titleMedium),
                if (name.trim().isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                // 保留按钮原有尺寸比例;空间不足时整组缩小,不换行、不改排列。
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      backButton,
                      const SizedBox(width: AppSpacing.sm),
                      continueButton,
                      const SizedBox(width: AppSpacing.sm),
                      openButton,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
