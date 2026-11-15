/// 聊天页:消息流渲染、输入发送、悬浮滚动导航与全部会话入口。
///
/// 消息列表以 `reverse` 渲染显示窗口(贴顶分页),与上下文组装窗口刻意
/// 分离;进入会话先透明收敛到最新消息再显示,滚动路径上零整页 setState。
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
import '../data/image_codec.dart';
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
import 'common/chat_layout.dart';
import 'common/confirm_dialog.dart';
import 'common/motion.dart';
import 'common/section_header.dart';
import 'common/text_edit_sheet.dart';
import 'common/session_file_helper.dart';
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
import 'widgets/chat_island.dart';

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
  final _scroll = ScrollController();
  final _messageListKey = GlobalKey<MessageListState>();

  /// 贴底/贴顶邻域标记走 [ValueNotifier] 而非 setState 字段:滚动期间它们
  /// 频繁翻转(每跨一次 80px 阈值就变一次),若走 setState 会连消息列表一起
  /// 整页重建,滑动掉帧;改由悬浮导航组([_ScrollNavRail])自行监听、只重建
  /// 那一小块。build 里的贴底跟随判定直接读 `.value` 取当前值。
  final _nearBottom = ValueNotifier<bool>(true);
  final _nearTop = ValueNotifier<bool>(true);
  int _lastCount = -1;

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

  /// 用户头像缓存:流式回复期间整页随每个流式块重建,若每次现包新的 MemoryImage,
  /// 头像在解码完成前的那一帧是空的,反复重建就表现为频闪(与 _ChatBackground
  /// 同源)。这里按 avatarBase64 的值缓存一个 ImageProvider 实例,值不变就复用同一
  /// 实例;用户改头像后下一次 build 检测到值变化自动重新解码。
  String? _userAvatarKey;
  ImageProvider? _userAvatarImage;

  /// 角色头像缓存(助手气泡旁):与用户头像同款 —— 按 _avatarBase64 值缓存
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
  String? _bgBase64;
  String? _avatarBase64;

  /// 当前角色卡的本地快照:初始取路由传入的卡,从聊天页编辑角色后刷新,
  /// 让 AppBar 名称/头像与气泡样式立即跟上,不必退出重进会话。
  late CharacterCard _character;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 先以卡内已有值起步(直构/测试/无列时立即可用),再用列值覆盖。
    _character = widget.character;
    _bgBase64 = widget.character.backgroundBase64;
    _avatarBase64 = widget.character.avatarBase64;
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
      bg = await repo.backgroundBase64For(widget.characterId);
    } catch (_) {
      bg = null;
    }
    // 头像与背景相互独立:背景是否设置都不影响 AppBar/气泡头像的取数
    // (背景层在无专属背景图时才回退头像,但头像本身始终要读)。
    try {
      av = await repo.avatarBase64For(widget.characterId);
    } catch (_) {
      av = null;
    }
    if (!mounted) return;
    final nextBg = bg ?? _character.backgroundBase64;
    final nextAv = av ?? _character.avatarBase64;
    if (nextBg != _bgBase64 || nextAv != _avatarBase64) {
      setState(() {
        _bgBase64 = nextBg;
        _avatarBase64 = nextAv;
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
      _load();
    }
    if (oldWidget.characterId != widget.characterId) {
      _character = widget.character;
      _bgBase64 = widget.character.backgroundBase64;
      _avatarBase64 = widget.character.avatarBase64;
      _loadVisuals();
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _navRestoreTimer?.cancel();
    _highlightTimer?.cancel();
    _nearBottom.dispose();
    _nearTop.dispose();
    _navAutoHidden.dispose();
    _autoTopRunning.dispose();
    _messageActionsOpen.dispose();
    _scrollNavCollapsed.dispose();
    _islandHub.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 直接写 ValueNotifier(同值赋值内部会跳过通知):滚动期间不再触发
    // 整页 setState,贴底/贴顶标记只驱动悬浮导航组那一小块重建。
    _syncScrollFlags();
    // 窗口化加载:贴近顶部且还有更早历史时向上分页。
    // 除 80px 的贴顶判定外,额外在「距顶部约 1.5 个视口」时预取一页 ——
    // 快速上滑不必先撞到旧顶部再等数据。
    if (_nearTop.value || _shouldPrefetchOlder()) _maybeLoadOlder();
  }

  /// 是否已进入顶部预取区。`maxScrollExtent` 在 reverse 列表里是估算值,
  /// 只用作提前量;真正是否可加载仍由控制器与 [canLoadOlder] 判定。
  bool _shouldPrefetchOlder() {
    if (!_scroll.hasClients) return false;
    final pos = _scroll.position;
    if (pos.pixels <= 0) return false;
    return pos.pixels >= pos.maxScrollExtent - pos.viewportDimension * 1.5;
  }

  /// 按当前滚动位置同步贴底/贴顶邻域标记。
  ///
  /// 消息列表是 `reverse: true` —— offset 0 = **最新消息(底部)**,
  /// `maxScrollExtent` = 最旧(顶部)。两个邻域判据随之对调,且贴底判据(0 邻域)
  /// 不再依赖 `maxScrollExtent` 这个估算值。
  ///
  /// 除滚动路径外,进入会话的初始定位也必须调一次:reverse 下视口本就停在
  /// offset 0(最新),**没有任何滚动发生**,`_onScroll` 不会被派发 —— 而两个
  /// 标记的初值会让「既贴顶又贴底」恒成立,悬浮导航组将永远不出现。
  void _syncScrollFlags() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _nearBottom.value = pos.pixels <= 80;
    _nearTop.value = pos.pixels >= pos.maxScrollExtent - 80;
  }

  /// 贴顶时的向上分页入口。窗口化只在超长会话生效(canLoadOlder=false 的
  /// 会话是空转);流式期间控制器侧同样拒绝。
  void _maybeLoadOlder() {
    if (!_screenDataReady) return;
    // 「回到顶部」逐页取旧进行中:由 _scrollToTop 的循环驱动分页,贴顶回调
    // 不再并发触发(否则锚定 jumpTo 会与循环互相打断)。
    if (_autoTopRunning.value) return;
    if (!ref.read(chatControllerProvider).canLoadOlder) return;
    _loadOlder();
  }

  /// 补一页更早的历史。
  ///
  /// 列表 `reverse: true` —— 更早的消息追加在列表**远端**(更大下标),而已有
  /// 条目到内容底部的距离(即 `layoutOffset`)完全不受影响,故**不需要任何锚定**:
  /// 视口纹丝不动地停在原内容上,用户继续上滑即可看到新页。(旧实现要按
  /// maxScrollExtent 增量前移视口,那是在非反向坐标下抵消"前拼导致内容整体
  /// 下移"的做法;反向坐标系里这件事天然不发生,锚定反而会把视口多推一页。)
  Future<void> _loadOlder() async {
    final before = ref.read(chatControllerProvider).messages.length;
    await ref.read(chatControllerProvider.notifier).loadOlder();
    if (!mounted) return;
    // 本页加载成功后,若视口仍在预取区(快速上滑/甩动),继续补一页 ——
    // 不必等用户再次滚动触发。加载被拒(流式/忙碌)时条数不变,不再递归。
    if (ref.read(chatControllerProvider).messages.length == before) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _autoTopRunning.value) return;
      if (_shouldPrefetchOlder()) _maybeLoadOlder();
    });
  }

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

  /// 最近一次用户主导滚动(拖动/惯性/滚轮,经 [UserScrollNotification] 打点)
  /// 的时刻。程序性跳转不派发该通知,不会误记。
  DateTime _lastUserScroll = DateTime.fromMillisecondsSinceEpoch(0);

  /// 是否应把当前滚动继续视为"用户在控制":手指按住([_userDragging])或
  /// 最近 [Duration] 内刚发生过用户滚动(覆盖抬手后的惯性段与鼠标滚轮 ——
  /// 滚轮每次滚动是瞬时 forcePixels,activity 不驻留,只能靠宽限窗)。
  ///
  /// 程序性 `jumpTo`/`animateTo` 的 `beginActivity` 会 dispose 当前 activity ——
  /// 在用户滚动进行中跳转,会把用户的滚动直接打断、画面被拽回底部,表现为
  /// "流式时想上滑看一眼历史,气泡却停不下来"。
  bool _userScrollInProgress() {
    if (_userDragging) return true;
    return DateTime.now().difference(_lastUserScroll) <
        const Duration(milliseconds: 500);
  }

  /// 消息区滚动通知:驱动悬浮导航组的自动隐藏/延迟恢复与用户滚动打点。
  /// 返回 false 不吞通知。
  ///
  /// 用户滚动期间把悬浮滚动导航组**自动隐藏**,避免按钮压住滚动中的手指/
  /// 光标和内容;滚动真正停下后延迟 600ms 再恢复。恢复计时必须被一切"滚动
  /// 仍在进行"的迹象反复撤销,否则在特定滑动节奏下按钮会交替显隐:
  /// - 连续滚轮 tick 之间、连续甩动的手势间停顿,一旦超过延时,旧逻辑就让
  ///   按钮弹回 —— 用户还在滚动会话中,下一次滚动又把它隐藏,按钮随滚动
  ///   节奏闪烁;且旧逻辑的每次显隐都走整页 setState,滑动表现为一卡一卡;
  /// - 非 idle 的 [UserScrollNotification] 与惯性段每帧的
  ///   [ScrollUpdateNotification] 都先撤销未到期的恢复计时 —— 即使某些时序
  ///   下拖动段收尾先报了一次 ScrollEnd(activity 切换序列因版本而异),
  ///   惯性段随后的帧更新也必须把计时撤销,恢复只能从**最后一个**
  ///   ScrollEnd 之后起算。
  ///
  /// 带 `dragDetails` 的 [ScrollStartNotification] 表示用户手势开始拖动;
  /// 滚轮/惯性等非拖动用户滚动经 UserScrollNotification(方向非 idle)同样
  /// 触发隐藏。
  bool _onScrollNotification(ScrollNotification n) {
    if (n is UserScrollNotification) {
      // 记录用户主导滚动的时刻,供宽限窗使用。UserScrollNotification 只由
      // 用户物理滚动派发(拖动/惯性/滚轮),程序性跳转不产生,不会误记
      // (idle 方向也打点:滚轮每 tick 收尾与惯性结束都会报一次 idle,
      // 同样属于"用户刚滚动过")。
      _lastUserScroll = DateTime.now();
      if (n.direction != ScrollDirection.idle) {
        _navRestoreTimer?.cancel();
        _navAutoHidden.value = true;
      }
    } else if (n is ScrollStartNotification && n.dragDetails != null) {
      if (!_userDragging) {
        _userDragging = true;
        _navRestoreTimer?.cancel();
        _navAutoHidden.value = true;
      }
    } else if (n is ScrollUpdateNotification) {
      // 滚动仍在进行(拖动/惯性的每一帧):撤销任何已武装的恢复计时,
      // 恢复只能从"最后一个 ScrollEnd"之后起算。程序性自动跟随的跳动也会
      // 经过这里,随后其自身的 ScrollEnd 会重新武装计时,不会卡在隐藏态。
      if (_navAutoHidden.value) _navRestoreTimer?.cancel();
    } else if (n is ScrollEndNotification) {
      if (_userDragging) _userDragging = false;
      // 收尾瞬间不立即恢复,延迟 600ms 让用户先看一眼停下的内容,再让按钮
      // "轻轻回"到原位而不是立刻压住刚露出的正文。惯性段的每次 ScrollEnd
      // 都顺延计时,惯性真正结束才算停下。
      if (_navAutoHidden.value) {
        _navRestoreTimer?.cancel();
        _navRestoreTimer = Timer(const Duration(milliseconds: 600), () {
          if (!mounted) return;
          _navAutoHidden.value = false;
        });
      }
    }
    return false;
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
    }
  }

  void _scrollToBottom({bool animate = true, bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // 用户恰在此刻按下拖动:程序性贴底必须让位,同时解除初始定位的隐藏态
      // (绝不滞留在"列表不可见"的状态)。
      if (_userDragging) {
        _settleEntry();
        return;
      }
      _performScrollToBottom(animate: animate, force: force);
    });
  }

  /// 解除「进入会话初始定位」的列表隐藏态并显示(幂等)。挂在贴底收敛链的
  /// 每一条退出点上:贴底 settled、帧预算用尽、用户抢先滚动 —— 保证任何
  /// 路径下列表最多隐藏几个收敛帧,不会停在透明态。
  void _settleEntry() {
    if (!_entrySettling || !mounted) return;
    setState(() => _entrySettling = false);
  }

  /// 贴底。列表 `reverse: true` —— 底部恒为 **offset 0**,与内容总高度无关:
  /// 懒加载列表的 `maxScrollExtent` 是「已布局窗口平均高度 × 剩余条数」的估算
  /// (本 App 条目高度差异极大、图片高度还异步变化,实测可偏离真值 2.6 倍),
  /// 而 offset 0 是精确值。于是这里退化为一次跳转:不再需要多帧收敛链,
  /// 也**不可能**越过真实末尾落进空白死区再被弹簧拖回 —— 那正是长会话里
  /// 「发送消息后先快速滚到远处又滚回来」的来源。
  ///
  /// 消息落库/草稿块/图片改高/视口尺寸变化都不需要额外处理:只要视口停在 0,
  /// 内容怎么变它都还在底部(内容在偏移更大一侧生长,不移动 offset 0 处的内容)。
  void _performScrollToBottom({bool animate = true, bool force = false}) {
    if (!mounted) return;
    if (!_scroll.hasClients) {
      // 首帧布局尚未建立滚动位置:直接解除隐藏即可 —— offset 初值本就是 0
      // (底部),不存在"落在最旧消息处"的可能。
      _settleEntry();
      return;
    }
    // 进入会话的贴底定位是唯一不经过 `_onScroll` 的定位路径(视口本就停在
    // offset 0、不产生滚动),邻域标记必须在这里补一次同步(见 _syncScrollFlags)。
    _syncScrollFlags();
    // force 只用于「用户主动发送」这一显式意图:不受 500ms 用户滚动宽限窗
    // 影响,但仍让位给正在按住的拖动。
    if (_userDragging || (!force && _userScrollInProgress())) {
      _settleEntry(); // 用户抢先接管:立即显示,跟随让位于手势。
      return;
    }
    final pos = _scroll.position;
    if (pos.pixels <= 1.0) {
      _settleEntry();
      return;
    }
    if (animate && !reduceMotionOf(context)) {
      // 用户可见的一段(如点「回到底部」)保持动画平滑;到位后解除隐藏态。
      _scroll
          .animateTo(
            0,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          )
          .whenComplete(() {
            if (mounted) _settleEntry();
          });
      return;
    }
    _scroll.jumpTo(0);
    _settleEntry();
  }

  /// 「回到顶部」:先把窗口之上未加载的旧历史**逐页取尽**,再落到绝对顶部
  /// (时间序第一条)。列表 `reverse: true` —— 顶部在偏移更大的一端,即
  /// `maxScrollExtent`;该值仍是估算(懒加载列表只有尾段条目布局后才精确),
  /// 故取尽后用 [_convergeToTop] 做「小步逼近 + 逐帧复核」的多帧收敛。
  ///
  /// 分页本身**不需要锚定**:更早的消息追加在列表远端,已有条目的位置不变,
  /// 视口不会因补页而漂移。循环期间 [_maybeLoadOlder] 让位(由本循环驱动)。
  ///
  /// 流式回复/耗时命令进行中控制器会拒绝 loadOlder([_loadOlder] 静默无进展):
  /// 以「消息条数不变」检测该拒绝,提示用户并停到当前窗口顶,不做死循环。
  Future<void> _scrollToTop() async {
    if (_autoTopRunning.value) return;
    _autoTopRunning.value = true;
    // 页数/时间双预算:历史极长的会话不再一次性把全部消息拉进内存。
    // 预算用尽时停在"已加载窗口的顶部",再次点击可继续向前加载。
    const pageBudget = 8; // 8 × 120 行 ≈ 960 条消息
    const timeBudget = Duration(seconds: 3);
    final budgetWatch = Stopwatch()..start();
    var pagesLoaded = 0;
    var budgetExhausted = false;
    try {
      while (mounted &&
          _screenDataReady &&
          ref.read(chatControllerProvider).canLoadOlder) {
        // 用户一旦接管(拖动/惯性/滚轮),立即让位,不再自动加载。
        if (_userDragging || _userScrollInProgress()) return;
        if (pagesLoaded >= pageBudget || budgetWatch.elapsed >= timeBudget) {
          budgetExhausted = true;
          break;
        }
        final before = ref.read(chatControllerProvider).messages.length;
        await _loadOlder();
        pagesLoaded++;
        // 等一帧:让补页的重建先落定,再继续下一页。
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        final st = ref.read(chatControllerProvider);
        if (st.canLoadOlder && st.messages.length == before) {
          _islandHub.push(
            '生成或命令进行中,暂不能加载更早的历史;已回到当前窗口顶部',
            tone: IslandTone.info,
          );
          break;
        }
      }
      if (!mounted) return;
      await _convergeToTop();
      if (budgetExhausted &&
          mounted &&
          ref.read(chatControllerProvider).canLoadOlder) {
        _islandHub.push(
          '已回到已加载历史的顶部;再点一次「回到顶部」可继续加载更早消息',
          tone: IslandTone.info,
        );
      }
    } finally {
      _autoTopRunning.value = false;
    }
  }

  /// 多帧收敛到列表顶部(reverse 下 = `maxScrollExtent`)。
  ///
  /// 顶部方向**仍然**是估算值,且只有视口贴近它时布局才会排布尾段条目、把
  /// 估算修正到精确 —— 单次跳转可能停在估算的中间点。逐帧按「单帧最多 6 个
  /// 视口」小步逼近,每次落点触发布局 refine,下一帧复核继续逼近;每步都
  /// 立即跳变(无缓动残差),落点精确。底部方向不需要这套:那是恒为 0 的精确
  /// 位置(见 [_performScrollToBottom])。
  Future<void> _convergeToTop({int attempts = 0}) async {
    if (!mounted || !_scroll.hasClients) return;
    if (_userDragging || _userScrollInProgress()) return;
    if (attempts >= 64) return; // 预算兜底,防止极端情况下的无限收敛。
    final pos = _scroll.position;
    final target = pos.maxScrollExtent;
    if ((pos.pixels - target).abs() < 1.0) return;
    final stepCap = pos.viewportDimension * 6;
    final capped = target > pos.pixels
        ? math.min(target, pos.pixels + stepCap)
        : math.max(target, pos.pixels - stepCap);
    _scroll.jumpTo(capped);
    // 显式催帧:内容不足一屏时本次 jump 不产生滚动活动,若此刻再无其它脏
    // 对象,复核回调要等某个无关事件碰巧催帧才发生。
    WidgetsBinding.instance.scheduleForcedFrame();
    await WidgetsBinding.instance.endOfFrame;
    await _convergeToTop(attempts: attempts + 1);
  }

  void _scrollToPreviousMessage() {
    _messageListKey.currentState?.scrollToPreviousMessage();
  }

  void _scrollToNextMessage() {
    _messageListKey.currentState?.scrollToNextMessage();
  }

  /// 会话内搜索:选中命中消息后先扩展显示窗口(目标可能远在首屏窗口之外),
  /// 再滚到该条并短暂高亮。组装窗口不受影响(见 ChatController.revealMessage)。
  /// 扩窗期间先压住贴底跟随;定位失败(消息已删/不可见)时恢复原标记并提示。
  Future<void> _openChatSearch() async {
    if (!_screenDataReady) {
      _islandHub.push('会话正在加载,请稍后再试', tone: IslandTone.info);
      return;
    }
    if (_autoTopRunning.value) {
      _islandHub.push('正在回到顶部,请稍后再试', tone: IslandTone.info);
      return;
    }
    final messageId = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (_) => ChatSearchScreen(
          sessionId: widget.sessionId,
          characterName: _character.name,
          characterAvatarBase64: _avatarBase64,
          initialQuery: _lastSearchQuery,
          onQueryChanged: (query) => _lastSearchQuery = query,
        ),
      ),
    );
    if (messageId == null || !mounted) return;
    // 扩窗会增加消息条数并触发「贴底跟随」;目标在历史里,先让出跟随,
    // 由定位滚动接管。失败时恢复原标记(下一次滚动也会重新同步)。
    final wasNearBottom = _nearBottom.value;
    _nearBottom.value = false;
    final located = await ref
        .read(chatControllerProvider.notifier)
        .revealMessage(messageId);
    if (!mounted) return;
    if (!located) {
      _nearBottom.value = wasNearBottom;
      _islandHub.push('无法定位该消息:它可能已被删除,或正在加载历史', tone: IslandTone.danger);
      return;
    }
    await _messageListKey.currentState?.revealMessage(messageId);
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightMessageId = messageId);
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightMessageId = null);
    });
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
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
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

  /// 从聊天页进入角色卡编辑;返回后刷新本地快照/头像,并让控制器重算上下文,
  /// 改名/换头像与设定修改立即生效,不必退出重进会话。
  Future<void> _openCharacterEdit() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CharacterEditScreen(characterId: widget.characterId),
      ),
    );
    if (!mounted) return;
    final card = await ref
        .read(characterRepositoryProvider)
        .get(widget.characterId);
    if (!mounted || card == null) return;
    setState(() => _character = card);
    await _loadVisuals();
    if (!mounted) return;
    if (ref.read(chatControllerProvider).sessionId == widget.sessionId) {
      await ref.read(chatControllerProvider.notifier).updateCharacter(card);
    }
  }

  /// 导出会话为 v4 归档:桌面端直接选路径并流式写出,移动端先写临时文件再
  /// 交给系统另存为或分享面板;取消与失败由 `saveSessionArchive` 统一提示。
  /// [title] 为归档文件名前缀:AppBar 菜单用「角色名-会话 id」,侧栏用会话
  /// 标题(AppBar 导出当前会话,侧栏可导出任意会话)。
  Future<void> _exportSessionArchive({
    required int sessionId,
    required String title,
    bool share = false,
  }) async {
    await saveSessionArchive(
      context,
      fileName: '$title.json',
      delivery: share
          ? SessionArchiveDelivery.share
          : SessionArchiveDelivery.save,
      build: (staging, {onProgress, isCancelled}) =>
          SessionExporter(ref.read(databaseProvider)).exportToFile(
            sessionId: sessionId,
            file: staging,
            onProgress: onProgress,
            isCancelled: isCancelled,
          ),
    );
  }

  Future<void> _exportSession({bool share = false}) => _exportSessionArchive(
    sessionId: widget.sessionId,
    title: '${_character.name}-${widget.sessionId}',
    share: share,
  );

  /// 级联删除一条会话并刷新会话列表与侧栏数据(调用方负责确认与导航)。
  Future<void> _deleteSessionCascade(int sessionId, int? characterId) async {
    await ref.read(sessionRepositoryProvider).deleteWithCascade(sessionId);
    if (characterId != null) ref.invalidate(sessionInfosProvider(characterId));
    ref.invalidate(sessionGroupsProvider);
  }

  /// 打开状态面板(AppBar 状态按钮与灵动岛的状态入口共用)。
  void _openStatus() {
    final character = ref.read(chatControllerProvider).character;
    if (character == null) return; // 尚未加载完成
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatusScreen(sessionId: widget.sessionId),
      ),
    );
  }

  /// 删除当前会话:确认后级联删除消息与关联行(不可恢复),刷新会话列表
  /// 并退出聊天页;用户取消则不做任何写入。
  Future<void> _deleteSession() async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除会话?',
      message: '会话内的全部消息都会被删除,不可恢复。',
    );
    if (!confirmed || !mounted) return;
    final characterId = ref.read(chatControllerProvider).characterId;
    await _deleteSessionCascade(widget.sessionId, characterId);
    if (!mounted) return;
    Navigator.pop(context);
  }

  /// 侧栏会话行菜单:置顶 / 重命名 / 导出 / 删除,作用对象可以是列表里的
  /// 任意会话(含其它角色);重命名 / 导出 / 删除与 AppBar 的会话菜单同口径。
  Future<void> _handleSidebarAction(
    SessionInfo session,
    SessionSidebarAction action,
  ) async {
    switch (action) {
      case SessionSidebarAction.togglePin:
        await _toggleSessionPin(session);
      case SessionSidebarAction.rename:
        await _renameSession(session);
      case SessionSidebarAction.export:
        await _exportSessionArchive(
          sessionId: session.id,
          title: session.title.trim().isEmpty
              ? '会话 #${session.id}'
              : session.title.trim(),
        );
      case SessionSidebarAction.delete:
        await _deleteSessionFromSidebar(session);
    }
  }

  /// 侧栏置顶/取消置顶:只改会话的展示优先级,不动消息与当前路由;
  /// 落库后失效侧栏数据即时重排。
  Future<void> _toggleSessionPin(SessionInfo session) async {
    try {
      await ref
          .read(sessionRepositoryProvider)
          .setPinned(session.id, session.pinnedAt == null);
      ref.invalidate(sessionInfosProvider(session.characterId));
      ref.invalidate(sessionGroupsProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          width: chatSnackBarWidth(context),
          content: Text('置顶状态更新失败:$e'),
        ),
      );
    }
  }

  /// 侧栏重命名:空标题不落库并明确提示;改名后会话列表与侧栏即时刷新。
  Future<void> _renameSession(SessionInfo session) => _renameSessionById(
    sessionId: session.id,
    characterId: session.characterId,
    initialTitle: session.title,
  );

  /// AppBar 会话菜单的重命名:聊天页不持有会话标题,先从库里取当前值
  /// 作对话框初始文本。
  Future<void> _renameCurrentSession() async {
    final session = await ref
        .read(sessionRepositoryProvider)
        .get(widget.sessionId);
    if (session == null || !mounted) return;
    await _renameSessionById(
      sessionId: widget.sessionId,
      characterId: widget.characterId,
      initialTitle: session.title,
    );
  }

  /// 重命名任意会话(AppBar 与侧栏共用):空标题不落库并明确提示;
  /// 改名后会话列表与侧栏即时刷新。
  Future<void> _renameSessionById({
    required int sessionId,
    required int characterId,
    required String initialTitle,
  }) async {
    final next = await showDialog<String>(
      context: context,
      builder: (_) => _RenameSessionDialog(initialTitle: initialTitle),
    );
    if (next == null || !mounted) return;
    final title = next.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            width: chatSnackBarWidth(context),
            content: const Text('会话标题不能为空'),
          ),
        );
      return;
    }
    await ref.read(sessionRepositoryProvider).rename(sessionId, title);
    ref.invalidate(sessionInfosProvider(characterId));
    ref.invalidate(sessionGroupsProvider);
  }

  /// 侧栏删除:删除的是当前会话就退出聊天页(与 AppBar 菜单一致),
  /// 否则留在当前会话并轻提示;两种路径都由侧栏数据失效即时反映。
  Future<void> _deleteSessionFromSidebar(SessionInfo session) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除会话?',
      message: '会话内的全部消息都会被删除,不可恢复。',
    );
    if (!confirmed || !mounted) return;
    await _deleteSessionCascade(session.id, session.characterId);
    if (!mounted) return;
    if (session.id == widget.sessionId) {
      Navigator.pop(context);
    } else {
      _islandHub.push('已删除会话', tone: IslandTone.info);
    }
  }

  /// 收起/展开桌面会话侧栏:内存态立即生效(宽度动画收展),并整体回写
  /// `ui-prefs.json`(保留布局与牌堆进度);写失败只打日志,不回滚本次切换。
  Future<void> _toggleSidebar() async {
    final next = !ref.read(sidebarCollapsedProvider);
    ref.read(sidebarCollapsedProvider.notifier).state = next;
    await syncUiPrefsFile(ref);
  }

  /// 侧栏 home 键:一次弹掉栈内全部会话路由,回到应用首页(角色列表)。
  /// 会话切换走 pushReplacement,返回栈深度不定,逐层返回不可靠。
  void _goHome() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// 侧栏切换到同角色/其它角色的会话:以零时长过渡整页替换当前路由 ——
  /// 会话切换本就是换一份数据,推入新路由会把返回栈越堆越深,且系统滑动
  /// 过渡在桌面场景显得拖沓。同一会话是空操作。
  void _switchSession(CharacterRecord character, SessionInfo session) {
    if (session.id == widget.sessionId) return;
    _openSession(character, session.id);
  }

  void _openSession(CharacterRecord character, int sessionId) {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => ChatScreen(
          sessionId: sessionId,
          characterId: character.id,
          character: character.card,
        ),
      ),
    );
  }

  /// 侧栏「新建会话」:与角色页新建同口径(角色有开场白时作为助手首条
  /// 消息落库),刷新侧栏数据后直接进入新会话。
  Future<void> _createSessionFor(CharacterRecord character) async {
    try {
      final id = await ref
          .read(sessionRepositoryProvider)
          .createWithDefaultTitle(character.id);
      if (character.card.firstMessage.isNotEmpty) {
        await ref
            .read(messageRepositoryProvider)
            .append(
              sessionId: id,
              role: 'assistant',
              content: character.card.firstMessage,
            );
      }
      ref.invalidate(sessionInfosProvider(character.id));
      ref.invalidate(sessionGroupsProvider);
      if (!mounted) return;
      final container = ProviderScope.containerOf(context, listen: false);
      _openSession(character, id);
      // 路由替换会销毁旧侧栏订阅;若分组刷新恰好横跨这一帧,新侧栏可能
      // 拿到失效前的快照。待新路由完成首帧后再失效一次,确保新会话行
      // 即时出现。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        container.invalidate(sessionGroupsProvider);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(width: chatSnackBarWidth(context), content: Text('新建会话失败:$e')),
      );
    }
  }

  /// 消息操作统一分发(气泡下方按钮与长按/右键菜单共用)。
  Future<void> _messageAction(Message m, MessageAction action) async {
    final controller = ref.read(chatControllerProvider.notifier);
    switch (action) {
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: m.content));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              width: chatSnackBarWidth(context),
              content: const Text('已复制到剪贴板'),
            ),
          );
        }
      case MessageAction.edit:
        await _editMessage(m);
      case MessageAction.delete:
        final id = m.id;
        if (id == null) return;
        final snapshot = await controller.deleteMessage(id);
        if (snapshot == null || !mounted) return;
        // 删除即时生效但保留撤销窗口:快照含图片字节,撤销后原位置/内容复原;
        // 撤销窗口内又有新消息落库时恢复行排到末尾,不留重复 seq。
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            width: chatSnackBarWidth(context),
            content: const Text('已删除消息'),
            action: SnackBarAction(
              label: '撤销',
              onPressed: () => controller.restoreMessage(snapshot),
            ),
          ),
        );
      case MessageAction.regenerate:
        final id = m.id;
        if (id != null) await controller.regenerate(id);
      case MessageAction.rewrite:
        await _rewriteMessage(m);
      case MessageAction.resend:
        final id = m.id;
        if (id != null) await controller.resend(id);
      case MessageAction.regenerateImage:
        await _regenerateImage(m);
    }
  }

  /// 按消息保留的原始图片描述重绘;结果(错误或成功提示)经灵动岛闪示,
  /// 图片原地替换后由列表修订号触发重新读库。
  Future<void> _regenerateImage(Message m) async {
    final id = m.id;
    if (id == null) return;
    final error = await ref
        .read(chatControllerProvider.notifier)
        .regenerateImage(id);
    if (!mounted) return;
    _islandHub.push(
      error ?? '图片已重新生成',
      tone: error == null ? IslandTone.success : IslandTone.danger,
    );
  }

  /// 长按/右键菜单:按消息角色与内容动态给出操作项 —— 空正文不提供复制/
  /// 编辑,重新生成图片只在助手消息带图且留有原始描述时出现(没有描述就
  /// 无法重绘);「按要求重写」只给最新一条有正文的助手回复(其后允许跟
  /// 图片消息);删除恒定提供。
  Future<void> _messageActions(Message m) async {
    final isUser = m.role == 'user';
    final hasText = m.content.trim().isNotEmpty;
    final canRewrite =
        !isUser &&
        hasText &&
        latestRewritableAssistantReply(
              ref.read(chatControllerProvider).messages,
            )?.id ==
            m.id;
    final picked = await showAppActionSheet<MessageAction>(
      context,
      actions: [
        if (hasText)
          const MenuAction(
            value: MessageAction.copy,
            label: '复制内容',
            icon: Icons.copy_outlined,
          ),
        if (hasText)
          const MenuAction(
            value: MessageAction.edit,
            label: '编辑消息',
            icon: Icons.edit_outlined,
          ),
        if (canRewrite)
          const MenuAction(
            value: MessageAction.rewrite,
            label: '按要求重写',
            icon: Icons.edit_note,
          ),
        if (!isUser && hasText)
          const MenuAction(
            value: MessageAction.regenerate,
            label: '重新生成',
            icon: Icons.refresh,
          ),
        if (!isUser &&
            m.hasVisualImage &&
            (m.imagePrompt?.trim().isNotEmpty ?? false))
          const MenuAction(
            value: MessageAction.regenerateImage,
            label: '重新生成图片',
            icon: Icons.autorenew,
          ),
        if (isUser && hasText)
          const MenuAction(
            value: MessageAction.resend,
            label: '重新发送',
            icon: Icons.send_outlined,
          ),
        const MenuAction(
          value: MessageAction.delete,
          label: '删除消息',
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
    if (picked != null) await _messageAction(m, picked);
  }

  /// 弹出名词释义卡:点击气泡内高亮词条时显示对应世界书条目的标题与全文。
  /// 释义不进上下文,纯显示;正文可选中复制。
  void _showTermCard(GlossaryTerm term) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: false,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 词条名长度不定:Expanded+Align 让胶囊左对齐、关闭钮恒在
                    // 右缘,长词条名在剩余宽度内自然换行 —— 自然宽度的胶囊在
                    // 窄弹层里会把本行顶出右缘(0.5px 级 overflow)。
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            term.title,
                            style: TextStyle(
                              color: scheme.onSecondaryContainer,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      term.content,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 弹一个底部编辑区改写消息内容;保存后落库并刷新。
  ///
  /// 相比旧的居中 AlertDialog,底部编辑区在移动端会**随软键盘整体抬升**
  /// (按 `viewInsets` 垫高),编辑区高度也更充裕(长回复不再挤在 6 行小框里),
  /// 整体更贴近"就地改写一条消息"的体验。
  Future<void> _editMessage(Message m) async {
    if (m.id == null || ref.read(chatControllerProvider).streaming) return;
    final saved = await showTextEditSheet(
      context,
      title: m.role == 'user' ? '编辑消息' : '编辑回复',
      initialText: m.content,
    );
    if (saved == null || !mounted) return;
    await ref.read(chatControllerProvider.notifier).editMessage(m.id!, saved);
  }

  /// 「按要求重写」:先收集修改要求,再由控制器剪断旧回复并带要求重走生成
  /// 管线。要求只随当次请求注入,不落库、不会出现在聊天流里。
  Future<void> _rewriteMessage(Message m) async {
    final id = m.id;
    if (id == null) return;
    final chat = ref.read(chatControllerProvider);
    if (chat.streaming || chat.busyCommand != null) {
      _islandHub.push('正在处理中,请稍候', tone: IslandTone.info);
      return;
    }
    if (chat.regeneratingImageId != null) {
      _islandHub.push('正在重新生成图片,请稍候', tone: IslandTone.info);
      return;
    }
    final saved = await showTextEditSheet(
      context,
      title: '按要求重写',
      initialText: '',
      hintText: '描述希望如何修改这条回复…',
      submitLabel: '重写',
      editorHeightFactor: 0.32,
      maxEditorHeight: 240,
    );
    if (saved == null || !mounted) return;
    final error = await ref
        .read(chatControllerProvider.notifier)
        .rewrite(id, saved);
    if (error != null && mounted) {
      _islandHub.push(error, tone: IslandTone.danger);
    }
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
    // 用户头像:按 base64 值缓存单个 ImageProvider(全列表共用),避免流式回复期间
    // 整页反复重建时头像被反复解码而频闪。
    if (user.avatarBase64 != _userAvatarKey) {
      _userAvatarKey = user.avatarBase64;
      final bytes = safeBase64Decode(user.avatarBase64);
      _userAvatarImage = bytes == null ? null : MemoryImage(bytes);
    }
    // 角色头像:值不变复用同一 provider 实例(避免流式期间反复重建重解码)。
    if (_avatarBase64 != _assistantAvatarKey) {
      _assistantAvatarKey = _avatarBase64;
      final bytes = safeBase64Decode(_avatarBase64);
      _assistantAvatarImage = bytes == null ? null : MemoryImage(bytes);
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
      // 首次数据到达不算「新消息」:此时侧栏刚拿到首查结果,再失效一次
      // 只会多打一轮无意义聚合查询。
      final hadBaseline = _lastCount >= 0;
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
          !_autoTopRunning.value) {
        _scrollToBottom(animate: !chat.streaming, force: fromSend);
      }
      // 侧栏的组内排序与末条预览随消息更新:帧末失效(不能在 build 期改
      // provider);侧栏不在可视区时跳过(失效只记脏,重新展开时由
      // [_sidebarWasShown] 的补失效统一兜底)。
      if (showSidebar && hadBaseline) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ref.invalidate(sessionGroupsProvider);
        });
      }
    }
    // 流式草稿在独立 provider(不驱动整页重建),经 listen 跟随:
    // 每个草稿块只触发这条回调(贴底时滚动一下),页面 build 不再陪跑。
    ref.listen<String>(chatDraftProvider, (_, _) {
      if (_screenDataReady &&
          _positioned &&
          _nearBottom.value &&
          !_userDragging) {
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

    // 会话记忆:驱动「初始化记忆」提示条(后台成功写入后经 invalidate 自动刷新,
    // 记忆非空即提示条消失)。手动关闭按会话记忆,重复进入同一会话不再弹出。
    final memoriesAsync = ref.watch(memoriesProvider(widget.sessionId));
    final memoryInitDismissed = ref
        .watch(memoryInitDismissedProvider)
        .contains(widget.sessionId);

    final appBarAvatar = InkWell(
      key: const ValueKey('appbar-character-avatar'),
      customBorder: const CircleBorder(),
      onTap: _showCharacterStatusCard,
      child: _ChatAvatar(name: _character.name, avatarBase64: _avatarBase64),
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
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
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
      titleSpacing: 0,
      automaticallyImplyLeading: false,
      title: Row(
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
      actions: appBarActions,
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
            backgroundBase64: _bgBase64,
            avatarBase64: _avatarBase64,
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
                            imageLoader: (id) => listRef
                                .read(messageRepositoryProvider)
                                .imageBase64For(id),
                            // 全屏查看器的"删除图片":只清空该消息图片字段,正文保留。
                            onImageDelete: (id) => listRef
                                .read(chatControllerProvider.notifier)
                                .deleteMessageImage(id),
                            regeneratingImageId: chat.regeneratingImageId,
                            imageRevisions: chat.imageRevisions,
                            highlightedMessageId: _highlightMessageId,
                            onMessageLongPress: _messageActions,
                            onMessageAction: (m, a) => _messageAction(m, a),
                            // 操作按钮排显隐上报:导航组据此让位(见 _messageActionsOpen)。
                            onActionsVisibleChanged: (open) =>
                                _messageActionsOpen.value = open,
                          ),
                        ),
                      ),
                    ),
                    // 灵动岛:错误警报 / 用量分账(主写·后台·压缩)/ 主写流式与后台
                    // 维护实况 / 后台运行后摘要闪示 / 初始化记忆行动项 / 命令反馈
                    // 闪示,统一由这颗悬浮胶囊承载。
                    // 贴顶翻历史时收起用量粒(_nearTop 经 AnimatedBuilder 只重建这
                    // 一小块);入场收敛期整粒隐藏。恒驻 Stack 子树(hidden 时渲染
                    // 零高占位),不改变消息区的元素下标,State 稳定。
                    AnimatedBuilder(
                      animation: Listenable.merge([_nearTop, _nearBottom]),
                      builder: (context, _) => ChatIsland(
                        key: const ValueKey('chat-island'),
                        chat: chat,
                        memoryInitPrompt:
                            !memoryInitDismissed &&
                            chat.backgroundStatus != BackgroundStatus.running &&
                            memoriesAsync.maybeWhen(
                              data: (list) =>
                                  list.every((m) => m.content.trim().isEmpty),
                              orElse: () => false,
                            ),
                        compacting: chat.busyCommand == 'compact',
                        hidden: _entrySettling,
                        // 用量粒让位:仅当列表真的可滚动且用户翻到了顶部(贴顶但
                        // 不贴底)。内容不足一屏的会话贴顶也贴底,不存在"胶囊压住
                        // 正在翻看的历史",照常常驻。
                        idleHushed: _nearTop.value && !_nearBottom.value,
                        hub: _islandHub,
                        onOpenStatus: _openStatus,
                        onInterrupt: () => ref
                            .read(chatControllerProvider.notifier)
                            .interrupt(),
                        onInitMemory: () => ref
                            .read(chatControllerProvider.notifier)
                            .initializeMemory(),
                        onDismissMemoryInit: () {
                          final notifier = ref.read(
                            memoryInitDismissedProvider.notifier,
                          );
                          notifier.state = {
                            ...notifier.state,
                            widget.sessionId,
                          };
                        },
                        onDismissError: () => ref
                            .read(chatControllerProvider.notifier)
                            .clearError(),
                      ),
                    ),
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
                    if (!_entrySettling)
                      _ScrollNavRail(
                        nearTop: _nearTop,
                        nearBottom: _nearBottom,
                        autoHidden: _navAutoHidden,
                        // 选中消息的操作按钮排可见时整组让位,不压住重新发送/重新生成。
                        actionsOpen: _messageActionsOpen,
                        collapsed: _scrollNavCollapsed,
                        autoTopRunning: _autoTopRunning,
                        onToggleCollapsed: () => _scrollNavCollapsed.value =
                            !_scrollNavCollapsed.value,
                        onScrollToTop: _scrollToTop,
                        onScrollToPreviousMessage: _scrollToPreviousMessage,
                        onScrollToNextMessage: _scrollToNextMessage,
                        onScrollToBottom: () => _scrollToBottom(),
                      ),
                  ],
                ),
              ),
              // /compact 的「压缩中」活动态由灵动岛呈现。
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
    return Scaffold(
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
            child: Column(
              children: [
                appBar,
                Expanded(child: content),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 空会话输入区抬升的底部留白:在 0 与 [height] 之间做 easeOutCubic 过渡。
/// 窗口缩放导致 [height] 变化时按当前进度即时随动 —— 隐式动画在持续缩放
/// 中会一直追新目标,输入区会橡皮一样滞后;只有「有/无内容」切换才播动画。
/// 留白取内容区高度的四分之一,不必测量输入区的实际高度。
class _ComposerLift extends StatefulWidget {
  final bool lifted;
  final double height;
  final Duration duration;

  const _ComposerLift({
    required this.lifted,
    required this.height,
    required this.duration,
  });

  @override
  State<_ComposerLift> createState() => _ComposerLiftState();
}

class _ComposerLiftState extends State<_ComposerLift>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.lifted ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant _ComposerLift oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.lifted != oldWidget.lifted) {
      if (widget.lifted) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => SizedBox(
        height:
            widget.height * Curves.easeOutCubic.transform(_controller.value),
      ),
    );
  }
}

