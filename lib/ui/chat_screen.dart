/// 聊天页:消息流渲染、输入发送、悬浮滚动导航与全部会话入口。
///
/// 消息列表以 `reverse` 渲染显示窗口(贴顶分页),与上下文组装窗口刻意
/// 分离;进入会话先透明收敛到最新消息再显示,滚动路径上零整页 setState。
///
/// 页面状态、build 组装与生命周期留在本文件;滚动、会话操作与消息操作按
/// 职责拆在同库 part 扩展,独立展示件在 `chat/` 下的 part 文件中。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/character_repository.dart';
import '../data/message_repository.dart';
import '../data/session_repository.dart';
import '../engine/background_status.dart';
import '../engine/display_regex.dart';
import '../engine/glossary.dart';
import '../export/session_exporter.dart';
import '../models/character_card.dart';
import '../models/context_snapshot.dart';
import '../models/message.dart';
import '../models/llm_units.dart';
import '../models/skill.dart';
import '../state/chat_controller.dart';
import '../state/providers.dart';
import '../state/slash_commands.dart';
import '../state/ui_prefs_sync.dart';
import 'common/app_menu.dart';
import 'common/app_sheet.dart';
import 'common/app_snack_bar.dart';
import 'common/chat_layout.dart';
import 'common/confirm_dialog.dart';
import 'common/hash_image.dart';
import 'common/inline_spinner.dart';
import 'common/motion.dart';
import 'common/section_header.dart';
import 'common/sheet_header.dart';
import 'common/text_edit_sheet.dart';
import 'common/session_file_helper.dart';
import 'theme/app_theme.dart';
import 'chat_search_screen.dart';
import 'character_edit_screen.dart';
import 'context_panel.dart';
import 'hooks_screen.dart';
import 'model_selector_bar.dart';
import 'skills_screen.dart';
import 'text_syntax.dart';
import 'status_screen.dart';
import 'user_screen.dart';
import 'widgets/chat_composer.dart';
import 'widgets/chat_empty_state.dart';
import 'widgets/chat_session_sidebar.dart';
import 'widgets/message_list.dart';
import 'widgets/message_selection_bar.dart';
import 'widgets/image_viewer.dart';
import 'widgets/chat_island.dart';

part 'chat/chat_screen_scroll.dart';
part 'chat/chat_screen_sessions.dart';
part 'chat/chat_screen_messages.dart';
part 'chat/chat_screen_chrome.dart';
part 'chat/chat_screen_overlays.dart';

/// 聊天页:一条会话的消息流、输入发送与全部会话侧入口。
///
/// 由会话列表页 push 进入。AppBar 提供搜索记录、上下文面板、状态面板与
/// 会话菜单(技能/Hooks/导出/删除);底部输入区整体由 [ChatComposer] 承载
/// (命令行、消息框、模型 chip、上下文圆环与发送/中断键)。
/// [ChatState.messages] 只是显示窗口(贴顶分页补更早
/// 历史),上下文组装另读仓库的活跃窗口 —— 翻阅历史不改变发给 LLM 的内容。
///
/// 流式回复期间草稿走独立 provider,消息列表单独包一层 Consumer 重建;
/// 停止经中断键(取消当前轮的中断令牌),重试走消息操作里的重新生成。
class ChatScreen extends ConsumerStatefulWidget {
  /// 会话 id;控制器据此 load 显示窗口与上下文基线。
  final int sessionId;

  /// 所属角色 id:聊天背景/AppBar 头像按 id 从仓库惰性取列(列表投影已把
  /// avatar/background BLOB 排除,卡里不再自带大图;列里没有则回退卡内已有值)。
  final int characterId;

