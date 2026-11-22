/// 聊天消息列表:reverse 懒加载、连续同角色气泡分组与选中操作排。
///
/// 只渲染可显示的行(`role != 'system'` 且 [MessageKind.chat]),图片解码与
/// 富文本都在气泡内完成;窗口化与分页由控制器决定,本列表不回库、不写消息。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import '../../engine/display_regex.dart';
import '../../engine/glossary.dart';
import '../../models/bubble_style.dart';
import '../../models/message.dart';
import '../common/chat_layout.dart';
import '../common/inline_spinner.dart';
import '../common/motion.dart';
import '../text_syntax.dart';
import 'message_bubble.dart';
import 'rich_message_text.dart';

/// 消息气泡的操作入口:复制 / 编辑 / 删除 / 重新生成(仅助手)/
/// 按要求重写(仅最新一条有正文的助手回复,其后允许跟图片消息)/
/// 重新发送(仅用户,把该条输入原样重发一遍)/
/// 重新生成 / 按要求重新生成(带原始描述的图片)/ 进入多选 / 下载图片。
enum MessageAction {
  copy,
  edit,
  delete,
  regenerate,
  rewrite,
  resend,
  regenerateImage,
  reviseImagePrompt,
  select,
  download,
}

/// 聊天消息列表。
///
/// 负责显示口径过滤、reverse 下标换算、气泡分组与滚动定位;只消费外部传入
/// 的 [messages] 与草稿参数,滚动贴底/翻页/定位都基于外部 [controller]。
class MessageList extends StatefulWidget {
  /// 时间序(旧 → 新)消息;system 摘要与附件行在渲染前被过滤掉。
  final List<Message> messages;

  /// 没有可显示消息时的内容区(角色引导/开场白);null = 一行灰字提示。
  final Widget? emptyState;

  /// 流式草稿正文;为空且 [streaming] 时草稿气泡显示打字指示器。
  final String draft;

  /// 是否正在流式生成(决定草稿伪条目是否出现)。
  final bool streaming;

  /// 外部滚动控制器;reverse 列表下 offset 0 恒为贴底。
  final ScrollController controller;

  /// 更早历史是否还有下一页(控制列表远端的分页提示行)。
  final bool canLoadOlder;

  /// 当前是否正在读取更早的一页(提示行显示转圈)。
  final bool loadingOlder;

  /// 长按/右键某条消息时回调(弹操作菜单);null = 不响应长按。
  final void Function(Message message)? onMessageLongPress;

  /// 气泡下方操作按钮触发的回调。
  final void Function(Message message, MessageAction action)? onMessageAction;

  /// 任一气泡被选中、操作按钮排显隐变化的回调(true 选中/false 取消)。
  /// 聊天页据此让右下角滚动导航组让位 —— 选中最后一条消息时操作排贴在
  /// 列表最底端,导航组叠上来会挡住最右的重新发送/重新生成。
  final ValueChanged<bool>? onActionsVisibleChanged;

  /// 用户头像图片 provider(由 chat_screen 缓存后注入,同一实例全列表共用),
  /// 显示在用户气泡旁;为空时回退占位图标。共用同一实例可避免流式回复期间
  /// 整页重建时每条用户消息各自新建 provider 而频闪。
  final ImageProvider? userAvatarImage;

  /// 角色头像图片 provider(与用户头像同款:chat_screen 按 base64 缓存实例),
  /// 显示在助手气泡上方;为空时回退占位图标(角色状态卡入口始终可用)。
  final ImageProvider? assistantAvatarImage;

  /// 点击用户/角色头像(气泡上方的小头像与草稿头像)的回调:
  /// 聊天页据此弹出对应的状态卡(null = 头像不响应点击)。
  final VoidCallback? onUserAvatarTap;
  final VoidCallback? onAssistantAvatarTap;

  /// 当前用户名(显示时替换正文里的 `{{user}}`;仅影响显示)。
  final String? displayUserName;

  /// 角色名(显示时替换正文里的 `{{char}}`;仅影响显示)。
  final String? displayCharName;

  /// 聊天页编译好的共享语法(命令/@技能/宏/标签),气泡与输入框同源。
  final CompiledSyntax? syntax;

  /// 显示层正则脚本(正文渲染管线用;null = 无脚本)。
  final List<CompiledRegexScript>? regexScripts;

  /// 名词词典(世界书词条高亮 + 点击;null = 不高亮)。
  final CompiledGlossary? glossary;

  /// 词条点击回调(弹释义卡);null = 仅高亮样式。
  final void Function(GlossaryTerm term)? onTermTap;

  /// 内置对话高亮(引号台词斜体+强调色)总开关;false = 引号内文字按普通正文渲染。
  final bool highlightDialogue;

  /// 角色级气泡样式(仅助手气泡生效;null = 应用默认)。
  final BubbleStyle? assistantBubbleStyle;

  /// 删除某条消息中的图片(全屏查看器"删除图片"按钮);null = 图片不可删。
  final Future<void> Function(int messageId)? onImageDelete;

  /// 正在重新生成图片的消息 id(null = 空闲):该气泡图片叠转圈遮罩,
  /// 操作行的图片重生成按钮禁用。
  final int? regeneratingImageId;

  /// 搜索命中的消息 id:对应气泡叠一圈强调描边与外发光,短暂提示定位结果。
  final int? highlightedMessageId;

  /// 是否处于多选模式:点击气泡切换 [selection],不显示单条操作排。
  final bool selectionMode;

  /// 多选模式下当前选中的消息 id 集合;null = 多选关闭。
  final ValueListenable<Set<int>>? selection;

  /// 多选模式下点击某条气泡的切换回调。
  final void Function(int messageId)? onSelectionToggle;

  const MessageList({
    super.key,
    required this.messages,
    this.emptyState,
    required this.draft,
    this.streaming = false,
    required this.controller,
    this.canLoadOlder = false,
    this.loadingOlder = false,
    this.onMessageLongPress,
    this.onMessageAction,
    this.onActionsVisibleChanged,
    this.userAvatarImage,
    this.assistantAvatarImage,
    this.onUserAvatarTap,
    this.onAssistantAvatarTap,
    this.displayUserName,
    this.displayCharName,
    this.syntax,
    this.regexScripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
    this.assistantBubbleStyle,
    this.onImageDelete,
    this.regeneratingImageId,
    this.highlightedMessageId,
    this.selectionMode = false,
    this.selection,
    this.onSelectionToggle,
  });

