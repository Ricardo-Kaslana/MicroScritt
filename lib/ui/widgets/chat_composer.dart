/// 聊天输入区(composer):命令行、消息输入卡与工具底栏。
///
/// 自上而下:
/// - 命令行:输入 `/xx` 时的实时建议,或手动展开的常驻命令组,同一个
///   [AnimatedSize] 负责显隐,展开/收起不跳变;
/// - 输入卡:消息框(默认一行高、随输入增长到 [_kFieldMaxLines] 行)+ 底栏
///   (命令入口、@ 技能、模型 chip、推理徽标、上下文圆环、发送/中断键);
/// - 输入卡与消息列同宽收敛:宽窗左右缘对齐助手气泡左缘 / 用户气泡右缘,
///   窄窗吃满可用宽度;
///
/// 制卡等独立工作台复用本组件时把 [showCommands] 关掉:命令行与命令/技能
/// 入口整组消失,只保留模型 chip、推理徽标、上下文圆环与发送/中断键 ——
/// 这些能力(选模型、调推理、看占用与缓存命中)与聊天页完全同源。
///
/// 视觉与交互不变量:
/// - 输入卡聚焦时外描边过渡为主色、阴影加深,失焦回落发丝边;
/// - 发送键随输入内容启用/禁用(空白输入发送必然被宿主拒绝,禁用是最直
///   接的反馈);流式或耗时命令期间原位换成中断键;
/// - 清空输入只由宿主(见 ChatScreen._send)在控制器真正接受发送后执行,
///   本组件不碰草稿文本;
/// - 「/ 命令 · @ 技能」提示文案与各 tooltip 是既有交互契约,改动需同步测试。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
import '../../models/skill.dart';
import '../../state/providers.dart';
import '../../state/slash_commands.dart';
import '../common/chat_layout.dart';
import '../common/motion.dart';
import '../common/sheet_header.dart';
import '../composer_span_builder.dart';
import '../model_selector_bar.dart';
import '../text_syntax.dart';
import 'reasoning_slider.dart';

/// 输入卡两侧留白:与消息气泡外框的 12px 边距同宽 —— 宽窗下输入卡左右缘
/// 与助手气泡左缘 / 用户气泡右缘严格对齐。
const double _kComposerEdgeInset = 12;

/// 输入卡圆角(输入 12 < 按钮 14 < 卡片 16 < 底单 20 之外的「输入胶囊」档)。
const double _kCardRadius = 24;

/// 消息框最多行数:再长由框内滚动接管,输入区不无限吃掉消息区高度。
const int _kFieldMaxLines = 6;

/// 描边/阴影/按钮切换共用的过渡时长;系统开启「减弱动态效果」时归零。
const Duration _kMotion = Duration(milliseconds: 180);

/// 底栏模型 chip 的最大宽度:超过按模型名省略,不挤占发送键。
const double _kModelChipMaxWidth = 240;

/// 聊天输入区。
///
/// 底栏左侧是命令入口与 @ 技能,右侧依次是模型 chip、(推理徽标)、上下文
/// 使用率圆环与发送/中断键;窄行(手机)与宽行(桌面/平板横屏)同一顺序,
/// chip 按模型名收缩省略,不再定宽撑满。
class ChatComposer extends ConsumerWidget {
  /// 流式或耗时命令进行中:发送键原位换成中断键。
  final bool interruptible;

  /// 斜杠输入 `/xx` 时的实时命令建议(非空时顶替常驻命令组)。
  final List<SlashCommand> suggestions;

  /// 消息输入控制器(宿主持有,清空/草稿归宿主管理)。
  final TextEditingController inputController;

  /// 输入焦点(宿主持有,便于发送后保持键盘)。
  final FocusNode inputFocusNode;

  /// 常驻命令按钮行是否展开(可折叠)。
  final bool commandsExpanded;

  /// 上下文 token 口径(估算 + 可选真实锚点)。
  final ContextLink usage;

  /// 折叠/展开常驻命令按钮行。
  final VoidCallback? onToggleCommands;

  /// 输入变化(用于刷新斜杠建议等派生状态)。
  final ValueChanged<String>? onChanged;

  /// 选择一个命令(命令按钮 / 斜杠建议共用):宿主把命令文本写入输入框
  /// 并聚焦,由用户确认后发送,不立即执行。
  final ValueChanged<SlashCommand>? onInsertCommand;

