/// 制卡审阅面板:头像 before/after、角色卡字段 diff、世界书条目 diff、
/// 逐项接受/拒绝/内联编辑与底部应用栏。
///
/// 页面组装留在本文件;diff 展示卡与应用面按同库 part 拆在同目录。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../engine/card_studio/card_diff.dart';
import '../../models/worldbook_entry.dart';
import '../../state/card_studio_controller.dart';
import '../../state/card_studio_state.dart';
import '../../state/providers.dart';
import '../common/app_sheet.dart';
import '../common/confirm_dialog.dart';
import '../common/diff_colors.dart';
import '../common/form_row.dart';
import '../common/hash_image.dart';
import '../common/inline_spinner.dart';
import '../common/list_edit_sheet.dart';
import '../common/section_header.dart';
import '../common/text_edit_sheet.dart';
import '../theme/app_theme.dart';
import '../widgets/image_viewer.dart';
import 'card_preview_sheet.dart';
import 'card_studio_layout.dart';
import 'diff_text_view.dart';

part 'card_review_cards.dart';
part 'card_review_actions.dart';

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
