/// 状态面板移动页与桌面工作台共用的展示件与小工具。
///
/// 权限徽标、严格模式待确认卡、后台摘要文本与若干只读派生逻辑放在这里,
/// 两套布局共享同一份语义;真正写库仍由仓库与 persistBackground* 负责。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/background_status.dart';
import '../../models/llm_provider.dart';
import '../../models/memory.dart';
import '../../models/variable.dart';
import '../../state/chat_controller.dart';
import '../../state/providers.dart';
import '../common/motion.dart';
import '../common/section_header.dart';
import '../common/app_menu.dart';
import '../common/app_snack_bar.dart';
import '../common/background_summary.dart';
import '../common/confirm_dialog.dart';
import '../common/info_dialog.dart';
import 'status_layout.dart';

/// 变量删除前确认严格模式的说明弹层:开关行只留标题,完整规则收在这里。
Future<void> showDeletionConfirmHelpDialog(BuildContext context) {
  return showInfoDialog(
    context,
    title: '变量删除前确认',
    bullets: const [
      '• 只作用于后台对变量的删除,新增与改值不受影响;'
          '后台只能按明确的键名请求删除,单轮至多 5 个。',
      '• 开启(严格模式):删除请求先进入状态面板的「待确认删除」,'
          '你确认后才移入回收站;忽略则变量保持原样。',
      '• 关闭:后台删除直接执行并移入回收站,可在回收站逐条恢复。',
    ],
    note:
        '「可改不可删」与「只读常量」的变量不会被删除;'
        '人工编辑、删除或修改权限时,对应的待确认请求自动作废。',
  );
}

/// Agentic 增强说明弹层:开关行只留标题,依赖条件与行为收在这里。
Future<void> showAgenticEnhancementsHelpDialog(BuildContext context) {
  return showInfoDialog(
    context,
    title: 'Agentic 增强',
    bullets: const [
      '• 变量注入主写:仅 Agentic 模式可用,且需先开启变量维护。'
          '后台维护时会挑选若干变量,提交后按最终值在下一条用户输入前'
          '以 system-reminder 附件注入主写上下文。',
      '• 下一步建议:仅 Agentic 模式可用。后台收尾时给出 1–3 条'
          '用户口吻的发言建议,聊天页自动弹底单;点击一条即作为你的消息发送,'
          '关闭或忽略则丢弃本批。',
      '• 两项默认关闭;当前模式或依赖不满足时开关置灰,已保存的选择会保留。',
    ],
    note: '两项都只影响下一次交互,不会改写已有的对话历史。',
  );
}

/// 变量行的后台权限徽标:三档 full / protected / readonly。
///
/// 移动页用图标 + 悬停提示,桌面表格传 [showLabel] 显示带文字的彩色 chip;
/// 权限只是提示,真正的约束在仓库事务内复核。
class VariableAccessBadge extends StatelessWidget {
  final VariableAccess access;

  /// 为真时在图标右侧显示 [VariableAccess.label],供宽表格扫读。
  final bool showLabel;

