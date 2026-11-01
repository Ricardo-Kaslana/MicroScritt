part of 'chat_controller.dart';

/// 发送主流程:trySend 忙碌门控/发送管线与附件展开/硬挡与软挡压缩/回复生成/重发·重生成/消息增删改。
abstract class ChatControllerPipeline extends ChatControllerBackground {
  /// 发送前硬挡预算检测([ContextBudgetPolicy.hard] = 80%)。
  ///
  /// 估算本次请求输入(system + messages)+ 输出预留,超过
  /// 容量×80% 时按序执行:
  /// ① LLM 摘要压缩,把活跃历史压回目标挡(摘要失败共 1+3 次尝试);
  /// ② 重算后仍超标 → 机械截断兜底(`CompactService.foldToFit`,不经 LLM,
  ///    把装不下的最老活跃消息标记折叠),保证请求一定发得出去。
  ///
  /// 压缩发生后:置压缩通知(调用方经 [_persistPendingNotices] 落库为附件行
  /// 再重组装)并刷新记忆冻结副本(压缩是缓存断点,顺带把第 0 条记忆换成库中最新版)。
  ///
  /// 返回最终生效的 (messages, snapshot, compacted);compacted 表示本路径
  /// 发生过压缩(调用方落库通知并重载重组装)。未触发预算线或总开关关闭时返回
  /// null(调用方沿用原 snapshot)。
  Future<({List<Message> messages, ContextSnapshot snapshot, bool compacted})?>
  _enforceHardBudget({
    required int sessionId,
    required List<Message> messages,
    required ContextSnapshot snapshot,
    required InterruptToken token,
  }) async {
    if (!ref.read(appSettingsProvider).autoCompactEnabled) return null;
    final capacity = await _resolveContextCapacity();
    if (capacity == null) return null;
    final backend = ref.read(backendProvider);
    final config = ref.read(backendConfigProvider);
    if (backend == null || config == null || !ref.mounted) return null;

    int estimateOf(ContextSnapshot s) => estimateRequestTokens(
      systemPrompt: s.systemPrompt,
      messages: s.messages,
    );

    final reserve =
        config.maxTokens ?? ContextBudgetPolicy.defaultOutputReserveTokens;
    final hardBudget = (capacity * ContextBudgetPolicy.hard).floor();
    if (estimateOf(snapshot) + reserve <= hardBudget) return null;

    var current = snapshot;
    var currentMessages = messages;
    var compacted = false;
    final messageRepo = ref.read(messageRepositoryProvider);
    final service = CompactService(backend, messageRepo);

    // ① LLM 摘要压缩到目标挡:保留条数按"目标占用 − 摘要预留"规划,
    //    压缩后重载消息并重新组装快照再判定(新摘要成为消息数组首条合成消息)。
    final activeBefore = _liveConversation(currentMessages);
    final targetHistoryBudget =
        (capacity * ContextBudgetPolicy.target).floor() -
        ContextBudgetPolicy.summaryReserveTokens;
    final keepForTarget = planKeepWithinBudget(
      active: activeBefore,
      budgetTokens: targetHistoryBudget,
    );
    if (keepForTarget < activeBefore.length) {
      // 压缩期间灵岛进入「压缩中」活动态、发送键可中断(摘要请求响应取消
      // 信号 —— 此刻流式尚未开始,不设防时用户没有任何停止入口)。
      if (ref.mounted) state = state.copyWith(busyCommand: 'compact');
      try {
        final done = await service.compact(
          sessionId: sessionId,
          model: config.model,
          keep: keepForTarget,
          maxSummarizeAttempts: 4, // 首次 + 3 次失败重试
          onUsage: _accumulateCompactUsage,
          cancelSignal: token.whenCancelled,
        );
        compacted = compacted || done;
      } catch (_) {
        // 压缩 best-effort;摘要彻底失败时走下方机械截断兜底。
      } finally {
        if (ref.mounted) state = state.copyWith(busyCommand: null);
      }
      if (compacted) await _refreshFrozenMemory(sessionId);
      // 组装窗口:全部未折叠活跃行(组装不再按条数裁剪,见 activeWindow)。
      final fresh = await messageRepo.activeWindow(sessionId);
      final rebuilt = await _assembleSnapshot(fresh);
      if (rebuilt != null && ref.mounted) {
        current = rebuilt;
        currentMessages = fresh;
      }
    }

    // ② 仍超硬挡 → 机械截断兜底:不经 LLM,把放不下的最老活跃消息标记折叠。
    //    用户已在压缩阶段中断时跳过(本轮发送由调用方检查中断标志后中止)。
    //    允许额 = 硬挡预算 − 输出预留 − 固定段(system + 首条记忆/摘要合成消息;
    //    摘要前置后属固定段,不随折叠收缩)。机械折叠也换掉旧消息 → 视同压缩,
    //    通知与记忆刷新同样生效。
    if (!token.cancelled && estimateOf(current) + reserve > hardBudget) {
      final active = _liveConversation(currentMessages);
      final fixedEstimate = estimateTokensFromChars(
        current.systemPrompt.length +
            (current.leadingSummaryContent?.length ?? 0) +
            (current.leadingMemoryContent?.length ?? 0),
      );
      final allowance = hardBudget - reserve - fixedEstimate;
      final keepToFit = planKeepWithinBudget(
        active: active,
        budgetTokens: allowance,
      );
      if (keepToFit < active.length) {
        try {
          final done = await service.foldToFit(
            sessionId: sessionId,
            keep: keepToFit,
          );
          compacted = compacted || done;
        } catch (_) {
          // 兜底也失败(极端 I/O 异常):原样发送,交由服务端报错。
        }
        if (compacted) await _refreshFrozenMemory(sessionId);
        final fresh = await messageRepo.activeWindow(sessionId);
        final rebuilt = await _assembleSnapshot(fresh);
        if (rebuilt != null && ref.mounted) {
          current = rebuilt;
          currentMessages = fresh;
        }
      }
    }

    if (!compacted) return null;
    return (messages: currentMessages, snapshot: current, compacted: true);
  }

