/// 最终卡预览:按当前审阅决策合成的只读角色卡。
///
/// 与 diff 卡不同,这里展示的是「应用后真正会是什么样」。身份与内容分区呈现:
/// 宽窗使用固定名片侧栏 + 独立滚动正文,窄窗收为顶部名片,所有字段保持可选择。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/character_card.dart';
import '../../models/worldbook_entry.dart';
import '../../state/providers.dart';
import '../common/app_sheet.dart';
import '../common/hash_image.dart';
import '../common/section_header.dart';
import '../theme/app_theme.dart';

/// 打开最终卡只读预览;卡片与世界书必须已由当前审阅决策合成。
Future<void> showCardPreview(
  BuildContext context, {
  required CharacterCard card,
  required List<WorldbookEntry> entries,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    maxWidth: 1040,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.94,
      child: CardPreviewSheet(card: card, entries: entries),
    ),
  );
}

/// 最终卡预览主体;不持有编辑状态,也不会修改角色卡。
class CardPreviewSheet extends StatelessWidget {
  final CharacterCard card;
  final List<WorldbookEntry> entries;

  const CardPreviewSheet({
    super.key,
    required this.card,
    required this.entries,
  });

  static const double _sidebarMinWidth = 800;

  @override
  Widget build(BuildContext context) {
    final name = card.name.trim().isEmpty ? '未命名角色' : card.name.trim();
    final tags = [
      for (final tag in card.tags)
        if (tag.trim().isNotEmpty) tag.trim(),
    ];
    final avatar = card.avatarHash;
    final basics = <(String, String)>[
      if (card.description.trim().isNotEmpty) ('描述', card.description),
      if (card.personality.trim().isNotEmpty) ('性格', card.personality),
      if (card.scenario.trim().isNotEmpty) ('场景', card.scenario),
    ];
    final greetings = <(String, String)>[
      if (card.firstMessage.trim().isNotEmpty) ('开场白', card.firstMessage),
      for (final (index, text) in card.alternateGreetings.indexed)
        if (text.trim().isNotEmpty) ('备用开场白 ${index + 1}', text),
    ];
    final advanced = <(String, String)>[
      if (card.mesExample.trim().isNotEmpty) ('对话示例', card.mesExample),
      if (card.systemPrompt.trim().isNotEmpty) ('系统提示词', card.systemPrompt),
      if (card.postHistoryInstructions.trim().isNotEmpty)
        ('历史后指令', card.postHistoryInstructions),
      if (card.depthPrompt.trim().isNotEmpty) ('深度提示', card.depthPrompt),
      if (card.creatorNotes.trim().isNotEmpty) ('作者备注', card.creatorNotes),
      if (card.creator.trim().isNotEmpty) ('作者', card.creator),
      if (card.characterVersion.trim().isNotEmpty)
        ('版本', card.characterVersion),
    ];

    final content = _PreviewContent(
      basics: basics,
      greetings: greetings,
      advanced: advanced,
      entries: entries,
    );
    Widget identity({required bool compact}) => _IdentityCard(
      name: name,
      tags: tags,
      avatar: avatar,
      entryCount: entries.length,
      greetingCount: greetings.length,
      compact: compact,
    );

    return Column(
      children: [
        const _PreviewAppBar(),
        Divider(
          height: 0.5,
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        Expanded(
          child: SelectionArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= _sidebarMinWidth) {
                  return Row(
                    children: [
                      Container(
                        width: 280,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          border: Border(
                            right: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant
                                  .withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                        child: SingleChildScrollView(
                          key: const ValueKey('card_preview_identity_sidebar'),
                          padding: const EdgeInsets.all(AppSpacing.xl),
                          child: identity(compact: false),
                        ),
                      ),
                      Expanded(
                        child: _PreviewScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [content, const _PreviewFootnote()],
                          ),
                        ),
                      ),
                    ],
                  );
                }
                return _PreviewScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SurfaceCard(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: identity(compact: true),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      content,
                      const _PreviewFootnote(),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewAppBar extends StatelessWidget {
  const _PreviewAppBar();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 16,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              '最终卡预览',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Text(
              '只读',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _PreviewScrollView extends StatelessWidget {
  final Widget child;

  const _PreviewScrollView({required this.child});

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('card_preview_sheet'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl * 2,
      ),
      children: [child],
    );
  }
}

class _IdentityCard extends StatelessWidget {
  final String name;
  final List<String> tags;
  final String? avatar;
  final int entryCount;
  final int greetingCount;
  final bool compact;

  const _IdentityCard({
    required this.name,
    required this.tags,
    required this.avatar,
    required this.entryCount,
    required this.greetingCount,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final cover = _AvatarCover(
      avatar: avatar,
      width: compact ? 144 : double.infinity,
      height: compact ? 180 : 270,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: compact
              ? Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)
              : Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [for (final tag in tags) _TagChip(text: tag)],
          ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cover,
              const SizedBox(width: AppSpacing.lg),
              Expanded(child: details),
            ],
          )
        else ...[
          cover,
          const SizedBox(height: AppSpacing.lg),
          details,
        ],
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerLow.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: _Stat(value: greetingCount, label: '开场白'),
              ),
              Expanded(
                child: _Stat(value: entryCount, label: '世界书'),
              ),
              Expanded(
                child: _Stat(value: tags.length, label: '标签'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AvatarCover extends ConsumerWidget {
  final String? avatar;
  final double width;
  final double height;

  const _AvatarCover({
    required this.avatar,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hash = avatar;
    final image = hash == null
        ? null
        : hashImageProvider(
            ref.read(databaseProvider).images,
            hash,
            cacheWidth: kLargeImageWidth,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        key: const ValueKey('card_preview_cover'),
        width: width,
        height: height,
        color: scheme.surfaceContainerHighest,
        child: image == null
            ? Icon(
                Icons.person_outline_rounded,
                size: 42,
                color: scheme.onSurfaceVariant,
              )
            : Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.broken_image_outlined,
                  size: 42,
                  color: scheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final int value;
  final String label;

  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          '$value',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
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

class _PreviewContent extends StatelessWidget {
  final List<(String, String)> basics;
  final List<(String, String)> greetings;
  final List<(String, String)> advanced;
  final List<WorldbookEntry> entries;

  const _PreviewContent({
    required this.basics,
    required this.greetings,
    required this.advanced,
    required this.entries,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (basics.isNotEmpty) ...[
          const SectionHeader('角色设定', icon: Icons.badge_outlined),
          _TextGroup(items: basics),
          const SizedBox(height: AppSpacing.xl),
        ],
        if (greetings.isNotEmpty) ...[
          const SectionHeader('对话开场', icon: Icons.forum_outlined),
          _TextGroup(items: greetings, framed: true),
          const SizedBox(height: AppSpacing.xl),
        ],
        SectionHeader(
          '世界书 · ${entries.length} 条',
          icon: Icons.menu_book_outlined,
        ),
        if (entries.isEmpty)
          const SurfaceCard(
            child: Row(
              children: [
                Icon(Icons.menu_book_outlined, size: 20),
                SizedBox(width: AppSpacing.md),
                Text('这张角色卡没有世界书条目'),
              ],
            ),
          )
        else
          GroupCard(
            margin: EdgeInsets.zero,
            children: [
              for (final (index, entry) in entries.indexed)
                _WorldbookPreviewTile(entry: entry, index: index + 1),
            ],
          ),
        if (advanced.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          SectionHeader(
            '高级字段 · ${advanced.length} 项',
            icon: Icons.tune_rounded,
          ),
          _TextGroup(items: advanced),
        ],
      ],
    );
  }
}

class _TextGroup extends StatelessWidget {
  final List<(String, String)> items;
  final bool framed;

  const _TextGroup({required this.items, this.framed = false});

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (index, item) in items.indexed) ...[
            if (index > 0)
              Divider(
                height: 0.5,
                indent: AppSpacing.lg,
                endIndent: AppSpacing.lg,
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.55),
              ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: _PreviewSection(
                title: item.$1,
                text: item.$2,
                framed: framed,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewSection extends StatelessWidget {
  final String title;
  final String text;
  final bool framed;

  const _PreviewSection({
    required this.title,
    required this.text,
    this.framed = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.65),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (framed)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: body,
          )
        else
          body,
      ],
    );
  }
}

class _WorldbookPreviewTile extends StatelessWidget {
  final WorldbookEntry entry;
  final int index;

  const _WorldbookPreviewTile({required this.entry, required this.index});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trigger = entry.constant
        ? '常驻'
        : entry.keys.isEmpty
        ? '无关键词'
        : entry.keys.join(', ');
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        childrenPadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        leading: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '$index',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                entry.displayLabel,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!entry.enabled) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                '已停用',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            trigger,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              entry.content,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewFootnote extends StatelessWidget {
  const _PreviewFootnote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '按当前审阅决策生成;未接受的变更保留原文,未接受的新条目不会出现。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String text;

  const _TagChip({required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
