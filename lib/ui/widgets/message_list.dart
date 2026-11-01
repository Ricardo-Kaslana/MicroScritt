import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import '../../engine/display_regex.dart';
import '../../engine/glossary.dart';
import '../../models/bubble_style.dart';
import '../../models/message.dart';
import 'message_bubble.dart';
import 'rich_message_text.dart';

/// 消息气泡的操作入口定义:复制 / 编辑 / 删除 / 重新生成(仅助手)/
/// 重新发送(仅用户,把该条输入原样重发一遍)/ 重新生成图片(带原始描述的图片)。
enum MessageAction { copy, edit, delete, regenerate, resend, regenerateImage }

class MessageList extends StatefulWidget {
  final List<Message> messages;
  final String draft;
  final bool streaming;
  final ScrollController controller;

  /// 更早历史是否还有下一页(控制列表远端的分页提示行)。
  final bool canLoadOlder;

  /// 当前是否正在读取更早的一页(提示行显示转圈)。
  final bool loadingOlder;

  /// 长按/右键某条消息时回调(旧入口,弹菜单)。
  final void Function(Message message)? onMessageLongPress;

  /// 气泡下方操作按钮触发的回调。
  final void Function(Message message, MessageAction action)? onMessageAction;

  /// 任一气泡被选中、操作按钮排显隐变化的回调(true 选中/false 取消)。
  /// 聊天页据此让右下角滚动导航组让位 —— 选中最后一条消息时操作排贴在
  /// 列表最底端,导航组叠上来会挡住最右的重新发送/重新生成。
  final ValueChanged<bool>? onActionsVisibleChanged;

  /// 用户头像图片 provider(由 chat_screen 缓存后注入,同一实例全列表共用),
  /// 显示在用户气泡旁;为空时回退占位图标。共用同一实例可避免流式回复期间
  /// 整页重建时每条用户消息各自 new MemoryImage 被反复解码而频闪。
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

  /// 已启用技能名集合:用户气泡内 `@技能名` 记号高亮(与输入框共用同一集合)。
  final Set<String>? skillNames;

  /// 聊天页预编译好的技能记号正则(见 [MessageBubble.skillTokenPattern])。
  final RegExp? skillTokenPattern;

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

  /// 按消息 id 惰性读取 image_base64(轻量查询后图片不随列表加载)。
  final Future<String?> Function(int messageId)? imageLoader;

  /// 删除某条消息中的图片(全屏查看器"删除图片"按钮);null = 图片不可删。
  final Future<void> Function(int messageId)? onImageDelete;

  /// 正在重新生成图片的消息 id(null = 空闲):该气泡图片叠转圈遮罩,
  /// 操作行的图片重生成按钮禁用。
  final int? regeneratingImageId;

  /// 各消息图片内容的本地修订号(原地替换后递增,气泡据此重新读库)。
  final Map<int, int> imageRevisions;

  /// 搜索命中的消息 id:对应气泡叠一圈强调描边与外发光,短暂提示定位结果。
  final int? highlightedMessageId;

  const MessageList({
    super.key,
    required this.messages,
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
    this.skillNames,
    this.skillTokenPattern,
    this.regexScripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
    this.assistantBubbleStyle,
    this.imageLoader,
    this.onImageDelete,
    this.regeneratingImageId,
    this.imageRevisions = const {},
    this.highlightedMessageId,
  });

  @override
  State<MessageList> createState() => MessageListState();
}

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

class MessageListState extends State<MessageList> {
  /// 显示口径过滤结果的记忆化(见 build 内注释):[_visibleSource] 记录上次
  /// 过滤的源列表实例,实例不变(仅 draft/streaming 等参数变化)时直接复用
  /// [_visibleMessages]。
  List<Message>? _visibleSource;
  List<Message>? _visibleMessages;

  /// 可见消息 id → 时间序下标(与 [_visibleMessages] 同批重建),供
  /// `findChildIndexCallback` O(1) 定位;旧实现的 indexWhere 在长会话里
  /// 每次重建都要扫一遍列表。
  Map<int, int> _visibleIndexById = const {};

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

  /// 搜索跳转的定位边距:目标气泡顶边距视口顶部留一点呼吸空间。
  static const double _revealTopMargin = 12;