  /// 路由传入的角色卡快照;进入后按 [characterId] 惰性刷新背景/头像列。
  final CharacterCard character;
  const ChatScreen({
    super.key,
    required this.sessionId,
    required this.characterId,
    required this.character,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = ComposerSyntaxController();
  final _inputFocus = FocusNode();

  /// 多选态的页面级焦点:Esc 与返回键在此退出多选,不依赖输入框。
  final _selectionFocus = FocusNode(debugLabel: 'message-selection');
  final _scroll = ScrollController();
  final _messageListKey = GlobalKey<MessageListState>();

  /// 下一步建议底单是否已打开:防止同一批建议触发重复弹层。
  bool _suggestionSheetOpen = false;

  /// 桌面消息导航的数据源:会话内**全部** user 消息的轻量索引(id/seq/摘要)。
  ///
  /// 刻意与显示窗口分开 —— 窗口只装尾部若干行,导航卡却要覆盖整段历史;
  /// 索引只带 160 字符摘要,长会话也不会把整份转录搬进内存。
  List<UserMessageRef> _userIndex = const [];

  /// 产生当前 [_userIndex] 的那份消息列表实例。消息列表每次变更(发送/删除/
  /// 编辑/压缩)都会整体换实例:据此重查索引,摘要不会停在旧正文上。
  List<Message>? _userIndexSource;

  /// 本会话是否已发起过全量索引查询(每会话一次;窗口增量走同步合并)。
  bool _userIndexQueryStarted = false;

  /// 视口当前对应的 user 消息 id:导航刻度高亮、卡片展开定位与卡片选中态
  /// 都按它判断。用真实可见条目而不是滚动比例 —— 条目高度差异大时比例会
  /// 指到相邻的其它消息,出现"已跳到目标、卡片却高亮别人"。
  final _visibleUserMessageId = ValueNotifier<int?>(null);

  /// 贴底/贴顶邻域标记走 [ValueNotifier] 而非 setState 字段:滚动期间它们
  /// 频繁翻转(每跨一次 80px 阈值就变一次),若走 setState 会连消息列表一起
  /// 整页重建,滑动掉帧;改由悬浮导航组([_ScrollNavRail])自行监听、只重建
  /// 那一小块。build 里的贴底跟随判定直接读 `.value` 取当前值。
  final _nearBottom = ValueNotifier<bool>(true);
  final _nearTop = ValueNotifier<bool>(true);
  int _lastCount = -1;

  /// 用户是否正在拖动消息列表(仅指手指按住的拖动段)。
  ///
  /// 流式期间每个块都会触发一次自动跟随(`_scrollToBottom` → `animateTo`),而
  /// `ScrollPosition.animateTo` 的 `beginActivity` 会 dispose 掉当前 activity ——
  /// 若用户正拖到一半,进行中的拖动会被直接打断、画面被拽回底部,表现为
  /// "流式自动滑动无法打断"。拖动期间跳过自动跟随,让用户手势完整生效;用户
  /// 一旦滚离底部,`_nearBottom` 随之变 false,跟随停止。
  ///
  /// 注意覆盖范围只有"手指按下"这一段:抬手瞬间 ScrollEnd 即复位,抬手后的
  /// **惯性段**与**鼠标滚轮**都不在保护内 —— 那两类由 [_userScrollInProgress]
  /// 的宽限窗在跳转前兜底。
  bool _userDragging = false;

  /// 用户主动发送后的首次新消息到达:强制贴底一次(即使此前停在上方读历史)。
  bool _followAfterSend = false;

  /// 搜索/导航卡定位进行中。定位会 jumpTo 历史位置,`_syncScrollFlags` 随即
  /// 把 `_nearBottom` 翻回 true;若此时恰好有一批条数变化(扩窗/提前分页)
  /// 被 build 消费,贴底跟随会把视口从目标拽回底部、与定位循环抢方向,
  /// 表现为目标与底部两条消息之间来回抖。定位期间一律不跟随,高亮锚点也
  /// 锁定为目标本身(见 [_syncScrollFlags])。
  bool _revealRunning = false;

  /// 定位请求编号:用户连点两条导航项时,后一次必须**接管**而不是被丢弃
  /// (旧实现见 `_revealRunning` 直接 return,第二次点击毫无反应)。旧请求
  /// 的异步链返回后凭编号自行作废,不写高亮、不改跟随基线,也就不可能与
  /// 新请求的定位循环互相拉扯。
  int _revealRequest = 0;

  /// 帧末重算可见锚点的去重标记。程序性跳转在布局更新前就发出滚动通知,
  /// 那一刻算出的锚点可能是 null 或旧位置;帧末(layout/paint 已完成)补算
  /// 一次才是落定后的真实可见消息。见 [_scheduleAnchorResync]。
  bool _anchorResyncScheduled = false;

  /// 最近一次用户主导滚动(拖动/惯性/滚轮,经 [UserScrollNotification] 打点)
  /// 的时刻。程序性跳转不派发该通知,不会误记。
  DateTime _lastUserScroll = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一帧侧栏是否可见。≥1000 的宽窗里侧栏始终挂载(收展只是宽度动画),
  /// 隐藏期(<1200)跳过消息驱动的分组失效;重新展开时补一次失效,避免
  /// 条数/排序停在隐藏前的快照。null = 尚未观察过(首帧不补,初次加载
  /// 本就是新查询)。
  bool? _sidebarWasShown;

  /// 进入会话的初始定位期间,消息列表以完全透明(Opacity 0)渲染:数据首帧
  /// 就不画出来,贴底收敛的多帧 jump 在不可见状态下进行,收敛到位才一次性
  /// 显示 —— 打开会话看到的第一眼直接是最新消息,而不是「从最旧消息一路
  /// 快速扫到底部」的一次可见滚动(长会话的收敛要走几十帧,肉眼完整可见)。
  /// 收敛链的每一条退出路径(贴底 settled、帧预算用尽、用户抢先滚动)都会
  /// 复位本标记([_settleEntry]),不存在滞留隐藏态的路径。置位发生在普通
  /// build 的定位判定里(与数据帧同帧生效,首帧不闪最旧消息),复位是收敛
  /// 完成 postFrame 里的一次 setState;置位期间悬浮滚动导航组一并隐藏。
  bool _entrySettling = false;

  /// controller 状态是否已是本屏会话的数据(`chat.sessionId == widget.sessionId`)。
  /// 会话切换窗口内(load 只清元数据、暂存上一会话的转录直到新数据就绪)为
  /// false:旧转录按初始定位隐藏,滚动尺寸通知也不做贴底跟随。
  bool _screenDataReady = false;

  /// 本屏会话的数据是否已完成过一次进入定位。切换会话时复位。用独立标记而
  /// 不是「消息数从无到有」判定:切换窗口里暂存的旧转录会把消息数基线
  /// ([_lastCount]) 污染成旧会话的条数,新会话条数恰好相同或更多时
  /// 「从无到有」永远不成立,初始定位就被吞掉。
  bool _positioned = false;
  List<SlashCommand> _slashSuggestions = const [];

  /// 常驻命令按钮行是否展开(可折叠)。默认折叠,避免常驻命令 chip 行占掉
  /// 输入区上方一行空间;需要时点输入框左侧的终端图标展开。
  bool _commandsExpanded = false;

  /// 悬浮滚动导航组(爬楼/首尾 FAB)是否折叠。默认展开;阅读长消息时整组
  /// 按钮会压住右下角正文,点「收起」折成一颗半透明小钮,再点即展开。
  /// 同样走 [ValueNotifier]:折叠切换由导航组自行监听,不整页重建。
  final _scrollNavCollapsed = ValueNotifier<bool>(false);

  /// 用户拖动/滚动消息列表时是否自动隐藏悬浮滚动导航组。滚动开始立即隐藏
  /// 整组(让出视觉空间给拖动中的手指和内容),滚动**真正停止**(含惯性
  /// 收尾的最后一个 ScrollEnd)后短暂延迟再恢复。走 [ValueNotifier]:
  /// 滚动路径上零 setState,不整页重建(整页重建正是滑动一卡一卡的来源)。
  final _navAutoHidden = ValueNotifier<bool>(false);

  /// 任一气泡被选中、操作按钮排(复制/编辑/删除/重新发送)是否可见。选中
  /// 最后一条消息时操作排落在列表最底端,正压在导航组的位置上 —— 与滚动
  /// 自动隐藏同一让位策略:操作排可见期间整组隐藏,取消选中即恢复。
  /// 由 MessageList 的 `onActionsVisibleChanged` 回调写入。
  final _messageActionsOpen = ValueNotifier<bool>(false);

  /// 会话内消息多选模式与选中集合。集合走 ValueNotifier:选择变化只重建
  /// 批量操作栏与各气泡的选中态,不整页重建。
  bool _selectionMode = false;
  final _selectedMessageIds = ValueNotifier<Set<int>>(const {});

  /// 「回到顶部」逐页取旧进行中([_scrollToTop]):循环 loadOlder 直到历史
  /// 取尽再跳绝对顶部。期间悬浮导航组常驻显示进度(不随贴顶/自动隐藏消失),
  /// [_maybeLoadOlder] 的分页也不再并发触发。走 [ValueNotifier]:进度态
  /// 只重建导航组那一小块。`dispose` 一并释放。
  final _autoTopRunning = ValueNotifier<bool>(false);

  /// ScrollEnd 后延迟恢复悬浮滚动导航组的计时器。每次新的滚动迹象
  /// (非 idle 的 UserScrollNotification / 拖动开始 / 惯性段的每一帧
  /// ScrollUpdate)都会撤销,避免上一轮延时器在滚动仍进行时触发误恢复。
  /// `dispose` 一并取消。
  Timer? _navRestoreTimer;

  /// 搜索命中后短暂高亮的气泡 id 与收起计时器。
  int? _highlightMessageId;
  Timer? _highlightTimer;

  /// 最近一次会话内搜索关键词:重新打开搜索页时恢复并直接检索。
  String _lastSearchQuery = '';

  /// 灵动岛的瞬态通知中枢:命令反馈(如压缩成功)由此闪示,替代旧 SnackBar。
  final _islandHub = IslandHub();

  /// 用户头像缓存:按 avatarHash 共享一个 FileImage provider,hash 不变时复用,
  /// 换头像后下一次 build 自然切到新的文件缓存键。
  String? _userAvatarKey;
  ImageProvider? _userAvatarImage;

  /// 角色头像缓存(助手气泡旁):与用户头像同款 —— 按 _avatarHash 值缓存
  /// 单个 ImageProvider 实例,全列表共用,流式回复期间反复重建不重新解码。
  String? _assistantAvatarKey;
  ImageProvider? _assistantAvatarImage;

  /// 上下文 token 估算缓存:流式回复期间 build 随每个流式块反复重建,而
  /// `lastContext` 只在每轮生成开始(或 load)时整体替换,同一轮内是同一个
  /// snapshot 实例。直接按该实例身份缓存估算结果,实例不变就复用 —— 避免每帧
  /// 都对完整 system + 全部消息做一次 O(总字符数) 的求和。
  ContextSnapshot? _ctxEstimateSnap;
  int _ctxEstimateTokens = 0;

  /// 聊天背景图(base64)。列表投影不携带 BLOB,聊天页按 characterId 惰性读列:
  /// 列里没有(测试直构/历史空列)回退卡内已有值,再没有就没有背景/头像。
  String? _bgHash;
  String? _avatarHash;

  /// 当前角色卡的本地快照:初始取路由传入的卡,从聊天页编辑角色后刷新,
  /// 让 AppBar 名称/头像与气泡样式立即跟上,不必退出重进会话。
  late CharacterCard _character;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 先以卡内已有值起步(直构/测试/无列时立即可用),再用列值覆盖。
    _character = widget.character;
    _bgHash = widget.character.backgroundHash;
    _avatarHash = widget.character.avatarHash;
    _loadVisuals();
    _load();
  }

  /// 惰性读角色背景/头像列(与角色列表同款策略;大 BLOB 不进列表查询/不随卡
  /// 传导)。列读到什么用什么;读不到(残留超大行/无行)回退卡内已有值,绝不让
  /// 一行把聊天页背景拖垮。
  Future<void> _loadVisuals() async {
    final repo = ref.read(characterRepositoryProvider);
    String? bg;
    String? av;
    try {
      bg = await repo.backgroundHashFor(widget.characterId);
    } catch (_) {
      bg = null;
    }
    // 头像与背景相互独立:背景是否设置都不影响 AppBar/气泡头像的取数
    // (背景层在无专属背景图时才回退头像,但头像本身始终要读)。
    try {
      av = await repo.avatarHashFor(widget.characterId);
    } catch (_) {
      av = null;
    }
    if (!mounted) return;
    final nextBg = bg ?? _character.backgroundHash;
    final nextAv = av ?? _character.avatarHash;
    if (nextBg != _bgHash || nextAv != _avatarHash) {
      setState(() {
        _bgHash = nextBg;
        _avatarHash = nextAv;
      });
    }
  }

  /// 载入当前会话(上下文/记忆/消息)。initState 首次调用;若同一 ChatScreen
  /// 因导航复用而被改写成另一个 sessionId,didUpdateWidget 也会重新载入,
  /// 避免上下文与记忆停留在上一个会话。
  void _load() {
    Future.microtask(
      () => ref
          .read(chatControllerProvider.notifier)
          .load(sessionId: widget.sessionId, character: _character),
    );
  }

  /// 重查桌面消息导航的全量 user 消息索引。查询失败静默保留上一份:导航卡
  /// 是辅助入口,不能因一次读库失败把已显示的历史索引清空。
  Future<void> _refreshUserIndex() async {
    final sessionId = widget.sessionId;
    final List<UserMessageRef> rows;
    try {
      rows = await ref
          .read(messageRepositoryProvider)
          .userMessagesForNavigation(sessionId);
    } catch (_) {
      return;
    }
    if (!mounted || sessionId != widget.sessionId) return;
    setState(() {
      _userIndex = rows;
      // 查询期间可能刚有新消息落库(本次结果不含增量):强制下一帧再用当前
      // 窗口合并一次,避免最新一条 user 消息在导航里缺席。
      _userIndexSource = null;
    });
  }

  /// 用显示窗口内的消息同步索引尾部,保留窗口之外更早的历史项。
  ///
  /// 窗口化时窗口里最小的非 system seq 就是显示窗口下界;`hasOlder=false`
  /// 表示全量在窗,直接用窗口重建整份索引。窗口内的删除/编辑因此立即反映,
  /// 不必再走一次全量查询。
  void _mergeUserIndex(List<Message> messages, {required bool hasOlder}) {
    final windowUsers = <UserMessageRef>[];
    int? floor;
    for (final message in messages) {
      if (!message.isChat || message.role == 'system') continue;
      floor = floor == null || message.seq < floor ? message.seq : floor;
      if (message.role != 'user' || message.id == null) continue;
      windowUsers.add(
        UserMessageRef(
          messageId: message.id!,
          seq: message.seq,
          preview: _navPreview(message.content),
        ),
      );
    }
    if (!hasOlder || floor == null) {
      _userIndex = windowUsers;
      return;
    }
    _userIndex = [
      for (final ref in _userIndex)
        if (ref.seq < floor) ref,
      ...windowUsers,
    ];
  }

  /// 导航摘要:与索引查询同一口径(单行化)并截到 160 字符,卡片本身单行
  /// 省略,更长的正文对展示无意义。
  String _navPreview(String content) {
    final single = singleLinePreview(content);
    return single.length > 160 ? single.substring(0, 160) : single;
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) {
      // 切换会话:重置滚动定位状态,一律回到"全新进入"的初始态 —— 上一个
      // 会话遗留的 _lastCount 会吞掉"进入会话贴底定位"判定(消息数恰好相同
      // 时整段跳过);遗留的 _nearBottom=false(上个会话里曾上滑)会直接
      // 跳过贴底跟随。reverse 列表下贴底 = offset 0,_nearBottom=true 即"新会话
      // 从最新消息处开始";_nearTop 置 false —— 非空会话的顶部在估算的
      // maxScrollExtent 一端,不在 0。两者的真值由进入定位时的 _syncScrollFlags
      // 按实际位置写入(内容不足一屏的会话届时会被正确置成"既贴顶又贴底")。
      _lastCount = -1;
      _nearBottom.value = true;
      _nearTop.value = false;
      // 新会话尚未定位;若上个会话的初始定位收敛链还挂在 postFrame 上,先
      // 解除隐藏态 —— 切换窗口内暂存的旧转录由 build 里的判定重新隐藏,
      // 新会话数据就位后再走一轮完整的初始定位。
      _positioned = false;
      _entrySettling = false;
      _navAutoHidden.value = false;
      _navRestoreTimer?.cancel();
      _highlightTimer?.cancel();
      _highlightMessageId = null;
      // 搜索词按会话记忆:换会话后重新打开搜索不再带着上一会话的关键词。
      _lastSearchQuery = '';
      // 导航卡索引随会话切换清空并重查:旧会话的摘要绝不能在新会话的卡片里
      // 停留一帧。
      _userIndex = const [];
      _userIndexSource = null;
      _userIndexQueryStarted = false;
      _visibleUserMessageId.value = null;
      // 多选不跨会话保留:选中 id 只对当前消息窗口有效。
      _selectionMode = false;
      _selectedMessageIds.value = const {};
      _load();
    }
    if (oldWidget.characterId != widget.characterId) {
      _character = widget.character;
      _bgHash = widget.character.backgroundHash;
      _avatarHash = widget.character.avatarHash;
      _loadVisuals();
    }
  }

