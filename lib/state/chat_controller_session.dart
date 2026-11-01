part of 'chat_controller.dart';

/// 会话生命周期:原子切换加载/贴顶分页/窗口消息刷新/会话列表失效/token 用量持久化。
abstract class ChatControllerSession extends ChatControllerContext {
  Future<void> _refreshMessages() async {
    final sessionId = state.sessionId;
    if (sessionId == null || !ref.mounted) return;
    final fetch = ++_messageFetchSeq;
    // 窗口化(DV 批):按当前窗口下界刷新,而非全量重读 —— 会话越长收益
    // 越大;从未窗口化的会话(floor=null)等价全量,行为不变。
    final messages = await ref
        .read(messageRepositoryProvider)
        .bySessionSince(sessionId, sinceSeq: _windowFloor);
    if (!ref.mounted ||
        fetch != _messageFetchSeq ||
        state.sessionId != sessionId) {
      return;
    }
    state = state.copyWith(messages: messages);
    // 消息条数/末条预览变化后,会话列表(sessionInfosProvider)会命中陈旧缓存,
    // 返回(弹回会话列表)时不刷新条数与预览 —— 在消息每次变更后失效它。
    _invalidateSessionList();
  }

  /// 使会话列表的消息数/末条预览失效(消息增删/清空/压缩后调用)。
  void _invalidateSessionList() {
    final characterId = state.characterId;
    if (characterId == null || !ref.mounted) return;
    ref.invalidate(sessionInfosProvider(characterId));
  }