  /// 回复落库后的软挡自动压缩([ContextBudgetPolicy.soft] = 60%,
  /// [ContextBudgetPolicy.target] = 20%)。
  ///
  /// 触发依据是**上下文窗口占用量**(估算输入 / 模型容量),不再是掉窗消息
  /// 条数;压缩后占用回落到目标挡,与软挡间约 40 个百分点的滞回天然防抖,
  /// 不再需要旧的按条数降频(minChunk)。摘要失败共 1+3 次尝试,全部失败时
  /// 静默放弃 —— 下一轮占用仍超软挡会自然再试。best-effort:不阻塞回复展示,
  /// 失败不影响已落库的回复。总开关关闭或模型无容量信息时跳过。
  ///
  /// 压缩成功后置 [_compactNoticePending](下一次用户输入注入压缩通知)并刷新
  /// 记忆冻结副本 —— 软挡发生在回复落库后,本轮请求已发出,通知属于下一次。
  Future<void> _autoCompactIfDue({
    required int sessionId,
    required String model,
    required InterruptToken token,
  }) async {
    if (!ref.read(appSettingsProvider).autoCompactEnabled) return;
    final capacity = await _resolveContextCapacity();
    if (capacity == null) return;
    final backend = ref.read(backendProvider);
    if (backend == null) return;

    final messageRepo = ref.read(messageRepositoryProvider);
    // 组装窗口:占用估算必须用与发送同一份输入(全部未折叠活跃行)。
    final messages = await messageRepo.activeWindow(sessionId);
    if (!ref.mounted) return;
    final snapshot = await _assembleSnapshot(messages);
    if (snapshot == null || !ref.mounted) return;

    final estimated = estimateRequestTokens(
      systemPrompt: snapshot.systemPrompt,
      messages: snapshot.messages,
    );
    if (budgetLevelFor(estimated / capacity) == ContextBudgetLevel.ok) return;

    final active = _liveConversation(messages);
    final targetHistoryBudget =
        (capacity * ContextBudgetPolicy.target).floor() -
        ContextBudgetPolicy.summaryReserveTokens;
    final keep = planKeepWithinBudget(
      active: active,
      budgetTokens: targetHistoryBudget,
    );
    if (keep >= active.length) return; // 高占用来自系统段而非历史,压无可压

    // 回复已落库后的软挡压缩:同样进入「压缩中」活动态并响应停止
    //(此刻主写流已结束,停止键本不可用 —— 置 busyCommand 让它重新可用)。
    state = state.copyWith(busyCommand: 'compact');
    try {
      final done = await CompactService(backend, messageRepo).compact(
        sessionId: sessionId,
        model: model,
        keep: keep,
        maxSummarizeAttempts: 4, // 首次 + 3 次失败重试
        onUsage: _accumulateCompactUsage,
        stripSkillNames: await enabledSkillNames(),
        cancelSignal: token.whenCancelled,
      );
      if (done) {
        _compactNoticePending = true;
        await _refreshFrozenMemory(sessionId);
        _invalidateSessionList();
        // 面板快照跟上:软挡压缩发生在 `lastContext: sentContext` 赋值**之后**,
        // 不重算的话面板会一直停在压缩前的快照上 —— 继续显示那些刚被折叠、
        // 已不再进上下文的旧附件行,与实际发送内容对不上。硬挡路径没有这个
        // 问题(压缩在快照赋值之前完成)。
        await _reassembleContext();
      }
    } catch (_) {
      // 自动压缩是 best-effort;失败不落库、不掉轮。
    } finally {
      if (ref.mounted) state = state.copyWith(busyCommand: null);
    }
  }

  /// 删除单条消息(UI 长按删除)并刷新当前消息列表。
  Future<void> deleteMessage(int messageId) async {
    if (state.streaming || _busy) return;
    _invalidateBackground();
    await ref.read(messageRepositoryProvider).delete(messageId);
    // 删一条消息对整体上下文的改动通常远小于字符估算的误差(÷3.2),上轮真实
    // 计数仍是最准的锚点 —— 保留它,不让圆环退回估算。
    await _refreshMessages();
  }

  /// 编辑消息文本(UI 长按编辑),改写后刷新列表。
  Future<void> editMessage(int messageId, String content) async {
    if (state.streaming || _busy) return;
    final text = content.trim();
    if (text.isEmpty) return;
    _invalidateBackground();
    await ref.read(messageRepositoryProvider).updateContent(messageId, text);
    await _refreshMessages();
  }

  /// 删除某条消息中的图片(全屏查看器"删除图片"按钮):有正文的只清空图片
  /// 字段、文字保留;纯图无正文的清空后什么都不剩 —— 连整条消息一起移除,
  /// 不留一个空白气泡。生成/忙碌期间拒绝,与 [deleteMessage] 同一口径。
  Future<void> deleteMessageImage(int messageId) async {
    if (state.streaming || _busy) return;
    final repo = ref.read(messageRepositoryProvider);
    final matches = state.messages.where((m) => m.id == messageId);
    final msg = matches.isEmpty ? null : matches.first;
    if (msg != null && msg.content.trim().isEmpty) {
      _invalidateBackground();
      await repo.delete(messageId);
      // 整行移除同样保留上轮真实锚点(见 [deleteMessage]);只清图不删正文时
      // 图片本就不进上下文(纯文本口径),输入不变,锚点本就有效。
    } else {
      await repo.clearImage(messageId);
    }
    await _refreshMessages();
  }