  /// 同库 part 扩展不是 State 子类,不能直接调用受保护的 setState;
  /// 统一经这个包装重建。
  void _rebuild(VoidCallback fn) => setState(fn);

  bool get _desktopPlatform =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _selectionFocus.dispose();
    _scroll.dispose();
    _navRestoreTimer?.cancel();
    _highlightTimer?.cancel();
    _nearBottom.dispose();
    _nearTop.dispose();
    _navAutoHidden.dispose();
    _visibleUserMessageId.dispose();
    _autoTopRunning.dispose();
    _messageActionsOpen.dispose();
    _selectedMessageIds.dispose();
    _scrollNavCollapsed.dispose();
    _islandHub.dispose();
    super.dispose();
  }

  /// 输入变化:只有输入以 `/` 打头且尚未带空格时,实时给出命令建议。
  /// 建议列表没变(普通输入恒为 const []、连续输入未跨过建议边界)就不
  /// setState —— 此前每个字符都整页重建一次。
  void _onInputChanged(String text) {
    final next = slashSuggestions(text);
    final identical =
        next.length == _slashSuggestions.length &&
        (next.isEmpty ||
            next.join('\u0000') == _slashSuggestions.join('\u0000'));
    if (!identical) setState(() => _slashSuggestions = next);
  }

  /// 命令按钮 / 斜杠建议:把 `/命令 ` 写入输入框并聚焦,不直接执行;
  /// 用户可继续追加参数(如 `/rerun 画面更暗`)再按发送。
  void _insertCommand(SlashCommand cmd) {
    final text = '${slashCommandSlash(cmd)} ';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _inputFocus.requestFocus();
    _onInputChanged(text);
  }

  /// 执行一个斜杠命令(发送端解析后调用);命令会清空当前输入。
  /// [args] 是命令名之后的文本(当前仅 `/rerun` 消费为修改方向)。
  /// 命令返回的反馈文本(如 /compact 的压缩成功提示)推给灵动岛闪示,
  /// 替代旧的 SnackBar。/compact 的「压缩中」活动态由 controller 侧
  /// `ChatState.busyCommand` 驱动(controller 置位/清零,UI 无本地镜像)。
  Future<void> _runCommandFromUI(SlashCommand cmd, {String args = ''}) async {
    // 清空历史不可撤销且会丢掉压缩摘要,执行前先确认;取消时保留
    // 输入框里的 /clear 与焦点,用户可修改或直接重试。
    if (cmd == SlashCommand.clearHistory) {
      final confirmed = await showConfirmDialog(
        context,
        title: '清空会话历史?',
        message: '将删除本会话的全部消息与压缩摘要,仅保留角色开场白。此操作不可撤销。',
        confirmLabel: '清空',
      );
      if (!mounted) return;
      if (!confirmed) {
        _inputFocus.requestFocus();
        return;
      }
    }
    _input.clear();
    setState(() => _slashSuggestions = const []);
    final feedback = await ref
        .read(chatControllerProvider.notifier)
        .runCommand(cmd, args: args);
    if (feedback != null && mounted) {
      _islandHub.push(feedback, tone: IslandTone.success);
    }
  }

  /// 发送当前输入:斜杠命令走命令通道(命令名后的文本作为参数),普通文本
  /// 交给控制器。只有控制器真正接受才清空输入 —— 忙碌期(生图/压缩)被拒时
  /// 文字留在输入框,避免用户输入凭空消失。
  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // 输入是斜杠命令时,当作命令执行而不是发送文本;命令后的文本作为参数
    // 透传(如 `/rerun 画面更暗一些`)。
    final match = slashCommandMatch(text);
    if (match != null) {
      _runCommandFromUI(match.command, args: match.args);
      return;
    }
    // 只有控制器真正接受了发送才清空输入 —— 忙碌期(生图/压缩可能长达
    // 数分钟)发送被拒时,文字留在输入框并有灵岛提示,不再凭空消失。
    final accepted = ref.read(chatControllerProvider.notifier).trySend(text);
    if (accepted) {
      // 用户主动发送:即使此刻正停在上方读历史,消息落库后也要带回底部
      // (只对本次发送生效;后台写入/流式跟随仍遵守贴底判定)。
      _followAfterSend = true;
      _input.clear();
      setState(() => _slashSuggestions = const []);
      // 轻触觉回执:发送键在点按瞬间的确认感,不打断连续输入。
      HapticFeedback.lightImpact();
      // 桌面点击发送键可能抢走焦点;送回输入框,保持连续输入。
      if (_desktopPlatform) _inputFocus.requestFocus();
    }
  }

  /// 处理一批新建议:只在当前会话页可见时自动弹底单;切页/换会话/未就绪
  /// 一律视为忽略并丢弃本批(纯内存态,不排队补弹)。
  void _onNextSuggestions(List<String> suggestions) {
    if (_suggestionSheetOpen || suggestions.isEmpty) return;
    if (!mounted ||
        !_screenDataReady ||
        ref.read(chatControllerProvider).sessionId != widget.sessionId) {
      _discardSuggestions();
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      _discardSuggestions();
      return;
    }
    _suggestionSheetOpen = true;
    final batch = List<String>.of(suggestions);
    final controller = ref.read(chatControllerProvider.notifier);
    Future<void>.microtask(() async {
      // 先清状态再展示:底单关闭/忽略时不残留,也避免 rebuild 重复弹。
      controller.dismissNextSuggestions();
      try {
        if (!mounted) return;
        final selected = await showAppSheet<String>(
          context,
          builder: (_) => _NextSuggestionsSheet(suggestions: batch),
        );
        if (!mounted || selected == null) return;
        if (ref.read(chatControllerProvider).sessionId != widget.sessionId) {
          return;
        }
        _sendSuggestion(selected);
      } finally {
        _suggestionSheetOpen = false;
      }
    });
  }

  void _discardSuggestions() {
    Future<void>.microtask(() {
      if (!mounted) return;
      ref.read(chatControllerProvider.notifier).dismissNextSuggestions();
    });
  }

  /// 点击建议:走与输入框发送相同的受理门;忙碌被拒时把文本放回输入框,
  /// 避免用户的选择凭空消失。
  void _sendSuggestion(String text) {
    final accepted = ref.read(chatControllerProvider.notifier).trySend(text);
    if (accepted) {
      _followAfterSend = true;
      _input.clear();
      setState(() => _slashSuggestions = const []);
      HapticFeedback.lightImpact();
      if (_desktopPlatform) _inputFocus.requestFocus();
      return;
    }
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _inputFocus.requestFocus();
    _onInputChanged(text);
  }

  /// 角色状态卡:点击角色头像(AppBar / 气泡旁)弹出,头像 + 名称 + 编辑入口。
  void _showCharacterStatusCard() {
    final description = _character.description.trim();
    _showAvatarStatusCard(
      avatar: _assistantAvatarImage,
      fallbackIcon: Icons.person_outline,
      title: _character.name,
      subtitle: '角色',
      body: description.isEmpty ? null : description,
      actionLabel: '编辑角色卡',
      actionIcon: Icons.edit_outlined,
      onAction: _openCharacterEdit,
    );
  }

  /// 用户状态卡:点击用户气泡旁头像弹出,入口直达个人设置。
  void _showUserStatusCard() {
    final user = ref.read(userProfileProvider);
    _showAvatarStatusCard(
      avatar: _userAvatarImage,
      fallbackIcon: Icons.person,
      title: user.name.trim().isEmpty ? '未设置用户名' : user.name,
      subtitle: '用户',
      actionLabel: '个人设置',
      actionIcon: Icons.manage_accounts_outlined,
      onAction: () => Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const UserScreen()),
      ),
    );
  }

  /// 角色/用户状态卡的通用弹层:入口行点击后先关闭弹层再执行跳转,
  /// 避免导航压在底单上。
  void _showAvatarStatusCard({
    required ImageProvider? avatar,
    required IconData fallbackIcon,
    required String title,
    required String subtitle,
    String? body,
    required String actionLabel,
    required IconData actionIcon,
    required VoidCallback onAction,
  }) {
    showAppSheet<void>(
      context,
      isScrollControlled: false,
      builder: (sheetCtx) => _AvatarStatusSheet(
        avatar: avatar,
        fallbackIcon: fallbackIcon,
        title: title,
        subtitle: subtitle,
        body: body,
        actionLabel: actionLabel,
        actionIcon: actionIcon,
        onAction: () {
          Navigator.pop(sheetCtx);
          onAction();
        },
      ),
    );
  }

  /// 估算当前已组装上下文的 token 用量(供上下文使用率圆环)。
  /// 结果按 snapshot 实例缓存:同一轮内实例不变,复用上次求和,不在每次 build
  /// 或每个流式块上重算;换轮(snapshot 被替换)时自动失效重算。
  int _estimateContextTokens(ContextSnapshot? snap) {
    if (snap == null) return 0;
    if (identical(_ctxEstimateSnap, snap)) return _ctxEstimateTokens;
    var chars = snap.systemPrompt.length;
    for (final m in snap.messages) {
      chars += m.content.length;
    }
    _ctxEstimateSnap = snap;
    _ctxEstimateTokens = estimateTokensFromChars(chars);
    return _ctxEstimateTokens;
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    // 已启用技能名集合:输入框与全部气泡共用同一份编译语法(命令/@技能/
    // 宏/标签),watch 触发惰性加载,技能增删改后自动跟随。
    final enabledSkillNames = {
      for (final s in (ref.watch(skillsProvider).value ?? const <Skill>[]))
        if (s.enabled && s.name.trim().isNotEmpty) s.name.trim(),
    };
    final syntax = CompiledSyntax.compile(skillNames: enabledSkillNames);
    final dialogueHighlight = ref
        .watch(appSettingsProvider)
        .dialogueHighlightEnabled;
    _input.updateSyntax(syntax, highlightDialogue: dialogueHighlight);
    // 用户档案:头像用于气泡旁展示;用户名仅用于显示层替换正文里的 {{user}}。
    final user = ref.watch(userProfileProvider);
    ImageProvider? avatarImage(String? hash) => hashImageProvider(
      ref.read(databaseProvider).images,
      hash,
      cacheWidth: kAvatarImageWidth,
    );

    // hash 不变时共享 provider;换图自然得到新的文件缓存键。
    if (user.avatarHash != _userAvatarKey) {
      _userAvatarKey = user.avatarHash;
      _userAvatarImage = avatarImage(user.avatarHash);
    }
    if (_avatarHash != _assistantAvatarKey) {
      _assistantAvatarKey = _avatarHash;
      _assistantAvatarImage = avatarImage(_avatarHash);
    }
    final displayUserName = user.name;

    final backgroundEnabled = ref.watch(chatBackgroundEnabledProvider);
    final backgroundBlur = ref.watch(chatBackgroundBlurProvider);
    // 宽窗桌面适配:≥1000 会话收敛成居中阅读列(刻度见 chat_layout),
    // ≥1200 再出左侧会话侧栏(主从布局);低于阈值一切照旧。侧栏还受
    // 用户折叠偏好约束(AppBar 左端的收起/展开键切换,偏好落 ui-prefs)。
    final windowWidth = MediaQuery.sizeOf(context).width;
    final sidebarAvailable = windowWidth >= kChatSidebarBreakpoint;
    final showSidebar =
        sidebarAvailable && !ref.watch(sidebarCollapsedProvider);
    // 侧栏从隐藏切回可见时补一次分组失效:隐藏期跳过了消息驱动的失效,
    // 不补的话条数/排序会停在隐藏前的快照。首帧(_sidebarWasShown 为
    // null)不补 —— 初次加载本来就是新查询。
    if (showSidebar && _sidebarWasShown == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.invalidate(sessionGroupsProvider);
      });
    }
    _sidebarWasShown = showSidebar;

    // 滚动定位判定(三种互斥情形):
    final count = chat.messages.length;
    // controller 状态是否已是本屏会话的数据。会话切换窗口内(load 的元数据
    // 清空在微任务里、数据在若干跳 DB 读之后才落地)state 里暂存的是上一
    // 会话的转录,sessionId 为旧值或 null。
    final loadedHere = chat.sessionId == widget.sessionId;
    _screenDataReady = loadedHere;
    // 桌面消息导航的 user 索引:进入会话查一次全量历史(不受显示窗口裁剪),
    // 之后随消息实例变化用窗口数据同步合并。窗口之外的历史行 UI 不能编辑/
    // 删除(多选与操作排只覆盖已加载窗口),因此无需每次消息落库都重查 DB;
    // 反复在 build 里发起窗口化 DB 往返还会把 sqflite 的事务计时器悬在帧外,
    // 拖住整个测试收尾。移动端用不到这份索引,整段跳过。
    if (loadedHere && _desktopPlatform) {
      if (!_userIndexQueryStarted) {
        _userIndexQueryStarted = true;
        _refreshUserIndex();
      }
      if (!identical(_userIndexSource, chat.messages)) {
        _userIndexSource = chat.messages;
        _mergeUserIndex(chat.messages, hasOlder: chat.canLoadOlder);
      }
    }
    // 空会话的输入区抬升:桌面端在本屏数据就位、没有任何消息、角色卡也没有
    // 开场白候选时,底部留白按内容高的四分之一把输入区抬离底部(此时空态里
    // 没有可点的起笔入口,输入卡贴在屏幕最底部显得空旷);有开场白时输入区
    // 留在底部,由空态的开场白卡承担起笔。移动端始终贴底 —— 抬高会让输入位
    // 与键盘位置脱节,不符合移动端输入习惯。
    final hasOpening =
        _character.firstMessage.trim().isNotEmpty ||
        _character.alternateGreetings.any((g) => g.trim().isNotEmpty);
    final desktopPlatform =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
    final liftComposer =
        desktopPlatform && loadedHere && count == 0 && !hasOpening;
    if (!loadedHere &&
        count > 0 &&
        chat.transcriptSessionId != widget.sessionId) {
      // 暂存的上一会话转录:按初始定位隐藏 —— 既不闪"发一条消息开始对话"
      // 空态(转录保留到了这个窗口),也不把旧会话内容暴露给用户;本会话
      // 数据就位后随初始定位一起揭示。
      // transcriptSessionId 门控(重进同一会话回归):退出后重进同一会话时,
      // 残留的控制器状态使首帧 loadedHere=true、一次性定位标记被消耗;随后
      // load 的元数据清空窗口里暂存的正是本屏会话自己的转录 —— 若这里无
      // 条件隐藏,已收敛的定位链不会再补发,列表就永远滞留透明态,表现为
      // 「重进会话消息列表为空」。归属一致时照常显示,定位/跟随逻辑自然收敛。
      _entrySettling = true;
    } else if (loadedHere && count == 0) {
      // 本会话数据已就位但没有消息(新会话/空会话):无定位可言,空态立即
      // 可见;也解除切换窗口遗留的隐藏。
      _entrySettling = false;
    }
    if (loadedHere && count > 0 && !_positioned) {
      // 本会话数据首次就位:进入会话的初始定位 —— 隐藏 + 无动画直跳收敛
      // (详见 _entrySettling 与 _performScrollToBottom)。用 _positioned
      // 而非「消息数从无到有」判定:切换窗口里的旧转录会污染 _lastCount
      // 基线(见该字段注释)。
      _positioned = true;
      if (_nearBottom.value && !_userDragging) {
        _entrySettling = true;
        _scrollToBottom(animate: false);
      }
    }
    // 新消息到达时,若用户贴着底部就跟随滚动。流式期间使用无动画即时贴底
    // (jumpTo),避免频繁开启和打断 150ms 动画导致动画控制器冲突与掉帧卡顿。
    // 用户正在拖动时跳过(详见 _userDragging)。
    if (count != _lastCount) {
      _lastCount = count;
      // 用户主动发送带来的首个新条目:无条件跟随一次(force 绕过滚动宽限窗)。
      final fromSend = _followAfterSend;
      _followAfterSend = false;
      // 「回到顶部」逐页取旧期间不跟随:前拼旧页会让 count 连跳,而视口未动、
      // `_nearBottom` 滞留 true,跟随会把用户拽回底部并与循环末尾的 jumpTo(0)
      // 竞争(回顶永远到不了顶)。
      if (loadedHere &&
          _positioned &&
          (_nearBottom.value || fromSend) &&
          !_userDragging &&
          !_autoTopRunning.value &&
          !_revealRunning) {
        _scrollToBottom(animate: !chat.streaming, force: fromSend);
      }
      // 侧栏的组内排序与末条预览由控制器在真正发生消息增删时失效
      // (见 ChatControllerSession._invalidateSessionList);向上分页只是
      // 扩充显示窗口,不改变会话条数/预览,不能再触发全库聚合重建。
    }
    // 流式草稿在独立 provider(不驱动整页重建),经 listen 跟随:
    // 每个草稿块只触发这条回调(贴底时滚动一下),页面 build 不再陪跑。
    ref.listen<String>(chatDraftProvider, (_, _) {
      if (_screenDataReady &&
          _positioned &&
          _nearBottom.value &&
          !_userDragging &&
          !_revealRunning) {
        _scrollToBottom(animate: !ref.read(chatControllerProvider).streaming);
      }
    });

    // 一次性瞬态通知(如自动压缩失败):推给灵动岛闪示后清除,避免重复展示。
    // 不走 [ChatState.error] 错误横幅 —— 主写本身已成功,不该显示为失败态。
    ref.listen(chatControllerProvider, (_, next) {
      final notice = next.notice;
      if (notice == null || notice.isEmpty) return;
      _islandHub.push(notice, tone: IslandTone.danger);
      Future<void>.microtask(() {
        if (mounted) ref.read(chatControllerProvider.notifier).clearNotice();
      });
    });

    // 后台 Agentic 下一步建议:仅当前聊天页可见时自动弹底单;切页/换会话/
    // 未就绪一律视为忽略并丢弃本批(纯内存态,不排队补弹)。
    ref.listen(chatControllerProvider, (previous, next) {
      if (next.nextSuggestions.isEmpty) return;
      if (identical(previous?.nextSuggestions, next.nextSuggestions)) return;
      _onNextSuggestions(next.nextSuggestions);
    });

    // 会话记忆:驱动「初始化记忆」提示条(后台成功写入后经 invalidate 自动刷新,
    // 记忆非空即提示条消失)。手动关闭按会话记忆,重复进入同一会话不再弹出。
    final memoriesAsync = ref.watch(memoriesProvider(widget.sessionId));
    final memoryInitDismissed = ref
        .watch(memoryInitDismissedProvider)
        .contains(widget.sessionId);

    final appBarAvatar = Semantics(
      button: true,
      label: '查看角色资料',
      child: InkWell(
        key: const ValueKey('appbar-character-avatar'),
        customBorder: const CircleBorder(),
        onTap: _showCharacterStatusCard,
        child: _ChatAvatar(name: _character.name, avatarHash: _avatarHash),
      ),
    );
    final appBarActions = <Widget>[
      IconButton(
        tooltip: '搜索聊天记录',
        icon: const Icon(Icons.search),
        onPressed: _openChatSearch,
      ),
      IconButton(
        tooltip: '上下文',
        icon: const Icon(Icons.query_stats_outlined),
        onPressed: () => showAppSheet<void>(
          context,
          showDragHandle: true,
          // 可拖拽缩放:默认接近全高,向下拖可让出聊天内容对照着看。
          builder: (_) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.9,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (context, scrollController) =>
                ContextPanel(scrollController: scrollController),
          ),
        ),
      ),
      // 状态面板:与"上下文"按钮并排,不藏在三点菜单里。
      IconButton(
        tooltip: '状态面板',
        icon: const Icon(Icons.insights_outlined),
        onPressed: _openStatus,
      ),
      AppPopupMenuButton<String>(
        tooltip: '会话操作',
        onSelected: (action) {
          switch (action) {
            case 'select':
              _enterSelectionMode();
            case 'rename':
              _renameCurrentSession();
            case 'skills':
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SkillsScreen()),
              );
            case 'hooks':
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HooksScreen()),
              );
            case 'export':
              _exportSession();
            case 'share':
              _exportSession(share: true);
            case 'delete':
              _deleteSession();
          }
        },
        actions: [
          const MenuAction(
            value: 'skills',
            label: '技能管理',
            icon: Icons.extension_outlined,
          ),
          const MenuAction(
            value: 'hooks',
            label: 'Hooks 管理',
            icon: Icons.code_outlined,
          ),
          // 会话级三项(重命名/导出/删除)连排,与上方管理入口分开。
          const MenuAction(
            value: 'select',
            label: '多选消息',
            icon: Icons.checklist_outlined,
          ),
          const MenuAction(
            value: 'rename',
            label: '重命名会话',
            icon: Icons.edit_outlined,
          ),
          const MenuAction(
            value: 'export',
            label: '导出会话',
            icon: Icons.file_download_outlined,
          ),
          if (isMobileSessionExport)
            const MenuAction(
              value: 'share',
              label: '分享会话',
              icon: Icons.share_outlined,
            ),
          const MenuAction(
            value: 'delete',
            label: '删除会话',
            icon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
      const SizedBox(width: 4),
    ];

    // AppBar 不跟随正文的居中列:左右内容各贴窗格最左/最右缘(侧栏展开
    // 时左缘接分隔线,右缘是窗口最右),与输入卡/气泡的列线脱钩。侧栏
    // 收起/展开键与返回键内联在最左,操作组在最右。
    // 主从布局下 AppBar 直接嵌进右窗 Column(嵌套 Scaffold 会让 SnackBar
    // 在两座脚手架各渲染一份);AppBar 自持 toolbarHeight 与顶部安全区。
    final appBar = AppBar(
      titleSpacing: _selectionMode ? 4 : 0,
      automaticallyImplyLeading: false,
      leading: _selectionMode
          ? IconButton(
              key: const ValueKey('message_selection_close'),
              tooltip: '退出多选',
              icon: const Icon(Icons.close),
              onPressed: _exitSelectionMode,
            )
          : null,
      title: _selectionMode
          ? ValueListenableBuilder<Set<int>>(
              valueListenable: _selectedMessageIds,
              builder: (_, selected, __) => Text('已选 ${selected.length} 条'),
            )
          : Row(
              children: [
                // 侧栏到达断点后常驻提供收起/展开入口(折叠偏好跨会话记忆);
                // 窗口更窄(<1200)时侧栏不可用,不出现。
                if (sidebarAvailable)
                  IconButton(
                    tooltip: showSidebar ? '收起会话侧栏' : '展开会话侧栏',
                    onPressed: _toggleSidebar,
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.vertical_split),
                  ),
                if (ModalRoute.of(context)?.canPop ?? false) const BackButton(),
                appBarAvatar,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_character.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
      actions: _selectionMode
          ? [
              // 多选的删除/导出固定在右上角,底部只保留快捷选择。
              ValueListenableBuilder<Set<int>>(
                valueListenable: _selectedMessageIds,
                builder: (context, selected, _) {
                  final empty = selected.isEmpty;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: const ValueKey('message_selection_delete'),
                        tooltip: '删除选中消息',
                        color: Theme.of(context).colorScheme.error,
                        onPressed: empty ? null : _deleteSelectedMessages,
                        icon: const Icon(Icons.delete_outline),
                      ),
                      IconButton(
                        key: const ValueKey('message_selection_export'),
                        tooltip: '导出选中消息',
                        onPressed: empty ? null : _exportSelectedMessages,
                        icon: const Icon(Icons.file_download_outlined),
                      ),
                    ],
                  );
                },
              ),
            ]
          : appBarActions,
    );

    // 灵动岛:错误警报 / 用量分账(主写·后台·压缩)/ 主写流式与后台维护
    // 实况 / 后台运行后摘要闪示 / 初始化记忆行动项 / 命令反馈闪示,统一由
    // 这颗悬浮胶囊承载。桌面端升到覆盖 AppBar 的外层 Stack,与头像/名字
    // 同一条水平线;移动端仍贴消息区顶边。两处都是恒驻子树(hidden 时渲染
    // 零高占位),不改变所在 Stack 其它元素的下标,State 稳定。
    // 贴顶翻历史时收起用量粒(_nearTop 经 AnimatedBuilder 只重建这一小块);
    // 入场收敛期整粒隐藏。
    final island = AnimatedBuilder(
      animation: Listenable.merge([_nearTop, _nearBottom]),
      builder: (context, _) => ChatIsland(
        key: const ValueKey('chat-island'),
        chat: chat,
        // 桌面端:收拢态胶囊高约 30,工具栏 56,顶部留 (56-30)/2 让岛面
        // 与 AppBar 内容垂直居中;展开时从同一顶边向下生长。
        topInset: desktopPlatform
            ? MediaQuery.paddingOf(context).top + (kToolbarHeight - 30) / 2
            : 6,
        memoryInitPrompt:
            !memoryInitDismissed &&
            chat.backgroundStatus != BackgroundStatus.running &&
            memoriesAsync.maybeWhen(
              data: (list) => list.every((m) => m.content.trim().isEmpty),
              orElse: () => false,
            ),
        compacting: chat.busyCommand == 'compact',
        hidden: _entrySettling || _selectionMode,
        // 用量粒让位:仅当列表真的可滚动且用户翻到了顶部(贴顶但
        // 不贴底)。内容不足一屏的会话贴顶也贴底,不存在"胶囊压住
        // 正在翻看的历史",照常常驻。
        idleHushed: _nearTop.value && !_nearBottom.value,
        hub: _islandHub,
        onOpenStatus: _openStatus,
        onInterrupt: () =>
            ref.read(chatControllerProvider.notifier).interrupt(),
        onInitMemory: () =>
            ref.read(chatControllerProvider.notifier).initializeMemory(),
        onDismissMemoryInit: () {
          final notifier = ref.read(memoryInitDismissedProvider.notifier);
          notifier.state = {...notifier.state, widget.sessionId};
        },
        onDismissError: () =>
            ref.read(chatControllerProvider.notifier).clearError(),
        onSwitchFallbackModel: () => ref
            .read(chatControllerProvider.notifier)
            .switchToFallbackModel(),
      ),
    );

    final content = Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.transparent),
        // 聊天背景:全局开关开启时铺一层背景图(优先角色卡背景;未设置回退头像),
        // 之上叠一层不透明白色/深色淡罩,让消息气泡保持清晰可读。纯显示层,不进上下文。
        if (backgroundEnabled)
          _ChatBackground(
            key: const ValueKey('chat-background'),
            backgroundHash: _bgHash,
            avatarHash: _avatarHash,
            blur: backgroundBlur,
          ),
        // 宽窗只收敛内容(消息行/输入卡同列;AppBar 贴窗格两缘),不铺列底色:助手气泡
        // 与输入卡同为 surface,铺一层同色纸面会让气泡失去与分组底的明度
        // 分层(暗色下尤甚,整块消息区看起来像裸文本)。消息列表本身铺满
        // 窗格,桌面滚动条因此贴在窗口最右缘。
        LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              // 顶部状态(错误/用量/后台/记忆提示/命令反馈)全部收纳进消息区悬浮的
              // 灵动岛(见下方 ChatIsland),Column 里不按状态插拔横幅,避免布局跳动。
              Expanded(
                key: const ValueKey('messages-area'),
                child: Stack(
                  children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: _onScrollNotification,
                      // 进入会话的初始定位期(_entrySettling)列表以 Opacity 0
                      // 渲染:会话切换窗口里暂存的上一会话转录不得露出,本会话
                      // 数据就位后一次性显示。reverse 列表下首帧 offset 0 即
                      // 最新消息,不存在"从最旧扫到底部"的可见过程,隐藏期只有
                      // 一帧。Opacity 不挡命中测试,用户此刻按下拖动仍会被各
                      // 退出点的 _userDragging 分支接住并立即解除隐藏。
                      child: Opacity(
                        key: const ValueKey('message-list-visibility'),
                        opacity: _entrySettling ? 0 : 1,
                        // 消息列表单独包一层 Consumer:流式草稿独立 provider
                        // 约 25FPS 一刷,只有这一小块随它重建;页面级 watch 不再被
                        // 草稿拖着整页陪跑(AppBar/输入区/灵动岛/上下文面板)。
                        // 正则/词典/对话高亮等列表专属 watch 也顺势收进来。
                        child: Consumer(
                          builder: (context, listRef, _) => MessageList(
                            key: _messageListKey,
                            messages: chat.messages,
                            // 空会话不再只有一行灰字:角色头像/名称 + 可直接
                            // 起笔的开场白;开场白作为助手首条消息落库。
                            // 会话数据就位前渲染空白,避免打开已有会话时先闪
                            // 一帧空态(此时控制器还没 load 完)。
                            emptyState: loadedHere
                                ? ChatEmptyState(
                                    character: _character,
                                    avatar: _assistantAvatarImage,
                                    onGreeting: (text) async {
                                      final ok = await listRef
                                          .read(chatControllerProvider.notifier)
                                          .startWithGreeting(text);
                                      if (!ok && mounted) {
                                        _islandHub.push(
                                          '会话已经开始或正在生成,开场白未插入',
                                          tone: IslandTone.info,
                                        );
                                      }
                                    },
                                  )
                                : const SizedBox.shrink(),
                            draft: listRef.watch(chatDraftProvider),
                            streaming: chat.streaming,
                            controller: _scroll,
                            canLoadOlder: chat.canLoadOlder,
                            loadingOlder: chat.loadingOlder,
                            userAvatarImage: _userAvatarImage,
                            assistantAvatarImage: _assistantAvatarImage,
                            onUserAvatarTap: _showUserStatusCard,
                            onAssistantAvatarTap: _showCharacterStatusCard,
                            displayUserName: displayUserName,
                            displayCharName: _character.name,
                            // 全部气泡的 @技能名 / /命令 高亮(与输入框共用同一语法)。
                            syntax: syntax,
                            // 直接 watch FutureProvider + 记忆化编译(不走派生 Provider:
                            // Provider→FutureProvider 桥接在 TickerMode 重启时会触发
                            // build 期 setState 崩溃,见 providers.dart 注释)。
                            // 列表加载中/失败为空 —— 退回无脚本/无高亮管线,不阻塞显示。
                            regexScripts: compileDisplayScripts(
                              listRef.watch(regexScriptsProvider).value ??
                                  const [],
                            ),
                            glossary: compileGlossary(
                              listRef
                                      .watch(
                                        worldbookProvider(widget.characterId),
                                      )
                                      .value ??
                                  const [],
                            ),
                            onTermTap: _showTermCard,
                            // 内置对话高亮(引号台词)总开关,随 app_settings 持久化,
                            // 入口在正则脚本管理页。
                            highlightDialogue: dialogueHighlight,
                            assistantBubbleStyle: _character.bubbleStyle,
                            // 全屏查看器的"删除图片":只清空该消息图片字段,正文保留。
                            onImageDelete: (id) => listRef
                                .read(chatControllerProvider.notifier)
                                .deleteMessageImage(id),
                            regeneratingImageId: chat.regeneratingImageId,
                            highlightedMessageId: _highlightMessageId,
                            onMessageLongPress: _messageActions,
                            onMessageAction: (m, a) => _messageAction(m, a),
                            selectionMode: _selectionMode,
                            selection: _selectedMessageIds,
                            onSelectionToggle: _toggleMessageSelection,
                            // 操作按钮排显隐上报:导航组据此让位(见 _messageActionsOpen)。
                            onActionsVisibleChanged: (open) =>
                                _messageActionsOpen.value = open,
                          ),
                        ),
                      ),
                    ),
                    // 桌面端灵岛在外层 Stack 覆盖 AppBar 带(见 build 中的
                    // island);移动端仍悬浮在消息区顶部。
                    if (!desktopPlatform) island,
                    // 悬浮爬楼与首尾导航按键组:
                    // 顶部方向(回到顶部/上一条消息)与底部方向(下一条消息/回到底部),
                    // 「收起/展开滚动导航」夹在两组之间(列表中部时是第 3 颗,即正中间);
                    // 只有单一方向组可见时(贴顶/贴底)放在该组另一端,仍不与方向钮挤在一起。
                    // 整组可折叠:点收起折成一颗半透明小钮,再点即展开。
                    // 用户滚动列表(拖动/滚轮/惯性)期间整组自动隐藏,滚动真正停止后
                    // 600ms 再恢复(由 `_onScrollNotification` 驱动)。显隐/折叠开关全部
                    // 走 ValueNotifier 并由导航组自行监听:滚动路径上零 setState,不把
                    // 整页(含消息列表)拖进来重建 —— 否则按钮每次隐藏/恢复都伴随一次
                    // 整页重建,滑动表现为一卡一卡。
                    // 进入会话的初始定位期(_entrySettling)整组一并隐藏:列表尚在
                    // 透明收敛,浮在空白背景上的「回到底部」等按钮只会造成困惑;
                    // 收敛结束的同一帧随之显示。该钮是 Stack 末位子项,条件增删
                    // 不影响前面子项的匹配位置。
                    // 桌面端换成右缘消息导航(刻度条 + 悬停卡片),移动端仍用
                    // 悬浮按键组。
                    if (!_entrySettling && !_selectionMode)
                      desktopPlatform
                          ? _MessageNavigator(
                              messages: _userIndex,
                              currentMessageId: _visibleUserMessageId,
                              nearTop: _nearTop,
                              nearBottom: _nearBottom,
                              autoTopRunning: _autoTopRunning,
                              canLoadOlder: chat.canLoadOlder,
                              onScrollToTop: _scrollToTop,
                              onScrollToBottom: () => _scrollToBottom(force: true),
                              onJumpTo: _jumpToUserMessage,
                            )
                          : _ScrollNavRail(
                              nearTop: _nearTop,
                              nearBottom: _nearBottom,
                              autoHidden: _navAutoHidden,
                              // 选中消息的操作按钮排可见时整组让位,不压住重新发送/重新生成。
                              actionsOpen: _messageActionsOpen,
                              collapsed: _scrollNavCollapsed,
                              autoTopRunning: _autoTopRunning,
                              canLoadOlder: chat.canLoadOlder,
                              onToggleCollapsed: () =>
                                  _scrollNavCollapsed.value =
                                      !_scrollNavCollapsed.value,
                              onScrollToTop: _scrollToTop,
                              onScrollToPreviousMessage:
                                  _scrollToPreviousMessage,
                              onScrollToNextMessage: _scrollToNextMessage,
                              onScrollToBottom: () => _scrollToBottom(force: true),
                            ),
                  ],
                ),
              ),
              // /compact 的「压缩中」活动态由灵动岛呈现。
              // 多选时底部换成批量操作栏,输入区整体收起,避免误发送。
              if (_selectionMode)
                ValueListenableBuilder<Set<int>>(
                  valueListenable: _selectedMessageIds,
                  builder: (context, selected, __) {
                    final visible = _loadedVisibleMessages();
                    final images = visible
                        .where((m) => m.hasVisualImage)
                        .length;
                    return MessageSelectionBar(
                      selectedCount: selected.length,
                      totalCount: visible.length,
                      imageCount: images,
                      textCount: visible.length - images,
                      onSelectAll: _selectAllMessages,
                      onClearSelection: _clearMessageSelection,
                      onSelectImages: _selectImageMessages,
                      onSelectText: _selectTextMessages,
                    );
                  },
                )
              else ...[
                // 底部输入区(命令行 + 输入卡 + 工具底栏)整体见 ChatComposer。
                ChatComposer(
                  interruptible: chat.streaming || chat.busyCommand != null,
                  suggestions: _slashSuggestions,
                  inputController: _input,
                  inputFocusNode: _inputFocus,
                  commandsExpanded: _commandsExpanded,
                  usage: ContextLink(
                    estimateTokens: _estimateContextTokens(chat.lastContext),
                    actualInputTokens: chat.lastSentInputTokens,
                    cachedInputTokens: chat.cachedInputTokens,
                  ),
                  onToggleCommands: () =>
                      setState(() => _commandsExpanded = !_commandsExpanded),
                  onChanged: _onInputChanged,
                  onInsertCommand: _insertCommand,
                  onSend: _send,
                  submitOnEnter: desktopPlatform,
                  onInterrupt: () =>
                      ref.read(chatControllerProvider.notifier).interrupt(),
                ),
                // 桌面端空会话且角色没有开场白:底部留白(内容高 25%)把输入区
                // 抬离底部;一旦有消息(发送/开场白/重发)留白收回,输入区回到
                // 底部。移动端 liftComposer 恒为 false,始终贴底。
                _ComposerLift(
                  lifted: liftComposer,
                  height: constraints.maxHeight * 0.25,
                  duration: reduceMotionOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 240),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    // 主从骨架全局统一:所有宽度都是 Row[侧栏槽, Column[AppBar, 聊天区]],
    // 侧栏槽在 <1200 时宽度为 0(子树卸载)。此前 <1000 与 ≥1000 用两套
    // 不同结构的 Scaffold,跨过 1000 断点时整棵内容子树换父重挂,暗色下
    // 会漏出脚手架黑底闪一帧;统一后唯一的断点变化只剩侧栏槽的宽度动画。
    // 侧栏跨过 1200 断点不瞬移:槽宽在 0..kChatSidebarWidth 间动画(聊天区
    // 随之平滑重排),内容始终按侧栏满宽布局、锚定槽右缘滑入滑出 —— 内部
    // 不随动画重排(标题/检索框不抖),右缘分隔线始终贴着聊天区;完全收起
    // 后卸载子树,不把隐藏的检索框留在焦点遍历里。
    return PopScope(
      // 多选时返回键/侧滑先退出多选,不直接离开会话。
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode) _exitSelectionMode();
      },
      child: Focus(
        focusNode: _selectionFocus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape &&
              _selectionMode) {
            _exitSelectionMode();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          body: Row(
            children: [
              _SidebarReveal(
                visible: showSidebar,
                duration: reduceMotionOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                child: ChatSessionSidebar(
                  currentSessionId: widget.sessionId,
                  onSelect: _switchSession,
                  onCreate: _createSessionFor,
                  onSessionAction: _handleSidebarAction,
                  onGoHome: _goHome,
                ),
              ),
              Expanded(
                // 桌面端灵岛要浮到 AppBar 带内(见 build 中的 island):用覆盖
                // 整块右窗的 Stack 承载,Positioned 坐标从窗格顶边起算;移动端
                // 岛在消息区自己的 Stack 里,这里只有基座一层。
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Column(
                      children: [
                        appBar,
                        Expanded(child: content),
                      ],
                    ),
                    if (desktopPlatform) island,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Agentic 后台的下一步建议底单:每行一条用户口吻的完整发言,点击即发送;
/// 关闭/下滑/点「忽略」都返回 null,由调用方丢弃整批。
class _NextSuggestionsSheet extends StatelessWidget {
  final List<String> suggestions;
  const _NextSuggestionsSheet({required this.suggestions});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: '下一步建议', closeLabel: '忽略'),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              '点击一条即可作为你的消息发送。',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: suggestions.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final suggestion = suggestions[i];
                return Material(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context, suggestion),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(suggestion, style: text.bodyMedium),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.north_east,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('忽略本批建议'),
          ),
        ],
      ),
    );
  }
}
