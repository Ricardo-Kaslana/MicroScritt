/// 桌面状态工作台:记忆与生图指导的大编辑区。
///
/// 记忆保存只更新库与列表,不重算上下文;待应用状态由「应用到上下文」显式
/// 消除。生图指导保存即生效,后台每轮直接读库携带。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/image_guide.dart';
import '../../models/memory.dart';
import '../../engine/background_status.dart';
import '../../state/chat_controller.dart';
import '../../state/providers.dart';
import '../common/confirm_dialog.dart';
import '../common/empty_state.dart';
import '../common/form_field.dart';
import '../common/section_header.dart';
import 'status_dialogs.dart';
import 'status_widgets.dart';

class StatusMemoryWorkspace extends ConsumerStatefulWidget {
  final int sessionId;
  const StatusMemoryWorkspace({super.key, required this.sessionId});

  @override
  ConsumerState<StatusMemoryWorkspace> createState() =>
      _StatusMemoryWorkspaceState();
}

class _StatusMemoryWorkspaceState extends ConsumerState<StatusMemoryWorkspace> {
  final _controller = TextEditingController();
  bool _editing = false;
  String _initial = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _beginEdit(String content) {
    _controller.text = content;
    _initial = content;
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  Future<void> _save(Memory? memory) async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (text == _initial.trim()) {
      _cancelEdit();
      return;
    }
    final repo = ref.read(memoryRepositoryProvider);
    if (memory?.id != null) {
      await repo.update(memory!.id!, text);
    } else {
      await repo.set(widget.sessionId, text);
    }
    if (!mounted) return;
    ref.invalidate(memoriesProvider(widget.sessionId));
    setState(() => _editing = false);
  }

  Future<void> _clear() async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空记忆?',
      message: '会话的长期记忆将被删除。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    await ref.read(memoryRepositoryProvider).clear(widget.sessionId);
    if (!mounted) return;
    ref.invalidate(memoriesProvider(widget.sessionId));
    setState(() => _editing = false);
  }

  Future<void> _apply({required bool pending}) async {
    final confirmed = await confirmApplyMemoryToContext(
      context,
      pending: pending,
    );
    if (!confirmed) return;
    await ref.read(chatControllerProvider.notifier).applyMemoryToContext();
  }

  @override
  Widget build(BuildContext context) {
    final memories = ref.watch(memoriesProvider(widget.sessionId));
    final chatState = ref.watch(chatControllerProvider);
    final running = chatState.backgroundStatus == BackgroundStatus.running;
    final pending = isMemoryPendingApply(chatState, widget.sessionId, memories);
    final memory = memories.value?.firstOrNull;
    final empty = memories.hasValue && memory == null;
    final Widget content;
    if (memories.isLoading) {
      content = const _WorkspaceSkeleton();
    } else if (memories.hasError) {
      content = _WorkspaceError(
        error: '${memories.error}',
        onRetry: () => ref.invalidate(memoriesProvider(widget.sessionId)),
      );
    } else if (_editing) {
      content = _MemoryEditor(
        controller: _controller,
        onCancel: _cancelEdit,
        onSave: () => _save(memory),
      );
    } else if (memory == null) {
      content = _MemoryEmptyState(
        running: running,
        onGenerate: () =>
            ref.read(chatControllerProvider.notifier).initializeMemory(),
        onManual: () => _beginEdit(''),
      );
    } else {
      content = _MemoryReadCard(memory: memory);
    }
    // 信息栏只在已有记忆或正在编辑时出现;加载/错误/空态保持单栏,
    // 让空态引导占据整个工作区。
    final showRail =
        !memories.isLoading &&
        !memories.hasError &&
        (_editing || memory != null);
    final rail = showRail
        ? _MemoryInfoRail(
            memory: memory,
            editing: _editing,
            pending: pending,
            controller: _controller,
          )
        : null;
    return StatusWorkspaceFrame(
      header: StatusWorkspaceHeader(
        title: '记忆',
        badge: pending ? '待应用' : null,
        description:
            '会话的长期事实底本,以第 0 条身份进入上下文;'
            '修改后需显式应用到上下文。',
        actions: [
          if (!_editing && memory != null) ...[
            StatusSecondaryAction(
              icon: Icons.auto_awesome,
              label: '重新生成',
              onPressed: running
                  ? null
                  : () => ref
                        .read(chatControllerProvider.notifier)
                        .regenerateMemory(),
            ),
            StatusPrimaryAction(
              buttonKey: const ValueKey('memory_edit_button'),
              icon: Icons.edit_outlined,
              label: '编辑',
              onPressed: () => _beginEdit(memory.content),
            ),
            StatusClearMenuButton(onClear: _clear),
          ],
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = rail != null && constraints.maxWidth >= 900;
          final body = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: content),
                    const SizedBox(width: 16),
                    SizedBox(width: 296, child: rail),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    content,
                    if (rail != null) ...[const SizedBox(height: 16), rail],
                  ],
                );
          return ListView(
            primary: false,
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (chatState.memoryProposal != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: MemoryProposalCard(
                    proposal: chatState.memoryProposal!,
                    enabled: !running,
                    onAccept: () => ref
                        .read(chatControllerProvider.notifier)
                        .acceptMemoryProposal(),
                    onDismiss: () => ref
                        .read(chatControllerProvider.notifier)
                        .dismissMemoryProposal(),
                  ),
                ),
              if (pending)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _MemoryPendingBanner(
                    memoryCleared: empty,
                    running: running,
                    onApply: () => _apply(pending: pending),
                  ),
                ),
              body,
            ],
          );
        },
      ),
    );
  }
}