  /// 按落库的原始描述重新生成某条消息的图片并原地替换。
  /// 返回 null 表示成功;非空字符串是可展示的失败原因。同一时刻只允许一张,
  /// 失败/取消一律保留旧图。
  Future<String?> regenerateImage(int messageId) async {
    final sessionId = state.sessionId;
    if (sessionId == null) return '尚未加载会话';
    if (state.regeneratingImageId != null) return '正在重新生成另一张图片,请稍候';
    final backend = ref.read(imageBackendProvider);
    if (backend == null) return '尚未配置生图服务';
    final repo = ref.read(messageRepositoryProvider);
    final storedPrompt = await repo.imagePromptFor(messageId);
    if (!ref.mounted || state.sessionId != sessionId) return null;
    final promptForGeneration = storedPrompt?.trim() ?? '';
    if (promptForGeneration.isEmpty) return '这张图片没有可用的原始描述,无法重新生成';

    final sessionEpoch = _sessionEpoch;
    state = state.copyWith(regeneratingImageId: messageId);
    try {
      final ImageResult generated;
      try {
        generated = await backend.generateImage(promptForGeneration);
      } catch (e) {
        return '重新生成失败:${_imageFailureText(e)}';
      }
      final image = generated.images.firstOrNull;
      if (image == null) return '未能生成新图片,请稍后重试';
      var base64 = image.base64;
      final url = image.url;
      if (base64 == null && url != null) {
        base64 = await downloadImageBase64(url);
      }
      if (!ref.mounted || state.sessionId != sessionId || _sessionEpoch != sessionEpoch) return null;
      final replaced = await repo.replaceImage(
        messageId,
        imageBase64: base64,
        imageUrl: url,
        expectedPrompt: storedPrompt!,
      );
      if (!replaced) return '原图已被删除或修改,未替换';
      final revision = (state.imageRevisions[messageId] ?? 0) + 1;
      state = state.copyWith(
        imageRevisions: {...state.imageRevisions, messageId: revision},
      );
      await _refreshMessages();
      return null;
    } finally {
      if (ref.mounted && state.sessionId == sessionId) {
        state = state.copyWith(regeneratingImageId: null);
      }
    }
  }

  static String _imageFailureText(Object error) {
    final line = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= 120 ? line : '${line.substring(0, 120)}…';
  }

  /// 重新生成助手回复(UI 长按"重新生成")。
  ///
  /// 剪掉该回复及其之后的所有消息,把历史"回滚"到它之前最后一条用户消息,
  /// 再走一遍与普通发送相同的生成管线(组装+hooks+流式+后台维护),用新回复
  /// 顶替原回复。
  Future<void> regenerate(int assistantMessageId) async {
    if (state.streaming || _busy) return;
    final sessionId = state.sessionId;
    if (sessionId == null || state.character == null) return;
    if (ref.read(backendProvider) == null) return;

    _busy = true;
    try {
      _invalidateBackground();
      await ref.read(messageRepositoryProvider).deleteFrom(assistantMessageId);
      if (!ref.mounted) return;
      final messages = await ref
          .read(messageRepositoryProvider)
          .bySessionSince(sessionId, sinceSeq: _windowFloor);
      if (!ref.mounted) return;
      if (messages.isEmpty || messages.last.role != 'user') {
        // 没有可回应的用户消息(例如被剪到了空/只剩助手),刷新后退出。
        state = state.copyWith(messages: messages);
        return;
      }
      state = state.copyWith(messages: messages);
      // DG 批:剪断后消费待发通知;行落库在最后一条用户消息之后,组装期
      // 位置校正把它挪到该用户消息之前(字节对齐旧合成位置)。
      await _persistPendingNotices(sessionId);
      await _generateReply();
    } finally {
      _busy = false;
    }
  }

  /// 清除错误横幅(UI 关闭按钮)。备用模型建议与契约漂移预警同属错误横幅
  /// 内容,一并清除,连击计数归零。
  void clearError() {
    _contractViolationStreak = 0;
    state = state.copyWith(error: null, fallbackModelHint: null, contractDriftWarning: false);
  }

  /// 生成失败后的备用模型建议(P1 契约层):错误属于"换模型可能有用"的三类
  /// (contentFlag/quota/gatewayPolicy —— 风控拦截/额度不足/网关策略)且当前
  /// provider 目录还有其它模型时,记下切换目标并把展示名挂到错误横幅;
  /// 其余错误(transient 已由后端透明重试、auth 换模型无意义)不提供建议。
  Future<void> _offerFallbackModel(UpstreamErrorKind kind) async {
    const eligible = {
      UpstreamErrorKind.contentFlag,
      UpstreamErrorKind.quota,
      UpstreamErrorKind.gatewayPolicy,
    };
    if (!eligible.contains(kind)) return;
    final providers = await ref.read(llmProvidersProvider.future);
    if (!ref.mounted) return;
    final active = providers.where((p) => p.isActive).toList();
    if (active.isEmpty) return;
    final provider = active.first;
    final currentModel = ref.read(backendConfigProvider)?.model;
    final fallback = provider.models.where((m) => m.modelId != currentModel).toList();
    if (fallback.isEmpty) return;
    _fallbackTarget = (provider.id, fallback.first.id);
    state = state.copyWith(fallbackModelHint: fallback.first.displayName);
  }

  /// 一键切换到错误横幅建议的备用模型:切 active 并刷新运行时配置,清除
  /// 错误与建议。用户随后直接重发即可走新模型。
  Future<void> switchToFallbackModel() async {
    final target = _fallbackTarget;
    if (target == null) return;
    _fallbackTarget = null;
    final repo = ref.read(llmProviderRepositoryProvider);
    await repo.setActive(providerId: target.$1, modelId: target.$2);
    final backend = await repo.loadBackendConfig();
    if (backend != null) {
      ref.read(backendConfigProvider.notifier).state = backend;
    }
    ref.invalidate(llmProvidersProvider);
    _contractViolationStreak = 0;
    if (!ref.mounted) return;
    state = state.copyWith(error: null, fallbackModelHint: null, contractDriftWarning: false);
  }