  Future<void> load({
    required int sessionId,
    required CharacterCard character,
  }) async {
    _invalidateBackground();
    _sessionEpoch++;
    final epoch = _backgroundEpoch;
    // 原子切换(DR 批):会话级元数据(sessionId/上下文/token/草稿/流式/后台
    // 状态)立即清空 —— send 靠 sessionId=null 门控,上下文面板/统计条不会
    // 显示上个会话的残留(沿用旧的清空决策);但**保留消息转录**,旧会话的
    // 气泡继续显示到新会话数据就绪、由下方最终赋值一次性整体替换。旧的
    // "先清空一切"会让切换瞬间闪出『发一条消息开始对话』空态。首次加载
    // (本来就无消息)不受影响。
    state = state.messages.isEmpty
        ? const ChatState()
        // 暂存的转录连同它的归属会话一起保留:transcriptSessionId 是 UI 判定
        // 「切换窗口里的旧转录该不该隐藏」的依据(重进同一会话时它 == 新
        // sessionId,转录照常显示;切往其它会话时它是旧会话,转录隐藏)。
        : const ChatState().copyWith(
            messages: state.messages,
            transcriptSessionId: state.transcriptSessionId ?? state.sessionId,
          );
    // 草稿属会话级瞬态(EF 批起在独立 provider):切换即刻清零,不让上一
    // 会话的生成中气泡在切换窗口里闪现。
    _setDraft('');
    // 窗口化加载(DV 批)的游标随会话切换重置。
    _windowFloor = null;
    _loadingOlder = false;
    // 消息取**窗口**(单次往返:全部 system 行 + 显示/组装双口径尾部,边界
    // 以内联子查询计算)而非全量 —— 进入延迟与内存不再随会话长度线性涨。
    // 注意保持这里的 await 链顺序形态:每一条查询在前一条落定后才派发,
    // 边界条件与真机/测试的事件循环推进模型都兼容(DV 批曾尝试并行起跑,
    // 在无帧推进的等待窗内会饿死后续链路,已回退)。
    final window = await ref
        .read(messageRepositoryProvider)
        .sessionWindow(
          sessionId: sessionId,
          displayCount: ChatControllerBase._historyWindowRows,
        );
    if (!ref.mounted || _backgroundEpoch != epoch) return;
    final messages = window.rows;
    _windowFloor = window.floor;
    final session = await ref.read(sessionRepositoryProvider).get(sessionId);
    if (!ref.mounted || _backgroundEpoch != epoch) return;
    final characterId = session?.characterId;
    final worldbook = characterId == null
        ? <WorldbookEntry>[]
        : await ref.read(worldbookRepositoryProvider).byCharacter(characterId);
    if (!ref.mounted || _backgroundEpoch != epoch) return;
    // 会话级控制器状态复位:记忆冻结副本取库中当前值(会话起点),压缩通知/
    // diff 记账/后台游标与轮次计数全部归零 —— 上一个会话的挂起通知绝不泄漏到
    // 新会话的第一次请求里。
    final memories = await ref
        .read(memoryRepositoryProvider)
        .bySession(sessionId);
    if (!ref.mounted || _backgroundEpoch != epoch) return;
    _frozenMemory = memories.isEmpty ? null : memories.first.content;
    _compactNoticePending = false;
    _memoryDiffNotifiedHash = null;
    _backgroundCursorSeq = null;
    _maintenanceRunCount = 0;
    // 基线上下文预览:打开会话即能看到"当前上下文里有什么",不必先发一条消息。
    // 变量不参与主写组装(CL 批起变量只进后台 agent 上下文),故此处不读 variables;
    // 技能同理不进组装(CW 批起只有 @ 触发附件,随消息历史进数组)。
    final snapshot = ContextAssembler().assemble(
      character: character,
      items: await ref.read(promptItemRepositoryProvider).allEnabled(),
      history: messages,
      worldbook: worldbook,
      frozenMemory: _frozenMemory,
    );
    if (!ref.mounted || _backgroundEpoch != epoch) return;
    // 真实输入锚点:会话行的 input_tokens 即"最近一轮主写请求"的实际用量
    // (每轮替换而非累加),重启/重进后圆环可立即回到真实口径;无历史用量
    // (全新会话)保持 null,圆环退回字符估算。
    final restoredTokens = session?.inputTokens ?? 0;
    state = ChatState(
      sessionId: sessionId,
      characterId: characterId,
      character: character,
      messages: messages,
      transcriptSessionId: sessionId,
      worldbook: worldbook,
      lastContext: snapshot,
      frozenMemory: _frozenMemory,
      lastSentInputTokens: restoredTokens > 0 ? restoredTokens : null,
      canLoadOlder: window.floor != null,
      inputTokens: restoredTokens,
      outputTokens: session?.outputTokens ?? 0,
      cachedInputTokens: session?.cachedInputTokens ?? 0,
      backgroundInputTokens: session?.backgroundInputTokens ?? 0,
      backgroundOutputTokens: session?.backgroundOutputTokens ?? 0,
      backgroundCachedInputTokens: session?.backgroundCachedInputTokens ?? 0,
      compactInputTokens: session?.compactInputTokens ?? 0,
      compactOutputTokens: session?.compactOutputTokens ?? 0,
      compactCachedInputTokens: session?.compactCachedInputTokens ?? 0,
    );
  }

  /// 角色卡在聊天页内被编辑后同步新设定:更新快照里的角色副本并重算上下文,
  /// 下一次请求与上下文面板立即使用新卡;会话未加载时是安全的 no-op。
  Future<void> updateCharacter(CharacterCard character) async {
    if (state.sessionId == null || state.characterId == null) return;
    state = state.copyWith(character: character);
    await _reassembleContext();
  }

  /// 按当前窗口下界抓取消息(不重算边界)。[load] 经 [_fetchSessionWindow]
  /// 计算下界;运行期刷新(发送/压缩/回滚)用本方法 —— 分页补进来的历史
  /// 在刷新后保持在窗。
  Future<List<Message>> _fetchCurrentWindow(int sessionId) {
    return ref
        .read(messageRepositoryProvider)
        .bySessionSince(sessionId, sinceSeq: _windowFloor);
  }