  /// 把指定消息滚动到视口内(聊天页搜索命中后的跳转)。
  ///
  /// 目标可能刚经 [ChatController.revealMessage] 扩窗补入,先等列表重建到
  /// 可见投影里出现该 id;随后按**反向列表下标**定位 —— `reverse: true` 下
  /// 条目 offset 从内容底部起算,目标不在已布局窗口时用已布局条目的
  /// index→offset 局部斜率估算落点,跳到附近后再由真实布局校正,最多多帧
  /// 收敛。返回是否成功滚到目标。
  Future<bool> revealMessage(int messageId) async {
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!mounted) return false;
      if (_visibleIndexById.containsKey(messageId)) break;
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!_visibleIndexById.containsKey(messageId)) return false;
    return _scrollToMessage(messageId);
  }

  /// 多帧收敛到 [messageId] 对应的条目。
  ///
  /// 每轮按当前可见投影重算反向下标(流式/分页可能在收敛途中改动列表),
  /// 再按「已布局就精确对齐、未布局就局部斜率估算」推进。本列表条目高度差异
  /// 极大(短文本 ~100px vs 图片气泡最高 520px),懒加载下 `maxScrollExtent`
  /// 只是估算,无法一次算出精确位置;跳到估算落点后目标附近随即参与布局,
  /// 下一轮即可按真实 `layoutOffset` 对齐其顶边。
  Future<bool> _scrollToMessage(int messageId) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      if (!mounted) return false;
      final logical = _visibleIndexById[messageId];
      final visible = _visibleMessages;
      if (logical == null || visible == null) return false;
      final hasDraft = widget.draft.isNotEmpty || widget.streaming;
      final leading = hasDraft ? 1 : 0;
      final total =
          visible.length +
          leading +
          ((widget.canLoadOlder || widget.loadingOlder) ? 1 : 0);
      final targetIndex = leading + visible.length - 1 - logical;
      if (!widget.controller.hasClients) {
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      final pos = widget.controller.position;
      final items = _getRenderedItems();
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
        // 视口顶边: pixels = bottom - viewport。
        final desired =
            (target.bottom - pos.viewportDimension + _revealTopMargin).clamp(
              0.0,
              pos.maxScrollExtent,
            );
        if ((pos.pixels - desired).abs() <= 1.0) return true;
        pos.jumpTo(desired);
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      final estimate = _estimateOffset(
        items,
        targetIndex,
        total,
        pos.maxScrollExtent,
      );
      final clamped = estimate.clamp(0.0, pos.maxScrollExtent);
      if ((pos.pixels - clamped).abs() <= 1.0) {
        // 估算饱和在当前 maxScrollExtent 而目标仍未布局:若目标接近列表
        // 顶端,先跳到估算顶部让远端条目参与布局、修正 max 后再试;否则
        // 说明索引/窗口已经错位,放弃(UI 仍可用,只是没有自动定位)。
        if (pos.pixels < pos.maxScrollExtent - 1) {
          pos.jumpTo(pos.maxScrollExtent);
        } else {
          return false;
        }
      } else {
        pos.jumpTo(clamped);
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }

  double _estimateOffset(
    List<_RenderItemInfo> items,
    int targetIndex,
    int total,
    double maxScrollExtent,
  ) {
    if (items.isEmpty) return maxScrollExtent;
    final sorted = [...items]..sort((a, b) => a.index.compareTo(b.index));
    // 距离目标最近的两条(不限同侧)拟合局部斜率:index 越大 offset 越大。
    final nearest = [...sorted]
      ..sort(
        (a, b) => (a.index - targetIndex).abs().compareTo(
          (b.index - targetIndex).abs(),
        ),
      );
    final anchor = nearest.first;
    final other = nearest.length > 1 ? nearest[1] : null;
    var slope = 0.0;
    if (other != null && other.index != anchor.index) {
      slope =
          (anchor.layoutOffset - other.layoutOffset) /
          (anchor.index - other.index);
    }
    if (!slope.isFinite || slope <= 0) {
      // 退化(只有一个已布局条目等):退回整表平均高度。
      slope = total > 1 ? maxScrollExtent / (total - 1) : 120.0;
    }
    if (!slope.isFinite || slope <= 0) slope = 120.0;
    return anchor.layoutOffset + (targetIndex - anchor.index) * slope;
  }

  /// 流式草稿正文:常规长度走完整显示管线(宏替换 + 正则脚本 + 词条高亮 +
  /// 台词强调);超过 [kStreamingDraftPlainThreshold] 的超长草稿降级为纯文本
  /// (仅剥 system-reminder + 宏替换 —— 内部注入在任何渲染路径下都不得露出)。
  /// 降级只影响流式期间的草稿气泡,落库后的正式气泡仍走完整管线,样式在
  /// 流结束时一次性补齐。
  Widget _draftBody(BuildContext context) {
    final text = widget.draft.isEmpty ? '…' : widget.draft;
    final style = chatBubbleTextStyle(Theme.of(context).colorScheme.onSurface);
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
    );
  }

  @override
  Widget build(BuildContext context) {
    // Compaction summaries (role=system) are internal context, not chat
    // bubbles — hide them from the view. Attachment rows (kind=attachment,
    // CW 批的世界书/@技能 <system-reminder> 注入)同样不在气泡中渲染 ——
    // 它们是给模型的旁路资料,不是用户发言;上下文面板里可逐条查看。
    // Compacted originals (is_compacted=1) 仍按聊天消息渲染:用户想看历史就
    // 必须看到这些,即便它们已不再进 LLM 上下文(ContextAssembler 的过滤口径
    // 未改,见 context_assembler.dart),也不会被二次发出去。
    // 过滤结果按 messages 列表实例记忆化(EF 批):流式草稿变化只换 draft
    // 参数、messages 实例不变,同一份过滤结果直接复用,不再每次 build 全量
    // 重扫(列表可达数百行);发送/落库时控制器整体替换 messages 实例,自然失效。
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
      // build 期 markNeedsBuild 而炸(EL 批真机必现),上报推迟到帧末。
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
    if (total == 0) {
      return Center(
        child: Text(
          '发一条消息开始对话',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }
    // reverse:true —— 下标 0 在**底部**(最新),下标增大向上(更旧)。
    // 这样 offset 0 恒等于"贴底",与内容总高度彻底解耦:懒加载列表的
    // maxScrollExtent 是「已布局窗口平均高度 × 剩余条数」的估算,本列表条目
    // 高度差异极大(短文本 ~100px vs 图片气泡最高 520px)且图片高度异步变化,
    // 估算可偏离真值数倍 —— 此前贴底跟随要跳到那个估算值,落点越过真实末尾
    // 落进空白死区再被弹簧拖回,即长会话里「发送消息后先快速滚到远处又滚回来」。
    // 反向后贴底退化为 jumpTo(0) 一次精确落位,估算误差不再作用于此。
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
          return _HistoryLoadRow(
            key: const ValueKey('history-loader'),
            loading: widget.loadingOlder,
          );
        }
        final logical = visible.length - 1 - (index - leading);
        if (logical >= 0 && logical < visible.length) {
          final m = visible[logical];
          // 连续同角色消息归为一组:iMessage 式气泡串 —— 组内收紧间距、
          // 只有组内末条带尾巴圆角。中间消息四角全圆,视觉上合并成一条。
          // 分组按**时间序**(prev = 更旧、next = 更新)判定,与渲染方向无关。
          final prev = logical > 0 ? visible[logical - 1] : null;
          final next = logical + 1 < visible.length
              ? visible[logical + 1]
              : null;
          // 稳定 key(消息 id):配合上面的 findChildIndexCallback 完成按下标
          // 平移时的 Element 搬迁(见该处注释)。
          return _MessageItem(
            key: ValueKey('msg-${m.id ?? 'idx-$logical'}'),
            message: m,
            selectedId: _selectedId,
            userAvatarImage: widget.userAvatarImage,
            assistantAvatarImage: widget.assistantAvatarImage,
            onAvatarTap: m.role == 'user'
                ? widget.onUserAvatarTap
                : widget.onAssistantAvatarTap,
            displayUserName: widget.displayUserName,
            displayCharName: widget.displayCharName,
            skillNames: widget.skillNames,
            skillTokenPattern: widget.skillTokenPattern,
            regexScripts: widget.regexScripts,
            glossary: widget.glossary,
            onTermTap: widget.onTermTap,
            highlightDialogue: widget.highlightDialogue,
            assistantBubbleStyle: widget.assistantBubbleStyle,
            imageLoader: widget.imageLoader,
            onImageDelete: widget.onImageDelete,
            regenerating: widget.regeneratingImageId == m.id,
            imageRevision: widget.imageRevisions[m.id] ?? 0,
            highlighted: widget.highlightedMessageId == m.id,
            groupStart: prev == null || prev.role != m.role,
            groupEnd: next == null || next.role != m.role,
            onTap: m.id == null ? null : () => _toggle(m.id!),
            onLongPress: widget.onMessageLongPress == null
                ? null
                : () => widget.onMessageLongPress!(m),
            onAction: widget.onMessageAction == null
                ? null
                : (a) => widget.onMessageAction!(m, a),
          );
        }
        // 流式草稿:助手方向的输入气泡 —— 与持久化助手气泡共用 ChatBubbleFrame
        // 外壳(同底色/同圆角/同发丝边),仅内容区换成草稿文本或打字指示器。
        // 超长草稿走纯文本降级(见 _draftBody)。
        final lastVisible = visible.isEmpty ? null : visible.last;
        final draftIsUser = lastVisible?.role == 'user';
        // 草稿伪条目同样给稳定 key:上方消息被删除时不因位置平移被重建,
        // 打字指示器动画不重头播。
        return Align(
          key: const ValueKey('draft-bubble'),
          alignment: Alignment.centerLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 12, 0),
                child: GestureDetector(
                  onTap: widget.onAssistantAvatarTap,
                  child: widget.assistantAvatarImage != null
                      ? CircleAvatar(
                          radius: kMessageAvatarRadius,
                          backgroundImage: widget.assistantAvatarImage,
                          onBackgroundImageError: (_, __) {},
                        )
                      : CircleAvatar(
                          radius: kMessageAvatarRadius,
                          child: const Icon(Icons.person_outline, size: 20),
                        ),
                ),
              ),
              ChatBubbleFrame(
                isUser: false,
                // 草稿紧跟用户消息 → 是新的一组;跟在助手消息后 → 并入该组。
                groupStart: draftIsUser || lastVisible == null,
                groupEnd: true,
                style: widget.assistantBubbleStyle,
                // 草稿气泡复用助手气泡的宽度上限(桌面 760/移动满宽)。
                constraints: BoxConstraints(
                  maxWidth: assistantBubbleMaxWidth(context),
                ),
                child: widget.draft.isEmpty && widget.streaming
                    ? const _TypingDots(key: ValueKey('typing-dots'))
                    : _draftBody(context),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 头像半径(气泡上方小头像,与旧实现一致)。
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
  final Set<String>? skillNames;
  final RegExp? skillTokenPattern;
  final List<CompiledRegexScript>? regexScripts;
  final CompiledGlossary? glossary;
  final void Function(GlossaryTerm term)? onTermTap;
  final bool highlightDialogue;
  final BubbleStyle? assistantBubbleStyle;
  final Future<String?> Function(int messageId)? imageLoader;
  final Future<void> Function(int messageId)? onImageDelete;
  final bool regenerating;
  final int imageRevision;
  final bool highlighted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(MessageAction action)? onAction;

  const _MessageItem({
    super.key,
    required this.message,
    required this.selectedId,
    required this.groupStart,
    required this.groupEnd,
    this.userAvatarImage,
    this.assistantAvatarImage,
    this.onAvatarTap,
    this.displayUserName,
    this.displayCharName,
    this.skillNames,
    this.skillTokenPattern,
    this.regexScripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
    this.assistantBubbleStyle,
    this.imageLoader,
    this.onImageDelete,
    this.regenerating = false,
    this.imageRevision = 0,
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
    return id != null && widget.selectedId.value == id;
  }

  @override
  void initState() {
    super.initState();
    widget.selectedId.addListener(_handleSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant _MessageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.selectedId, widget.selectedId)) {
      oldWidget.selectedId.removeListener(_handleSelectionChanged);
      widget.selectedId.addListener(_handleSelectionChanged);
    }
    _selected = _computeSelected();
  }

  @override
  void dispose() {
    widget.selectedId.removeListener(_handleSelectionChanged);
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
      displayUserName: widget.displayUserName,
      displayCharName: widget.displayCharName,
      skillNames: widget.skillNames,
      skillTokenPattern: widget.skillTokenPattern,
      regexScripts: widget.regexScripts,
      glossary: widget.glossary,
      onTermTap: widget.onTermTap,
      highlightDialogue: widget.highlightDialogue,
      style: widget.assistantBubbleStyle,
      imageLoader: widget.imageLoader,
      onImageDelete: widget.onImageDelete,
      regenerating: widget.regenerating,
      imageRevision: widget.imageRevision,
      groupStart: widget.groupStart,
      groupEnd: widget.groupEnd,
      selected: _selected,
      highlighted: widget.highlighted,
    );
    // 头像在气泡上方:用户头像右对齐(与气泡同侧)、角色头像左对齐(与气泡
    // 同侧)。头像不占气泡横向宽度,气泡宽度上限与旧实现完全一致。
    // 两侧均始终显示头像:未设置头像时用占位图标,点击仍可打开对应状态卡。
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
          // 用户侧右对齐留 20 右缘(与旧实现一致),助手侧左对齐对称留 20 左缘。
          padding: EdgeInsets.fromLTRB(
            isUser ? 12 : 20,
            2,
            isUser ? 20 : 12,
            0,
          ),
          child: GestureDetector(
            onTap: widget.onAvatarTap,
            child: avatarImage != null
                ? CircleAvatar(
                    radius: kMessageAvatarRadius,
                    backgroundImage: avatarImage,
                    onBackgroundImageError: (_, __) {},
                  )
                : CircleAvatar(
                    radius: kMessageAvatarRadius,
                    child: Icon(
                      isUser ? Icons.person : Icons.person_outline,
                      size: 20,
                    ),
                  ),
          ),
        ),
        bubble,
        if (_selected && widget.onAction != null)
          _MessageActionsRow(
            message: message,
            regenerating: widget.regenerating,
            onAction: widget.onAction!,
          ),
      ],
    );
  }
}