/// 宽窗侧栏的收展容器:槽宽按 [visible] 在 0..[kChatSidebarWidth] 间做
/// easeOutCubic 动画,聊天区随行重排;子树始终按侧栏满宽布局并锚定槽右缘,
/// 被 [ClipRect] 按槽宽裁切 —— 滑入滑出而不是整体缩放,标题/检索框/行宽
/// 在动画中不重排。完全收起后卸载子树:隐藏的检索框不应留在焦点遍历与
/// widget 树里(也避免测试把侧栏输入框误当聊天输入框)。
class _SidebarReveal extends StatefulWidget {
  final bool visible;
  final Duration duration;
  final Widget child;

  const _SidebarReveal({
    required this.visible,
    required this.duration,
    required this.child,
  });

  @override
  State<_SidebarReveal> createState() => _SidebarRevealState();
}

class _SidebarRevealState extends State<_SidebarReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    // 首帧即按目标状态成形:从宽窗打开聊天页不该先播一次展开动画。
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant _SidebarReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.visible != oldWidget.visible) {
      if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final width =
              kChatSidebarWidth *
              Curves.easeOutCubic.transform(_controller.value);
          if (width <= 0) return const SizedBox.shrink();
          return SizedBox(
            width: width,
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: kChatSidebarWidth,
              maxWidth: kChatSidebarWidth,
              child: SizedBox(width: kChatSidebarWidth, child: widget.child),
            ),
          );
        },
      ),
    );
  }
}