class _MemoryPendingBanner extends StatelessWidget {
  final bool memoryCleared;
  final bool running;
  final VoidCallback onApply;

  const _MemoryPendingBanner({
    required this.memoryCleared,
    required this.running,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.publish, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  memoryCleared ? '记忆已清空,上下文仍保留旧版本' : '记忆已修改,尚未应用到上下文',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  running ? '后台运行中,结束后可应用' : '应用后记忆整体换新,提示前缀会变化。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            key: const ValueKey('memory_apply_button'),
            onPressed: running ? null : onApply,
            child: const Text('应用到上下文'),
          ),
        ],
      ),
    );
  }
}

class _MemoryInfoRail extends StatelessWidget {
  final Memory? memory;
  final bool editing;
  final bool pending;
  final TextEditingController controller;

  const _MemoryInfoRail({
    required this.memory,
    required this.editing,
    required this.pending,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final status = editing ? '编辑中' : (pending ? '待应用' : '已应用');
    return _InfoRailCard(
      key: const ValueKey('memory_info_rail'),
      icon: Icons.info_outline,
      title: '记忆信息',
      rows: [
        _InfoRow(
          label: '应用状态',
          child: _InfoPill(label: status, active: editing || pending),
        ),
        _InfoRow(
          label: '上次更新',
          value: editing ? '保存后刷新' : _formatTimestamp(memory?.updatedAt),
        ),
        const _InfoRow(label: '进入位置', value: '上下文第 0 条'),
        if (editing)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) =>
                _InfoRow(label: '当前字数', value: '${value.text.length} 字符'),
          ),
      ],
      note: editing
          ? '保存只更新库;需要点击「应用到上下文」才会进入下一轮。'
          : '修改记忆不会立即改变上下文;应用后提示前缀会变化,缓存重新预热。',
    );
  }
}