  /// 向上分页:在当前窗口之前再补一页历史(显示口径行)。由聊天页贴顶时
  /// 触发;流式/命令进行中拒绝(与发送管线的刷新互斥,避免半页状态)。
  /// 分页行严格老于首屏窗口边界;而组装窗口由「全部未折叠活跃行」独立界定
  /// (不共用分页游标)—— 翻阅历史不改变发给 LLM 的上下文(仓库层有完整论证)。
  Future<void> loadOlder() async {
    final sessionId = state.sessionId;
    if (sessionId == null || !state.canLoadOlder || _loadingOlder) return;
    if (state.streaming || _busy) return;
    final floor = _windowFloor;
    if (floor == null) return;
    _loadingOlder = true;
    state = state.copyWith(loadingOlder: true);
    try {
      final page = await ref
          .read(messageRepositoryProvider)
          .bySessionPageBefore(
            sessionId,
            beforeSeq: floor,
            limit: ChatControllerBase._historyPageRows,
          );
      if (!ref.mounted) return;
      if (page.isEmpty) {
        state = state.copyWith(canLoadOlder: false, loadingOlder: false);
        return;
      }
      // 页内不足一页 = 后面再无历史,一并终结分页。
      final noMore = page.length < ChatControllerBase._historyPageRows;
      _windowFloor = page.first.seq;
      // 页与现窗按 seq 不相交(页 < 旧 floor ≤ 现窗非 system 行;system 行
      // 全在现窗),直接前拼即恢复时间序。
      state = state.copyWith(
        messages: [...page, ...state.messages],
        canLoadOlder: noMore ? false : null,
        loadingOlder: false,
      );
    } finally {
      _loadingOlder = false;
      // 异常/容器销毁等未走成功分支时也要把加载状态复位。
      if (ref.mounted && state.loadingOlder) {
        state = state.copyWith(loadingOlder: false);
      }
    }
  }

  /// 定位一条聊天流消息(搜索跳转):确保目标进入当前显示窗口并返回是否成功。
  ///
  /// 目标已在窗口内时只做存在性校验;在更早历史中时才把显示窗口下界下移到
  /// 目标 seq 并重读 —— 这会暂时载入「目标到最新」的整段尾部(搜索跳转的
  /// 显式代价),但**不影响组装窗口**:上下文组装始终独立读
  /// [MessageRepository.activeWindow](见 `_reassembleContext`),搜索跳转
  /// 不会改变发给 LLM 的内容。目标已被删除、属于其它会话或不是聊天流可见行
  /// (system/附件)时返回 false,绝不把窗口换成半截数据。
  Future<bool> revealMessage(int messageId) async {
    final sessionId = state.sessionId;
    if (sessionId == null || !ref.mounted || _loadingOlder) return false;
    final repo = ref.read(messageRepositoryProvider);
    final target = await repo.locate(messageId);
    if (!ref.mounted || state.sessionId != sessionId) return false;
    if (target == null || target.sessionId != sessionId || !target.visible) {
      return false;
    }
    final floor = _windowFloor;
    if (floor == null || target.seq >= floor) {
      return state.messages.any(
        (m) => m.id == messageId && m.isChat && m.role != 'system',
      );
    }
    final messages = await repo.bySessionSince(sessionId, sinceSeq: target.seq);
    if (!ref.mounted || state.sessionId != sessionId) return false;
    if (!messages.any((m) => m.id == messageId)) return false;
    // 让在飞的旧窗口刷新失效(它按旧 floor 读,晚到会覆盖掉目标)。
    _messageFetchSeq++;
    _windowFloor = target.seq;
    state = state.copyWith(
      messages: messages,
      canLoadOlder: target.seq > 0,
      loadingOlder: false,
    );
    return true;
  }

  /// 把当前累计的 token 用量持久化到会话(重启/重进后恢复)。开销小、失败静默。
  /// 先确认 ref 仍挂载再读 state —— 容器已销毁时读 state 会抛 invalid usage。
  Future<void> _persistTokenUsage() async {
    if (!ref.mounted) return;
    final sessionId = state.sessionId;
    if (sessionId == null) return;
    try {
      await ref
          .read(sessionRepositoryProvider)
          .updateTokenUsage(
            sessionId: sessionId,
            inputTokens: state.inputTokens,
            outputTokens: state.outputTokens,
            cachedInputTokens: state.cachedInputTokens,
            backgroundInputTokens: state.backgroundInputTokens,
            backgroundOutputTokens: state.backgroundOutputTokens,
            backgroundCachedInputTokens: state.backgroundCachedInputTokens,
            compactInputTokens: state.compactInputTokens,
            compactOutputTokens: state.compactOutputTokens,
            compactCachedInputTokens: state.compactCachedInputTokens,
          );
    } catch (_) {}
  }
}