  @override
  State<MessageList> createState() => MessageListState();
}

/// 一个已布局条目的几何信息(reverse 列表口径)。
///
/// [layoutOffset] 是条目视觉**底边**到内容底部的距离,`bottom` 是视觉上边缘;
/// 爬楼与定位都按这个口径换算视口位置。
class _RenderItemInfo {
  final int index;
  final double layoutOffset;
  final double height;
  double get bottom => layoutOffset + height;

  const _RenderItemInfo({
    required this.index,
    required this.layoutOffset,
    required this.height,
  });
}

/// 列表状态:缓存显示口径投影与下标映射,并暴露爬楼/搜索定位入口。
///
/// 投影按 [MessageList.messages] 的实例记忆化 —— 流式草稿变化只换草稿参数,
/// 不触发全量重扫;控制器整体替换 messages 实例时自然失效。
class MessageListState extends State<MessageList> {
  /// 显示口径过滤结果的记忆化(见 build 内注释):[_visibleSource] 记录上次
  /// 过滤的源列表实例,实例不变(仅 draft/streaming 等参数变化)时直接复用
  /// [_visibleMessages]。
  List<Message>? _visibleSource;
  List<Message>? _visibleMessages;

  /// 可见消息 id → 时间序下标(与 [_visibleMessages] 同批重建),供
  /// `findChildIndexCallback` O(1) 定位;逐条 indexWhere 在长会话里每次
  /// 重建都要扫一遍列表。
  Map<int, int> _visibleIndexById = const {};

  /// 定位请求代数:新的 reveal(搜索返回后连点导航、或连点两条卡片项)会
  /// 作废仍在收敛的旧循环 —— 两个循环各自 jumpTo 会把视口在相邻消息之间
  /// 来回拉扯,表现为疯狂抖动。
  int _revealSeq = 0;

  /// 当前被选中、因而显示下方操作按钮的消息 id(null 表示都不显示)。
  /// 走 [ValueNotifier] 而非 setState 字段:切换选中时每个可见条目各自监听、
  /// 只在**本条**的选中态翻转时重建自己 —— 点选一条消息不再整列表 setState
  /// (所有可见气泡陪跑重建),与 chat_screen 的贴底标记/导航组同一思路。
  final ValueNotifier<int?> _selectedId = ValueNotifier<int?>(null);

  void _toggle(int id) {
    _selectedId.value = _selectedId.value == id ? null : id;
    widget.onActionsVisibleChanged?.call(_selectedId.value != null);
  }