  /// 追加一条用户消息并走完整生成管线(测试生成 / 推动剧情共用)。
  /// [userText] 同样过 `beforeContextAssembly`(EQ 批修):/test /continue 注入
  /// 的消息此前绕过输入改写 hook,main/jump 等输入改写在所有入口一致生效
  /// 静默失效 —— 现在"用户输入 → beforeContextAssembly → 组装管线"的数据流
  /// 对所有注入入口一致(改写后的文本才落库与进上下文,spec §12)。
  Future<bool> _appendAndGenerate(String userText) async {
    final sessionId = state.sessionId;
    if (sessionId == null || state.character == null) return false;
    if (ref.read(backendProvider) == null ||
        ref.read(backendConfigProvider) == null) {
      return false;
    }

    _busy = true;
    try {
      // 世界书同步:与 _sendPipeline 同款(见 _syncWorldbook)。
      await _syncWorldbook();
      if (!ref.mounted) return false;
      final beforeCtx = await _runHooks(
        HookTriggerPoint.beforeContextAssembly,
        {'userText': userText},
      );
      if (!ref.mounted) return false;
      final rewritten = beforeCtx['userText'] is String
          ? beforeCtx['userText'] as String
          : userText;
      if (rewritten.trim().isEmpty) return false; // hook 清空了消息 → 本轮无事可做
      // DG 批:该路径不经 _sendPipeline,待发通知同样在此消费落库,
      // 避免滞留到下一次用户发送。
      await _persistPendingNotices(sessionId);
      await ref
          .read(messageRepositoryProvider)
          .append(sessionId: sessionId, role: 'user', content: rewritten);
      await _refreshMessages();
      await _generateReply();
      return true;
    } finally {
      _busy = false;
    }
  }

  /// 同步发送门:接受返回 true(UI 据此清空输入框);正忙(流式/生图/压缩
  /// 进行中)返回 false 并给出可见提示 —— 此前 send 直接静默 return,而 UI
  /// 已先清空输入,用户打的内容凭空消失、无任何提示。
  bool trySend(String text) {
    if (state.streaming || _busy) {
      state = state.copyWith(error: '正在处理中(生成/生图/压缩进行时),请稍候或按停止中断');
      return false;
    }
    _busy = true;
    unawaited(() async {
      try {
        await _sendPipeline(text);
      } catch (e) {
        // 管线内未预期的异常(DB/解析等):给用户可见的失败提示,而不是
        // 静默的 unhandled async exception。
        if (ref.mounted) state = state.copyWith(error: '发送失败:$e');
      } finally {
        _busy = false;
      }
    }());
    return true;
  }

