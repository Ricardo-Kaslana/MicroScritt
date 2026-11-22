/// 聊天输入区(composer):命令行、消息输入卡与工具底栏。
///
/// 自上而下:
/// - 命令行:输入 `/xx` 时的实时建议,或手动展开的常驻命令组,同一个
///   [AnimatedSize] 负责显隐,展开/收起不跳变(移动端形态);
/// - 输入卡:消息框(默认一行高、随输入增长到 [_kFieldMaxLines] 行)+ 底栏
///   (命令入口、@ 技能、「模型 | 推理」合并胶囊、上下文圆环、发送/中断键);
/// - 输入卡与消息列同宽收敛:宽窗左右缘对齐助手气泡左缘 / 用户气泡右缘,
///   窄窗吃满可用宽度;
///
/// 弹层形态按平台分流:移动端保持底部抽屉([showAppSheet])与内联命令行;
/// 桌面端([isDesktopPlatformOf])一律改为锚定弹卡([showAppFlyout])——
/// 斜杠命令建议与 `@` 技能建议都从输入卡上方原地长出(↑/↓ 选择、Enter
/// 插入、Esc 关闭),命令、技能与推理等级也可从各自入口按钮上方弹出,
/// 鼠标点选后无需移步屏幕底缘。
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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
import '../../models/skill.dart';
import '../../state/providers.dart';
import '../../state/skill_suggestions.dart';
import '../../state/slash_commands.dart';
import '../common/app_flyout.dart';
import '../common/app_sheet.dart';
import '../common/app_snack_bar.dart';
import '../common/chat_layout.dart';
import '../common/layout_breakpoints.dart';
import '../common/motion.dart';
import '../common/sheet_header.dart';
import '../composer_span_builder.dart';
import '../model_selector_bar.dart';
import '../text_syntax.dart';
import '../theme/app_theme.dart';
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

/// 底栏模型胶囊的最大宽度:桌面宽窗能放下更长的模型名,移动端优先把
/// 宽度留给输入与发送键。
const double _kModelCapsuleMaxWidthDesktop = 320;
const double _kModelCapsuleMaxWidthMobile = 240;

/// 桌面弹卡定宽:命令/建议卡按命令行文案适配,技能卡放下两行描述。
const double _kCommandFlyoutWidth = 320;
const double _kSkillFlyoutWidth = 360;
const double _kReasoningFlyoutWidth = 320;

/// 输入卡上方建议弹卡的内容类型:斜杠命令或 `@` 技能,二者共用同一张卡位。
enum _SuggestionMode { command, skill }