class _MemoryReadCard extends StatelessWidget {
  final Memory memory;
  const _MemoryReadCard({required this.memory});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      key: const ValueKey('memory_read_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const StatusCardSectionTitle(
            icon: Icons.psychology_outlined,
            title: '记忆正文',
          ),
          const SizedBox(height: 10),
          SelectionArea(
            child: Text(
              memory.content,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
            ),
          ),
          Divider(
            height: 22,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          Row(
            children: [
              Text(
                '${memory.content.length} 字符',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                '修改后需点击「应用到上下文」才会进入下一轮',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MemoryEditor extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onCancel;
  final Future<void> Function() onSave;

  const _MemoryEditor({
    required this.controller,
    required this.onCancel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      key: const ValueKey('memory_editor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StatusCardSectionTitle(
            icon: Icons.edit_outlined,
            title: '编辑记忆',
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 420,
            child: TextField(
              key: const ValueKey('memory_text_field'),
              controller: controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
              decoration: appInputDecoration(
                context,
                hintText: '输入长期记忆内容…',
                borderAlpha: 0.5,
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => Row(
              children: [
                Text(
                  '${value.text.length} 字符',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('memory_cancel_button'),
                  onPressed: onCancel,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey('memory_save_button'),
                  onPressed: value.text.trim().isEmpty ? null : () => onSave(),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryEmptyState extends StatelessWidget {
  final bool running;
  final VoidCallback onGenerate;
  final VoidCallback onManual;

  const _MemoryEmptyState({
    required this.running,
    required this.onGenerate,
    required this.onManual,
  });

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: EmptyState(
        compact: true,
        icon: Icons.psychology_outlined,
        title: '暂无记忆',
        message: '记忆是给主写模型的长期事实底本,可由 AI 依据角色卡生成,也可手动填写。',
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: running ? null : onGenerate,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('生成初始记忆'),
            ),
            OutlinedButton.icon(
              onPressed: onManual,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('手动填写'),
            ),
          ],
        ),
      ),
    );
  }
}

class StatusImageGuideWorkspace extends ConsumerStatefulWidget {
  final int sessionId;
  const StatusImageGuideWorkspace({super.key, required this.sessionId});

  @override
  ConsumerState<StatusImageGuideWorkspace> createState() =>
      _StatusImageGuideWorkspaceState();
}

class _StatusImageGuideWorkspaceState
    extends ConsumerState<StatusImageGuideWorkspace> {
  final _controller = TextEditingController();
  bool _editing = false;
  String _initial = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _beginEdit(String content) {
    _controller.text = content;
    _initial = content;
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    if (text == _initial.trim()) {
      _cancelEdit();
      return;
    }
    await ref.read(imageGuideRepositoryProvider).set(widget.sessionId, text);
    if (!mounted) return;
    ref.invalidate(imageGuideProvider(widget.sessionId));
    setState(() => _editing = false);
  }

  Future<void> _clear() async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空生图指导?',
      message: '清空后后台生图将回退内置 tag 规范,定妆外貌可能漂移。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    await ref.read(imageGuideRepositoryProvider).clear(widget.sessionId);
    if (!mounted) return;
    ref.invalidate(imageGuideProvider(widget.sessionId));
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final guideAsync = ref.watch(imageGuideProvider(widget.sessionId));
    final chatState = ref.watch(chatControllerProvider);
    final running = chatState.backgroundStatus == BackgroundStatus.running;
    final guide = guideAsync.value?.firstOrNull;
    final Widget content;
    if (guideAsync.isLoading) {
      content = const _WorkspaceSkeleton();
    } else if (guideAsync.hasError) {
      content = _WorkspaceError(
        error: '${guideAsync.error}',
        onRetry: () => ref.invalidate(imageGuideProvider(widget.sessionId)),
      );
    } else if (_editing) {
      content = _GuideEditor(
        controller: _controller,
        onCancel: _cancelEdit,
        onSave: _save,
      );
    } else if (guide == null) {
      content = SurfaceCard(
        child: EmptyState(
          compact: true,
          icon: Icons.palette_outlined,
          title: '暂无生图指导',
          message: '指导固定角色外貌与画风,由后台生图每轮携带;可由 AI 生成,也可手动填写。',
          action: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: running
                    ? null
                    : () => ref
                          .read(chatControllerProvider.notifier)
                          .initializeImageGuide(),
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('生成初始指导'),
              ),
              OutlinedButton.icon(
                onPressed: () => _beginEdit(''),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('手动填写'),
              ),
            ],
          ),
        ),
      );
    } else {
      content = _GuideReadCard(guide: guide);
    }
    final showRail =
        !guideAsync.isLoading &&
        !guideAsync.hasError &&
        (_editing || guide != null);
    final rail = showRail
        ? _GuideInfoRail(guide: guide, editing: _editing)
        : null;
    return StatusWorkspaceFrame(
      header: StatusWorkspaceHeader(
        title: '生图指导',
        description: '后台生图每轮携带的角色外貌与画风 tag;保存后立即生效。',
        actions: [
          if (!_editing && guide != null) ...[
            StatusSecondaryAction(
              buttonKey: const ValueKey('image_guide_regenerate_button'),
              icon: Icons.auto_awesome,
              label: '重新生成',
              onPressed: running
                  ? null
                  : () => ref
                        .read(chatControllerProvider.notifier)
                        .regenerateImageGuide(),
            ),
            StatusPrimaryAction(
              buttonKey: const ValueKey('image_guide_edit_button'),
              icon: Icons.edit_outlined,
              label: '编辑',
              onPressed: () => _beginEdit(guide.content),
            ),
            StatusClearMenuButton(onClear: _clear),
          ],
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = rail != null && constraints.maxWidth >= 900;
          final body = wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: content),
                    const SizedBox(width: 16),
                    SizedBox(width: 296, child: rail),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    content,
                    if (rail != null) ...[const SizedBox(height: 16), rail],
                  ],
                );
          return ListView(
            primary: false,
            padding: const EdgeInsets.only(bottom: 24),
            children: [body],
          );
        },
      ),
    );
  }
}

class _GuideInfoRail extends StatelessWidget {
  final ImageGuide? guide;
  final bool editing;

