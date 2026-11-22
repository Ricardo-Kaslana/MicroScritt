/// 聊天页滚动:贴底/贴顶邻域、贴顶分页、回顶逐页取旧与首尾消息导航。
///
/// 同库 part 扩展共享 ChatScreen 的私有滚动状态;滚动路径刻意不 setState。

part of '../chat_screen.dart';

extension _ChatScreenScrollOps on _ChatScreenState {
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
    // 桌面导航的高亮口径:直接取视口内真实可见的 user 消息。跳转落定后
    // 由 [_jumpToUserMessage] 再同步一次,确保高亮跟上的就是目标本身。
    // 布局尚未更新的一帧可能算不出锚点(null):保留上一份,避免滚动中
    // 高亮闪断;会话切换的复位由页面状态单独负责。
    //
    // 主动定位期间**不覆盖**:定位是逐帧 jumpTo,中间帧的可见锚点会一路
    // 扫过目标上方的其它 user 消息;若让监听写回,落定瞬间卡片高亮会指错。
    // 定位成功时调用方直接把锚点设为目标;两秒高亮期内继续锁定,结束后由
    // 计时器交还真实口径(用户此刻滚动也最多滞后两秒,不会指错)。
    if (_revealRunning || _highlightMessageId != null) return;
    final visibleId = _messageListKey.currentState?.visibleUserMessageId();
    if (visibleId != null) {
      _visibleUserMessageId.value = visibleId;
    } else {
      // 程序性跳转在布局更新前就发出了滚动通知:这一刻读到的还是上一帧
      // 条目几何,null 被当作"布局尚未跟上"而保留旧锚点;跳转结束后又
      // 不再有滚动事件,高亮就永远停在原来的消息上。帧末补算一次。
      _scheduleAnchorResync();
    }
  }

  /// 帧末(布局/绘制已完成)重算一次可见锚点。
  ///
  /// 滚动通知与布局的时序问题见 [_syncScrollFlags];用去重标记避免滚动期间
  /// 每帧注册回调。定位/高亮锁定期跳过 —— 那时锚点是显式指定的目标。
  void _scheduleAnchorResync() {
    if (_anchorResyncScheduled || !mounted) return;
    if (_revealRunning || _highlightMessageId != null) return;
    _anchorResyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorResyncScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      if (_revealRunning || _highlightMessageId != null) return;
      final id = _messageListKey.currentState?.visibleUserMessageId();
      if (id != null) _visibleUserMessageId.value = id;
    });
  }

  /// 新的滚动意图(回顶/回底)接管视口前,清掉旧的定位循环与高亮锁定。
  ///
  /// 旧高亮会通过 [_syncScrollFlags] 的锁定把锚点钉在中段的那条消息上,
  /// 即使视口已经到了边界也不更新 —— 用户看到的正是"已经到了,卡片还停在
  /// 中间某条"。
  void _takeOverScrollIntent() {
    if (_revealRunning) {
      _revealRequest++;
      _revealRunning = false;
      _messageListKey.currentState?.cancelReveal();
    }
    if (_highlightMessageId != null) {
      _highlightTimer?.cancel();
      _rebuild(() => _highlightMessageId = null);
    }
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

  void _scrollToBottom({bool animate = true, bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // 用户恰在此刻按下拖动:程序性贴底必须让位,同时解除初始定位的隐藏态
      // (绝不滞留在"列表不可见"的状态)。
      if (_userDragging) {
        _settleEntry();
        return;
      }
      _takeOverScrollIntent();
      _performScrollToBottom(animate: animate, force: force);
    });
  }

  /// 解除「进入会话初始定位」的列表隐藏态并显示(幂等)。挂在贴底收敛链的
  /// 每一条退出点上:贴底 settled、帧预算用尽、用户抢先滚动 —— 保证任何
  /// 路径下列表最多隐藏几个收敛帧,不会停在透明态。
  void _settleEntry() {
    if (!_entrySettling || !mounted) return;
    _rebuild(() => _entrySettling = false);
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
      _scheduleAnchorResync();
      return;
    }
    // 进入会话的贴底定位是唯一不经过 `_onScroll` 的定位路径(视口本就停在
    // offset 0、不产生滚动),邻域标记必须在这里补一次同步(见 _syncScrollFlags)。
    _syncScrollFlags();
    // force 用于「用户主动发送」与「点击回到底部」这两类显式意图:不受
    // 500ms 用户滚动宽限窗影响(刚滚过就点按钮,第一次点击会被静默吞掉),
    // 但仍让位给正在按住的拖动。
    if (_userDragging || (!force && _userScrollInProgress())) {
      _settleEntry(); // 用户抢先接管:立即显示,跟随让位于手势。
      return;
    }
    final pos = _scroll.position;
    if (pos.pixels <= 1.0) {
      _settleEntry();
      _scheduleAnchorResync();
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
            if (mounted) {
              _settleEntry();
              _scheduleAnchorResync();
            }
          });
      return;
    }
    _scroll.jumpTo(0);
    _settleEntry();
    _scheduleAnchorResync();
  }

  /// 「回到顶部」:把窗口之上未加载的旧历史**逐页取尽**,再落到绝对顶部
  /// (时间序第一条)。列表 `reverse: true` —— 顶部在偏移更大的一端,即
  /// `maxScrollExtent`;该值仍是估算(懒加载列表只有尾段条目布局后才精确),
  /// 故取尽后用 [_convergeToTop] 做「小步逼近 + 逐帧复核」的多帧收敛。
  ///
  /// **一次点击必须到顶**:旧实现有 8 页(约 960 行)预算,历史更长的会话
  /// 第一次点完停在半截,用户必须再点一次 —— 这正是「回顶要两次」的直接
  /// 来源。现在只留 10 秒时间预算,兜底异常长历史/异常慢查询。
  ///
  /// 用户点击是显式意图,不受 500ms 用户滚动宽限窗限制(旧实现在刚滚过
  /// 就点按钮时,第一次点击被静默吞掉);只在手指按住拖动时让位。
  ///
  /// 分页本身**不需要锚定**:更早的消息追加在列表远端,已有条目的位置不变,
  /// 视口不会因补页而漂移。循环期间 [_maybeLoadOlder] 让位(由本循环驱动)。
  ///
  /// 流式回复/耗时命令进行中控制器会拒绝 loadOlder([_loadOlder] 静默无进展):
  /// 以「消息条数不变」检测该拒绝,提示用户并停到当前窗口顶,不做死循环。
  Future<void> _scrollToTop() async {
    if (_autoTopRunning.value) return;
    // 回顶是新的滚动意图:作废仍在飞的定位循环,并解除旧跳转的两秒高亮
    // 锁定(否则锚点会被钉在原来的中段消息上,到顶也不更新)。
    _takeOverScrollIntent();
    _autoTopRunning.value = true;
    const timeBudget = Duration(seconds: 10);
    final budgetWatch = Stopwatch()..start();
    var budgetExhausted = false;
    try {
      while (mounted &&
          _screenDataReady &&
          ref.read(chatControllerProvider).canLoadOlder) {
        // 只让位给正在按住拖动的用户;滚轮/惯性的宽限窗不适用于显式点击。
        if (_userDragging) return;
        if (budgetWatch.elapsed >= timeBudget) {
          budgetExhausted = true;
          break;
        }
        final before = ref.read(chatControllerProvider).messages.length;
        await _loadOlder();
        // 催帧:补页重建与进度钮刷新都要等一帧;不催帧时循环可能在同一
        // 事件循环里连续读库,进度指示永远来不及绘制。
        WidgetsBinding.instance.scheduleForcedFrame();
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
      // 收敛的最后一次 jumpTo 同样在布局更新前通知了滚动监听;max 还可能
      // 在落定帧之后被远端布局再修正一次。等一帧让布局彻底稳定,再在
      // 帧末重算高亮锚点。
      if (!mounted || !_scroll.hasClients) return;
      WidgetsBinding.instance.scheduleForcedFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _scheduleAnchorResync();
      if (budgetExhausted &&
          mounted &&
          ref.read(chatControllerProvider).canLoadOlder) {
        _islandHub.push(
          '历史过长,已回到已加载的顶部;再点一次「回到顶部」可继续加载更早消息',
          tone: IslandTone.info,
        );
      }
    } finally {
      // 页面可能已在循环中途销毁(notifier 随 State.dispose 释放)。
      if (mounted) _autoTopRunning.value = false;
    }
  }

  /// 多帧收敛到列表顶部(reverse 下 = `maxScrollExtent`)。
  ///
  /// 顶部方向**仍然**是估算值,且只有视口贴近它时布局才会排布尾段条目、把
  /// 估算修正到精确 —— 单次跳转可能停在估算的中间点。逐帧按「单帧最多 6 个
  /// 视口」小步逼近,每次落点触发布局 refine,下一帧复核继续逼近;每步都
  /// 立即跳变(无缓动残差),落点精确。底部方向不需要这套:那是恒为 0 的精确
  /// 位置(见 [_performScrollToBottom])。
  ///
  /// 与 [_scrollToTop] 一致:显式回顶流程不受用户滚动宽限窗限制;落点已到
  /// 边界(像素未变化)时直接收口,避免空转。
  Future<void> _convergeToTop({int attempts = 0}) async {
    if (!mounted || !_scroll.hasClients) return;
    if (_userDragging) return;
    if (attempts >= 96) return; // 预算兜底,防止极端情况下的无限收敛。
    final pos = _scroll.position;
    final target = pos.maxScrollExtent;
    if ((pos.pixels - target).abs() < 1.0) {
      // 懒加载列表的 maxScrollExtent 只是估算:第一脚踏上"估算顶"时,
      // 远端条目才刚参与布局,下一帧可能把上限改大。必须等一帧复核,
      // 否则会停在旧顶 —— 视口没到最旧消息,导航高亮也就落在中段。
      WidgetsBinding.instance.scheduleForcedFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return;
      final after = _scroll.position;
      if ((after.maxScrollExtent - target).abs() < 1.0) return;
      return _convergeToTop(attempts: attempts + 1);
    }
    final stepCap = pos.viewportDimension * 6;
    final capped = target > pos.pixels
        ? math.min(target, pos.pixels + stepCap)
        : math.max(target, pos.pixels - stepCap);
    if ((capped - pos.pixels).abs() < 1.0) return;
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

  /// 桌面导航卡片点击:先扩窗把目标并入显示窗口,再滚到该条并短暂高亮。
  ///
  /// 与搜索跳转同一条链路。扩窗会增加条数并触发贴底跟随,目标多在历史里,
  /// 先让出跟随由定位滚动接管;失败时恢复原标记并提示。
  ///
  /// 用户连点两条时**后一次接管**:旧请求的异步链返回后凭 [_revealRequest]
  /// 自行作废,不写高亮、不改跟随基线。旧实现用 `_revealRunning` 直接丢弃
  /// 第二次点击,用户看到的是「点了没反应」。
  Future<void> _jumpToUserMessage(int messageId) async {
    if (!_screenDataReady || _autoTopRunning.value) return;
    final request = ++_revealRequest;
    final wasNearBottom = _nearBottom.value;
    _nearBottom.value = false;
    _revealRunning = true;
    try {
      final located = await ref
          .read(chatControllerProvider.notifier)
          .revealMessage(messageId);
      if (!mounted || request != _revealRequest) return;
      if (!located) {
        _nearBottom.value = wasNearBottom;
        _islandHub.push('无法定位该消息:它可能已被删除,或正在加载历史', tone: IslandTone.danger);
        return;
      }
      await _messageListKey.currentState?.revealMessage(messageId);
      if (!mounted || request != _revealRequest) return;
      // 锚点直接锁定目标:定位是逐帧 jumpTo,滚动监听扫过的中间位置不能
      // 写回;落定后立即让刻度/卡片指向用户刚跳的那条。
      _visibleUserMessageId.value = messageId;
      _highlightTimer?.cancel();
      _rebuild(() => _highlightMessageId = messageId);
      _highlightTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        _rebuild(() => _highlightMessageId = null);
        // 高亮结束交还真实可见锚点(图片异步改高可能让目标移出视口)。
        if (!_revealRunning) _syncScrollFlags();
      });
    } finally {
      if (request == _revealRequest) {
        _revealRunning = false;
        // 扩窗/提前分页改动了条数:把跟随基线同步到当前值,避免定位结束后的
        // build 把这次扩窗当成"新消息"而触发贴底跟随;侧栏预览的失效在下面
        // 手动补上(那条路径平时由 build 的条数分支负责)。
        if (mounted && _screenDataReady) {
          _lastCount = ref.read(chatControllerProvider).messages.length;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) ref.invalidate(sessionGroupsProvider);
          });
        }
      }
    }
  }
}