/// 斜杠建议是否与上一帧相同:宿主每次重建都带同一列表,相同就不重复同步,
/// 避免用户 Esc/点卡外关掉后又被无关重建弹开。
bool _sameSuggestions(List<SlashCommand> a, List<SlashCommand> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 聊天输入区。
///
/// 底栏左侧是命令入口与 @ 技能,右侧依次是「模型 | 推理」合并胶囊、(桌面端
/// 的)推理档位、上下文使用率圆环与发送/中断键;窄行(手机)与宽行(桌面/
/// 平板横屏)的组件顺序一致,但间距与可见部件按平台各自排版。
class ChatComposer extends ConsumerStatefulWidget {
  /// 流式或耗时命令进行中:发送键原位换成中断键。
  final bool interruptible;

  /// 斜杠输入 `/xx` 时的实时命令建议(非空时顶替常驻命令组)。
  final List<SlashCommand> suggestions;

  /// 消息输入控制器(宿主持有,清空/草稿归宿主管理)。
  final TextEditingController inputController;

  /// 输入焦点(宿主持有,便于发送后保持键盘)。
  final FocusNode inputFocusNode;

  /// 常驻命令按钮行是否展开(可折叠;移动端形态,桌面端由弹卡顶替)。
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

  /// 桌面端按 Enter 直接发送、Shift+Enter 换行。
  ///
  /// 与 [onSubmitted] 互斥使用:后者改的是软键盘动作(移动端也生效),
  /// 这里只在桌面键盘上拦截 Enter,移动端仍保持换行。
  final bool submitOnEnter;

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
    this.submitOnEnter = false,
  });

  @override
  ConsumerState<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends ConsumerState<ChatComposer> {
  /// 输入卡锚点:桌面端斜杠建议弹卡从这里原地向上展开。
  final GlobalKey _cardAnchorKey = GlobalKey();

  /// 键盘导航的高亮下标(建议弹卡与 [Focus.onKeyEvent] 共享)。
  final ValueNotifier<int> _suggestionIndex = ValueNotifier(0);

  /// 打开中的斜杠建议弹卡;null = 未打开。
  FlyoutHandle? _suggestionFlyout;

  /// 当前建议卡内容类型;命令与技能共用 [_suggestionFlyout]。
  _SuggestionMode? _suggestionMode;

  /// 光标所在的 `@` 提及;null = 当前不提供技能建议。
  SkillMentionQuery? _skillMention;

  /// 当前匹配的技能列表(键盘导航与弹卡内容共用)。
  List<Skill> _skillSuggestions = const [];

  /// didUpdateWidget 在 build 期触发,弹卡的开/关/热更新统一推迟到帧尾。
  bool _suggestionSyncScheduled = false;

  bool get _desktop => isDesktopPlatformOf(context);

  @override
  void initState() {
    super.initState();
    widget.inputController.addListener(_onInputValueChanged);
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputController != widget.inputController) {
      oldWidget.inputController.removeListener(_onInputValueChanged);
      widget.inputController.addListener(_onInputValueChanged);
    }
    if (oldWidget.inputController != widget.inputController ||
        oldWidget.showCommands != widget.showCommands ||
        !_sameSuggestions(oldWidget.suggestions, widget.suggestions)) {
      _syncSuggestionFlyout();
    }
  }

  @override
  void dispose() {
    widget.inputController.removeListener(_onInputValueChanged);
    _suggestionFlyout?.close();
    _suggestionIndex.dispose();
    super.dispose();
  }

  /// 文本或光标变化时重算 `@` 提及:斜杠命令正文优先,不在这里给技能建议。
  /// 弹卡开合仍推迟到帧尾,与宿主 setState 驱动的建议刷新合并。
  void _onInputValueChanged() {
    final value = widget.inputController.value;
    final cursor = value.selection.isValid
        ? value.selection.extentOffset
        : value.text.length;
    final next = value.text.trimLeft().startsWith('/')
        ? null
        : skillMentionAt(value.text, cursor);
    if (next == _skillMention) return;
    _skillMention = next;
    _syncSuggestionFlyout();
  }

  @override
  Widget build(BuildContext context) {
    final motion = motionDurationOf(context, _kMotion);
    final reasoning = ref.watch(appSettingsProvider).reasoningLevel;
    // 技能目录异步就绪后重算候选:先开卡显示加载圈,数据到达再收敛。
    ref.listen(skillsProvider, (_, _) => _syncSuggestionFlyout());
    // 输入卡宽度 = 会话列内容宽(列宽 − 两侧与气泡同宽的边距):列宽 880
    // 封顶,输入卡最大 856;窄/中窗吃满可用宽 —— 输入卡左右缘始终与
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
                // 桌面端的命令组与斜杠建议都由弹卡呈现,不再占消息区高度。
                if (widget.showCommands && !_desktop)
                  _commandRow(context, motion),
                // 聚焦态只驱动外描边与阴影,不重建整页:FocusNode 是
                // Listenable,失焦/聚焦在这里就地重建这一小块。
                ListenableBuilder(
                  listenable: widget.inputFocusNode,
                  builder: (context, _) => KeyedSubtree(
                    // 桌面端斜杠建议弹卡的锚点:弹卡底边贴输入卡顶缘。
                    key: _cardAnchorKey,
                    child: AnimatedContainer(
                      duration: motion,
                      curve: Curves.easeOut,
                      decoration: _cardDecoration(
                        context,
                        widget.inputFocusNode.hasFocus,
                      ),
                      child: ClipRRect(
                        key: const ValueKey('composer_card'),
                        borderRadius: BorderRadius.circular(_kCardRadius - 1),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _field(context),
                            _footer(context, reasoning, motion),
                          ],
                        ),
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
    final platform = Theme.of(context).platform;
    final desktop =
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
    Widget field = TextField(
      controller: widget.inputController,
      focusNode: widget.inputFocusNode,
      enabled: widget.enabled,
      minLines: 1,
      maxLines: _kFieldMaxLines,
      keyboardType: TextInputType.multiline,
      textInputAction: widget.onSubmitted == null
          ? TextInputAction.newline
          : TextInputAction.send,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted == null
          ? null
          : (_) => widget.onSubmitted!(),
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4),
      decoration: InputDecoration(
        hintText: widget.hintText,
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
    if (desktop) {
      // 桌面视觉密度比移动端紧一档,TextField 自身反而更矮;上下各垫 8px,
      // 让桌面输入卡比移动端高 6,单行输入在宽卡里不再显得扁。
      field = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: field,
      );
    }
    if (!widget.submitOnEnter) return field;
    // 输入框自身是焦点后代,这里作为祖先 Focus 接收冒泡的按键:
    // 建议弹卡打开时 ↑/↓ 移动高亮、Tab 补全高亮项(Shift+Tab 反向移动)、
    // Enter 选中插入、Esc 关闭;否则 Enter 提交、Shift+Enter 放行给多行
    // 输入;输入法组合中不提交,避免中文候选词的确认键被当成发送。
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (_suggestionFlyout?.isOpen ?? false) {
          final count = _activeSuggestionCount;
          if (key == LogicalKeyboardKey.escape) {
            _suggestionFlyout?.close();
            return KeyEventResult.handled;
          }
          if (count > 0 && key == LogicalKeyboardKey.arrowDown) {
            _moveSuggestion(1);
            return KeyEventResult.handled;
          }
          if (count > 0 && key == LogicalKeyboardKey.arrowUp) {
            _moveSuggestion(-1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.tab) {
            // Tab 是补全语义,不能放行给焦点遍历,否则卡片还开着焦点就跑了。
            if (count > 0) {
              if (HardwareKeyboard.instance.isShiftPressed) {
                _moveSuggestion(-1);
              } else {
                final index = _suggestionIndex.value.clamp(0, count - 1);
                _pickActiveSuggestion(index);
              }
            }
            return KeyEventResult.handled;
          }
          if ((key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter) &&
              !HardwareKeyboard.instance.isShiftPressed) {
            // 卡片已开但候选还在加载时也不能让 Enter 直接发出半截 @ 文本。
            if (count > 0) {
              final index = _suggestionIndex.value.clamp(0, count - 1);
              _pickActiveSuggestion(index);
            }
            return KeyEventResult.handled;
          }
        }
        if (key != LogicalKeyboardKey.enter &&
            key != LogicalKeyboardKey.numpadEnter) {
          return KeyEventResult.ignored;
        }
        if (HardwareKeyboard.instance.isShiftPressed) {
          return KeyEventResult.ignored;
        }
        if (widget.inputController.value.composing.isValid) {
          return KeyEventResult.ignored;
        }
        // 忙碌期发送键已换成中断键,Enter 不再触发发送。
        if (!widget.enabled || widget.interruptible) {
          return KeyEventResult.ignored;
        }
        widget.onSend();
        return KeyEventResult.handled;
      },
      child: field,
    );
  }

  /// 输入卡底栏:浅一档的 tonal 分区,与消息框用发丝线分开。
  ///
  /// 两端按平台各自排版:
  /// - 桌面端:左侧命令/技能入口 32,右侧「模型 | 推理」合并胶囊 → 圆环 →
  ///   发送键统一成 32/32/38,组件之间留 10,宽窗下节奏一致;
  /// - 移动端:工具按钮收紧到 30 且零间距,合并胶囊只留模型段,组件之间
  ///   留 4~6,把宽度优先让给模型名。
  ///
  /// 桌面端的命令/技能入口换成锚定弹卡触发件;移动端保持原交互,且不再
  /// 单独显示推理档位(调整推理走模型选择底单里的滑块)。
  Widget _footer(
    BuildContext context,
    ReasoningLevel reasoning,
    Duration motion,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final desktop = _desktop;
    final showReasoning = desktop && reasoning != ReasoningLevel.off;
    return Container(
      // 移动端水平留白收到 6,给模型胶囊多腾几个像素;桌面维持 8。
      padding: EdgeInsets.symmetric(horizontal: desktop ? 8 : 6, vertical: 6),
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
          if (widget.showCommands) ...[
            if (desktop)
              AppFlyoutAnchor(
                width: _kCommandFlyoutWidth,
                alignment: AppFlyoutAlignment.start,
                builder: (context, handle) => _toolButton(
                  context,
                  tooltip: '命令',
                  icon: Icons.terminal,
                  onPressed: handle.toggle,
                ),
                flyoutBuilder: (context, handle) =>
                    _commandFlyoutContent(context, handle),
              )
            else
              _toolButton(
                context,
                tooltip: widget.commandsExpanded ? '收起命令按钮行' : '展开命令按钮行',
                icon: widget.commandsExpanded
                    ? Icons.expand_less
                    : Icons.terminal,
                active: widget.commandsExpanded,
                onPressed: widget.onToggleCommands,
                size: 30,
              ),
            // 桌面留 4 的呼吸;移动端两颗工具按钮零间距紧贴,挤压出更多
            // 模型胶囊宽度。
            if (desktop) const SizedBox(width: 4),
            if (widget.onInsertCommand != null)
              if (desktop)
                AppFlyoutAnchor(
                  width: _kSkillFlyoutWidth,
                  alignment: AppFlyoutAlignment.start,
                  builder: (context, handle) => _toolButton(
                    context,
                    tooltip: '调用技能(@)',
                    icon: Icons.alternate_email,
                    // 与命令按钮同一 toggle 语义;先校验有可用技能再开卡,
                    // 避免弹出空卡(无技能时仍走 SnackBar 引导)。
                    onPressed: () {
                      if (handle.isOpen) {
                        handle.close();
                        return;
                      }
                      _pickSkill(handle);
                    },
                  ),
                  flyoutBuilder: (context, handle) => _SkillFlyoutCard(
                    onPick: (skill) {
                      handle.close();
                      _insertSkillToken(skill);
                    },
                  ),
                )
              else
                _toolButton(
                  context,
                  tooltip: '插入技能(@)',
                  icon: Icons.alternate_email,
                  onPressed: _pickSkillSheet,
                  size: 30,
                ),
          ],
          // 中段让给「模型 | 推理」合并胶囊:Align 松开紧约束后按内容
          // 自适应收窄,长模型名省略;聊天页继续贴右键组,精简模式(无
          // 命令/技能入口的工作台)贴左,与输入框左缘对齐。
          Expanded(
            child: Align(
              alignment: widget.showCommands
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: desktop
                      ? _kModelCapsuleMaxWidthDesktop
                      : _kModelCapsuleMaxWidthMobile,
                ),
                child: _modelCapsule(context, reasoning, showReasoning),
              ),
            ),
          ),
          // 桌面宽窗给足呼吸(10);移动端收紧到 4/6,保持一行不挤。
          SizedBox(width: desktop ? 10 : 4),
          ContextUsageRing(usage: widget.usage),
          SizedBox(width: desktop ? 10 : 6),
          _primaryAction(context, motion),
        ],
      ),
    );
  }

  /// 底栏「模型 | 推理」合并胶囊。
  ///
  /// 两段共用一层中立底色与整块圆角 Material:模型段占左半,推理段占右半,
  /// 中间只隔一条短发丝线。悬停/按下的反馈落在各自段内,视觉上仍是一颗
  /// 完整的胶囊 —— 不再由两段各自上色后硬拼,接缝处不会出现两种色块的直边。
  /// 推理非 Off 时才拉出右段,且只在桌面出现(移动端走模型底单里的滑块)。
  Widget _modelCapsule(
    BuildContext context,
    ReasoningLevel reasoning,
    bool showReasoning,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('model_reasoning_capsule'),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      shape: StadiumBorder(
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 两段都给弹性(模型 2 份、推理 1 份):极窄视口下推理文本先
          // 省略,模型段吃到 2/3 剩余宽,整颗胶囊始终塞进底栏不溢出。
          const Flexible(flex: 2, child: ModelSelectorChip(embedded: true)),
          if (showReasoning) ...[
            // 线高短于胶囊,上下留白,读作分区而不是把胶囊一分为二。
            Container(
              key: const ValueKey('model_reasoning_divider'),
              width: 1,
              height: 16,
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
            Flexible(
              flex: 1,
              child: AppFlyoutAnchor(
                width: _kReasoningFlyoutWidth,
                builder: (context, handle) => _ReasoningBadge(
                  level: reasoning.label,
                  onTap: handle.toggle,
                ),
                flyoutBuilder: (context, handle) => _reasoningFlyoutContent(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 底栏图标按钮:桌面 32 与合并胶囊/圆环同高;移动端收紧到 30,给模型
  /// 胶囊让出宽度。active 时主色高亮底。
  Widget _toolButton(
    BuildContext context, {
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool active = false,
    double size = 32,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
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
      valueListenable: widget.inputController,
      builder: (context, value, _) {
        final canSend = widget.enabled && value.text.trim().isNotEmpty;
        return IconButton.filled(
          tooltip: widget.interruptible ? '中断生成' : '发送',
          constraints: const BoxConstraints.tightFor(width: 38, height: 38),
          padding: EdgeInsets.zero,
          iconSize: 20,
          style: IconButton.styleFrom(
            backgroundColor: widget.interruptible
                ? scheme.error
                : scheme.primary,
            foregroundColor: widget.interruptible
                ? scheme.onError
                : scheme.onPrimary,
            disabledBackgroundColor: scheme.surfaceContainerHighest,
            disabledForegroundColor: scheme.onSurfaceVariant.withValues(
              alpha: 0.45,
            ),
            shape: const CircleBorder(),
          ),
          onPressed: widget.interruptible
              ? widget.onInterrupt
              : (canSend ? widget.onSend : null),
          icon: AnimatedSwitcher(
            duration: motion,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: animation, child: child),
            ),
            child: Icon(
              widget.interruptible
                  ? Icons.stop_rounded
                  : Icons.arrow_upward_rounded,
              key: ValueKey(widget.interruptible),
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
  /// 仅移动端渲染(桌面端由斜杠建议弹卡与命令弹卡顶替)。
  Widget _commandRow(BuildContext context, Duration motion) {
    final show = widget.suggestions.isNotEmpty || widget.commandsExpanded;
    final cmds = widget.suggestions.isNotEmpty
        ? widget.suggestions
        : allSlashCommands;
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
      onPressed: widget.onInsertCommand == null
          ? null
          : () => widget.onInsertCommand!(c),
    );
  }

  /// 命令 chip 的显示文本:常驻与斜杠建议用同一份(标签一致)。
  static String _commandLabel(SlashCommand c) =>
      '${slashCommandSlash(c)} ${slashCommandLabel[c]}';

  // ---------------------------------------------------------------------------
  // 桌面弹卡:斜杠建议 / 全部命令 / 技能 / 推理等级
  // ---------------------------------------------------------------------------

  /// 建议弹卡同步:didUpdateWidget / 文本变化 / 技能目录就绪都在 build 期或
  /// 监听回调里触发,Overlay 的插拔必须推迟到帧尾;一帧内的多次变化合并
  /// 为一次判定。
  void _syncSuggestionFlyout() {
    if (_suggestionSyncScheduled) return;
    _suggestionSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _suggestionSyncScheduled = false;
      if (!mounted) return;
      _applySuggestionSync();
    });
  }

  void _applySuggestionSync() {
    if (!widget.showCommands || !_desktop) {
      _closeSuggestionFlyout();
      return;
    }
    // 斜杠命令优先:命令正文里的 @ 不作为技能触发。
    if (widget.suggestions.isNotEmpty) {
      _openOrRefreshSuggestion(
        mode: _SuggestionMode.command,
        width: _kCommandFlyoutWidth,
        builder: _suggestionCardContent,
      );
      return;
    }
    final mention = _skillMention;
    if (mention == null) {
      _closeSuggestionFlyout();
      return;
    }
    final skillsAsync = ref.read(skillsProvider);
    if (skillsAsync.hasError) {
      _closeSuggestionFlyout();
      return;
    }
    final matches = suggestedSkills(
      skillsAsync.value ?? const <Skill>[],
      mention.query,
    );
    // 技能目录未就绪时先开卡显示加载圈;就绪后无匹配再关闭。
    if (skillsAsync.hasValue && matches.isEmpty) {
      _closeSuggestionFlyout();
      return;
    }
    _skillSuggestions = matches;
    _openOrRefreshSuggestion(
      mode: _SuggestionMode.skill,
      width: _kSkillFlyoutWidth,
      builder: _skillSuggestionCardContent,
    );
  }

  /// 打开或热更新同一类型的建议卡;命令/技能切换时换一张卡(定宽不同)。
  void _openOrRefreshSuggestion({
    required _SuggestionMode mode,
    required double width,
    required WidgetBuilder builder,
  }) {
    _suggestionIndex.value = 0;
    final handle = _suggestionFlyout;
    if (handle != null && handle.isOpen && _suggestionMode == mode) {
      // 建议列表随输入收缩:热更新已开弹卡的内容,不闪不跳。
      handle.rebuild();
      return;
    }
    handle?.close();
    final anchor = _cardAnchorKey.currentContext;
    if (anchor == null) return;
    _suggestionMode = mode;
    _suggestionFlyout = showAppFlyout(
      anchorContext: anchor,
      width: width,
      alignment: AppFlyoutAlignment.start,
      builder: builder,
      onClose: () {
        _suggestionFlyout = null;
        _suggestionMode = null;
        _skillSuggestions = const [];
        _suggestionIndex.value = 0;
      },
    );
  }

  void _closeSuggestionFlyout() {
    final handle = _suggestionFlyout;
    _suggestionFlyout = null;
    _suggestionMode = null;
    _skillSuggestions = const [];
    handle?.close();
  }

  /// 斜杠建议弹卡内容:匹配命令行,高亮项带 Enter 提示;高亮下标由
  /// [_suggestionIndex] 驱动,键盘导航不经过宿主 setState。
  Widget _suggestionCardContent(BuildContext context) {
    final cmds = widget.suggestions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ValueListenableBuilder<int>(
            valueListenable: _suggestionIndex,
            builder: (context, active, _) => ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              children: [
                for (final (i, c) in cmds.indexed)
                  _commandCardRow(
                    context,
                    c,
                    highlighted: i == active,
                    onTap: () => _pickSuggestion(c),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// `@` 技能建议弹卡内容:按已输入前缀筛出的技能,高亮行同样支持 Enter 插入。
  /// 技能目录未就绪时先显示加载圈,数据到达后由 [_applySuggestionSync] 收敛。
  Widget _skillSuggestionCardContent(BuildContext context) {
    if (!ref.read(skillsProvider).hasValue) {
      return const SizedBox(
        height: 56,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final skills = _skillSuggestions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ValueListenableBuilder<int>(
            valueListenable: _suggestionIndex,
            builder: (context, active, _) => ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              children: [
                for (final (i, skill) in skills.indexed)
                  _skillCardRow(
                    context,
                    skill,
                    highlighted: i == active,
                    onTap: () => _pickSkillSuggestion(skill),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 全部命令弹卡内容(命令按钮触发):完整命令清单,点选即插入输入框。
  Widget _commandFlyoutContent(
    BuildContext context,
    FlyoutTriggerHandle handle,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppFlyoutHeader(icon: Icons.terminal, title: '命令'),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            children: [
              for (final c in allSlashCommands)
                _commandCardRow(
                  context,
                  c,
                  onTap: () {
                    handle.close();
                    widget.onInsertCommand?.call(c);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 弹卡里的一行命令:图标 + 「/命令 标签」,高亮行垫主色底并补 Enter 提示。
  Widget _commandCardRow(
    BuildContext context,
    SlashCommand c, {
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        color: highlighted ? scheme.primary.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            Icon(Icons.terminal, size: 16, color: scheme.primary),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: Text(
                _commandLabel(c),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (highlighted)
              Text(
                'Enter',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// `@` 技能建议里的一行:名称 + 可选描述,高亮行垫主色底并补 Enter 提示。
  Widget _skillCardRow(
    BuildContext context,
    Skill skill, {
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = skill.description.trim();
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        color: highlighted ? scheme.primary.withValues(alpha: 0.08) : null,
        child: Row(
          children: [
            Icon(Icons.extension_outlined, size: 16, color: scheme.primary),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '@${skill.name.trim()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (highlighted) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Enter',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 当前建议条数:命令与技能共用同一张弹卡,键盘导航按当前类型取长度。
  int get _activeSuggestionCount => switch (_suggestionMode) {
    _SuggestionMode.command => widget.suggestions.length,
    _SuggestionMode.skill => _skillSuggestions.length,
    null => 0,
  };

  /// 键盘导航:在当前建议范围内循环移动高亮。
  void _moveSuggestion(int delta) {
    final count = _activeSuggestionCount;
    if (count == 0) return;
    var next = (_suggestionIndex.value + delta) % count;
    if (next < 0) next += count;
    _suggestionIndex.value = next;
  }

  /// 选定当前类型的建议:命令交给宿主插入斜杠文本,技能直接写入 `@技能名`。
  void _pickActiveSuggestion(int index) {
    switch (_suggestionMode) {
      case _SuggestionMode.command:
        _pickSuggestion(widget.suggestions[index]);
        return;
      case _SuggestionMode.skill:
        _pickSkillSuggestion(_skillSuggestions[index]);
        return;
      case null:
        return;
    }
  }

  /// 选定一条技能建议:关弹卡并把光标所在的 `@前缀` 整体替换为完整令牌。
  void _pickSkillSuggestion(Skill skill) {
    final mention = _skillMention;
    _suggestionFlyout?.close();
    _insertSkillToken(skill, mention: mention);
  }

  /// 选定一条命令建议:关弹卡并交给宿主写入输入框(宿主随后的建议清空会再
  /// 触发一次同步,重复关闭是幂等的)。
  void _pickSuggestion(SlashCommand command) {
    _suggestionFlyout?.close();
    widget.onInsertCommand?.call(command);
  }

  /// 推理等级桌面弹卡:滑块直接内嵌,当前档位实时从设置读 —— 落库成功后
  /// 档位刷新,失败时滑块自动回弹,弹卡保持打开可重试。
  Widget _reasoningFlyoutContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppFlyoutHeader(icon: Icons.psychology_outlined, title: '推理等级'),
          Consumer(
            builder: (context, ref, _) {
              final level = ref.watch(appSettingsProvider).reasoningLevel;
              return ReasoningSlider(
                value: level,
                onSelected: _persistReasoning,
              );
            },
          ),
        ],
      ),
    );
  }

  /// 推理等级快捷切换:点底栏徽标拖动滑块改档,不必打开模型选择器。
  /// 写库成功后才更新内存(与模型选择器同一约定),失败保留原值并提示。
  Future<void> _persistReasoning(ReasoningLevel picked) async {
    try {
      await persistReasoningLevel(
        level: picked,
        appSettingsSetter: (s) =>
            ref.read(appSettingsProvider.notifier).state = s,
        repo: ref.read(appSettingsRepositoryProvider),
        current: ref.read(appSettingsProvider),
      );
    } catch (_) {
      if (mounted) showAppSnack(context, '保存推理等级失败,请重试');
    }
  }

  /// @ 技能选择弹层(桌面):先校验有可用技能(无则提示,不弹空卡),
  /// 再打开锚定弹卡;点选即把 `@技能名 ` 插入输入框光标处 —— 与发送端的
  /// 触发判据(文本含 @技能名)完全同构,选中即等价于主动调用该技能。
  Future<void> _pickSkill(FlyoutTriggerHandle handle) async {
    final skills = await ref.read(skillsProvider.future);
    final usable = suggestedSkills(skills, '');
    if (!mounted) return;
    if (usable.isEmpty) {
      showAppSnack(context, '暂无启用的技能,可在 设置 → 全局技能 中创建');
      return;
    }
    handle.open();
  }

  /// @ 技能选择弹层(移动端):底部抽屉列出全部启用中的技能。
  Future<void> _pickSkillSheet() async {
    final skills = await ref.read(skillsProvider.future);
    final usable = suggestedSkills(skills, '');
    if (!mounted) return;
    if (usable.isEmpty) {
      showAppSnack(context, '暂无启用的技能,可在 设置 → 全局技能 中创建');
      return;
    }
    await showAppSheet<void>(
      context,
      isScrollControlled: false,
      showDragHandle: true,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: ChatSheetHeader(icon: Icons.alternate_email, title: '调用技能'),
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
    );
  }

  /// 把 `@技能名 ` 写入输入框并聚焦。[mention] 非空时先整体替换用户已输入的
  /// `@前缀`,避免候选插入后留下 “@剑@剑术” 这样的重复令牌。
  ///
  /// 编程式赋值不会触发 TextField 的 onChanged,手动补一次以刷新宿主的
  /// 斜杠建议等派生状态;本组件自己的 `@` 提及由控制器监听器同步。
  void _insertSkillToken(Skill s, {SkillMentionQuery? mention}) {
    final controller = widget.inputController;
    final token = '@${s.name.trim()} ';
    final selection = controller.selection;
    final offset = selection.isValid && selection.extentOffset >= 0
        ? selection.extentOffset
        : controller.text.length;
    final from = (mention?.start ?? offset).clamp(0, offset);
    final text = controller.text.replaceRange(from, offset, token);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: from + token.length),
    );
    widget.inputFocusNode.requestFocus();
    widget.onChanged?.call(controller.text);
  }
}

/// 技能弹卡内容:启用中的技能(name + description)逐行列出,点选交给
/// 宿主插入输入框。技能目录经 provider 读取,弹卡打开期间不刷新目录
/// (与移动端底单「打开即快照」同一语义)。
class _SkillFlyoutCard extends ConsumerWidget {
  final ValueChanged<Skill> onPick;
  const _SkillFlyoutCard({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skillsAsync = ref.watch(skillsProvider);
    return skillsAsync.when(
      loading: () => const SizedBox(
        height: 56,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          '技能加载失败,请重试',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      data: (skills) {
        final usable = suggestedSkills(skills, '');
        if (usable.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Text(
              '暂无启用的技能',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppFlyoutHeader(icon: Icons.alternate_email, title: '调用技能'),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                children: [
                  for (final s in usable)
                    AppFlyoutRow(
                      icon: Icons.extension_outlined,
                      title: '@${s.name.trim()}',
                      subtitle: s.description.trim().isEmpty
                          ? null
                          : s.description.trim(),
                      onTap: () => onPick(s),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 推理等级段:只显示英文档位(Off 不显示),tooltip 补全语义。
///
/// 与模型段同处一颗合并胶囊:底色由外层 Material 统一提供,本段只负责
/// 右半的点击面。图标点明这是推理档位,不必再写「推理」二字挤占宽度;
/// 文本保留强调色,与模型名区分开又不会形成第二块色底。
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
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(26)),
        hoverColor: scheme.primary.withValues(alpha: 0.06),
        highlightColor: scheme.primary.withValues(alpha: 0.09),
        child: Padding(
          // 与模型段同厚:同字号 + 同纵向内边距,合并后整颗胶囊齐平。
          padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.psychology_outlined, size: 14, color: scheme.tertiary),
              const SizedBox(width: 3),
              // 极窄视口下文本可省略收缩,外层弹性分配才不会溢出。
              Flexible(
                child: Text(
                  level,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.tertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
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
  void updateSyntax(CompiledSyntax syntax, {required bool highlightDialogue}) {
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