/// 气泡下方的操作按钮排:复制 / 编辑(有正文时)/ 删除 + 文本重新生成或重新发送;
/// 带原始描述的图片另给「重新生成图片」。
class _MessageActionsRow extends StatelessWidget {
  final Message message;
  final bool regenerating;
  final void Function(MessageAction action) onAction;
  const _MessageActionsRow({
    required this.message,
    required this.regenerating,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final hasText = message.content.trim().isNotEmpty;
    final canRegenerateImage =
        !isUser &&
        message.hasVisualImage &&
        (message.imagePrompt?.trim().isNotEmpty ?? false);
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
              if (hasText)
                _action(context, Icons.copy_outlined, '复制', MessageAction.copy),
              if (hasText)
                _action(context, Icons.edit_outlined, '编辑', MessageAction.edit),
              _action(
                context,
                Icons.delete_outline,
                '删除',
                MessageAction.delete,
                danger: true,
              ),
              if (isUser && hasText)
                _action(
                  context,
                  Icons.send_outlined,
                  '重新发送',
                  MessageAction.resend,
                ),
              if (!isUser && hasText)
                _action(
                  context,
                  Icons.refresh,
                  '重新生成',
                  MessageAction.regenerate,
                ),
              if (canRegenerateImage)
                _action(
                  context,
                  Icons.autorenew,
                  '重新生成图片',
                  MessageAction.regenerateImage,
                  enabled: !regenerating,
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
    MessageAction action, {
    bool danger = false,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = !enabled
        ? scheme.outline
        : (danger ? scheme.error : scheme.onSurfaceVariant);
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      onPressed: enabled ? () => onAction(action) : null,
      icon: Icon(icon, color: color),
    );
  }
}

/// 列表最远端(视觉顶部)的历史分页提示行:加载中转圈,空闲时提示上滑。
class _HistoryLoadRow extends StatelessWidget {
  final bool loading;
  const _HistoryLoadRow({super.key, required this.loading});

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
                  const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
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
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
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