/// 悬浮滚动导航按键组:顶部方向(回到顶部/上一条消息)与底部方向(下一条
/// 消息/回到底部),「收起/展开滚动导航」夹在两组之间(列表中部时是第 3 颗,
/// 即正中间;贴顶/贴底只剩单侧方向组时,收起钮放在该组另一端,不与方向钮
/// 挤在一起)。整组可折叠:点收起折成一颗半透明小钮,再点即展开。用户滚动
/// 列表(拖动/滚轮/惯性)期间整组自动隐藏,滚动真正停止后延迟恢复(由
/// ChatScreen 的滚动通知驱动 `_navAutoHidden`)。
///
/// 六个显隐/折叠开关全部是 [ValueListenable] 且由本组通过 [AnimatedBuilder]
/// 自行监听:滚动期间这些开关频繁翻转(贴底/贴顶阈值跨越、自动隐藏/恢复),
/// 若在 ChatScreen 里走 setState 会连消息列表一起整页重建,滑动掉帧、表现为
/// 一卡一卡;这里只重建这一小块,滚动路径上零 setState。页面内悬浮的滚动
/// 工具钮统一禁用 hero 动画(`heroTag: null`),避免与其它页面的 FAB 撞默认
/// hero 标签(多个同 tag hero 触发断言)。
class _ScrollNavRail extends StatelessWidget {
  final ValueListenable<bool> nearTop;
  final ValueListenable<bool> nearBottom;
  final ValueListenable<bool> autoHidden;