  const VariableAccessBadge({
    super.key,
    required this.access,
    this.showLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (access) {
      VariableAccess.full => (Icons.auto_awesome_outlined, scheme.primary),
      VariableAccess.protected => (
        Icons.verified_user_outlined,
        scheme.onSurfaceVariant,
      ),
      VariableAccess.readonly => (Icons.lock_outline, scheme.error),
    };
    final tooltip = '${access.label}:${access.description}';
    if (!showLabel) {
      return Tooltip(
        message: tooltip,
        child: Icon(icon, size: 16, color: color),
      );
    }
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              access.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 严格模式下的待确认删除卡片。确认后移入回收站(可恢复)。
class PendingVariableDeletions extends ConsumerWidget {
  final int sessionId;
  const PendingVariableDeletions({super.key, required this.sessionId});

  /// 建议、变量行与回收站三者会互相影响,处理完一并失效。
  void _refresh(WidgetRef ref) {
    ref.invalidate(pendingVariableDeletionsProvider(sessionId));
    refreshVariableViews(ref, sessionId);
    ref.invalidate(variableTrashProvider(sessionId));
  }

  /// 确认单条建议:仓库在事务内复核变量仍在、权限仍为 `full` 且值未变;
  /// 否则视为失效建议并清掉,这里按结果分别提示。
  Future<void> _approveOne(
    BuildContext context,
    WidgetRef ref,
    VariableDeletionProposal proposal,
  ) async {
    final result = await ref
        .read(variableRepositoryProvider)
        .approveDeletion(sessionId, proposal.id!);
    if (!context.mounted) return;
    _refresh(ref);
    final message = result.removed > 0
        ? '已移除「${proposal.key}」,可在「已删除」中恢复'
        : '「${proposal.key}」已变化或不再是可删状态,建议已失效';
    showAppSnack(context, message);
  }

  /// 忽略单条建议:只删建议行,变量本身不动。
  Future<void> _dismissOne(
    BuildContext context,
    WidgetRef ref,
    VariableDeletionProposal proposal,
  ) async {
    await ref
        .read(variableRepositoryProvider)
        .dismissDeletion(sessionId, proposal.id!);
    if (!context.mounted) return;
    _refresh(ref);
  }

  /// 确认全部建议(同一事务):失效建议会计入返回结果,提示里一并说明,
  /// 避免用户以为全部都已删除。
  Future<void> _approveAll(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '执行全部删除?',
      message: '将把 $count 个变量移入回收站,可在「已删除」中恢复。',
      confirmLabel: '执行',
    );
    if (!confirmed) return;
    final result = await ref
        .read(variableRepositoryProvider)
        .approveAllDeletions(sessionId);
    if (!context.mounted) return;
    _refresh(ref);
    final stale = result.stale > 0 ? ',${result.stale} 个建议已失效' : '';
    showAppSnack(context, '已移除 ${result.removed} 个变量$stale');
  }

  /// 忽略全部建议:只清空待确认列表,变量本身不动。
  Future<void> _dismissAll(BuildContext context, WidgetRef ref) async {
    await ref.read(variableRepositoryProvider).dismissAllDeletions(sessionId);
    if (!context.mounted) return;
    _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingVariableDeletionsProvider(sessionId));
    return pending.maybeWhen(
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return SurfaceCard(
          color: scheme.errorContainer.withValues(alpha: 0.35),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.fact_check_outlined,
                    size: 18,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '后台建议删除的变量 (${list.length})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '这些删除建议尚未执行:确认后移入回收站,可恢复。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              for (final proposal in list)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    proposal.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    proposal.value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '忽略建议',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => _dismissOne(context, ref, proposal),
                      ),
                      IconButton(
                        tooltip: '执行删除',
                        icon: Icon(Icons.check, size: 20, color: scheme.error),
                        onPressed: () => _approveOne(context, ref, proposal),
                      ),
                    ],
                  ),
                ),
              if (list.length > 1)
                Row(
                  children: [
                    TextButton(
                      onPressed: () => _dismissAll(context, ref),
                      child: const Text('全部忽略'),
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: () => _approveAll(context, ref, list.length),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: const Text('全部执行'),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// 后台运行摘要:成功摘要按语义拆成「变量 / 移除 / 待确认 / 注入 / 生图 /
/// 审计」分组条目,失败与非常规文案回退为带状态图标的整段文本。
///
/// 摘要本身仍是控制器拼好的一行字符串(灵动岛消费同一份),这里只做展示层
/// 解析;任何认不出的片段都回退全文,避免把引擎诊断误拆成条目。
class BackgroundSummaryView extends StatefulWidget {
  final String text;
  final BackgroundStatus status;

  const BackgroundSummaryView({
    super.key,
    required this.text,
    required this.status,
  });

  @override
  State<BackgroundSummaryView> createState() => _BackgroundSummaryViewState();
}

class _BackgroundSummaryViewState extends State<BackgroundSummaryView> {
  static const int _collapsedLines = 3;

  /// 用户展开/收起的选择保持到组件销毁:每轮后台完成后摘要文本都会刷新,
  /// 旧实现在文本变化时强制收起,正在读长摘要的用户每次都被打断。
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // 与「模型与参数」里的输入框同款填充灰:摘要从白色卡片背景中
    // 独立成一块可读区域,而不是浮在标题下方的一串灰字。
    final fill =
        theme.inputDecorationTheme.fillColor ??
        theme.colorScheme.surfaceContainerHighest;
    return Container(
      key: const ValueKey('background-summary-box'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _body(context, style),
    );
  }

  Widget _body(BuildContext context, TextStyle? style) {
    if (widget.status != BackgroundStatus.succeeded) {
      return _SummaryNotice(
        text: widget.text,
        status: widget.status,
        style: style,
      );
    }
    final parsed = BackgroundSummaryParts.parse(widget.text);
    if (parsed != null) {
      return _structured(context, parsed, style);
    }
    return _collapsibleText(context, style);
  }

  // ---- 结构化成功摘要 ----

  Widget _structured(
    BuildContext context,
    BackgroundSummaryParts data,
    TextStyle? style,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // 窄屏(移动页)组名独占一行、胶囊在其下方铺开,不再和组名抢宽度;
    // 宽屏(桌面工作台)保持左侧组名列的横向对照。
    final stacked = MediaQuery.sizeOf(context).width < kStatusDesktopBreakpoint;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = stacked
            ? constraints.maxWidth
            : constraints.maxWidth - _kSummaryLabelWidth - 8;
        final chipMax = available > 80 ? available : 80.0;
        final rows = <Widget>[];
        if (data.headline != null) {
          rows.add(
            _headlineRow(
              context,
              icon: data.headline!.startsWith('重跑')
                  ? Icons.replay_rounded
                  : data.headline!.startsWith('审计')
                  ? Icons.fact_check_outlined
                  : Icons.check_circle_outline,
              text: data.headline!,
            ),
          );
        }
        if (data.noChange != null) {
          rows.add(
            Padding(
              // 与标题文字对齐(图标 14 + 间距 5),不另起一列。
              padding: const EdgeInsets.only(left: 19, top: 2, bottom: 2),
              child: Text(data.noChange!, style: style),
            ),
          );
        }
        if (data.updates.isNotEmpty) {
          rows.add(
            _groupRow(
              context,
              stacked: stacked,
              icon: Icons.tune_rounded,
              label: '变量',
              color: scheme.onSurfaceVariant,
              chips: [
                for (final entry in data.updates)
                  _updateChip(context, entry.key, entry.value, chipMax),
              ],
            ),
          );
        }
        if (data.removed.isNotEmpty) {
          rows.add(
            _groupRow(
              context,
              stacked: stacked,
              icon: Icons.remove_circle_outline,
              label: '移除',
              color: scheme.onSurfaceVariant,
              chips: [
                for (final name in data.removed)
                  _tagChip(
                    context,
                    label: name,
                    color: scheme.onSurfaceVariant,
                    strike: true,
                    maxWidth: chipMax,
                  ),
              ],
            ),
          );
        }
        if (data.proposed.isNotEmpty) {
          rows.add(
            _groupRow(
              context,
              stacked: stacked,
              icon: Icons.pending_actions_outlined,
              label: '待确认',
              color: scheme.tertiary,
              chips: [
                for (final name in data.proposed)
                  _tagChip(
                    context,
                    label: name,
                    color: scheme.tertiary,
                    filled: true,
                    icon: Icons.help_outline,
                    maxWidth: chipMax,
                  ),
              ],
            ),
          );
        }
        if (data.injected.isNotEmpty) {
          rows.add(
            _groupRow(
              context,
              stacked: stacked,
              icon: Icons.input_rounded,
              label: '注入',
              color: scheme.primary,
              chips: [
                for (final name in data.injected)
                  _tagChip(
                    context,
                    label: name,
                    color: scheme.primary,
                    maxWidth: chipMax,
                  ),
              ],
            ),
          );
        }
        if (data.auditStats.isNotEmpty) {
          rows.add(
            _groupRow(
              context,
              stacked: stacked,
              icon: Icons.bar_chart_rounded,
              label: '统计',
              color: scheme.onSurfaceVariant,
              chips: [
                for (final stat in data.auditStats)
                  _tagChip(
                    context,
                    label: stat,
                    color: stat.contains('待确认')
                        ? scheme.tertiary
                        : scheme.onSurfaceVariant,
                    filled: stat.contains('待确认'),
                    maxWidth: chipMax,
                  ),
              ],
            ),
          );
        }
        if (data.imageState != null) {
          rows.add(
            _groupRow(
              context,
              stacked: stacked,
              icon: Icons.image_outlined,
              label: '生图',
              color: scheme.primary,
              chips: [
                _tagChip(
                  context,
                  label: data.imageState!,
                  color: scheme.primary,
                  filled: true,
                  icon: Icons.image_outlined,
                  maxWidth: chipMax,
                ),
              ],
            ),
          );
        }
        if (data.note != null) {
          rows.add(
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 13, color: scheme.outline),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      data.note!,
                      style: style?.copyWith(color: scheme.outline),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      },
    );
  }

  Widget _headlineRow(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 1, bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupRow(
    BuildContext context, {
    required bool stacked,
    required IconData icon,
    required String label,
    required Color color,
    required List<Widget> chips,
  }) {
    final labelRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
    if (stacked) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(left: 1), child: labelRow),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 6, children: chips),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kSummaryLabelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: labelRow,
            ),
          ),
          Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
        ],
      ),
    );
  }

  Widget _updateChip(
    BuildContext context,
    String key,
    String value,
    double maxWidth,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return _chipBox(
      context,
      tooltip: '$key = $value',
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: key,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              TextSpan(
                text: ' = ',
                style: TextStyle(color: scheme.outline),
              ),
              TextSpan(
                text: value,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, height: 1.3),
        ),
      ),
    );
  }

  Widget _tagChip(
    BuildContext context, {
    required String label,
    required Color color,
    IconData? icon,
    bool strike = false,
    bool filled = false,
    required double maxWidth,
  }) {
    return _chipBox(
      context,
      tooltip: label,
      background: filled ? color.withValues(alpha: 0.08) : null,
      border: filled ? color.withValues(alpha: 0.28) : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  color: color,
                  decoration: strike ? TextDecoration.lineThrough : null,
                  decorationColor: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chipBox(
    BuildContext context, {
    required Widget child,
    String? tooltip,
    Color? background,
    Color? border,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Widget box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: border ?? scheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: child,
    );
    if (tooltip != null) {
      box = Tooltip(message: tooltip, child: box);
    }
    return box;
  }

  // ---- 回退文案 ----

  Widget _collapsibleText(BuildContext context, TextStyle? style) {
    if (_expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSize(
            duration: motionDurationOf(
              context,
              const Duration(milliseconds: 180),
            ),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topLeft,
            child: Text(widget.text, style: style),
          ),
          _toggle(context),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_overflows(context, constraints.maxWidth, style)) {
          return Text(widget.text, style: style);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _collapsedLines,
              overflow: TextOverflow.ellipsis,
            ),
            _toggle(context),
          ],
        );
      },
    );
  }

  bool _overflows(BuildContext context, double maxWidth, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: _collapsedLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final overflows = painter.didExceedMaxLines;
    painter.dispose();
    return overflows;
  }

  Widget _toggle(BuildContext context) {
    return TextButton.icon(
      onPressed: () => setState(() => _expanded = !_expanded),
      icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16),
      label: Text(_expanded ? '收起' : '展开'),
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(vertical: 2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

const double _kSummaryLabelWidth = 76;

/// 非成功状态的摘要条:状态图标 + 文案;失败时把尾部括号里的引擎诊断
/// 拆成第二行,主因与诊断各占一行,不再糊成一长串。
class _SummaryNotice extends StatelessWidget {
  final String text;
  final BackgroundStatus status;
  final TextStyle? style;

  const _SummaryNotice({
    required this.text,
    required this.status,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (status) {
      BackgroundStatus.failed => (Icons.error_outline, scheme.error),
      BackgroundStatus.interrupted => (
        Icons.stop_circle_outlined,
        scheme.tertiary,
      ),
      BackgroundStatus.running => (Icons.autorenew, scheme.primary),
      BackgroundStatus.disabled => (Icons.power_settings_new, scheme.outline),
      BackgroundStatus.skipped ||
      BackgroundStatus.idle => (Icons.info_outline, scheme.outline),
      BackgroundStatus.succeeded => (
        Icons.check_circle_outline,
        scheme.primary,
      ),
    };
    final parts = status == BackgroundStatus.failed
        ? _splitDiagnostic(text)
        : (text, null);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(parts.$1, style: style?.copyWith(color: scheme.onSurface)),
              if (parts.$2 != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    parts.$2!,
                    style: style?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 末尾括号内的诊断摘要与主因拆开;不匹配或嵌套括号时原样返回。
  (String, String?) _splitDiagnostic(String raw) {
    final match = RegExp(r'^(.*?)\s*\(([^()]*)\)\s*$').firstMatch(raw);
    if (match == null) return (raw, null);
    final base = match.group(1)!.trim();
    final detail = match.group(2)!.trim();
    if (base.isEmpty || detail.isEmpty) return (raw, null);
    return (base, '诊断摘要:$detail');
  }
}

/// 记忆库中最新内容与上下文冻结副本不一致时为真;只在控制器已装载本会话
/// 时判定,避免拿别的会话的冻结副本误报。
bool isMemoryPendingApply(
  ChatState chatState,
  int sessionId,
  AsyncValue<List<Memory>> memories,
) {
  return chatState.sessionId == sessionId &&
      memories.hasValue &&
      (memories.value?.firstOrNull?.content.trim() ?? '') !=
          (chatState.frozenMemory?.trim() ?? '');
}

/// 变量正文与全量行视图一起失效;变量默认不进主写上下文,不触发上下文重算
/// (Agentic 注入在下一次发送时以附件行消费)。
void refreshVariableViews(WidgetRef ref, int sessionId) {
  ref.invalidate(variablesProvider(sessionId));
  ref.invalidate(variableRowsProvider(sessionId));
}

/// 回收站与待确认建议的刷新:人工增删改会顺带清掉同键的建议。
void refreshVariableAuxViews(WidgetRef ref, int sessionId) {
  ref.invalidate(variableTrashProvider(sessionId));
  ref.invalidate(pendingVariableDeletionsProvider(sessionId));
}

/// 展平 LLM 模型目录:每项携带所属 provider 显示名(区分同名模型)。
List<({int id, String label})> flattenLlmModels(
  List<LlmProviderConfig> providers,
) {
  final out = <({int id, String label})>[];
  for (final p in providers) {
    for (final m in p.models) {
      out.add((
        id: m.id,
        label: providers.length > 1
            ? '${m.displayName} · ${p.displayName}'
            : m.displayName,
      ));
    }
  }
  return out;
}

/// 工作区头部的主操作(新增 / 编辑):统一的 tonal 填充按钮。
class StatusPrimaryAction extends StatelessWidget {
  final Key? buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const StatusPrimaryAction({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      key: buttonKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

/// 工作区头部的次操作(回收站 / 重新生成):统一的文字按钮。
class StatusSecondaryAction extends StatelessWidget {
  final Key? buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 非 null 时在图标右上角显示角标,为 0 自动隐藏(如回收站条数)。
  final int? badgeCount;

  const StatusSecondaryAction({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    final baseIcon = Icon(icon, size: 18);
    final count = badgeCount;
    return TextButton.icon(
      key: buttonKey,
      onPressed: onPressed,
      icon: count == null
          ? baseIcon
          : Badge(
              isLabelVisible: count > 0,
              label: Text('$count'),
              child: baseIcon,
            ),
      label: Text(label),
    );
  }
}

/// 工作区头部的危险操作入口:统一把「清空」收进三点菜单。
class StatusClearMenuButton extends StatelessWidget {
  final VoidCallback onClear;

  const StatusClearMenuButton({super.key, required this.onClear});

  static const _clear = 'clear';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPopupMenuButton<String>(
      tooltip: '更多操作',
      iconSize: 20,
      iconColor: scheme.outline,
      actions: const [
        MenuAction(
          value: _clear,
          label: '清空',
          icon: Icons.delete_sweep_outlined,
          destructive: true,
        ),
      ],
      onSelected: (action) {
        if (action == _clear) onClear();
      },
    );
  }
}

/// 桌面工作区的统一骨架:限宽居中 + 固定区块头 + 占满剩余高度的内容区。
///
/// 各工作区只声明头部与内容;变量表格的固定表头、记忆编辑器的高度都由
/// 内容区自行分配。
class StatusWorkspaceFrame extends StatelessWidget {
  final Widget header;
  final Widget child;

  const StatusWorkspaceFrame({
    super.key,
    required this.header,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: kStatusDesktopContentMaxWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 20),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面工作区头部:标题 + 可选待应用徽标 + 说明 + 右侧动作。
///
/// 工作区在 1000 宽时只有约 650 可用,头部按宽度自动把动作折到标题下方,
/// 不让操作按钮把标题挤成省略号。
class StatusWorkspaceHeader extends StatelessWidget {
  final String title;
  final String? description;

  /// 标题后的小徽标(如「待应用」)。
  final String? badge;
  final List<Widget> actions;

  const StatusWorkspaceHeader({
    super.key,
    required this.title,
    this.description,
    this.badge,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (badge != null) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badge!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(
            description!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final actionWrap = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: actions,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleBlock,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: actionWrap),
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: titleBlock),
            if (actions.isNotEmpty) ...[const SizedBox(width: 16), actionWrap],
          ],
        );
      },
    );
  }
}

/// 后台 agent 的记忆提议卡(移动/桌面共用):只读展示,用户显式「采用」才
/// 写入记忆库;上下文换新仍在记忆区「应用到上下文」二次确认。
class MemoryProposalCard extends StatelessWidget {
  final String proposal;
  final bool enabled;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  const MemoryProposalCard({
    super.key,
    required this.proposal,
    required this.enabled,
    required this.onAccept,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GroupCard(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
          title: const Text('后台记忆建议'),
          subtitle: const Text('采用只写入记忆库;应用到上下文需在下方另行确认。'),
          trailing: IconButton(
            tooltip: '忽略建议',
            icon: const Icon(Icons.close, size: 20),
            onPressed: onDismiss,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            proposal,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            Icons.check_circle_outline,
            size: 20,
            color: scheme.primary,
          ),
          title: const Text('采用建议'),
          enabled: enabled,
          onTap: enabled ? onAccept : null,
        ),
      ],
    );
  }
}

/// 桌面工作区内的卡片小标题(图标 + 灰字),与外层 SurfaceCard 形成层级。
class StatusCardSectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;

  const StatusCardSectionTitle({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 15, color: scheme.primary),
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
        if (trailing != null) trailing!,
      ],
    );
  }
}