  Future<void> send(String text) async {
    if (state.streaming || _busy) return;
    _busy = true;
    try {
      await _sendPipeline(text);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: '发送失败:$e');
    } finally {
      _busy = false;
    }
  }

  /// 发送管线主体([send] 与 [resend] 共用,不含 busy 门控):
  /// beforeContextAssembly 可以改写用户输入,改写后的文本才落库与进上下文
  /// (spec §12 数据流:用户输入 → beforeContextAssembly → 组装管线)。
  /// 随后计算本轮附件(@技能/世界书触发,去重记账)并**先于用户消息**落库
  /// —— 附件行的 seq 因此天然位于它所属的用户消息之前,组装无需重排;
  /// 最后追加用户消息并生成回复。@技能名 记号只在附件里展开(CY 批):实际
  /// 落库的用户消息与请求末条 user 消息不再携带触发记号。
  Future<void> _sendPipeline(String text) async {
    final sessionId = state.sessionId;
    final backend = ref.read(backendProvider);
    if (sessionId == null || state.character == null || backend == null) return;

    // 世界书可能刚在聊天页外被改(世界书页/状态面板):引擎读的是 ChatState 里的
    // 快照,不重读的话启停/内容/删除都要等重进会话才生效。发送前对齐一次。
    await _syncWorldbook();
    if (!ref.mounted) return;

    final messageRepo = ref.read(messageRepositoryProvider);
    final beforeCtx = await _runHooks(HookTriggerPoint.beforeContextAssembly, {
      'userText': text,
    });
    if (!ref.mounted) return;
    final userText = beforeCtx['userText'] is String
        ? beforeCtx['userText'] as String
        : text;
    if (userText.trim().isEmpty) return; // hook 清空了消息 → 本轮无事可做

    // attachments(CW 批):@技能提及 + 世界书触发命中,按"窗口内是否已注入"
    // 去重后逐条落库(append-only)。落库顺序在用户消息之前 → 组装时位于
    // 用户实际输入之前,用户输入始终是请求的最后一条消息。
    // DG 批:待发通知(压缩/记忆差异)也先落库为附件行,同样位于用户消息之前。
    await _persistPendingNotices(sessionId);
    await _appendSessionAttachments(sessionId, userText);

    // 用户消息**原样落库**(含 @技能名 记号):气泡/编辑所见即所得;记号在
    // 组装请求的出口统一剥离(见 _assembleSnapshot 的 stripSkillNames)。
    await messageRepo.append(
      sessionId: sessionId,
      role: 'user',
      content: userText,
    );
    // 窗口刷新(含刚落的附件行与用户消息),而非全量重读。
    state = state.copyWith(messages: await _fetchCurrentWindow(sessionId));
    await _generateReply();
  }

  /// 计算并落库本轮附件行(@技能 / 世界书触发):
  ///
  /// 用户消息本体**原样落库**(含 @记号,DA 批起剥离移到组装出口);
  /// 世界书键匹配基于剥离后的文本 —— 记号是调用语法,不参与键匹配。
  ///
  /// 1. **@技能**:用户输入里出现 `@技能名`(启用中的技能)才注入 —— 有且仅有
  ///    主动触发,技能不再常驻 system;
  /// 2. **世界书触发**:对"窗口内对话文本 + 即将发送的用户输入"做键匹配,
  ///    常驻条目不在此列(它们始终在 system 稳定段);
  /// 3. **去重记账**(对齐 Claude Code skill_listing 的账本哲学):窗口内
  ///    已有同 ref 的附件行则跳过 —— 触发型世界书命中频率高,不去重会导致
  ///    同一条目反复注入、请求越滚越大;被压缩/裁剪挤出窗口后(行不在窗口里)
  ///    重新注入合法;
  /// 4. **单轮预算与优先级**(DG 批):候选经 [selectWithinBudget] 筛选 ——
  ///    技能(用户主动)豁免名额全收,世界书触发占名额、超出全局限额
  ///    (`AppSettings.maxAutoAttachments`)按命中顺序丢弃尾部。通知附件
  ///    不在此处(系统事件,[ _persistPendingNotices] 落库,同样豁免)。
  Future<void> _appendSessionAttachments(int sessionId, String userText) async {
    final assembler = ContextAssembler();
    // 去重集合:当前窗口内已出现的附件 ref(用与组装同一把窗口尺子)。
    // 窗口下界覆盖全部未折叠活跃行(2026-09-28 批),所以这里的行集与组装
    // 所见完全一致 —— 账本口径与发送内容口径不再有偏差。
    final history = await ref.read(messageRepositoryProvider).activeWindow(sessionId);
    final windowed = ContextAssembler.activeRows(history);
    final injectedRefs = windowed
        .where((m) => !m.isChat)
        .map((m) => m.refId)
        .whereType<String>()
        .toSet();
    // 世界书条目按**名**去重(2026-09-28 批):refId 含数据库 id,而历史编辑
    // 让同一条目留下过多个 refId —— 只按 refId 比对挡不住存量旧行,条目会
    // 再注入一遍。名字取自附件行文本(与组装侧收敛同一判据)。
    final injectedWorldbookNames = windowed
        .map(ContextAssembler.worldbookEntryNameOf)
        .whereType<String>()
        .toSet();

    final messageRepo = ref.read(messageRepositoryProvider);
    final candidates = <AttachmentCandidate>[];

    // ① @技能附件(仅启用中的技能可触发)。触发判据看原始输入;记号本身
    //    不落库剥离(转录保留原话),只在组装/匹配出口剥。
    final skills = await ref.read(skillRepositoryProvider).allEnabled();
    final skillNames = skills.map((s) => s.name);
    for (final s in skills) {
      final name = s.name.trim();
      if (name.isEmpty) continue;
      final ref = AttachmentRef.skill(s.id ?? -1).value;
      if (s.id == null || injectedRefs.contains(ref)) continue;
      if (!userText.contains('@$name')) continue;
      candidates.add(
        AttachmentCandidate(
          origin: AttachmentOrigin.skill,
          refId: ref,
          content: ContextAssembler.skillAttachment(
            name,
            s.description,
            s.content,
          ),
        ),
      );
    }

    // 触发匹配文本:窗口内真实对话 + 本轮用户输入,均先剥离 @技能名 记号
    // (记号是调用语法,不该喂给世界书键匹配;与请求正文的口径一致)。
    final matchText = [
      for (final m in windowed.where((m) => m.isChat))
        ContextAssembler.withoutSkillTokens(m.content, skillNames),
      ContextAssembler.withoutSkillTokens(userText, skillNames),
    ].join('\n');

    // ② 世界书触发附件(常驻条目除外)。
    final triggered = assembler.matchTriggered(state.worldbook, matchText);
    for (final e in triggered) {
      final ref = AttachmentRef.worldbook(e.id ?? -1).value;
      if (e.id == null || injectedRefs.contains(ref)) continue;
      final name = e.name.trim().isNotEmpty
          ? e.name
          : e.keys.where((k) => k.isNotEmpty).take(2).join('、');
      if (injectedWorldbookNames.contains(name)) continue;
      candidates.add(
        AttachmentCandidate(
          origin: AttachmentOrigin.worldbook,
          refId: ref,
          content: ContextAssembler.worldbookAttachment(name, e.content),
        ),
      );
    }

    // ③ 单轮预算筛选后按序落库(豁免项在前:技能 → 世界书)。
    final maxAuto = ref.read(appSettingsProvider).maxAutoAttachments;
    for (final c in selectWithinBudget(candidates, maxAuto)) {
      await messageRepo.append(
        sessionId: sessionId,
        role: 'user',
        content: c.content,
        kind: MessageKind.attachment,
        refId: c.refId,
      );
    }
  }

  /// 重新发送用户消息(UI 气泡"重新发送",与助手气泡的"重新生成"对偶)。
  ///
  /// 剪掉该消息及其之后的所有消息(历史回滚到它之前),再把同样的文本作为新
  /// 输入走一遍与普通发送完全相同的管线(beforeContextAssembly 改写 → 落库
  /// 用户消息 → 组装+hooks+流式+后台维护)。
  Future<void> resend(int userMessageId) async {
    if (state.streaming || _busy) return;
    final sessionId = state.sessionId;
    if (sessionId == null || state.character == null) return;
    if (ref.read(backendProvider) == null) return;

    // 原文取自内存列表(剪断之前);找不到或为空则无事可做。
    final original = state.messages
        .where((m) => m.id == userMessageId)
        .firstOrNull;
    final text = original?.content ?? '';
    if (text.trim().isEmpty) return;

    _busy = true;
    try {
      _invalidateBackground();
      await ref.read(messageRepositoryProvider).deleteFrom(userMessageId);
      if (!ref.mounted) return;
      final messages = await ref
          .read(messageRepositoryProvider)
          .bySessionSince(sessionId, sinceSeq: _windowFloor);
      if (!ref.mounted) return;
      state = state.copyWith(messages: messages);
      await _sendPipeline(text);
    } finally {
      _busy = false;
    }
  }

  /// 组装当前会话上下文 → 跑各阶段 hook → 流式生成 → 落库回复 → 后台维护。
  /// [send] 追加用户消息后调用;重新生成同样走这里。不含 beforeContextAssembly
  /// (那是用户输入改写,只属于普通发送)。
  Future<void> _generateReply() async {
    final sessionId = state.sessionId;
    final characterId = state.characterId;
    final character = state.character;
    final backend = ref.read(backendProvider);
    if (sessionId == null || character == null || backend == null) return;

    // 本轮的中断令牌(EF 批换发语义):入口换新实例并捕获,本轮全部的取消
    // 判定/唤醒通道都走这个局部引用 —— 后台轮或下一轮主写换发不影响在飞的
    // 本轮,上一轮遗留的取消也绝不会泄漏到本轮。
    _mainToken = InterruptToken();
    final token = _mainToken;

    final messageRepo = ref.read(messageRepositoryProvider);
    final config = ref.read(backendConfigProvider);
    if (config == null) return;

    try {
      // 组装窗口:全部未折叠活跃行(组装不再按条数裁剪)。
      var messages = await messageRepo.activeWindow(sessionId);
      if (!ref.mounted) return;

      // DG 批:通知(压缩/记忆差异)已由调用方(_sendPipeline/_appendAndGenerate/
      // regenerate)落库为附件行,随历史自然进数组,此处不再合成插入。
      var snapshot = await _assembleSnapshot(messages);
      if (snapshot == null || !ref.mounted) return;

      // 硬挡预算检测(API 发送前):估算输入 + 输出预留超容量×80% 时先压缩
      // 再发 —— LLM 摘要压回目标挡(失败 1+3 次),仍超标机械截断兜底。
      // 压缩发生时:记忆冻结副本已被刷新,压缩通知落库为附件行再重组装
      // (压缩发生在本次用户输入的管线内,当轮即"压缩后的第一次用户输入");
      // 行落库在用户消息之后,组装期位置校正把它挪到用户行之前。
      final enforced = await _enforceHardBudget(
        sessionId: sessionId,
        messages: messages,
        snapshot: snapshot,
        token: token,
      );
      if (!ref.mounted) return;
      if (enforced != null) {
        if (enforced.compacted) {
          _compactNoticePending = true;
          await _persistPendingNotices(sessionId);
          messages = await messageRepo.activeWindow(sessionId);
          final rebuilt = await _assembleSnapshot(messages);
          if (rebuilt != null && ref.mounted) snapshot = rebuilt;
        } else {
          messages = enforced.messages;
          snapshot = enforced.snapshot;
        }
      }

      // 硬挡压缩期间用户按了停止:本轮发送就此中止(用户消息已落库保留,
      // 不再发起生成 —— 与流式中断的语义一致)。
      if (token.cancelled) {
        if (ref.mounted) state = state.copyWith(messages: await _fetchCurrentWindow(sessionId));
        return;
      }

      // afterContextAssembly may rewrite the system prompt before the request.
      final afterAssembly = await _runHooks(
        HookTriggerPoint.afterContextAssembly,
        {'systemPrompt': snapshot.systemPrompt},
      );
      final effectivePrompt = afterAssembly['systemPrompt'] is String
          ? afterAssembly['systemPrompt'] as String
          : snapshot.systemPrompt;

      // beforeGenerate: 请求发出前最后一次改写机会 —— systemPrompt / 参数
      // (temperature / maxTokens)读写回并应用到请求。
      final beforeGenerate = await _runHooks(HookTriggerPoint.beforeGenerate, {
        'systemPrompt': effectivePrompt,
        'temperature': config.temperature,
        'maxTokens': config.maxTokens,
      });
      final finalPrompt = beforeGenerate['systemPrompt'] is String
          ? beforeGenerate['systemPrompt'] as String
          : effectivePrompt;
      final temperature = beforeGenerate['temperature'] is num
          ? (beforeGenerate['temperature'] as num).toDouble()
          : config.temperature;
      final maxTokens = beforeGenerate['maxTokens'] is num
          ? (beforeGenerate['maxTokens'] as num).toInt()
          : config.maxTokens;

      // 缓存分段透传:仅当 hook 未改写 system prompt 时才传组装器的稳定分段
      // (hook 改写后分段边界不再可靠,传 null 让 Anthropic 后端回退到纯字符串
      // system 格式)。CW 批起可变内容(附件/通知)都在 messages 数组内,不再有
      // system 尾部旁路;末条消息锚 cache_control 断点,稳定前缀
      // (system + 记忆第 0 条 + 历史)整体命中缓存。
      final promptRewritten = finalPrompt != snapshot.systemPrompt;
      final request = LlmRequest(
        model: config.model,
        systemPrompt: finalPrompt,
        messages: snapshot.messages,
        temperature: temperature,
        maxTokens: maxTokens,
        // 推理等级(对话输入框选择器里设置,随 AppSettings 持久化)。
        reasoningLevel: ref.read(appSettingsProvider).reasoningLevel,
        // 请求稳定前缀提示缓存:配合组装器"静态段在前"的重排,轮次间命中缓存区。
        cacheContext: true,
        stableSystemPart: promptRewritten ? null : snapshot.stableSystemPrompt,
      );

      // 记录本次请求实际发出的上下文(系统提示词取 hook 改写后的最终版),
      // 供上下文面板实时展示;分段来源沿用组装结果(含结构化 segments,
      // 否则面板在每轮发送后只剩 segmentSources、segments 为空会变得空白)。
      // 稳定前缀与稳定哈希沿用组装结果(而非改写后的 finalPrompt —— 后者可能被
      // hook 改动,不代表真实缓存分段的稳定区),供面板判断"稳定前缀是否变化"。
      final sentContext = ContextSnapshot(
        systemPrompt: finalPrompt,
        messages: snapshot.messages,
        segmentSources: snapshot.segmentSources,
        segments: snapshot.segments,
        stableSystemPrompt: snapshot.stableSystemPrompt,
        stableSystemHash: snapshot.stableSystemHash,
      );

      _setDraft('');
      state = state.copyWith(
        messages: messages,
        streaming: true,
        error: null,
        fallbackModelHint: null,
        lastContext: sentContext,
        prevStableSystemHash: state.lastContext?.stableSystemHash,
      );
      _fallbackTarget = null;

      final buffer = StringBuffer();
      var inTok = 0, outTok = 0, cachedTok = 0;
      Timer? throttleTimer;
      var lastFlushMs = 0;
      const throttleIntervalMs = 40; // 约 25FPS 节流刷新,兼顾视觉平滑度并避免高频渲染导致移动端卡顿
      // 本轮失败的稳定分类(备用模型建议判据,P1 契约层)。
      UpstreamErrorKind? failureKind;

      void flushDraft() {
        if (!ref.mounted || token.cancelled) return;
        // 只写独立 draft provider,不再触碰 ChatState —— 这是流式期间唯一的
        // 高频写,拆出后整页 watch 不会被拖着重建(EF 批)。
        _setDraft(buffer.toString());
        lastFlushMs = DateTime.now().millisecondsSinceEpoch;
      }

      void onTextDelta(String text) {
        buffer.write(text);
        final now = DateTime.now().millisecondsSinceEpoch;
        final elapsed = now - lastFlushMs;
        if (elapsed >= throttleIntervalMs) {
          throttleTimer?.cancel();
          throttleTimer = null;
          flushDraft();
        } else {
          throttleTimer ??= Timer(
            Duration(milliseconds: throttleIntervalMs - elapsed),
            () {
              throttleTimer = null;
              flushDraft();
            },
          );
        }
      }

      try {
        // 流完成/出错 与 中断令牌 竞速:模型思考迟迟不吐首块时(加载期零事件),
        // 旧实现的 `await for` 只能等下一个事件到达才轮询到 cancelled —— 按
        // 停止毫无反应。这里 Future.any 让令牌即时唤醒等待,sub.cancel() 随即
        // 关闭底层 HTTP 连接,不必等服务端慢慢吐出首块。
        final finished = Completer<void>();
        final sub = ChatEngine(backend)
            .generate(snapshot, request)
            .listen(
              (event) {
                if (token.cancelled) return; // 用户中断:丢弃剩余事件。
                switch (event) {
                  case TextDelta(:final text):
                    onTextDelta(text);
                  case UsageEvent(:final usage):
                    inTok += usage.inputTokens;
                    outTok += usage.outputTokens;
                    cachedTok += usage.cachedInputTokens;
                  case ErrorEvent(:final message, :final kind):
                    throttleTimer?.cancel();
                    throttleTimer = null;
                    failureKind ??= kind;
                    state = state.copyWith(error: message);
                  case DoneEvent():
                    break;
                }
              },
              onError: (Object e) {
                throttleTimer?.cancel();
                throttleTimer = null;
                // 传输层异常(断网/DNS/TLS):与 SSE ErrorEvent 一样落到 state.error
                // 由灵岛展示。此前这里只暂存异常再上抛,而 send/_sendPipeline/
                // _generateReply 全链路无 catch —— 用户看不到任何提示(打字指示器
                // 无声消失),还成为未捕获异步异常。
                if (ref.mounted && state.error == null) {
                  state = state.copyWith(error: '网络错误:$e');
                }
                finished.complete();
              },
              onDone: () {
                throttleTimer?.cancel();
                throttleTimer = null;
                flushDraft();
                finished.complete();
              },
              cancelOnError: true,
            );
        await Future.any([finished.future, token.whenCancelled]);
        throttleTimer?.cancel();
        throttleTimer = null;
        if (!token.cancelled) {
          flushDraft();
        }
        // 取消订阅但**不等待其完成**:后端流是 async* 生成器,零事件期正停在
        // `await client.send()`(首字节未到)—— Dart 的取消 Future 要等生成器
        // 本体收敛才算完,await 它会把"打断"拖回"等请求自然结束"(streaming
        // 一直为 true,表现为按停止毫无反应)。这里取消只作善后(停止事件
        // 投递、流进入回收),UI 状态立即往下走。
        unawaited(sub.cancel());
        // 传输层错误已在 onError 写入 state.error,不再上抛(上层无 catch,
        // 裸抛 = 无提示 + unhandled exception);buffer 里的部分草稿继续走
        // 正常的 hook/落库流程 —— 已生成的内容不因断网丢失。
      } finally {
        throttleTimer?.cancel();
        throttleTimer = null;
        if (ref.mounted) state = state.copyWith(streaming: false);
      }
      if (!ref.mounted) return;

      // 契约漂移预警(P2):连续 ≥3 轮以 contractViolation 失败 → 上游协议
      // 疑似变更,错误横幅加导语(保留最后一轮原文供排查);成功一轮或其它
      // 类别失败即复位 —— 预警不该在无关错误上误触发。被中断的轮次不计。
      if (!token.cancelled) {
        if (failureKind == UpstreamErrorKind.contractViolation) {
          _contractViolationStreak++;
          if (_contractViolationStreak >= ChatControllerBase._contractDriftThreshold && ref.mounted) {
            state = state.copyWith(
              error: '【契约漂移预警】连续 $_contractViolationStreak 轮契约不符,上游协议疑似变更。'
                  '最后一轮错误:${state.error ?? ''}',
              contractDriftWarning: true,
            );
          }
        } else {
          _contractViolationStreak = 0;
          if (ref.mounted && state.contractDriftWarning) {
            state = state.copyWith(contractDriftWarning: false);
          }
        }
      }

      // 生成失败的备用模型建议(P1 契约层):流结束后按失败分类决定是否在
      // 错误横幅挂「切换备用模型」一键动作。被中断的轮次不提供建议。
      if (!token.cancelled && failureKind != null) {
        await _offerFallbackModel(failureKind!);
      }

      // 主写被中断:已生成的部分文本照样落库(不想保留可由用户自行删除),
      // 仍不压缩、不跑后台维护;零事件就停的空草稿不产生空回复。
      if (token.cancelled) {
        _setDraft('');
        var finalText = buffer.toString();
        if (finalText.trim().isNotEmpty) {
          final afterStream = await _runHooks(HookTriggerPoint.afterStream, {
            'text': finalText,
          });
          if (afterStream['text'] is String) {
            finalText = afterStream['text'] as String;
          }
          final beforePersist = await _runHooks(HookTriggerPoint.beforePersist, {
            'text': finalText,
          });
          if (beforePersist['text'] is String) {
            finalText = beforePersist['text'] as String;
          }
          if (finalText.trim().isNotEmpty) {
            await messageRepo.append(
              sessionId: sessionId,
              role: 'assistant',
              content: finalText,
            );
            messages = await messageRepo.bySessionSince(
              sessionId,
              sinceSeq: _windowFloor,
            );
          }
        }
        // 后台状态归后台轮自己收敛(并发在飞时它可能正写 interrupted),
        // 主写收尾只刷新消息列表,不越权覆盖。
        state = state.copyWith(messages: messages);
        return;
      }

      // afterStream may rewrite the buffered reply text (regex replace/filter).
      var finalText = buffer.toString();
      final afterStream = await _runHooks(HookTriggerPoint.afterStream, {
        'text': finalText,
      });
      if (afterStream['text'] is String) {
        finalText = afterStream['text'] as String;
      }

      // beforePersist may rewrite the text one last time before it is stored.
      final beforePersist = await _runHooks(HookTriggerPoint.beforePersist, {
        'text': finalText,
      });
      if (beforePersist['text'] is String) {
        finalText = beforePersist['text'] as String;
      }

      Message? persistedReply;
      if (finalText.isNotEmpty) {
        persistedReply = await messageRepo.append(
          sessionId: sessionId,
          role: 'assistant',
          content: finalText,
        );
        // 软挡自动压缩(按上下文占用率):回复落库后重算占用,达 60% 软挡即把
        // 活跃历史压回 20% 目标挡(摘要失败重试 3 次);best-effort 不掉轮。
        await _autoCompactIfDue(
          sessionId: sessionId,
          model: config.model,
          token: token,
        );
      }

      // Refresh state BEFORE background work so the reply + token stats render
      // immediately, without waiting on the background LLM call.
      // 窗口刷新(DV 批):回复落库后按当前窗口下界取回,而非全量重读。
      messages = await messageRepo.bySessionSince(
        sessionId,
        sinceSeq: _windowFloor,
      );
      _setDraft('');
      // 真实输入锚点重锚:inTok 即本轮主写请求(as-sent)的服务端精确计数。
      // 网关本轮未上报(0)时**整组沿用上一次已知的真实快照** —— 上下文规模与
      // 上轮几乎一致,清零只会让圆环退回字符估算(÷3.2,比已知实数更不准),还会
      // 把会话行持久化的锚点冲掉、重进会话后再也拿不回来。
      final hasUsage = inTok > 0;
      state = state.copyWith(
        messages: messages,
        inputTokens: hasUsage ? inTok : state.inputTokens,
        outputTokens: hasUsage ? outTok : state.outputTokens,
        cachedInputTokens: hasUsage ? cachedTok : state.cachedInputTokens,
        lastSentInputTokens: hasUsage ? inTok : state.lastSentInputTokens,
      );

      // Background maintenance: best-effort, only after a reply was produced.
      // Its token usage is accounted separately from the main write (spec §6).
      // 与主回复解耦:这里只同步置 running 并触发,后台轮在独立 future 中运行,
      // _generateReply 立即返回、_busy 随之释放 —— 用户可马上发送下一条消息,
      // 不再被后台 LLM 调用(生图时最长 5 分钟)挂住。
      if (characterId == null || finalText.isEmpty) {
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.skipped,
          backgroundSummary: '无有效回复,后台维护被跳过',
        );
      } else if (!ref.read(backgroundEnabledProvider)) {
        // 后台agent 被全局关闭:本轮直接标记已禁用,跳过 LLM 状态维护。
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.disabled,
          backgroundSummary: '后台agent 已关闭,未自动维护状态',
        );
      } else {
        final features = ref.read(backgroundFeaturesProvider);
        if (!features.anyEnabled) {
          // 后台agent 开启但所有子功能都被关掉 → 无内容可维护,等价跳过。
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.disabled,
            backgroundSummary: '后台agent 未选中任何维护功能',
          );
        } else {
          state = state.copyWith(backgroundStatus: BackgroundStatus.running);
          _fireBackgroundMaintenance(persistedReply!.seq);
        }
      }
      // 每轮生成收尾后把累计的 token 用量持久化,重启/重进会话后上下文面板
      // 仍能恢复这些数值。用量记账是附加信息,落库失败不影响本轮回复。
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
    } finally {
      _busy = false;
    }
  }
}