  /// 选中消息的操作按钮排(复制/编辑/删除/重新发送)是否可见:可见期间整组
  /// 隐藏 —— 操作排贴在列表内容底端,选中最后一条消息时正好落在导航组的
  /// 位置上,叠着会挡住最右的重新发送/重新生成。
  final ValueListenable<bool> actionsOpen;
  final ValueListenable<bool> collapsed;

  /// 「回到顶部」逐页取旧是否进行中:进行中整组导航钮换成一颗进度指示钮并
  /// **常驻**(不随贴顶邻域/滚动自动隐藏消失 —— 旧实现正是按钮在贴顶 80px 内
  /// 消失导致用户卡在半截历史无从继续)。
  final ValueListenable<bool> autoTopRunning;
  final VoidCallback onToggleCollapsed;
  final VoidCallback onScrollToTop;
  final VoidCallback onScrollToPreviousMessage;
  final VoidCallback onScrollToNextMessage;
  final VoidCallback onScrollToBottom;

  const _ScrollNavRail({
    required this.nearTop,
    required this.nearBottom,
    required this.autoHidden,
    required this.actionsOpen,
    required this.collapsed,
    required this.autoTopRunning,
    required this.onToggleCollapsed,
    required this.onScrollToTop,
    required this.onScrollToPreviousMessage,
    required this.onScrollToNextMessage,
    required this.onScrollToBottom,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 12,
      bottom: 12,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          nearTop,
          nearBottom,
          autoHidden,
          actionsOpen,
          collapsed,
          autoTopRunning,
        ]),
        builder: (context, _) {
          // 逐页取旧进行中:整组换成进度钮,常驻显示直到落定(优先级高于
          // 下面的隐藏/折叠判定)。
          if (autoTopRunning.value) {
            return FloatingActionButton.small(
              tooltip: '正在加载更早的历史…',
              heroTag: null,
              onPressed: null,
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          // 内容不足一屏(既贴顶又贴底)没有导航意义;滚动中与消息操作排
          // 可见期间自动隐藏让位。
          if ((nearTop.value && nearBottom.value) ||
              autoHidden.value ||
              actionsOpen.value) {
            return const SizedBox.shrink();
          }
          if (collapsed.value) {
            return Opacity(
              opacity: 0.55,
              child: FloatingActionButton.small(
                tooltip: '展开滚动导航',
                heroTag: null,
                onPressed: onToggleCollapsed,
                child: const Icon(Icons.unfold_more),
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!nearTop.value) ...[
                FloatingActionButton.small(
                  tooltip: '回到顶部',
                  heroTag: null,
                  onPressed: onScrollToTop,
                  child: const Icon(Icons.keyboard_double_arrow_up),
                ),
                const SizedBox(height: 6),
                FloatingActionButton.small(
                  tooltip: '上一条消息',
                  heroTag: null,
                  onPressed: onScrollToPreviousMessage,
                  child: const Icon(Icons.keyboard_arrow_up),
                ),
              ],
              // 间距按"相邻组可见即加":贴顶/贴底只剩单侧方向组时,收起钮与
              // 最近的方向钮之间也要有 6px,不能贴住。
              if (!nearTop.value) const SizedBox(height: 6),
              FloatingActionButton.small(
                tooltip: '收起滚动导航',
                heroTag: null,
                onPressed: onToggleCollapsed,
                child: const Icon(Icons.unfold_less),
              ),
              if (!nearBottom.value) const SizedBox(height: 6),
              if (!nearBottom.value) ...[
                FloatingActionButton.small(
                  tooltip: '下一条消息',
                  heroTag: null,
                  onPressed: onScrollToNextMessage,
                  child: const Icon(Icons.keyboard_arrow_down),
                ),
                const SizedBox(height: 6),
                FloatingActionButton.small(
                  tooltip: '回到底部',
                  heroTag: null,
                  onPressed: onScrollToBottom,
                  child: const Icon(Icons.keyboard_double_arrow_down),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// AppBar 里的小头像:base64 图或名字首字。
/// 必须是 StatefulWidget:流式回复期间 AppBar 随每个流式块重建,若每次 build 都
/// 现解 base64 并 new 一个 MemoryImage,头像会被反复重新解码而频闪(与
/// _ChatBackground 同源)。这里缓存解码结果与图片 provider,仅当 avatarBase64
/// 真正变化时才重建。
class _ChatAvatar extends StatefulWidget {
  final String name;
  final String? avatarBase64;
  const _ChatAvatar({required this.name, required this.avatarBase64});

  @override
  State<_ChatAvatar> createState() => _ChatAvatarState();
}

class _ChatAvatarState extends State<_ChatAvatar> {
  Uint8List? _bytes;
  MemoryImage? _provider;

  @override
  void didUpdateWidget(covariant _ChatAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarBase64 != widget.avatarBase64) {
      _bytes = null;
      _provider = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes ??= safeBase64Decode(widget.avatarBase64);
    final initial = widget.name.isEmpty ? '?' : widget.name.characters.first;
    // foregroundImage 画在 child 之上:解码失败时自动露出首字,不会留下
    // 一个没有内容的空白圆。
    return CircleAvatar(
      radius: 16,
      foregroundImage: bytes == null
          ? null
          : (_provider ??= MemoryImage(bytes)),
      onForegroundImageError: bytes == null ? null : (_, __) {},
      child: Text(initial, style: const TextStyle(fontSize: 14)),
    );
  }
}

/// 角色 / 用户的头像状态卡(底部弹层):大头像 + 名称 + 简介,下接入口行
/// (角色卡编辑 / 个人设置)。头像缺失时退回图标占位。
class _AvatarStatusSheet extends StatelessWidget {
  final ImageProvider? avatar;
  final IconData fallbackIcon;
  final String title;
  final String subtitle;
  final String? body;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;

  const _AvatarStatusSheet({
    required this.avatar,
    required this.fallbackIcon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.body,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final icon = Icon(
      fallbackIcon,
      size: 36,
      color: scheme.onSecondaryContainer,
    );
    final avatarWidget = avatar == null
        ? CircleAvatar(
            radius: 40,
            backgroundColor: scheme.secondaryContainer,
            child: icon,
          )
        : CircleAvatar(
            radius: 40,
            backgroundColor: scheme.secondaryContainer,
            foregroundImage: avatar,
            onForegroundImageError: (_, __) {},
            child: icon,
          );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: avatarWidget),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (body != null && body!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                body!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 16),
            GroupCard(
              margin: EdgeInsets.zero,
              children: [
                ListTile(
                  leading: Icon(actionIcon, size: 20),
                  title: Text(actionLabel),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: onAction,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 聊天页背景层:全局开关开启后显示。优先角色卡专属背景图(backgroundBase64),
/// 未设置时回退角色头像(avatarBase64)——即"卡面"。背景图铺满并轻微模糊,
/// 其上再叠一层不透明白/深色淡罩,保证气泡与文字清晰可读。纯显示层,不进上下文。
///
/// 必须是 StatefulWidget:流式生成期间每次 `setState` 都会重建本层,若每次都用
/// 新的 MemoryImage,整幅背景会被反复重新解码 —— 解码期间画面闪白,表现为
/// "按钮出现/消失时闪一次、AI 生成回复时频闪"。这里缓存解码结果与图片 provider,
/// 仅在 base64 真正变化时才重建,彻底消除重建引起的闪屏。
class _ChatBackground extends StatefulWidget {
  final String? backgroundBase64;
  final String? avatarBase64;
  final double blur;
  const _ChatBackground({
    super.key,
    required this.backgroundBase64,
    required this.avatarBase64,
    required this.blur,
  });

  @override
  State<_ChatBackground> createState() => _ChatBackgroundState();
}

class _ChatBackgroundState extends State<_ChatBackground> {
  Uint8List? _bytes;
  MemoryImage? _provider;

  @override
  void didUpdateWidget(covariant _ChatBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backgroundBase64 != widget.backgroundBase64 ||
        oldWidget.avatarBase64 != widget.avatarBase64) {
      _bytes = null;
      _provider = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes ??=
        safeBase64Decode(widget.backgroundBase64) ??
        safeBase64Decode(widget.avatarBase64);
    if (bytes == null) return const SizedBox.shrink();
    // 取主题背景色的一个不透明近似色做遮罩:亮色用白、暗色用黑,让背景若隐若现。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final veilColor =
        (isDark ? const Color(0xFF121212) : const Color(0xFFFAFAFA)).withValues(
          alpha: 0.60,
        );
    final image = Image(
      image: _provider ??= MemoryImage(bytes),
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      // 即便 provider 因某种原因被替换,也保留旧帧直到新图就绪,避免闪白。
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    // blur <= 0 时不包 ImageFiltered(零模糊本就是无操作),便于测试区分。
    final rendered = widget.blur <= 0
        ? image
        : ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: widget.blur,
              sigmaY: widget.blur,
            ),
            child: image,
          );
    // ImageFiltered 的模糊输出不受布局边界约束,会画到自身 rect 之外;宽窗
    // 主从布局下背景左缘的晕染会越过窗格边界、渗到侧栏上。裁到自身边界,
    // 背景只落在聊天窗格内。
    return ClipRect(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            rendered,
            ColoredBox(color: veilColor),
          ],
        ),
      ),
    );
  }
}

/// 会话重命名弹窗:控制器归弹窗 State 所有 —— 在 showDialog 调用方释放会
/// 撞上退场动画期间 TextField 重建(controller used after dispose)。
class _RenameSessionDialog extends StatefulWidget {
  final String initialTitle;
  const _RenameSessionDialog({required this.initialTitle});

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '会话标题'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
