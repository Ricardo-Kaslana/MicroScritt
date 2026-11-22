// 斜杠命令执行:/test /continue /clear /compact /rerun,含忙碌门控与
// 压缩用量记账的命令层入口。
part of 'chat_controller.dart';

/// 斜杠命令:/test /continue /clear /compact /rerun 与压缩用量记账。
abstract class ChatControllerCommands extends ChatControllerPipeline {
  /// 消费一次性瞬态通知([ChatState.notice]):UI 闪示后调用,避免重复展示。
  void clearNotice() {
    if (state.notice != null) state = state.copyWith(notice: null);
  }

  /// 执行一个快捷命令(发送端斜杠命令,命令按钮填入输入框后同样走这里)。
  /// [args] 是命令名之后的文本,当前仅 `/rerun` 消费为修改方向。
  /// 忙碌期拒绝并给出可见错误;返回一段给 UI 展示的反馈文本
  /// (null 表示无需提示)。
  Future<String?> runCommand(SlashCommand cmd, {String args = ''}) async {
    if (state.streaming || _busy) {
      // 忙碌期拒绝要有可见提示:命令输入同样可能已被 UI 清空。
      state = state.copyWith(error: '正在处理中(生成/生图/压缩进行时),请稍候或按停止中断');
      return null;
    }
    if (state.sessionId == null || state.character == null) {
      state = state.copyWith(error: '会话尚未加载完成,命令未执行');
      return null;
    }
    switch (cmd) {
      case SlashCommand.test:
        await _runTest();
        return null;
      case SlashCommand.continueStory:
        await _runContinue();
        return null;
      case SlashCommand.clearHistory:
        return await _runClear() ? '已清空会话历史' : null;
      case SlashCommand.compact:
        return _runCompact();
      case SlashCommand.rerun:
        return _runRerun(args);
    }
  }

  /// 空会话从一条开场白起笔:把用户选中的开场白作为助手首条消息落库,
  /// 不发 LLM 请求。仅在会话仍为空、无生成/耗时命令时接受;返回是否写入。
  Future<bool> startWithGreeting(String content) async {
    final sessionId = state.sessionId;
    final text = content.trim();
    if (sessionId == null ||
        text.isEmpty ||
        state.streaming ||
        _busy ||
        state.messages.any((m) => m.role != 'system' && m.isChat)) {
      return false;
    }
    // 同步置忙挡住双击/与发送竞争:append 落库前 state.messages 还看不到
    // 新行,仅靠入口检查会让两次调用都通过。
    _busy = true;
    try {
      final epoch = _sessionEpoch;
      await ref
          .read(messageRepositoryProvider)
          .append(sessionId: sessionId, role: 'assistant', content: text);
      if (!_ownsMain(sessionId, epoch)) return true;
      await _refreshMessages();
      if (!_ownsMain(sessionId, epoch)) return true;
      // 历史从空到一条:上下文面板与圆环立即跟上,不必等下一轮发送。
      // 上轮真实输入计数对新上下文已失效,圆环退回估算。
      state = state.copyWith(lastSentInputTokens: null);
      await _reassembleContext();
      return true;
    } finally {
      _busy = false;
    }
  }

  /// `/test`:追加一条测试消息走生成,验证 LLM 链路。
  Future<void> _runTest() async {
    final ok = await _appendAndGenerate('（系统测试:验证生成链路,请简短回复）');
    if (!ok && !ref.mounted) return;
    if (!ok) {
      state = state.copyWith(error: '尚无会话或后端未配置,无法测试生成');
    }
  }

  /// `/continue`:追加一条"请继续"消息,推动 AI 自动续写剧情。
  Future<void> _runContinue() async {
    final count = state.messages
        .where((m) => m.role != 'system' && !m.isCompacted)
        .length;
    final ok = await _appendAndGenerate(
      count == 0 ? '（请以角色的视角自然展开一段剧情开场）' : '（请自然地继续推动剧情）',
    );
    if (!ok && !ref.mounted) return;
    if (!ok) {
      state = state.copyWith(error: '尚无会话或后端未配置,无法推进剧情');
    }
  }

  /// `/clear`:清空该会话全部消息(含压缩摘要与原文),但保留开场消息 ——
  /// 即新建会话时自动写入的角色开场白(`firstMessage`),使清空后对话以开场起头
  /// 而非完全空白。
  Future<bool> _runClear() async {
    final sessionId = state.sessionId;
    if (sessionId == null) return false;
    final character = state.character;
    _invalidateBackground();
    _windowFloor = null;
    await ref.read(messageRepositoryProvider).clearSession(sessionId);
    // 重放开场白(与新建会话时一致的 assistant 行),若角色未配开场则维持空白。
    if (character != null && character.firstMessage.isNotEmpty) {
      await ref
          .read(messageRepositoryProvider)
          .append(
            sessionId: sessionId,
            role: 'assistant',
            content: character.firstMessage,
          );
    }
    await _refreshMessages();
    // 清空后重算上下文快照:否则上下文面板的"历史消息 N 条"仍是清空前的数字,
    // 直到下一轮发送才更新,观感上"清空没生效"。
    // 历史清空 = 上轮实际计数对新上下文完全失效,圆环退回估算。
    state = state.copyWith(lastSentInputTokens: null);
    await _reassembleContext();
    return true;
  }