  const _GuideInfoRail({required this.guide, required this.editing});

  @override
  Widget build(BuildContext context) {
    return _InfoRailCard(
      key: const ValueKey('image_guide_info_rail'),
      icon: Icons.info_outline,
      title: '指导信息',
      rows: [
        _InfoRow(
          label: '当前状态',
          child: _InfoPill(
            label: editing ? '编辑中' : '已生效',
            active: editing || guide != null,
          ),
        ),
        const _InfoRow(label: '写入方式', value: '保存即生效'),
        _InfoRow(
          label: '上次更新',
          value: editing ? '保存后刷新' : _formatTimestamp(guide?.updatedAt),
        ),
        const _InfoRow(label: '携带时机', value: '每轮后台生图'),
      ],
      note: '英文 NovelAI tag、逗号分隔更稳定;保存后无需重新应用。',
    );
  }
}

class _GuideReadCard extends StatelessWidget {
  final ImageGuide guide;
  const _GuideReadCard({required this.guide});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      key: const ValueKey('image_guide_read_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const StatusCardSectionTitle(
            icon: Icons.palette_outlined,
            title: '指导正文',
          ),
          const SizedBox(height: 10),
          SelectionArea(
            child: Text(
              guide.content,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.7,
              ),
            ),
          ),
          Divider(
            height: 22,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          Row(
            children: [
              Text(
                '${guide.content.length} 字符',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                '清空后回退内置 tag 规范',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuideEditor extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onCancel;
  final Future<void> Function() onSave;

  const _GuideEditor({
    required this.controller,
    required this.onCancel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      key: const ValueKey('image_guide_editor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StatusCardSectionTitle(
            icon: Icons.edit_outlined,
            title: '编辑生图指导',
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 360,
            child: TextField(
              key: const ValueKey('image_guide_text_field'),
              controller: controller,
              autofocus: true,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.55,
              ),
              decoration: appInputDecoration(
                context,
                hintText: '生图指导:定妆外貌 tag、画风与构图偏好…',
                borderAlpha: 0.5,
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => Row(
              children: [
                Text(
                  '${value.text.length} 字符',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const ValueKey('image_guide_cancel_button'),
                  onPressed: onCancel,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey('image_guide_save_button'),
                  onPressed: value.text.trim().isEmpty ? null : () => onSave(),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面信息侧栏的通用卡:小标题 + 键值行 + 底部说明。
class _InfoRailCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> rows;
  final String note;

  const _InfoRailCard({
    super.key,
    required this.icon,
    required this.title,
    required this.rows,
    required this.note,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatusCardSectionTitle(icon: icon, title: title),
          const SizedBox(height: 8),
          ...rows,
          const SizedBox(height: 8),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
          Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String? value;
  final Widget? child;

  const _InfoRow({required this.label, this.value, this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child:
                  child ??
                  Text(
                    value ?? '—',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final String label;
  final bool active;

  const _InfoPill({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

String _formatTimestamp(int? millis) {
  if (millis == null) return '尚未保存';
  final time = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

class _WorkspaceSkeleton extends StatelessWidget {
  const _WorkspaceSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double widthFactor) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: 12,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [bar(0.35), bar(0.9), bar(0.75), bar(0.5)],
      ),
    );
  }
}

class _WorkspaceError extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _WorkspaceError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SurfaceCard(
      child: Column(
        children: [
          Text(error, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