  @override
  void didUpdateWidget(covariant MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进入多选时收起单条操作排:两种选择态互斥,否则按钮排会盖住列表底部。
    if (widget.selectionMode && !oldWidget.selectionMode) {
      _selectedId.value = null;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onActionsVisibleChanged?.call(false);
      });
    }
  }

  @override
  void dispose() {
    _selectedId.dispose();
    super.dispose();
  }

  /// 快捷爬楼:跳转到上一条(更旧)消息。
  ///
  /// 列表 `reverse: true` —— 滚动坐标从**内容底部**起算:`layoutOffset` 是条目
  /// 视觉**下边缘**到内容底部的距离,`bottom = layoutOffset + height` 是视觉
  /// **上边缘**;视口覆盖 `[pixels, pixels + viewport]`,即视口顶边在
  /// `pixels + viewport`。上一条 = 往更大偏移(视觉向上)走,并把目标条目的
  /// **顶边对齐视口顶边**(完整露出、并停在你正在看的那条的上方)。
  void scrollToPreviousMessage() {
    if (!widget.controller.hasClients) return;
    final pos = widget.controller.position;
    final currentOffset = pos.pixels;
    final viewFar = currentOffset + pos.viewportDimension;
    final items = _getRenderedItems();

    if (items.isEmpty) {
      _animateTo(currentOffset + 400);
      return;
    }

    // 1. 视口顶边落在某条目内部(离上下两端都 > 15px):把该条目顶边对齐视口顶边。
    for (final item in items) {
      if (item.bottom > viewFar + 15.0 && item.layoutOffset < viewFar - 15.0) {
        _animateTo(item.bottom - pos.viewportDimension);
        return;
      }
    }

    // 2. 否则取顶边高于视口顶边的**最近**条目(视口顶正好贴在某条目顶边时跳过它、
    //    取更旧的一条),同样把它的顶边对齐视口顶边。
    _RenderItemInfo? best;
    for (final item in items) {
      if (item.bottom > viewFar + 15.0) {
        if (best == null || item.layoutOffset < best.layoutOffset) best = item;
      }
    }
    if (best != null) {
      _animateTo(best.bottom - pos.viewportDimension);
      return;
    }

    // 3. 已到渲染窗口最早处:继续往顶部走(更早的条目由布局按需构建)。
    _animateTo(pos.maxScrollExtent);
  }

  /// 快捷爬楼:跳转到下一条(更新)消息。
  ///
  /// 下一条 = 往更小偏移(视觉向下)走,并把目标条目的**底边对齐视口底边**。
  /// 坐标口径见 [scrollToPreviousMessage]。
  void scrollToNextMessage() {
    if (!widget.controller.hasClients) return;
    final pos = widget.controller.position;
    final currentOffset = pos.pixels;
    final items = _getRenderedItems();

    if (items.isEmpty) {
      _animateTo(currentOffset - 400);
      return;
    }

    // 1. 视口底边落在某条目内部:把该条目底边对齐视口底边。
    for (final item in items) {
      if (item.layoutOffset < currentOffset - 15.0 &&
          item.bottom > currentOffset + 15.0) {
        _animateTo(item.layoutOffset);
        return;
      }
    }

    // 2. 否则取底边低于视口底边的**最近**条目(视口底正好贴在某条目底边时跳过它、
    //    取更新的一条),把它的底边对齐视口底边。
    _RenderItemInfo? best;
    for (final item in items) {
      if (item.layoutOffset < currentOffset - 15.0) {
        if (best == null || item.bottom > best.bottom) best = item;
      }
    }
    if (best != null) {
      _animateTo(best.layoutOffset);
      return;
    }

    // 3. 已到最新:回到底部(reverse 下恒为偏移 0)。
    _animateTo(0.0);
  }

  void _animateTo(double offset) {
    if (!widget.controller.hasClients) return;
    final pos = widget.controller.position;
    final target = offset.clamp(0.0, pos.maxScrollExtent);
    final distance = (pos.pixels - target).abs();
    if (distance < 1.0) return;
    // 减弱动态效果:爬楼直接落位,不播放长距离滚动动画。
    if (reduceMotionOf(context)) {
      widget.controller.jumpTo(target);
      return;
    }
    widget.controller.animateTo(
      target,
      duration: crawlAnimationDuration(distance, pos.viewportDimension),
      curve: Curves.easeOutCubic,
    );
  }

  List<_RenderItemInfo> _getRenderedItems() {
    final list = <_RenderItemInfo>[];
    final ro = context.findRenderObject();
    if (ro == null) return list;

    RenderSliverList? sliver;
    void findSliver(RenderObject node) {
      if (node is RenderSliverList) {
        sliver = node;
        return;
      }
      node.visitChildren(findSliver);
    }

    findSliver(ro);

    final targetSliver = sliver;
    if (targetSliver == null) return list;

    RenderBox? child = targetSliver.firstChild;
    while (child != null) {
      final parentData = child.parentData;
      if (parentData is SliverMultiBoxAdaptorParentData &&
          parentData.layoutOffset != null) {
        list.add(
          _RenderItemInfo(
            index: parentData.index ?? 0,
            layoutOffset: parentData.layoutOffset!,
            height: child.size.height,
          ),
        );
      }
      child = targetSliver.childAfter(child);
    }
    list.sort((a, b) => a.layoutOffset.compareTo(b.layoutOffset));
    return list;
  }

  /// 搜索/导航跳转的对齐边距:目标气泡顶边距视口顶部留一点呼吸空间。
  static const double _revealTopMargin = 12;

  /// 定位循环的帧预算。正常 2–3 轮即可落定,预算只兜底极端高度差。
  static const int _revealFrameBudget = 64;

  /// 目标未布局时每轮至少推进的视口比例。估算偏小时(例如窗口内全是短
  /// 文本、目标一侧全是图片)仍能单调逼近,不会在几十轮里只挪几条消息。
  static const double _revealMinStepScreens = 0.8;

  /// 目标未布局时连续「像素未变化」的轮数上限,超过即判定无法继续推进。
  static const int _revealStallLimit = 2;

  /// 条目间距先验(仅用于跨窗口外推;消息组间距远小于它,误差可忽略)。
  static const double _estimatedItemGap = 6;

  /// 主动等一个真实布局帧再继续定位。
  ///
  /// `jumpTo` 只改 `position.pixels`,条目要等下一帧由 sliver 重排。此刻若
  /// 没有别的脏对象,`endOfFrame` 可能迟迟不落 —— 旧循环于是读到**上一帧**
  /// 的几何,按同一份数据算出同样的落点反复跳,表现为疯狂抖动且永远到不了
  /// 目标。必须显式催帧。
  Future<void> _awaitLayoutFrame() async {
    WidgetsBinding.instance.scheduleForcedFrame();
    await WidgetsBinding.instance.endOfFrame;
  }

  /// 视口当前对应的 user 消息 id(桌面消息导航的高亮与展开定位口径)。
  ///
  /// 以视口内最上方/最下方的已布局条目确定可见时间段,先在其中找最靠上的
  /// user;视口里没有 user 时才向上找刚滚过的那条。纯滚动比例
  /// (`pixels / maxScrollExtent`)在条目高度差异大的会话里会指到相邻的
  /// 其它消息 —— 用户看到"已经跳到目标,卡片高亮的却是别人"。
  int? visibleUserMessageId() {
    if (!widget.controller.hasClients) return null;
    final visible = _visibleMessages;
    if (visible == null || visible.isEmpty) return null;
    final items = _getRenderedItems();
    if (items.isEmpty) return null;
    final pos = widget.controller.position;
    final viewFar = pos.pixels + pos.viewportDimension;
    final hasDraft = widget.draft.isNotEmpty || widget.streaming;
    final leading = hasDraft ? 1 : 0;
    final oldestRealIndex = leading + visible.length - 1;
    _RenderItemInfo? top;
    _RenderItemInfo? bottom;
    for (final item in items) {
      // 草稿与历史加载行是伪条目:它们没有时间序位置,进入视口时既不能
      // 把锚点判成 null(滚到接近顶部时高亮会卡在旧值),也不能参与换算。
      if (item.index < leading || item.index > oldestRealIndex) continue;
      // 只取与视口相交的条目:上边缘在视口顶之下,下边缘在视口底之上。
      if (item.layoutOffset >= viewFar - 1) continue;
      if (item.bottom <= pos.pixels + 1) continue;
      if (top == null || item.layoutOffset > top.layoutOffset) top = item;
      if (bottom == null || item.layoutOffset < bottom.layoutOffset) {
        bottom = item;
      }
    }
    if (top == null) return null;
    final topLogical = visible.length - 1 - (top.index - leading);
    if (topLogical < 0 || topLogical >= visible.length) return null;
    final bottomLogical = bottom == null
        ? topLogical
        : (visible.length - 1 - (bottom.index - leading)).clamp(
            0,
            visible.length - 1,
          );
    for (var logical = topLogical; logical <= bottomLogical; logical++) {
      final message = visible[logical];
      if (message.role == 'user' && message.id != null) return message.id;
    }
    for (var logical = topLogical - 1; logical >= 0; logical--) {
      final message = visible[logical];
      if (message.role == 'user' && message.id != null) return message.id;
    }
    return null;
  }

  /// 作废仍在飞的定位循环(回顶/回底等新的滚动意图接管视口)。
  ///
  /// 只递增代数、不碰滚动位置:在飞的 [_scrollToMessage] 下一轮检查代数后
  /// 自行退出,不再与新的滚动意图互相拉扯。
  void cancelReveal() {
    _revealSeq++;
  }

  /// 把指定消息滚动到视口内(聊天页搜索/桌面导航的跳转入口)。
  ///
  /// 目标可能刚经 `ChatController.revealMessage` 扩窗补入,先等列表重建到
  /// 可见投影里出现该 id;之后交给 [_scrollToMessage] 定位。返回是否成功。
  Future<bool> revealMessage(int messageId) async {
    final seq = ++_revealSeq;
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!mounted || seq != _revealSeq) return false;
      if (_visibleIndexById.containsKey(messageId)) break;
      await _awaitLayoutFrame();
    }
    if (!_visibleIndexById.containsKey(messageId)) return false;
    return _scrollToMessage(messageId, seq);
  }

  /// 定位到 [messageId] 对应的条目。
  ///
  /// 两段式设计:
  /// 1. **目标一旦参与布局**,按 `layoutOffset` 一次精确对顶,随即返回 ——
  ///    不再追图片解码/异步改高造成的几像素漂移,那是旧实现多帧微调、视口
  ///    在相邻条目间反复跳的直接来源。
  /// 2. **目标未布局**,按窗口外条目的**内容先验高度**累计出真实距离,朝目标
  ///    一侧单方向推进;每轮至少推进 [_revealMinStepScreens] 个视口。方向
  ///    由 `targetIndex` 与已布局窗口的上下界决定,绝不用估算值定方向 ——
  ///    估算反向时旧实现会与下一轮互相拉扯,表现为疯狂抖动且最终到不了。
  ///
  /// `jumpTo` 允许越过当前 `maxScrollExtent`:懒加载列表的该值只是估算,
  /// 落到边界后远端条目参与布局、上限随之增长,下一轮继续。旧实现在边界处
  /// 直接放弃,长会话里目标永远到不了。
  Future<bool> _scrollToMessage(int messageId, int seq) async {
    var stalled = 0;
    for (var attempt = 0; attempt < _revealFrameBudget; attempt++) {
      if (!mounted || seq != _revealSeq) return false;
      final logical = _visibleIndexById[messageId];
      final visible = _visibleMessages;
      if (logical == null || visible == null) return false;

      final hasDraft = widget.draft.isNotEmpty || widget.streaming;
      final leading = hasDraft ? 1 : 0;
      final oldestRealIndex = leading + visible.length - 1;
      final targetIndex = oldestRealIndex - logical;

      if (!widget.controller.hasClients) {
        await _awaitLayoutFrame();
        continue;
      }
      final pos = widget.controller.position;
      final items = _getRenderedItems();

      // 1) 目标已布局:一次精确落位,立即结束。
      _RenderItemInfo? target;
      for (final item in items) {
        if (item.index == targetIndex) {
          target = item;
          break;
        }
      }
      if (target != null) {
        // reverse 下标下 layoutOffset 是条目**底边**到内容底部的距离,
        // bottom = layoutOffset + height 是视觉**上边缘**;把上边缘对齐
        // 视口顶边:pixels = bottom - viewport。
        final desired =
            (target.bottom - pos.viewportDimension + _revealTopMargin).clamp(
              pos.minScrollExtent,
              pos.maxScrollExtent,
            );
        if ((pos.pixels - desired).abs() > 1.0) {
          pos.jumpTo(desired);
          // 落位帧:调用方随后要读可见锚点、断言目标已进入视口,必须等
          // 这一帧的布局真正完成,否则拿到的还是跳转前的渲染树。
          await _awaitLayoutFrame();
        }
        return true;
      }

      if (items.isEmpty) {
        // 还没有任何条目落地:先回到 offset 0(最新)让列表开始布局,
        // 而不是盲跳估算的顶部。
        pos.jumpTo(pos.pixels > 1.0 ? 0.0 : math.min(1.0, pos.maxScrollExtent));
        await _awaitLayoutFrame();
        continue;
      }

      // 2) 目标未布局:方向由下标边界决定,距离由内容先验估算。
      final sorted = [...items]..sort((a, b) => a.index.compareTo(b.index));
      final wantsOlder = targetIndex > sorted.last.index;
      final wantsNewer = targetIndex < sorted.first.index;
      if (!wantsOlder && !wantsNewer) return false;
      final anchor = wantsOlder ? sorted.last : sorted.first;
      final estimatedBottom = _estimateTargetBottom(
        visible: visible,
        leading: leading,
        anchor: anchor,
        targetIndex: targetIndex,
      );
      final estimatedPixels =
          estimatedBottom - pos.viewportDimension + _revealTopMargin;
      final minStep = pos.viewportDimension * _revealMinStepScreens;
      var desired = wantsOlder
          ? math.max(estimatedPixels, pos.pixels + minStep)
          : math.min(estimatedPixels, pos.pixels - minStep);
      // 不超过框架当前给出的内容上界:越过它会被 position 立即 clamp 回来,
      // 下一帧布局还可能回缩 maxScrollExtent,产生一次反向修正 —— 视口
      // 先冲过头再被拉回,就是用户看到的"抖一下"。到边界后下一轮等远端
      // 条目布局、上限增长再继续,单调推进不放弃。
      desired = desired.clamp(pos.minScrollExtent, pos.maxScrollExtent);

      final before = pos.pixels;
      pos.jumpTo(desired);
      await _awaitLayoutFrame();
      if (!mounted || seq != _revealSeq) return false;
      if ((pos.pixels - before).abs() < 1.0) {
        if (++stalled >= _revealStallLimit) return false;
        // 已顶在内容边界:等目标侧的新条目参与布局后再试一轮。
        await _awaitLayoutFrame();
      } else {
        stalled = 0;
      }
    }
    return false;
  }

  /// 估算 [targetIndex] 条目的视觉上边缘到内容底部的距离(bottom)。
  ///
  /// 从已布局窗口的端点 [anchor] 出发,逐条累计未布局条目的**内容先验高度**。
  /// 旧实现用最近两条的局部斜率外推:条目高度差异大(短文本 ~100px、图片
  /// 气泡最高 520px、长文可达数千 px)时斜率毫无代表性,估算可偏离真值一个
  /// 数量级 —— 这正是长会话定位抖动/到不了的根源。按内容逐条累计把误差
  /// 收敛到单条级别,再配合单方向推进,通常两三轮即可落到目标。
  double _estimateTargetBottom({
    required List<Message> visible,
    required int leading,
    required _RenderItemInfo anchor,
    required int targetIndex,
  }) {
    var edge = anchor.bottom;
    if (targetIndex > anchor.index) {
      var index = anchor.index;
      while (index < targetIndex) {
        final logical = leading + visible.length - 1 - index;
        final height = index == anchor.index
            ? anchor.height
            : (logical >= 0 && logical < visible.length)
            ? _estimatedEntryHeight(visible[logical])
            : 120.0;
        edge += height + _estimatedItemGap;
        index++;
      }
    } else {
      var index = anchor.index;
      while (index > targetIndex) {
        final logical = leading + visible.length - 1 - (index - 1);
        final height = (logical >= 0 && logical < visible.length)
            ? _estimatedEntryHeight(visible[logical])
            : 120.0;
        edge -= height + _estimatedItemGap;
        index--;
      }
    }
    return edge;
  }

  /// 单条消息在滚动方向上的高度先验(含头像行与气泡内边距)。
  ///
  /// 只服务于跨窗口外推,不需要像素级准确 —— 相错一两倍也会被下一轮的
  /// 「目标已布局 → 精确对顶」纠正,但必须体现文本长度与图片的巨大差异,
  /// 否则跨几十上百条的累计会完全失真。
  double _estimatedEntryHeight(Message message) {
    // 桌面阅读列约 880、中文正文 16px:每行约 34 字,行高 24。
    final lines = (message.content.runes.length / 34)
        .ceil()
        .clamp(1, 400)
        .toDouble();
    var height = 74.0 + lines * 24.0; // 头像行 + 气泡上下内边距
    if (message.hasVisualImage) height += 280; // 图片中位高度(上界 520)
    return height.clamp(96.0, 9600.0);
  }

  /// 流式草稿正文:常规长度走完整显示管线(宏替换 + 正则脚本 + 词条高亮 +
  /// 台词强调);超过 [kStreamingDraftPlainThreshold] 的超长草稿降级为纯文本
  /// (仅剥 system-reminder + 宏替换 —— 内部注入在任何渲染路径下都不得露出)。
  /// 降级只影响流式期间的草稿气泡,落库后的正式气泡仍走完整管线,样式在
  /// 流结束时一次性补齐。
  Widget _draftBody(BuildContext context) {
    final text = widget.draft.isEmpty ? '…' : widget.draft;
    // 草稿气泡与落库后的助手气泡共用角色级样式(字体/字号/文字色):
    // 漏掉该样式时,流式期间显示应用默认字体,流结束落库的瞬间才跳成
    // 角色设定的衬线字体。
    final scheme = Theme.of(context).colorScheme;
    final style = chatBubbleTextStyle(
      resolveAssistantTextColor(scheme, widget.assistantBubbleStyle),
      fontFamily: widget.assistantBubbleStyle?.fontFamily,
      fontSize: widget.assistantBubbleStyle?.fontSize,
    );
    if (text.length > kStreamingDraftPlainThreshold) {
      return Text.rich(
        TextSpan(
          text: expandDisplayMacros(
            stripSystemReminders(text),
            userName: widget.displayUserName,
            charName: widget.displayCharName,
          ),
          style: style,
        ),
      );
    }
    return RichMessageText(
      text: text,
      style: style,
      userName: widget.displayUserName,
      charName: widget.displayCharName,
      scripts: widget.regexScripts,
      glossary: widget.glossary,
      onTermTap: widget.onTermTap,
      highlightDialogue: widget.highlightDialogue,
      syntax: widget.syntax,
      surface: SyntaxSurface.assistantBubble,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 压缩摘要(role=system)是内部上下文,不在聊天流渲染;附件行
    // (kind=attachment,世界书/@技能的 <system-reminder> 注入)同样不渲染 ——
    // 它们是给模型的旁路资料,不是用户发言,上下文面板里可逐条查看。
    // 已压缩的原始消息(is_compacted=1)仍按聊天消息显示:用户回看历史必须
    // 看得到,即便它们已不再进 LLM 上下文,也不会被二次发出去。
    // 过滤结果按 messages 列表实例记忆化:流式草稿变化只换 draft 参数、
    // messages 实例不变,直接复用同一份结果,不每次 build 全量重扫(列表可达
    // 数百行);发送/落库时控制器整体替换 messages 实例,自然失效。
    if (!identical(_visibleSource, widget.messages)) {
      _visibleSource = widget.messages;
      final visibleMessages = widget.messages
          .where((m) => m.role != 'system' && m.isChat)
          .toList(growable: false);
      _visibleMessages = visibleMessages;
      _visibleIndexById = {
        for (var i = 0; i < visibleMessages.length; i++)
          if (visibleMessages[i].id != null) visibleMessages[i].id!: i,
      };
      // 选中消息被删除/重发改写、或切会话换了整份列表后,旧选中 id 可能已
      // 不存在:操作排随之消失,但通知态还挂着 true,导航组会一直隐形。这里
      // 同步清空(通知的是本列表的后代条目 —— build 期通知合法,后代尚未构建),
      // 但 `onActionsVisibleChanged` 的监听方是聊天页侧的导航组
      // ([MessageList.onActionsVisibleChanged] → _messageActionsOpen),它**不是**
      // 本列表的后代而是兄弟子树 —— build 期写值会让其 AnimatedBuilder 在
      // build 期 markNeedsBuild 而炸(真机必现),上报推迟到帧末。
      final selected = _selectedId.value;
      if (selected != null && !widget.messages.any((m) => m.id == selected)) {
        _selectedId.value = null;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onActionsVisibleChanged?.call(false);
        });
      }
    }
    final visible = _visibleMessages ?? const <Message>[];
    final hasDraft = widget.draft.isNotEmpty || widget.streaming;
    final hasHistoryLoader = widget.canLoadOlder || widget.loadingOlder;
    final leading = hasDraft ? 1 : 0;
    final total = visible.length + leading + (hasHistoryLoader ? 1 : 0);
    final windowWidth = MediaQuery.sizeOf(context).width;
    if (total == 0) {
      return _columnRow(
        windowWidth,
        child:
            widget.emptyState ??
            Center(
              child: Text(
                '发一条消息开始对话',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
      );
    }
    // reverse:true —— 下标 0 在**底部**(最新),下标增大向上(更旧),offset 0
    // 恒等于"贴底",与内容总高度彻底解耦。懒加载列表的 maxScrollExtent 只是
    // 「已布局窗口平均高度 × 剩余条数」的估算,而本列表条目高度差异极大
    // (短文本 ~100px vs 图片气泡最高 520px)且图片高度异步变化,估算可偏离
    // 真值数倍;正向列表按它贴底会越过真实末尾落进空白区再被弹簧拖回
    // (长会话里「发送后先滚到远处又滚回来」)。反向后贴底退化为 jumpTo(0)
    // 一次精确落位,估算误差不再作用于此。
    // 渲染下标 index 与时间序下标 logical 的换算:`index == 0` 是草稿(有则)
    // 或最新消息;消息按时间倒序向上;最远端 `total - 1` 是历史分页提示行。
    return ListView.builder(
      controller: widget.controller,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      // 上滑看历史时自动收起软键盘:长会话浏览不再被键盘占掉半屏。
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: total,
      // 删除/重发等列表变动会让条目整体移位。sliver 对子项默认按**下标**
      // 匹配:幸存图片消息的旧 Element 会对上新下标处的另一条消息,key 不匹配
      // 即销毁重建 —— 图片控件 State 被清空、已解码帧丢失,表现为"删第一张图,
      // 第二张图转圈重新加载,点开大图却是好的"。给每个条目稳定 key + 本回调
      // 后,框架会按 key 把旧 Element 搬到新下标(而非销毁重建),解码帧缓存
      // 原地保留。注意:**只有 key 没有本回调时 sliver 仍按下标匹配**(与
      // Column/Row 的 key 语义不同),二者缺一不可。
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final value = key.value;
        if (value == 'draft-bubble') {
          // 草稿伪条目恒为最新 → reverse 下占下标 0(存在时)。
          return hasDraft ? 0 : null;
        }
        if (value == 'history-loader') {
          return hasHistoryLoader ? total - 1 : null;
        }
        final id = value.startsWith('msg-')
            ? int.tryParse(value.substring(4))
            : null;
        if (id == null) return null;
        final logical = _visibleIndexById[id];
        if (logical == null) return null;
        return leading + visible.length - 1 - logical;
      },
      itemBuilder: (context, index) {
        // 最远端(视觉顶部)是分页提示/加载行。
        if (hasHistoryLoader && index == total - 1) {
          return _columnRow(
            windowWidth,
            key: const ValueKey('history-loader'),
            child: _HistoryLoadRow(loading: widget.loadingOlder),
          );
        }
        final logical = visible.length - 1 - (index - leading);
        if (logical >= 0 && logical < visible.length) {
          final m = visible[logical];
          // 连续同角色消息归为一组:组内收紧间距,只有组内末条带尾巴圆角,
          // 中间消息四角全圆,视觉上合并成一串。分组按**时间序**判定
          // (prev = 更旧、next = 更新),与渲染方向无关。
          final prev = logical > 0 ? visible[logical - 1] : null;
          final next = logical + 1 < visible.length
              ? visible[logical + 1]
              : null;
          // 稳定 key(消息 id):配合上面的 findChildIndexCallback 完成按下标
          // 平移时的 Element 搬迁(见该处注释)。
          return _columnRow(
            windowWidth,
            key: ValueKey('msg-${m.id ?? 'idx-$logical'}'),
            child: _MessageItem(
              message: m,
              selectedId: _selectedId,
              selectionMode: widget.selectionMode,
              selection: widget.selection,
              userAvatarImage: widget.userAvatarImage,
              assistantAvatarImage: widget.assistantAvatarImage,
              onAvatarTap: widget.selectionMode
                  ? null
                  : m.role == 'user'
                  ? widget.onUserAvatarTap
                  : widget.onAssistantAvatarTap,
              displayUserName: widget.displayUserName,
              displayCharName: widget.displayCharName,
              syntax: widget.syntax,
              regexScripts: widget.regexScripts,
              glossary: widget.glossary,
              onTermTap: widget.onTermTap,
              highlightDialogue: widget.highlightDialogue,
              assistantBubbleStyle: widget.assistantBubbleStyle,
              onImageDelete: widget.onImageDelete,
              regenerating: widget.regeneratingImageId == m.id,
              highlighted: widget.highlightedMessageId == m.id,
              groupStart: prev == null || prev.role != m.role,
              groupEnd: next == null || next.role != m.role,
              onTap: m.id == null
                  ? null
                  : widget.selectionMode
                  ? (widget.onSelectionToggle == null
                        ? null
                        : () => widget.onSelectionToggle!(m.id!))
                  : () => _toggle(m.id!),
              onLongPress:
                  widget.selectionMode || widget.onMessageLongPress == null
                  ? null
                  : () => widget.onMessageLongPress!(m),
              onAction: widget.onMessageAction == null
                  ? null
                  : (a) => widget.onMessageAction!(m, a),
            ),
          );
        }
        // 流式草稿:助手方向的输入气泡 —— 与持久化助手气泡共用 ChatBubbleFrame
        // 外壳(同底色/同圆角/同发丝边),仅内容区换成草稿文本或打字指示器。
        // 超长草稿走纯文本降级(见 _draftBody)。
        final lastVisible = visible.isEmpty ? null : visible.last;
        final draftIsUser = lastVisible?.role == 'user';
        // 草稿伪条目同样给稳定 key:上方消息被删除时不因位置平移被重建,
        // 打字指示器动画不重头播。
        return _columnRow(
          windowWidth,
          key: const ValueKey('draft-bubble'),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 12, 0),
                  child: Semantics(
                    button: widget.onAssistantAvatarTap != null,
                    label: widget.onAssistantAvatarTap == null
                        ? null
                        : '查看角色资料',
                    child: GestureDetector(
                      onTap: widget.onAssistantAvatarTap,
                      child: CircleAvatar(
                        radius: kMessageAvatarRadius,
                        // foregroundImage 失败时下方 child 占位自然露出,
                        // 坏图不会再留一个空白圆。
                        foregroundImage: widget.assistantAvatarImage,
                        onForegroundImageError:
                            widget.assistantAvatarImage == null
                            ? null
                            : (_, __) {},
                        child: const Icon(Icons.person_outline, size: 20),
                      ),
                    ),
                  ),
                ),
                ChatBubbleFrame(
                  isUser: false,
                  // 草稿紧跟用户消息 → 是新的一组;跟在助手消息后 → 并入该组。
                  groupStart: draftIsUser || lastVisible == null,
                  groupEnd: true,
                  style: widget.assistantBubbleStyle,
                  // 草稿气泡复用助手气泡的宽度上限(与输入卡同宽/移动满宽)。
                  constraints: BoxConstraints(
                    maxWidth: assistantBubbleMaxWidth(context),
                  ),
                  child: widget.draft.isEmpty && widget.streaming
                      ? const _TypingDots(key: ValueKey('typing-dots'))
                      : _draftBody(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 宽窗行收敛:消息列表本身铺满可用宽(桌面滚动条因此贴在窗口最右缘),
/// 每行内容再收敛到居中的会话列 —— 与输入卡同列。
///
/// 行内容必须经 `SizedBox(width: double.infinity)` 强制铺满列宽:列内
/// Column 按最宽子项收缩时,右对齐的用户气泡会失去列右缘的对齐基准。
///
/// [key] 必须落在这层包装上:sliver 的直接子项才是 `findChildIndexCallback`
/// 的匹配对象,key 埋在行内容里会退回按下标匹配(删消息后幸存图片条目被
/// 销毁重建、已解码帧丢失)。
///
/// 根 widget 类型在所有宽度下保持一致:Flutter 匹配 Element 时同时要求
/// runtimeType 与 key,窄窗返回 KeyedSubtree、宽窗返回 Align 会让窗口跨过
/// 宽窗断点时即使 key 相同也销毁整条消息子树(图片 State/解码帧一起丢,
/// 拖拽宽度表现为闪灰)。窄窗把列宽退化为 infinity,视觉上仍是满宽。
Widget _columnRow(double windowWidth, {Key? key, required Widget child}) {
  final columnWidth = chatColumnMaxWidth(windowWidth);
  return Align(
    key: key,
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: columnWidth),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}

/// 头像半径(气泡上方的小头像)。
const double kMessageAvatarRadius = 18;

/// 流式草稿的纯文本降级阈值(字符)。富文本解析(主正则扫描/词典匹配/
/// span 树构建)成本随草稿长度线性涨,而流式期间每个节流块(40ms)都会
/// 对草稿全文重跑一遍 —— 几万字级回复的尾段会吃满帧预算。超过 8192 字符
/// (约 4000+ 汉字,远超常规单条回复)的草稿降级为纯文本渲染(仅剥
/// system-reminder + 宏替换),流结束落库后的正式气泡仍走完整管线,样式
/// 在流结束时一次性补齐。常规长度完全不受影响,样式无损。
const int kStreamingDraftPlainThreshold = 8192;

/// 爬楼跳转(上一条/下一条消息)的动画时长:按距离占视口倍数缩放 ——
/// 短跳干脆利落,跨超长消息的长跳不至于在固定 200ms 里一闪而过。
/// 4 个视口内线性放大,下限 120ms 保底可感知,上限 400ms 防拖沓;
/// 零/负距离零时长(调用方本就有 <1px 的提前返回,此处兜底)。
Duration crawlAnimationDuration(double distance, double viewport) {
  if (distance <= 0) return Duration.zero;
  final scale = viewport <= 0
      ? 1.0
      : (distance / (viewport * 4)).clamp(0.0, 1.0);
  return Duration(milliseconds: (120 + 280 * scale).round());
}

/// 一条消息:头像(气泡上方)+ 气泡 + 选中时下方显示的操作按钮。
/// StatefulWidget:共享的选中 notifier([MessageListState._selectedId])每次
/// 切换都通知所有可见条目,各自比对后只有选中态翻转的那条 setState 重建,
/// 其余条目直接忽略 —— 点选消息不再整列表重建。
class _MessageItem extends StatefulWidget {
  final Message message;

  /// 全列表共享的选中消息 id notifier(null = 无选中)。
  final ValueListenable<int?> selectedId;

  /// 多选模式:选中态改由 [selection] 集合驱动,不渲染单条操作排。
  final bool selectionMode;
  final ValueListenable<Set<int>>? selection;

  /// 组内首条(上方无同角色消息):顶部间距加大,形成组间留白。
  final bool groupStart;

  /// 组内末条(下方无同角色消息):底部尾巴圆角。
  final bool groupEnd;

  final ImageProvider? userAvatarImage;
  final ImageProvider? assistantAvatarImage;

  /// 点击本条气泡旁头像(用户/角色)的回调;null = 头像不响应点击。
  final VoidCallback? onAvatarTap;

  final String? displayUserName;
  final String? displayCharName;
  final CompiledSyntax? syntax;
  final List<CompiledRegexScript>? regexScripts;
  final CompiledGlossary? glossary;
  final void Function(GlossaryTerm term)? onTermTap;
  final bool highlightDialogue;
  final BubbleStyle? assistantBubbleStyle;
  final Future<void> Function(int messageId)? onImageDelete;
  final bool regenerating;

  final bool highlighted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(MessageAction action)? onAction;

  const _MessageItem({
    required this.message,
    required this.selectedId,
    required this.groupStart,
    required this.groupEnd,
    this.selectionMode = false,
    this.selection,
    this.userAvatarImage,
    this.assistantAvatarImage,
    this.onAvatarTap,
    this.displayUserName,
    this.displayCharName,
    this.syntax,
    this.regexScripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
    this.assistantBubbleStyle,
    this.onImageDelete,
    this.regenerating = false,
    this.highlighted = false,
    this.onTap,
    this.onLongPress,
    this.onAction,
  });

  @override
  State<_MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<_MessageItem> {
  /// 本条当前是否选中。必须是**缓存值**:notifier 通知到达时值已是新的,
  /// 现场重读会与"新值"恒等、永远等不出翻转。
  late bool _selected = _computeSelected();

  bool _computeSelected() {
    final id = widget.message.id;
    if (id == null) return false;
    if (widget.selectionMode) {
      return widget.selection?.value.contains(id) ?? false;
    }
    return widget.selectedId.value == id;
  }

  @override
  void initState() {
    super.initState();
    widget.selectedId.addListener(_handleSelectionChanged);
    widget.selection?.addListener(_handleSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant _MessageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selectedId, widget.selectedId)) {
      oldWidget.selectedId.removeListener(_handleSelectionChanged);
      widget.selectedId.addListener(_handleSelectionChanged);
    }
    if (!identical(oldWidget.selection, widget.selection)) {
      oldWidget.selection?.removeListener(_handleSelectionChanged);
      widget.selection?.addListener(_handleSelectionChanged);
    }
    _selected = _computeSelected();
  }

  @override
  void dispose() {
    widget.selectedId.removeListener(_handleSelectionChanged);
    widget.selection?.removeListener(_handleSelectionChanged);
    super.dispose();
  }

  void _handleSelectionChanged() {
    final nowSelected = _computeSelected();
    if (nowSelected != _selected) {
      setState(() => _selected = nowSelected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isUser = message.role == 'user';
    final bubble = MessageBubble(
      message: message,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      selectionMode: widget.selectionMode,
      displayUserName: widget.displayUserName,
      displayCharName: widget.displayCharName,
      syntax: widget.syntax,
      regexScripts: widget.regexScripts,
      glossary: widget.glossary,
      onTermTap: widget.onTermTap,
      highlightDialogue: widget.highlightDialogue,
      style: widget.assistantBubbleStyle,
      onImageDelete: widget.onImageDelete,
      regenerating: widget.regenerating,
      groupStart: widget.groupStart,
      groupEnd: widget.groupEnd,
      selected: _selected,
      highlighted: widget.highlighted,
    );
    // 头像在气泡上方:用户右对齐、角色左对齐,均与气泡同侧;头像不占气泡
    // 横向宽度。两侧始终显示头像,未设置时用占位图标,点击仍可打开状态卡。
    final avatarImage = isUser
        ? widget.userAvatarImage
        : widget.assistantAvatarImage;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Padding(
          // 用户侧右缘留 20,助手侧左缘对称留 20,与气泡边距对齐。
          padding: EdgeInsets.fromLTRB(
            isUser ? 12 : 20,
            2,
            isUser ? 20 : 12,
            0,
          ),
          child: Semantics(
            button: widget.onAvatarTap != null,
            label: widget.onAvatarTap == null
                ? null
                : (isUser ? '查看用户资料' : '查看角色资料'),
            child: GestureDetector(
              onTap: widget.onAvatarTap,
              child: CircleAvatar(
                radius: kMessageAvatarRadius,
                foregroundImage: avatarImage,
                onForegroundImageError: avatarImage == null ? null : (_, __) {},
                child: Icon(
                  isUser ? Icons.person : Icons.person_outline,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
        bubble,
        if (!widget.selectionMode && _selected && widget.onAction != null)
          _MessageActionsRow(
            message: message,
            onAction: widget.onAction!,
            // 长按/右键菜单的显式入口:选中后的操作排里给一颗「更多」,
            // 不必先发现长按手势。
            onMore: widget.onLongPress,
          ),
      ],
    );
  }
}

/// 气泡下方的快捷操作排。
///
/// 文本气泡只保留复制/编辑/多选,图片气泡只保留下载/多选;删除、重发、
/// 按要求重写与重新生成等完整动作收进三点菜单和长按菜单,避免操作排过长。
class _MessageActionsRow extends StatelessWidget {
  final Message message;
  final void Function(MessageAction action) onAction;

  /// 打开完整操作菜单(长按/右键的同一入口);null 时不渲染。
  final VoidCallback? onMore;
  const _MessageActionsRow({
    required this.message,
    required this.onAction,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final hasText = message.content.trim().isNotEmpty;
    final hasImage = message.hasVisualImage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: ConstrainedBox(
        constraints: isUser
            ? BoxConstraints(maxWidth: userBubbleMaxWidth(context))
            : const BoxConstraints(),
        child: Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasImage)
                _action(
                  context,
                  Icons.download_outlined,
                  '下载图片',
                  MessageAction.download,
                )
              else if (hasText) ...[
                _action(context, Icons.copy_outlined, '复制', MessageAction.copy),
                _action(context, Icons.edit_outlined, '编辑', MessageAction.edit),
              ],
              _action(
                context,
                Icons.checklist_outlined,
                '多选消息',
                MessageAction.select,
              ),
              if (onMore != null)
                IconButton(
                  tooltip: '更多操作',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: onMore,
                  icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String tooltip,
    MessageAction action,
  ) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      onPressed: () => onAction(action),
      icon: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// 列表最远端(视觉顶部)的历史分页提示行:加载中转圈,空闲时提示上滑。
class _HistoryLoadRow extends StatelessWidget {
  final bool loading;
  const _HistoryLoadRow({required this.loading});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: loading
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const InlineSpinner(size: 15),
                  const SizedBox(width: 8),
                  Text(
                    '正在加载更早消息…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            : Text(
                '上滑加载更早消息',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
      ),
    );
  }
}

/// 流式草稿的"正在输入"指示器:三个小圆点错峰呼吸,替代静止的『…』。
/// 只出现在草稿为空且流式进行中;widget 在流结束后即被移除,动画随之停止。
class _TypingDots extends StatefulWidget {
  const _TypingDots({super.key});

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = reduceMotionOf(context);
    if (_reduceMotion) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    if (_reduceMotion) {
      // 呼吸动画停住,仍用三点表示「正在输入」,不闪动。
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            Opacity(
              opacity: 0.7,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          ],
        ],
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              _dot(i, color),
            ],
          ],
        );
      },
    );
  }

  /// 相位错开约 1/3 周期:三个点依次淡入淡出,像打字呼吸。
  Widget _dot(int index, Color color) {
    final t = (_controller.value + index / 3) % 1.0;
    final opacity = 0.25 + 0.75 * (1 - (t * 2 - 1).abs());
    final scale = 0.6 + 0.4 * (1 - (t * 2 - 1).abs());
    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