  /// `/rerun [修改方向]`:重跑上一次后台维护(变量按同一批对话重放,生图
  /// 原地重绘)。命令后的文本作为修改方向交给后台 LLM。
  /// 被拒绝时走 error 横幅(与其它命令一致,不覆盖后台在跑的实时状态文案);
  /// 已启动则回一句确认,后续进度由灵动岛/状态面板的后台状态跟进。
  String? _runRerun(String direction) {
    final refusal = rerunBackgroundMaintenance(direction: direction);
    if (refusal != null) {
      state = state.copyWith(error: refusal);
      return null;
    }
    return direction.trim().isEmpty ? '正在重跑上次后台维护…' : '正在按修改方向重跑上次后台维护…';
  }

  /// `/compact`:主动压缩历史(比自动阈值更激进,保留最近若干条并做摘要)。
  /// 返回给 UI 展示的成功反馈文本;无操作或失败时置 error。
  Future<String?> _runCompact() async {
    final sessionId = state.sessionId;
    final backend = ref.read(backendProvider);
    final config = ref.read(backendConfigProvider);
    if (sessionId == null || backend == null || config == null) return null;

    // 本轮令牌:入口换新实例并捕获,取消判定只认这个实例;并发在飞的后台轮
    // 持有自己的实例,不受影响。
    _mainToken = InterruptToken();
    final token = _mainToken;
    final epoch = _sessionEpoch;
    final windowFloor = _windowFloor;

    // 「压缩中」活动态 + 可中断:网络黑洞/排队过长时用户有停止入口。
    // 置位必须先于本方法内首个 await —— UI 事件派发是同步链,放在 await 之后
    // 的话活动态要等事件循环推进才可见(tap 后首帧不出「压缩中」)。
    if (_ownsMain(sessionId, epoch)) {
      state = state.copyWith(busyCommand: 'compact');
    }

    final messageRepo = ref.read(messageRepositoryProvider);
    var done = false;
    var failed = false;
    var activeBefore = 0;
    try {
      // 压缩前统计待压缩的活跃消息数,用于给用户可见的"压缩成功"反馈。
      // 窗口读即可:显示口径与活跃计数都只关心尾部窗口,此前为一个数字
      // 全量读了整条会话(超长会话一次搬全部行)。
      final before = await messageRepo.bySessionSince(
        sessionId,
        sinceSeq: windowFloor,
      );
      activeBefore = before
          .where((m) => m.role != 'system' && !m.isCompacted)
          .length;
      done = await CompactService(backend, messageRepo).compact(
        sessionId: sessionId,
        model: config.model,
        temperature: config.temperature,
        keep: 6,
        onUsage: (usage) =>
            _accumulateCompactUsage(usage, sessionId: sessionId, epoch: epoch),
        stripSkillNames: await enabledSkillNames(),
        cancelSignal: token.whenCancelled,
      );
    } catch (_) {
      // 命令内联的 DB/网络异常不能让 busyCommand 永久停留在「压缩中」
      // (旧实现没有 try/finally,事务抛错后灵动岛与发送键会一直卡住)。
      failed = true;
    } finally {
      if (_ownsMain(sessionId, epoch)) {
        state = state.copyWith(busyCommand: null);
      }
    }
    if (!_ownsMain(sessionId, epoch)) return null;
    final interrupted = token.cancelled;
    if (failed) {
      state = state.copyWith(error: '压缩失败(未生成摘要,历史保持原样)');
      return null;
    }
    if (done) {
      // 立即落库压缩通知,而不是等到下一次用户输入:通知属于"压缩后的第一次
      // 组装",延迟发送会在切换会话时丢失(`load` 会清空待发标志)。通知行由
      // 组装期的位置校正排在所属用户消息之前。
      try {
        await _persistCompactNotice(sessionId);
      } catch (_) {
        // 通知是辅助信息:写入失败不影响已完成的摘要压缩。
      }
      // 压缩是缓存断点,顺带把第 0 条记忆换成库中最新版。
      await _refreshFrozenMemory(sessionId);
      // 历史被压缩改写且本命令不生成 —— 上轮实际计数对压缩后的请求失效,
      // 圆环退回估算,下一轮发送后重新锚定。
      state = state.copyWith(lastSentInputTokens: null);
    }
    await _refreshMessages();
    // 压缩后重算上下文快照:让上下文面板立即反映"历史变短 + 摘要段出现",
    // 否则压缩只在下一轮发送时才可见,观感上"没有效果"。
    await _reassembleContext();
    if (!done) {
      if (interrupted) {
        state = state.copyWith(error: '已中断压缩(未生成摘要,历史保持原样)');
      } else {
        state = state.copyWith(error: '历史太短或无有效消息,暂无可压缩内容');
      }
      return null;
    }
    final compacted = activeBefore > 6 ? activeBefore - 6 : 0;
    return compacted > 0 ? '已压缩 $compacted 条历史并生成摘要,保留最近 6 条' : '已完成压缩,历史已摘要化';
  }
}