  /// 发送当前输入。
  final VoidCallback onSend;

  /// 中断正在进行的生成/耗时命令。
  final VoidCallback onInterrupt;

  /// 消息框提示文案;工作台复用时可换成场景化提示。
  final String hintText;

  /// 是否保留命令行与命令/技能入口。false 时只留底栏右半(模型/推理/
  /// 上下文/发送),供没有命令语法的页面(如 AI 制卡)复用同一输入卡。
  final bool showCommands;

  /// 消息框是否可编辑。false 时发送键一并禁用,中断键不受影响。
  final bool enabled;

  /// 非空时键盘发送动作直接提交(Enter 不再换行),用于简报式输入。
  final VoidCallback? onSubmitted;

  const ChatComposer({
    super.key,
    required this.interruptible,
    this.suggestions = const [],
    required this.inputController,
    required this.inputFocusNode,
    this.commandsExpanded = false,
    required this.usage,
    this.onToggleCommands,
    this.onChanged,
    this.onInsertCommand,
    required this.onSend,
    required this.onInterrupt,
    this.hintText = '输入消息…(/ 命令 · @ 技能)',
    this.showCommands = true,
    this.enabled = true,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final motion = motionDurationOf(context, _kMotion);
    final reasoning = ref.watch(appSettingsProvider).reasoningLevel;
    // 输入卡宽度 = 会话列内容宽(列宽 − 两侧与气泡同宽的边距):宽窗列宽
    // 封顶 880,中等/移动宽度取满可用宽 —— 三种情形下输入卡左右缘都与
    // 助手气泡左缘 / 用户气泡右缘对齐。
    final maxWidth =
        chatColumnMaxWidth(MediaQuery.sizeOf(context).width) -
        _kComposerEdgeInset * 2;
    // 聊天页 Scaffold 没有 appBar(AppBar 手工排在正文列里),body 的
    // MediaQuery 仍带状态栏顶部留白;composer 贴在屏幕底部,只需左右/底部
    // 安全区 —— top: true 会在输入卡上方垫出一条状态栏高的空白带,移动端
    // 表现为约一厘米的「不显示气泡」区域。
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          _kComposerEdgeInset,
          4,
          _kComposerEdgeInset,
          8,
        ),
        // 先经 Align 松开紧约束再封顶 —— 紧约束下 ConstrainedBox 的上限会被
        // enforce 钳回全宽,封顶静默失效(与模型 chip 封顶同陷阱)。
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showCommands) _commandRow(context, motion),
                // 聚焦态只驱动外描边与阴影,不重建整页:FocusNode 是
                // Listenable,失焦/聚焦在这里就地重建这一小块。
                ListenableBuilder(
                  listenable: inputFocusNode,
                  builder: (context, _) => AnimatedContainer(
                    duration: motion,
                    curve: Curves.easeOut,
                    decoration: _cardDecoration(
                      context,
                      inputFocusNode.hasFocus,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(_kCardRadius - 1),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _field(context),
                          _footer(context, ref, reasoning, motion),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 输入卡外观:白色卡面 + 发丝边,聚焦时描边转主色并加深投影。
  BoxDecoration _cardDecoration(BuildContext context, bool focused) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(_kCardRadius),
      border: Border.all(
        color: focused
            ? scheme.primary.withValues(alpha: 0.55)
            : scheme.outlineVariant.withValues(alpha: 0.5),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: focused ? 0.08 : 0.05),
          blurRadius: focused ? 18 : 10,
          offset: const Offset(0, 5),
        ),
      ],
    );
  }

  /// 消息框:默认一行、最多 [_kFieldMaxLines] 行。
  ///
  /// 主题的 InputDecorationTheme 默认 `filled` 且带聚焦描边:这里全部显式
  /// 关掉,避免在输入卡里再叠一层灰底方块与内层蓝色描边 —— 焦点反馈统一
  /// 由外层输入卡承担。
  Widget _field(BuildContext context) {
    return TextField(
      controller: inputController,
      focusNode: inputFocusNode,
      enabled: enabled,
      minLines: 1,
      maxLines: _kFieldMaxLines,
      keyboardType: TextInputType.multiline,
      textInputAction:
          onSubmitted == null ? TextInputAction.newline : TextInputAction.send,
      onChanged: onChanged,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
      decoration: InputDecoration(
        hintText: hintText,
        hintMaxLines: 1,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      ),
    );
  }

  /// 输入卡底栏:浅一档的 tonal 分区,与消息框用发丝线分开。
  Widget _footer(
    BuildContext context,
    WidgetRef ref,
    ReasoningLevel reasoning,
    Duration motion,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final badge = reasoning == ReasoningLevel.off
        ? null
        : _ReasoningBadge(
            level: reasoning.label,
            onTap: () => _pickReasoning(context, ref, reasoning),
          );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          if (showCommands) ...[
            _toolButton(
              context,
              tooltip: commandsExpanded ? '收起命令按钮行' : '展开命令按钮行',
              icon: commandsExpanded ? Icons.expand_less : Icons.terminal,
              active: commandsExpanded,
              onPressed: onToggleCommands,
            ),
            const SizedBox(width: 2),
            if (onInsertCommand != null)
              _toolButton(
                context,
                tooltip: '插入技能(@)',
                icon: Icons.alternate_email,
                onPressed: () => _pickSkill(context, ref),
              ),
          ],
          // 中段全部让给模型 chip:Align 松开紧约束后按模型名自适应收窄,
          // 长名省略;聊天页继续贴右给固定组让位,精简模式(无命令/技能
          // 入口的工作台)贴左,与输入框左缘对齐不再悬在中间。
          Expanded(
            child: Align(
              alignment:
                  showCommands ? Alignment.centerRight : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: _kModelChipMaxWidth,
                ),
                child: const ModelSelectorChip(),
              ),
            ),
          ),
          if (badge != null) ...[const SizedBox(width: 6), badge],
          const SizedBox(width: 6),
          ContextUsageRing(usage: usage),
          const SizedBox(width: 8),
          _primaryAction(context, motion),
        ],
      ),
    );
  }

  /// 底栏图标按钮:34 的命中外径比旧 28 更易点中,active 时主色高亮底。
  Widget _toolButton(
    BuildContext context, {
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      iconSize: 19,
      style: IconButton.styleFrom(
        foregroundColor: active ? scheme.primary : scheme.onSurfaceVariant,
        backgroundColor: active
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        shape: const CircleBorder(),
      ),
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }

  /// 发送/中断主按钮。
  ///
  /// 同一颗按钮承担两种动作:流式或耗时命令期间是红色中断键,否则是主色
  /// 发送键(空白输入禁用)。动作与 tooltip 随状态**即时**切换,只有图标
  /// 在按钮内部淡入缩放 —— 若整颗按钮做外观切换,过渡期会同时存在两颗
  /// 可点按钮,tooltip 也会短暂出现两种文案。
  Widget _primaryAction(BuildContext context, Duration motion) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: inputController,
      builder: (context, value, _) {
        final canSend = enabled && value.text.trim().isNotEmpty;
        return IconButton.filled(
          tooltip: interruptible ? '中断生成' : '发送',
          constraints: const BoxConstraints.tightFor(width: 38, height: 38),
          padding: EdgeInsets.zero,
          iconSize: 20,
          style: IconButton.styleFrom(
            backgroundColor: interruptible ? scheme.error : scheme.primary,
            foregroundColor: interruptible ? scheme.onError : scheme.onPrimary,
            disabledBackgroundColor: scheme.surfaceContainerHighest,
            disabledForegroundColor: scheme.onSurfaceVariant.withValues(
              alpha: 0.45,
            ),
            shape: const CircleBorder(),
          ),
          onPressed: interruptible ? onInterrupt : (canSend ? onSend : null),
          icon: AnimatedSwitcher(
            duration: motion,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: Icon(
              interruptible ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              key: ValueKey(interruptible),
            ),
          ),
        );
      },
    );
  }

  /// 命令行:斜杠建议优先;无建议时按折叠状态显示常驻命令组。
  ///
  /// 显隐与内容切换都发生在 [AnimatedSize] 内:键盘弹出/收起旁边的输入卡
  /// 位置不动,命令行从底部对齐伸缩;ClipRect 防止收起过程的内容溢画。
  Widget _commandRow(BuildContext context, Duration motion) {
    final show = suggestions.isNotEmpty || commandsExpanded;
    final cmds = suggestions.isNotEmpty ? suggestions : allSlashCommands;
    return ClipRect(
      child: AnimatedSize(
        duration: motion,
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: show
            ? Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _chipLayout(context, cmds),
              )
            : const SizedBox(width: double.infinity, height: 0),
      ),
    );
  }

  /// 命令 chip 布局:单行横向排布,窄窗下滚动查看 —— 不换行,避免多加
  /// 一行命令占掉消息区高度。桌面滚轮/拖拽由 [_ScrollableChipRow] 支持。
  Widget _chipLayout(BuildContext context, List<SlashCommand> cmds) {
    return _ScrollableChipRow(
      children: [
        for (final c in cmds)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _commandChip(context, c),
          ),
      ],
    );
  }

  /// 一行命令 chip(常驻按钮行与斜杠建议共用,样式完全一致)。
  ///
  /// shrinkWrap 命中区避免 48 的默认触控外扩盖到输入卡上;间距由布局方
  /// ([_chipLayout]) 统一给,换行与单行两种排版保持一致。
  Widget _commandChip(BuildContext context, SlashCommand c) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(Icons.terminal, size: 15, color: scheme.primary),
      label: Text(_commandLabel(c)),
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
      tooltip: slashCommandDescription[c],
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: scheme.surface,
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onPressed: onInsertCommand == null ? null : () => onInsertCommand!(c),
    );
  }

  /// 命令 chip 的显示文本:常驻与斜杠建议用同一份(标签一致)。
  static String _commandLabel(SlashCommand c) =>
      '${slashCommandSlash(c)} ${slashCommandLabel[c]}';

  /// 推理等级快捷切换:点底栏徽标拖动滑块改档,不必打开模型选择器。
  /// 写库成功后才更新内存(与模型选择器同一约定),失败保留原值并提示。
  Future<void> _pickReasoning(
    BuildContext context,
    WidgetRef ref,
    ReasoningLevel current,
  ) async {
    final picked = await showModalBottomSheet<ReasoningLevel>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ChatSheetHeader(
                icon: Icons.psychology_outlined,
                title: '推理等级',
              ),
              const SizedBox(height: 4),
              ReasoningSlider(
                value: current,
                onSelected: (level) => Navigator.pop(sheetContext, level),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await persistReasoningLevel(
        level: picked,
        appSettingsSetter: (s) =>
            ref.read(appSettingsProvider.notifier).state = s,
        repo: ref.read(appSettingsRepositoryProvider),
        current: ref.read(appSettingsProvider),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('保存推理等级失败,请重试')));
      }
    }
  }

  /// @ 技能选择弹层:列出全部启用中的技能(name + description),点选即把
  /// `@技能名 ` 插入输入框光标处 —— 与发送端的触发判据(文本含 @技能名)
  /// 完全同构,选中即等价于主动调用该技能。无启用技能时给引导提示。
  Future<void> _pickSkill(BuildContext context, WidgetRef ref) async {
    final skills = await ref.read(skillsProvider.future);
    final usable = [
      for (final s in skills)
        if (s.enabled && s.name.trim().isNotEmpty) s,
    ];
    if (!context.mounted) return;
    if (usable.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无启用的技能,可在 设置 → 全局技能 中创建')));
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.alternate_email, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text('调用技能', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(sheetContext),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: usable.length,
                itemBuilder: (context, index) {
                  final s = usable[index];
                  return ListTile(
                    leading: const Icon(Icons.extension_outlined),
                    title: Text('@${s.name.trim()}'),
                    subtitle: s.description.trim().isEmpty
                        ? null
                        : Text(
                            s.description.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _insertSkillToken(s);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 把 `@技能名 ` 插入输入框光标处并聚焦;编程式赋值不会触发 TextField 的
  /// onChanged,手动补一次以刷新斜杠建议等派生状态。
  void _insertSkillToken(Skill s) {
    final controller = inputController;
    final token = '@${s.name.trim()} ';
    final selection = controller.selection;
    final offset = selection.isValid && selection.baseOffset >= 0
        ? selection.baseOffset
        : controller.text.length;
    final text = controller.text.replaceRange(offset, offset, token);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset + token.length),
    );
    inputFocusNode.requestFocus();
    onChanged?.call(controller.text);
  }
}

/// 推理等级徽标:只显示等级单字(高/中/低),tooltip 补全语义。完整「推理 xx」
/// 文案在窄屏输入框底栏会与模型 chip 抢宽互相省略,单字徽标恒定窄小。
class _ReasoningBadge extends StatelessWidget {
  final String level;
  final VoidCallback? onTap;
  const _ReasoningBadge({required this.level, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '推理等级:$level',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.tertiary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            level,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.tertiary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// 输入框控制器:把本地特殊语法渲染成行内样式。
///
/// 只影响显示层 —— [text]/[value] 始终保持原始输入(命令/技能/标签字符一个
/// 不少),发送管线照常按原文解析。语法集合由 ChatScreen 每次 build 经
/// [updateSyntax] 更新;IME 组合中回退基类渲染,保住组合下划线。
class ComposerSyntaxController extends TextEditingController {
  CompiledSyntax _syntax = CompiledSyntax.compile();
  bool _highlightDialogue = true;
  bool _disposed = false;
  bool _notifyScheduled = false;

  TextSpan? _cachedSpan;
  bool _hasCache = false;
  String? _cachedText;
  TextStyle? _cachedStyle;
  String? _cachedSignature;
  ColorScheme? _cachedScheme;
  bool? _cachedDialogue;

  ComposerSyntaxController();

  /// 注入最新语法与台词高亮开关;仅在内容变化时清缓存并异步刷新一次。
  ///
  /// 调用点在 ChatScreen.build 内,不能同步 notifyListeners(会触发布局期
  /// 重建);post-frame 通知只用于技能集合变化后的高亮兜底。
  void updateSyntax(
    CompiledSyntax syntax, {
    required bool highlightDialogue,
  }) {
    final changed =
        syntax.signature != _syntax.signature ||
        highlightDialogue != _highlightDialogue;
    _syntax = syntax;
    _highlightDialogue = highlightDialogue;
    if (!changed) return;
    _clearCache();
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _clearCache() {
    _hasCache = false;
    _cachedSpan = null;
    _cachedText = null;
    _cachedStyle = null;
    _cachedSignature = null;
    _cachedScheme = null;
    _cachedDialogue = null;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // IME 组合中回退默认渲染,保住组合文字的下划线交互。
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final text = this.text;
    // 快路径:没有可能触发语法的字符时完全不做扫描。
    if (text.isEmpty || !_syntax.mayContainSpecial(text)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    if (_hasCache &&
        _cachedText == text &&
        _cachedStyle == style &&
        _cachedSignature == _syntax.signature &&
        _cachedScheme == scheme &&
        _cachedDialogue == _highlightDialogue) {
      return _cachedSpan!;
    }
    final palette = SyntaxPalette.of(
      scheme,
      SyntaxSurface.composer,
      baseTextColor: style?.color,
    );
    final built = buildComposerSpans(
      text: text,
      baseStyle: style,
      syntax: _syntax,
      palette: palette,
      highlightDialogue: _highlightDialogue,
    );
    final span =
        built ??
        super.buildTextSpan(
          context: context,
          style: style,
          withComposing: withComposing,
        );
    _hasCache = true;
    _cachedSpan = span;
    _cachedText = text;
    _cachedStyle = style;
    _cachedSignature = _syntax.signature;
    _cachedScheme = scheme;
    _cachedDialogue = _highlightDialogue;
    return span;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 单行命令 chip 的横向滚动容器。
///
/// 抹平桌面端的两个输入差异:
/// - 鼠标默认不参与拖拽滚动 → 显式把 mouse/trackpad 加入 dragDevices;
/// - 鼠标滚轮只产生纵向 delta → 把纵向增量映射到横向(jumpTo 即时跟随,
///   不加惯性),触控板横滑自带 dx 时优先用 dx。
///
/// 滚轮事件经 pointerSignalResolver 独占:横向 delta 场景里内部 Scrollable
/// 可能先注册,避免同一事件被二次消费。
class _ScrollableChipRow extends StatefulWidget {
  final List<Widget> children;
  const _ScrollableChipRow({required this.children});

  @override
  State<_ScrollableChipRow> createState() => _ScrollableChipRowState();
}

class _ScrollableChipRowState extends State<_ScrollableChipRow> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final position = _controller.position;
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    final delta = dx.abs() >= dy.abs() ? dx : dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (!_controller.hasClients) return;
      final target = (_controller.offset + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (target != _controller.offset) _controller.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
          },
        ),
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: Row(children: widget.children),
        ),
      ),
    );
  }
}
