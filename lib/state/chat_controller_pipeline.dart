// 发送主流程:忙碌门控、附件展开与落库、硬挡/软挡压缩、流式生成与回复落库、
// 中断收尾、重发/重生成与消息增删改。
part of 'chat_controller.dart';

/// 发送主流程:trySend 忙碌门控/发送管线与附件展开/硬挡与软挡压缩/回复生成/重发·重生成/消息增删改。
abstract class ChatControllerPipeline extends ChatControllerBackground {
  /// 发送前硬挡预算检测(硬挡 = max(80%, 用户触发线 + 5%))。
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
    RewriteContext? rewrite,
  }) async {
    // 硬挡检测恒开:总开关只控制「LLM 摘要压缩」,超预算时的机械截断兜底
    // 必须始终可用,否则请求会原样发出等上游 400。
    final autoEnabled = ref.read(appSettingsProvider).autoCompactEnabled;
    final threshold = ref.read(appSettingsProvider).autoCompactThreshold;
    final epoch = _sessionEpoch;
    final capacity = await _resolveContextCapacity();
    if (capacity == null || !_ownsMain(sessionId, epoch)) return null;
    final backend = ref.read(backendProvider);
    final config = ref.read(backendConfigProvider);
    if (backend == null || config == null || !ref.mounted) return null;

    int estimateOf(ContextSnapshot s) => estimateRequestTokens(
      systemPrompt: s.systemPrompt,
      messages: s.messages,
    );

    final reserve =
        config.maxTokens ?? ContextBudgetPolicy.defaultOutputReserveTokens;
    final hardBudget = (capacity * ContextBudgetPolicy.hardFor(threshold))
        .floor();
    if (estimateOf(snapshot) + reserve <= hardBudget) return null;

    // 重写提醒是单轮临时注入、无法被压缩折叠;把它当作固定段从压缩预算里
    // 预扣,避免规划时把它挤出去后又超出硬挡。
    final rewriteTokens = rewrite == null
        ? 0
        : estimateTokensFromChars(
            ContextAssembler.rewriteReminder(
              rewrite.instruction,
              rewrite.previousReply,
            ).length,
          );

    var current = snapshot;
    var currentMessages = messages;
    var compacted = false;
    // 记忆冻结副本在本次硬挡里只需刷一次:① 摘要压缩成功后刷新;若后续
    // 又走机械折叠,记忆内容并未再变,不必重复读库。
    var memoryRefreshed = false;
    final messageRepo = ref.read(messageRepositoryProvider);
    final service = CompactService(backend, messageRepo);

    // ① LLM 摘要压缩到目标挡:保留条数按"目标占用 − 摘要预留"规划,
    //    压缩后重载消息并重新组装快照再判定(新摘要成为消息数组首条合成消息)。
    final activeBefore = _activeRows(currentMessages);
    final targetHistoryBudget =
        (capacity * ContextBudgetPolicy.target).floor() -
        ContextBudgetPolicy.summaryReserveTokens -
        rewriteTokens;
    final keepForTarget = planKeepWithinBudgetWithAttachments(
      active: activeBefore,
      budgetTokens: targetHistoryBudget,
    );
    final chatBefore = activeBefore.where((m) => m.isChat).length;
    if (autoEnabled && keepForTarget < chatBefore) {
      // 压缩期间灵岛进入「压缩中」活动态、发送键可中断(摘要请求响应取消
      // 信号 —— 此刻流式尚未开始,不设防时用户没有任何停止入口)。
      if (_ownsMain(sessionId, epoch)) {
        state = state.copyWith(busyCommand: 'compact');
      }
      try {
        final done = await service.compact(
          sessionId: sessionId,
          model: config.model,
          temperature: config.temperature,
          keep: keepForTarget,
          maxSummarizeAttempts: 4, // 首次 + 3 次失败重试
          onUsage: (usage) => _accumulateCompactUsage(
            usage,
            sessionId: sessionId,
            epoch: epoch,
          ),
          cancelSignal: token.whenCancelled,
        );
        compacted = compacted || done;
      } catch (_) {
        // 压缩 best-effort;摘要彻底失败时走下方机械截断兜底。
      } finally {
        if (_ownsMain(sessionId, epoch)) {
          state = state.copyWith(busyCommand: null);
        }
      }
      if (!_ownsMain(sessionId, epoch)) return null;
      if (compacted) {
        await _refreshFrozenMemory(sessionId);
        memoryRefreshed = true;
      }
      // 组装窗口:全部未折叠活跃行(组装不再按条数裁剪,见 activeWindow)。
      final fresh = await messageRepo.activeWindow(sessionId);
      final rebuilt = await _assembleSnapshot(fresh, rewrite: rewrite);
      if (rebuilt != null && _ownsMain(sessionId, epoch)) {
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
      final active = _activeRows(currentMessages);
      final fixedEstimate = estimateTokensFromChars(
        current.systemPrompt.length +
            (current.leadingSummaryContent?.length ?? 0) +
            (current.leadingMemoryContent?.length ?? 0) +
            (rewrite == null
                ? 0
                : ContextAssembler.rewriteReminder(
                    rewrite.instruction,
                    rewrite.previousReply,
                  ).length),
      );
      final allowance = hardBudget - reserve - fixedEstimate;
      final keepToFit = planKeepWithinBudgetWithAttachments(
        active: active,
        budgetTokens: allowance,
      );
      if (keepToFit < active.where((m) => m.isChat).length) {
        try {
          final done = await service.foldToFit(
            sessionId: sessionId,
            keep: keepToFit,
          );
          compacted = compacted || done;
        } catch (_) {
          // 兜底也失败(极端 I/O 异常):原样发送,交由服务端报错。
        }
        if (!_ownsMain(sessionId, epoch)) return null;
        if (compacted && !memoryRefreshed) {
          await _refreshFrozenMemory(sessionId);
          memoryRefreshed = true;
        }
        final fresh = await messageRepo.activeWindow(sessionId);
        final rebuilt = await _assembleSnapshot(fresh, rewrite: rewrite);
        if (rebuilt != null && _ownsMain(sessionId, epoch)) {
          current = rebuilt;
          currentMessages = fresh;
        }
      }
    }

    if (!compacted) return null;
    return (messages: currentMessages, snapshot: current, compacted: true);
  }

  /// 回复落库后的软挡自动压缩(触发线来自 `AppSettings.autoCompactThreshold`,
  /// 默认 60%;[ContextBudgetPolicy.target] = 20%)。
  ///
  /// 触发依据是**上下文窗口占用量**(估算输入 / 模型容量),不再是掉窗消息
  /// 条数;压缩后占用回落到目标挡,与触发线之间形成自然滞回防抖。
  /// 摘要失败共 1+3 次尝试,全部失败时静默放弃 —— 下一轮占用仍超软挡会自然
  /// 再试。best-effort:不阻塞回复展示,失败不影响已落库的回复。总开关关闭
  /// 或模型无容量信息时跳过。
  ///
  /// 压缩成功后立即落库压缩通知(压缩后的第一次组装)并刷新记忆冻结副本;
  /// 失败经 [ChatState.notice] 一次性闪示,不再完全静默。
  Future<void> _autoCompactIfDue({
    required int sessionId,
    required String model,
    required InterruptToken token,
  }) async {
    if (!ref.read(appSettingsProvider).autoCompactEnabled) return;
    final threshold = ref.read(appSettingsProvider).autoCompactThreshold;
    final epoch = _sessionEpoch;
    if (!_ownsMain(sessionId, epoch)) return;
    final capacity = await _resolveContextCapacity();
    if (capacity == null || !_ownsMain(sessionId, epoch)) return;
    final backend = ref.read(backendProvider);
    final config = ref.read(backendConfigProvider);
    if (backend == null || config == null) return;

    final messageRepo = ref.read(messageRepositoryProvider);
    // 组装窗口:占用估算必须用与发送同一份输入(全部未折叠活跃行)。
    final messages = await messageRepo.activeWindow(sessionId);
    if (!_ownsMain(sessionId, epoch)) return;
    final snapshot = await _assembleSnapshot(messages);
    if (snapshot == null || !_ownsMain(sessionId, epoch)) return;

    final estimated = estimateRequestTokens(
      systemPrompt: snapshot.systemPrompt,
      messages: snapshot.messages,
    );
    if (budgetLevelFor(
          estimated / capacity,
          soft: threshold,
          hard: ContextBudgetPolicy.hardFor(threshold),
        ) ==
        ContextBudgetLevel.ok) {
      return;
    }

    final active = _activeRows(messages);
    final targetHistoryBudget =
        (capacity * ContextBudgetPolicy.target).floor() -
        ContextBudgetPolicy.summaryReserveTokens;
    final keep = planKeepWithinBudgetWithAttachments(
      active: active,
      budgetTokens: targetHistoryBudget,
    );
    if (keep >= active.where((m) => m.isChat).length) {
      return; // 高占用来自系统段而非历史,压无可压
    }

    // 回复已落库后的软挡压缩:同样进入「压缩中」活动态并响应停止
    // (此刻主写流已结束,停止键本不可用 —— 置 busyCommand 让它重新可用)。
    if (_ownsMain(sessionId, epoch)) {
      state = state.copyWith(busyCommand: 'compact');
    }
    try {
      final done = await CompactService(backend, messageRepo).compact(
        sessionId: sessionId,
        model: model,
        temperature: config.temperature,
        keep: keep,
        maxSummarizeAttempts: 4, // 首次 + 3 次失败重试
        onUsage: (usage) =>
            _accumulateCompactUsage(usage, sessionId: sessionId, epoch: epoch),
        stripSkillNames: await enabledSkillNames(),
        cancelSignal: token.whenCancelled,
      );
      if (done) {
        // 立即落库压缩通知:通知属于压缩后的第一次组装,等到下一次用户输入
        // 再发会在切换会话时丢失(`load` 会清空待发标志)。
        try {
          await _persistCompactNotice(sessionId);
        } catch (_) {
          // 通知是辅助信息:写入失败不影响已完成的摘要压缩。
        }
        await _refreshFrozenMemory(sessionId);
        _invalidateSessionList();
        // 面板快照跟上:软挡压缩发生在 `lastContext: sentContext` 赋值**之后**,
        // 不重算的话面板会一直停在压缩前的快照上 —— 继续显示那些刚被折叠、
        // 已不再进上下文的旧附件行,与实际发送内容对不上。硬挡路径没有这个
        // 问题(压缩在快照赋值之前完成)。
        await _reassembleContext();
      } else if (!token.cancelled) {
        // 摘要重试耗尽(或无可压产出)且用户没有主动中断:让失败可见,
        // 不再像旧实现那样完全静默。
        if (_ownsMain(sessionId, epoch)) {
          state = state.copyWith(notice: '自动上下文压缩未完成:历史保持原样,后续仍会尝试');
        }
      }
    } catch (_) {
      // 自动压缩是 best-effort:失败不落库、不掉轮。但不能完全静默 ——
      // 用户需要知道这次没有压成(经 ChatState.notice 一次性闪示)。
      if (_ownsMain(sessionId, epoch)) {
        state = state.copyWith(notice: '自动上下文压缩失败:历史保持原样,后续仍会尝试');
      }
    } finally {
      if (_ownsMain(sessionId, epoch)) {
        state = state.copyWith(busyCommand: null);
      }
    }
  }

  /// 删除单条消息(UI 长按删除)并刷新当前消息列表;返回恢复快照供撤销,
  /// 被拒绝(生成中)或行已不存在时返回 null。
  Future<DeletedMessageSnapshot?> deleteMessage(int messageId) async {
    final sessionId = state.sessionId;
    if (sessionId == null || state.streaming || _busy) return null;
    _invalidateBackground();
    final snapshot = await ref
        .read(messageRepositoryProvider)
        .deleteWithSnapshot(messageId);
    // 删一条消息对整体上下文的改动通常远小于字符估算的误差(÷3.2),上轮真实
    // 计数仍是最准的锚点 —— 保留它,不让圆环退回估算。
    await _reloadWindow(sessionId);
    return snapshot;
  }

  /// 撤销 [deleteMessage]:把快照写回库并刷新列表。会话已切换/生成中时
  /// 拒绝,避免把旧会话的消息写进当前视图。
  Future<void> restoreMessage(DeletedMessageSnapshot snapshot) async {
    if (state.streaming || _busy || state.sessionId != snapshot.sessionId) {
      return;
    }
    _invalidateBackground();
    await ref.read(messageRepositoryProvider).restoreDeleted(snapshot);
    await _reloadWindow(snapshot.sessionId);
  }

  /// 批量删除当前会话的选中消息;返回撤销快照,忙碌或会话未就绪时返回 null。
  Future<List<DeletedMessageSnapshot>?> deleteMessages(Set<int> ids) async {
    final sessionId = state.sessionId;
    if (state.streaming || _busy || sessionId == null || ids.isEmpty) {
      return null;
    }
    _invalidateBackground();
    final snapshots = await ref
        .read(messageRepositoryProvider)
        .deleteManyWithSnapshots(sessionId, ids);
    await _reloadWindow(sessionId);
    return snapshots;
  }

  /// 撤销批量删除;会话已切换/生成中时拒绝,避免恢复进错误的会话。
  Future<void> restoreMessages(List<DeletedMessageSnapshot> snapshots) async {
    if (snapshots.isEmpty) return;
    if (state.streaming ||
        _busy ||
        snapshots.any((s) => s.sessionId != state.sessionId)) {
      return;
    }
    _invalidateBackground();
    await ref.read(messageRepositoryProvider).restoreManyDeleted(snapshots);
    await _reloadWindow(snapshots.first.sessionId);
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
    final sessionId = state.sessionId;
    if (sessionId == null || state.streaming || _busy) return;
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
    await _reloadWindow(sessionId);
  }

  /// 按落库的原始描述重新生成某条消息的图片并原地替换。
  /// 返回 null 表示成功;非空字符串是可展示的失败原因。同一时刻只允许一张,
  /// 失败/取消一律保留旧图。
  Future<String?> regenerateImage(int messageId) async {
    final sessionId = state.sessionId;
    if (sessionId == null) return '尚未加载会话';
    if (state.regeneratingImageId != null) return '正在重新生成另一张图片,请稍候';
    final repo = ref.read(messageRepositoryProvider);
    final storedPrompt = await repo.imagePromptFor(messageId);
    if (!ref.mounted || state.sessionId != sessionId) return null;
    final promptForGeneration = storedPrompt?.trim() ?? '';
    if (promptForGeneration.isEmpty) return '这张图片没有可用的原始描述,无法重新生成';
    return _generateAndReplaceImage(
      messageId: messageId,
      expectedPrompt: storedPrompt!,
      promptForGeneration: promptForGeneration,
    );
  }

  /// 按用户确认的新描述只重绘一张图片并原地替换(后台单图提示词改写的第二步)。
  ///
  /// [expectedPrompt] 必须是生成建议时读到的旧描述原文:期间旧描述被改/图被删
  /// 时条件更新失败,不覆盖另一条已变化的图片。成功后 `image_prompt` 与新图一起
  /// 落库,并同步 [_lastMaintenanceImages],让之后 `/rerun` 仍按同一行替换。
  Future<String?> regenerateImageWithPrompt(
    int messageId, {
    required String newPrompt,
    required String expectedPrompt,
  }) async {
    final sessionId = state.sessionId;
    if (sessionId == null) return '尚未加载会话';
    if (state.regeneratingImageId != null) return '正在重新生成另一张图片,请稍候';
    if (_backgroundInFlight || _backgroundImageTask != null) {
      return '后台维护正在运行,请稍候再重绘';
    }
    if (newPrompt.trim().isEmpty) return '新的图片描述不能为空';
    if (ref.read(imageBackendProvider) == null) return '尚未配置生图服务';
    final repo = ref.read(messageRepositoryProvider);
    final storedPrompt = await repo.imagePromptFor(messageId);
    if (!ref.mounted || state.sessionId != sessionId) return null;
    if (storedPrompt == null || storedPrompt.trim().isEmpty) {
      return '这张图片没有可用的原始描述,无法重新生成';
    }
    if (storedPrompt != expectedPrompt) {
      return '图片描述已被修改,请重新生成新的描述';
    }
    final prompt = newPrompt.trim();
    final error = await _generateAndReplaceImage(
      messageId: messageId,
      expectedPrompt: expectedPrompt,
      promptForGeneration: prompt,
      newImagePrompt: prompt,
    );
    if (error == null) {
      _updateLastMaintenanceImagePrompt(messageId, prompt);
      // 仅在建议摘要仍是最新状态时收尾;期间后台维护已写过摘要则不覆盖。
      if (state.backgroundStatus == BackgroundStatus.succeeded &&
          state.backgroundSummary == _kImagePromptReadySummary) {
        state = state.copyWith(backgroundSummary: '图片已按要求重新生成');
      }
    }
    return error;
  }

  /// 单张图片生成并原地替换的共享实现(原样重绘 / 按新描述重绘共用)。
  /// 调用方负责目标校验与并发门控;本方法自行置位/清理 [regeneratingImageId],
  /// 失败一律保留旧图与旧描述。
  Future<String?> _generateAndReplaceImage({
    required int messageId,
    required String expectedPrompt,
    required String promptForGeneration,
    String? newImagePrompt,
  }) async {
    final sessionId = state.sessionId;
    if (sessionId == null) return '尚未加载会话';
    final backend = ref.read(imageBackendProvider);
    if (backend == null) return '尚未配置生图服务';
    final repo = ref.read(messageRepositoryProvider);
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
      final url = image.url;
      String? imageHash;
      try {
        final bytes = image.base64 != null
            ? safeBase64Decode(image.base64)
            : url != null
            ? await downloadImageBytes(url)
            : null;
        if (image.base64 != null && bytes == null) {
          return '重新生成失败:图片数据无效';
        }
        if (bytes != null) {
          // URL 来源保留原字节,否则按哈希修复时重新下载的原图永远对不上;
          // base64 无再取路径,可按设置压缩。
          imageHash = (await repo.db.images.putBytes(
            bytes,
            compress: image.base64 != null,
          )).hash;
        }
      } catch (e) {
        return '重新生成失败:${_imageFailureText(e)}';
      }
      if (!ref.mounted ||
          state.sessionId != sessionId ||
          _sessionEpoch != sessionEpoch) {
        return null;
      }
      if (imageHash == null && (url == null || url.isEmpty)) {
        return '未能生成新图片,请稍后重试';
      }
      final replaced = await repo.replaceImage(
        messageId,
        imageHash: imageHash,
        imageUrl: url,
        expectedPrompt: expectedPrompt,
        newImagePrompt: newImagePrompt,
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

  /// 单图描述被人工改写后同步 `/rerun` 的替换目标:只更新已记录的那一行,
  /// 不凭空新增目标。列表不可变,重建后整表替换。
  void _updateLastMaintenanceImagePrompt(int messageId, String prompt) {
    var found = false;
    final updated = <BackgroundImagePlacement>[];
    for (final entry in _lastMaintenanceImages) {
      if (entry.messageId == messageId) {
        found = true;
        updated.add((
          messageId: entry.messageId,
          prompt: prompt,
          replaced: entry.replaced,
        ));
      } else {
        updated.add(entry);
      }
    }
    if (found) _lastMaintenanceImages = List.unmodifiable(updated);
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
      final epoch = _sessionEpoch;
      await ref.read(messageRepositoryProvider).deleteFrom(assistantMessageId);
      if (!_ownsMain(sessionId, epoch)) return;
      final messages = await _reloadWindow(sessionId);
      if (messages == null) return;
      if (messages.isEmpty || messages.last.role != 'user') {
        // 没有可回应的用户消息(例如被剪到了空/只剩助手),刷新后退出。
        return;
      }
      // 剪断后消费待发通知;行落库在最后一条用户消息之后,组装期位置校正
      // 把它挪到该用户消息之前(字节对齐旧合成位置)。
      await _persistPendingNotices(sessionId);
      if (!_ownsMain(sessionId, epoch)) return;
      await _generateReply(sessionId: sessionId, epoch: epoch);
    } finally {
      _busy = false;
    }
  }

  /// 带修改要求重写最新一条助手回复(UI 长按/操作排「按要求重写」)。
  ///
  /// 与 [regenerate] 共用"剪断尾巴 + 重走生成管线",区别是把被替换的旧稿与
  /// 用户修改要求作为 [RewriteContext] 只注入当次请求:不落库,后续轮次看不到。
  /// 目标是最新一条有正文的助手回复([latestRewritableAssistantReply]):
  /// 其后允许跟后台生图落库的图片消息,随重写一并剪掉;但更后面绝不能还有
  /// 用户消息或其他有正文回复 —— 剪断会连带删掉它们。
  ///
  /// 返回 null 表示已受理(生成结果照常落库);非空字符串是失败原因,由 UI
  /// 经灵动岛提示。
  Future<String?> rewrite(int assistantMessageId, String instruction) async {
    if (state.streaming || _busy) return '正在处理中,请稍候';
    final requirement = instruction.trim();
    if (requirement.isEmpty) return '修改要求不能为空';
    final sessionId = state.sessionId;
    if (sessionId == null || state.character == null) return '尚未加载会话';
    if (ref.read(backendProvider) == null) return '尚未配置 LLM 服务';

    final target = state.messages
        .where((m) => m.id == assistantMessageId)
        .firstOrNull;
    if (target == null ||
        !target.isChat ||
        target.role != 'assistant' ||
        target.content.trim().isEmpty) {
      return '这条回复没有可重写的正文';
    }
    if (latestRewritableAssistantReply(state.messages)?.id !=
        assistantMessageId) {
      return '只能按要求重写最新一条 AI 回复';
    }

    _busy = true;
    try {
      _invalidateBackground();
      final epoch = _sessionEpoch;
      await ref.read(messageRepositoryProvider).deleteFrom(assistantMessageId);
      if (!_ownsMain(sessionId, epoch)) return null;
      final messages = await _reloadWindow(sessionId);
      if (messages == null) return null;
      // 通知落库在剪断之后:组装期位置校正会把它们挪到最新用户行之前。
      await _persistPendingNotices(sessionId);
      if (!_ownsMain(sessionId, epoch)) return null;
      await _generateReply(
        rewrite: RewriteContext(
          instruction: requirement,
          previousReply: target.content,
        ),
        sessionId: sessionId,
        epoch: epoch,
      );
      return null;
    } finally {
      _busy = false;
    }
  }

  /// 清除错误横幅(UI 关闭按钮)。备用模型建议与契约漂移预警同属错误横幅
  /// 内容,一并清除,连击计数归零。
  void clearError() {
    _contractViolationStreak = 0;
    state = state.copyWith(
      error: null,
      fallbackModelHint: null,
      contractDriftWarning: false,
    );
  }

  /// 生成失败后的备用模型建议:错误属于"换模型可能有用"的三类
  /// (contentFlag/quota/gatewayPolicy —— 风控拦截/额度不足/网关策略)且当前
  /// provider 目录还有其它模型时,记下切换目标并把展示名挂到错误横幅;
  /// 其余错误(transient 已由后端透明重试、auth 换模型无意义)不提供建议。
  Future<void> _offerFallbackModel(
    UpstreamErrorKind kind, {
    int? sessionId,
    int? epoch,
  }) async {
    const eligible = {
      UpstreamErrorKind.contentFlag,
      UpstreamErrorKind.quota,
      UpstreamErrorKind.gatewayPolicy,
    };
    if (!eligible.contains(kind)) return;
    final providers = await ref.read(llmProvidersProvider.future);
    final owns =
        sessionId == null || _ownsMain(sessionId, epoch ?? _sessionEpoch);
    if (!owns) return;
    final active = providers.where((p) => p.isActive).toList();
    if (active.isEmpty) return;
    final provider = active.first;
    final currentModel = ref.read(backendConfigProvider)?.model;
    final fallback = provider.models
        .where((m) => m.modelId != currentModel)
        .toList();
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
    state = state.copyWith(
      error: null,
      fallbackModelHint: null,
      contractDriftWarning: false,
    );
  }

  /// 追加一条用户消息并走完整生成管线(测试生成 / 推动剧情共用)。
  /// [userText] 同样过 `beforeContextAssembly`:/test /continue 注入的消息
  /// 也遵循"用户输入 → beforeContextAssembly → 组装管线"的数据流,输入改写
  /// 在所有入口一致生效(改写后的文本才落库与进上下文)。
  Future<bool> _appendAndGenerate(String userText) async {
    final sessionId = state.sessionId;
    if (sessionId == null || state.character == null) return false;
    if (ref.read(backendProvider) == null ||
        ref.read(backendConfigProvider) == null) {
      return false;
    }

    _busy = true;
    try {
      final epoch = _sessionEpoch;
      // 世界书同步:与 _sendPipeline 同款(见 _syncWorldbook)。
      await _syncWorldbook();
      if (!_ownsMain(sessionId, epoch)) return false;
      final beforeCtx = await _runHooks(
        HookTriggerPoint.beforeContextAssembly,
        {'userText': userText},
      );
      if (!_ownsMain(sessionId, epoch)) return false;
      final rewritten = beforeCtx['userText'] is String
          ? beforeCtx['userText'] as String
          : userText;
      if (rewritten.trim().isEmpty) return false; // hook 清空了消息 → 本轮无事可做
      // 该路径不经 _sendPipeline,待发通知同样在此消费落库,
      // 避免滞留到下一次用户发送。
      await _persistPendingNotices(sessionId);
      if (!_ownsMain(sessionId, epoch)) return false;
      await _persistPendingVariableInjection(sessionId);
      await ref
          .read(messageRepositoryProvider)
          .append(sessionId: sessionId, role: 'user', content: rewritten);
      await _refreshMessages();
      if (!_ownsMain(sessionId, epoch)) return true;
      await _generateReply(sessionId: sessionId, epoch: epoch);
      return true;
    } finally {
      _busy = false;
    }
  }

  /// 同步发送门:接受返回 true(UI 据此清空输入框);正忙(流式/生图/压缩
  /// 进行中)返回 false 并给出可见提示 —— 此前 send 直接静默 return,而 UI
  /// 已先清空输入,用户打的内容凭空消失、无任何提示。
  bool trySend(String text) {
    if (state.streaming || _busy || state.busyCommand != null) {
      state = state.copyWith(error: '正在处理中(生成/生图/压缩进行时),请稍候或按停止中断');
      return false;
    }
    if (state.regeneratingImageId != null) {
      state = state.copyWith(error: '正在重新生成图片,请稍候');
      return false;
    }
    if (state.sessionId == null ||
        state.character == null ||
        ref.read(backendProvider) == null) {
      // 装载窗口或后端缺失:此前返回 true 会让 UI 清空输入,而管线直接空跑。
      state = state.copyWith(error: '会话尚未加载完成或未配置 LLM,消息未发送');
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

  /// 异步发送入口(与 [trySend] 对偶,不返回是否受理):正忙时静默返回,
  /// 未预期异常落到错误横幅。正常 UI 路径用 [trySend] 以保留输入框内容。
  Future<void> send(String text) async {
    if (state.streaming ||
        _busy ||
        state.busyCommand != null ||
        state.regeneratingImageId != null) {
      return;
    }
    if (state.sessionId == null ||
        state.character == null ||
        ref.read(backendProvider) == null) {
      return;
    }
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
  /// (数据流:用户输入 → beforeContextAssembly → 组装管线)。
  /// 随后计算本轮附件(@技能/世界书触发,去重记账)并**先于用户消息**落库
  /// —— 附件行的 seq 因此天然位于它所属的用户消息之前,组装无需重排;
  /// 最后追加用户消息并生成回复。@技能名 记号只在附件里展开:实际落库的
  /// 用户消息保留原话,请求出口再统一剥离触发记号。
  Future<void> _sendPipeline(
    String text, {
    int? expectedSessionId,
    int? expectedEpoch,
  }) async {
    final sessionId = state.sessionId;
    final epoch = _sessionEpoch;
    if (expectedSessionId != null &&
        (sessionId != expectedSessionId || epoch != expectedEpoch)) {
      return;
    }
    final backend = ref.read(backendProvider);
    if (sessionId == null || state.character == null || backend == null) return;
    final windowFloor = _windowFloor;

    // 世界书可能刚在聊天页外被改(世界书页/状态面板):引擎读的是 ChatState 里的
    // 快照,不重读的话启停/内容/删除都要等重进会话才生效。发送前对齐一次。
    await _syncWorldbook();
    if (!_ownsMain(sessionId, epoch)) return;

    final messageRepo = ref.read(messageRepositoryProvider);
    final beforeCtx = await _runHooks(HookTriggerPoint.beforeContextAssembly, {
      'userText': text,
    });
    if (!_ownsMain(sessionId, epoch)) return;
    final userText = beforeCtx['userText'] is String
        ? beforeCtx['userText'] as String
        : text;
    if (userText.trim().isEmpty) return; // hook 清空了消息 → 本轮无事可做

    // attachments:@技能提及 + 世界书触发命中,按"窗口内是否已注入"
    // 去重后逐条落库(append-only)。落库顺序在用户消息之前 → 组装时位于
    // 用户实际输入之前,用户输入始终是请求的最后一条消息。
    // 待发通知(压缩/记忆差异)也先落库为附件行,同样位于用户消息之前。
    await _persistPendingNotices(sessionId);
    if (!_ownsMain(sessionId, epoch)) return;
    await _appendSessionAttachments(sessionId, userText);
    // 后落库的变量注入行紧贴用户消息:附件段末尾、用户输入之前。
    await _persistPendingVariableInjection(sessionId);

    // 用户消息**原样落库**(含 @技能名 记号):气泡/编辑所见即所得;记号在
    // 组装请求的出口统一剥离(见 _assembleSnapshot 的 stripSkillNames)。
    await messageRepo.append(
      sessionId: sessionId,
      role: 'user',
      content: userText,
    );
    // 窗口刷新(含刚落的附件行与用户消息),而非全量重读。窗口下界取本轮
    // 发起时的值:切会话后 `_windowFloor` 已属于新会话。
    final refreshed = await messageRepo.bySessionSince(
      sessionId,
      sinceSeq: windowFloor,
    );
    if (!_ownsMain(sessionId, epoch)) return;
    state = state.copyWith(messages: refreshed);
    await _generateReply(sessionId: sessionId, epoch: epoch);
  }

  /// 计算并落库本轮附件行(@技能 / 世界书触发):
  ///
  /// 用户消息本体**原样落库**(含 @记号,剥离在组装出口);
  /// 世界书键匹配基于剥离后的文本 —— 记号是调用语法,不参与键匹配。
  ///
  /// 1. **@技能**:用户输入里出现 `@技能名`(启用中的技能)才注入 —— 有且仅有
  ///    主动触发,技能不再常驻 system;
  /// 2. **世界书触发**:对"窗口内对话文本 + 即将发送的用户输入"做键匹配,
  ///    常驻条目不在此列(它们始终在 system 稳定段);
  /// 3. **去重记账**:窗口内已有同 ref 的附件行则跳过 —— 触发型世界书命中
  ///    频率高,不去重会导致同一条目反复注入、请求越滚越大;被压缩/裁剪挤出
  ///    窗口后(行不在窗口里)重新注入合法;世界书另按条目**名**去重,挡住
  ///    同一条目因历史编辑留下多个 refId 的存量旧行;
  /// 4. **单轮预算与优先级**:候选经 [selectWithinBudget] 筛选 —— 技能(用户
  ///    主动)豁免名额全收,世界书触发占名额、超出全局限额
  ///    (`AppSettings.maxAutoAttachments`)按命中顺序丢弃尾部。通知附件
  ///    不在此处(系统事件,由 [_persistPendingNotices] 落库,同样豁免)。
  Future<void> _appendSessionAttachments(int sessionId, String userText) async {
    final assembler = ContextAssembler();
    // 去重集合:当前窗口内已出现的附件 ref(用与组装同一把窗口尺子)。
    // 窗口下界覆盖全部未折叠活跃行,所以这里的行集与组装所见完全一致 ——
    // 账本口径与发送内容口径不再有偏差。
    final history = await ref
        .read(messageRepositoryProvider)
        .activeWindow(sessionId);
    final windowed = ContextAssembler.activeRows(history);
    final injectedRefs = windowed
        .where((m) => !m.isChat)
        .map((m) => m.refId)
        .whereType<String>()
        .toSet();
    // 世界书条目按**名**去重:refId 含数据库 id,而历史编辑让同一条目留下过
    // 多个 refId —— 只按 refId 比对挡不住存量旧行,条目会再注入一遍。名字取自
    // 附件行文本(与组装侧收敛同一判据)。
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
    // 名字去重只对"唯一名字"生效:两条不同条目同名(或都无名字且前两个键
    // 相同)时,按名字跳过会让后者被永久排除;此时退回只按 refId 去重。
    final nameCounts = <String, int>{};
    for (final e in state.worldbook) {
      final name = e.name.trim().isNotEmpty
          ? e.name
          : e.keys.where((k) => k.isNotEmpty).take(2).join('、');
      nameCounts.update(name, (v) => v + 1, ifAbsent: () => 1);
    }
    for (final e in triggered) {
      final ref = AttachmentRef.worldbook(e.id ?? -1).value;
      if (e.id == null || injectedRefs.contains(ref)) continue;
      final name = e.name.trim().isNotEmpty
          ? e.name
          : e.keys.where((k) => k.isNotEmpty).take(2).join('、');
      if ((nameCounts[name] ?? 0) <= 1 &&
          injectedWorldbookNames.contains(name)) {
        continue;
      }
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
      final epoch = _sessionEpoch;
      await ref.read(messageRepositoryProvider).deleteFrom(userMessageId);
      if (!_ownsMain(sessionId, epoch)) return;
      await _reloadWindow(sessionId);
      await _sendPipeline(
        text,
        expectedSessionId: sessionId,
        expectedEpoch: epoch,
      );
    } finally {
      _busy = false;
    }
  }

  /// 组装当前会话上下文 → 跑各阶段 hook → 流式生成 → 落库回复 → 后台维护。
  /// [send] 追加用户消息后调用;重新生成同样走这里。不含 beforeContextAssembly
  /// (那是用户输入改写,只属于普通发送)。
  /// [rewrite] 非空时是"按要求重写最新回复":旧稿与要求只注入当次快照,
  /// 不落库、不随历史进入后续轮次。
  Future<void> _generateReply({
    RewriteContext? rewrite,
    required int sessionId,
    required int epoch,
  }) async {
    if (!_ownsMain(sessionId, epoch)) return;
    final characterId = state.characterId;
    final character = state.character;
    final backend = ref.read(backendProvider);
    if (character == null || backend == null) return;

    // 本轮的中断令牌:入口换新实例并捕获,本轮全部的取消判定/唤醒通道都走
    // 这个局部引用 —— 后台轮或下一轮主写换发不影响在飞的本轮,上一轮遗留的
    // 取消也绝不会泄漏到本轮。
    _mainToken = InterruptToken();
    final token = _mainToken;
    // 本轮归属:会话/代次未变且令牌仍是本轮实例时才允许写 UI 状态、压缩、
    // 触发后台与持久化会话级汇总。数据库写入始终使用捕获的 sessionId。
    bool owns() => _ownsMain(sessionId, epoch) && identical(_mainToken, token);
    // 显示窗口下界属于发起会话:切会话后 load 会重置它,收尾不能再拿新下界
    // 去读旧会话。
    final windowFloor = _windowFloor;

    final messageRepo = ref.read(messageRepositoryProvider);
    final config = ref.read(backendConfigProvider);
    if (config == null) {
      if (owns()) {
        state = state.copyWith(error: '尚未配置 LLM 模型,本轮未生成回复');
      }
      return;
    }

    try {
      // 组装窗口:全部未折叠活跃行(组装不再按条数裁剪)。
      var messages = await messageRepo.activeWindow(sessionId);
      if (!owns()) return;

      // 通知(压缩/记忆差异)已由调用方(_sendPipeline/_appendAndGenerate/
      // regenerate)落库为附件行,随历史自然进数组,此处不再合成插入。
      var snapshot = await _assembleSnapshot(messages, rewrite: rewrite);
      if (snapshot == null || !owns()) return;

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
        rewrite: rewrite,
      );
      if (!owns()) return;
      if (enforced != null) {
        if (enforced.compacted) {
          _compactNoticePending = true;
          await _persistPendingNotices(sessionId);
          messages = await messageRepo.activeWindow(sessionId);
          final rebuilt = await _assembleSnapshot(messages, rewrite: rewrite);
          if (rebuilt != null && owns()) snapshot = rebuilt;
        } else {
          messages = enforced.messages;
          snapshot = enforced.snapshot;
        }
      }

      // 硬挡压缩期间用户按了停止:本轮发送就此中止(用户消息已落库保留,
      // 不再发起生成 —— 与流式中断的语义一致)。
      if (token.cancelled) {
        if (owns()) {
          state = state.copyWith(
            messages: await messageRepo.bySessionSince(
              sessionId,
              sinceSeq: windowFloor,
            ),
          );
        }
        return;
      }

      // afterContextAssembly:请求发出前可改写 system prompt。
      final afterAssembly = await _runHooks(
        HookTriggerPoint.afterContextAssembly,
        {'systemPrompt': snapshot.systemPrompt},
      );
      if (!owns()) return;
      final effectivePrompt = afterAssembly['systemPrompt'] is String
          ? afterAssembly['systemPrompt'] as String
          : snapshot.systemPrompt;

      // beforeGenerate:请求发出前最后一次改写机会 —— systemPrompt / 参数
      // (temperature / maxTokens)读写回并应用到请求。
      final beforeGenerate = await _runHooks(HookTriggerPoint.beforeGenerate, {
        'systemPrompt': effectivePrompt,
        'temperature': config.temperature,
        'maxTokens': config.maxTokens,
      });
      if (!owns()) return;
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
      // system 格式)。可变内容(附件/通知)都在 messages 数组内,没有 system
      // 尾部旁路;末条消息锚 cache_control 断点,稳定前缀
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
      if (!owns()) return;
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
      // 本轮失败的稳定分类(备用模型建议判据)。
      UpstreamErrorKind? failureKind;

      void flushDraft() {
        if (!owns() || token.cancelled) return;
        // 只写独立 draft provider,不再触碰 ChatState —— 这是流式期间唯一的
        // 高频写,拆出后整页 watch 不会被拖着重建。
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
                    if (owns()) state = state.copyWith(error: message);
                  case ToolCallsEvent():
                    break; // 主写无工具消费方(tools 恒空),忽略。
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
                if (owns() && state.error == null) {
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
        if (owns()) state = state.copyWith(streaming: false);
      }
      if (!owns()) return;

      // 契约漂移预警:连续 ≥3 轮以 contractViolation 失败 → 上游协议
      // 疑似变更,错误横幅加导语(保留最后一轮原文供排查);成功一轮或其它
      // 类别失败即复位 —— 预警不该在无关错误上误触发。被中断的轮次不计。
      if (!token.cancelled) {
        if (failureKind == UpstreamErrorKind.contractViolation) {
          _contractViolationStreak++;
          if (_contractViolationStreak >=
                  ChatControllerBase._contractDriftThreshold &&
              ref.mounted) {
            state = state.copyWith(
              error:
                  '【契约漂移预警】连续 $_contractViolationStreak 轮契约不符,上游协议疑似变更。'
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

      // 生成失败的备用模型建议:流结束后按失败分类决定是否在
      // 错误横幅挂「切换备用模型」一键动作。被中断的轮次不提供建议。
      if (!token.cancelled && failureKind != null) {
        await _offerFallbackModel(
          failureKind!,
          sessionId: sessionId,
          epoch: epoch,
        );
      }

      // 主写被中断:已生成的部分文本照样落库(不想保留可由用户自行删除),
      // 仍不压缩、不跑后台维护;零事件就停的空草稿不产生空回复。
      if (token.cancelled) {
        if (owns()) _setDraft('');
        var finalText = buffer.toString();
        if (finalText.trim().isNotEmpty) {
          final afterStream = await _runHooks(HookTriggerPoint.afterStream, {
            'text': finalText,
          });
          if (afterStream['text'] is String) {
            finalText = afterStream['text'] as String;
          }
          final beforePersist = await _runHooks(
            HookTriggerPoint.beforePersist,
            {'text': finalText},
          );
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
              sinceSeq: windowFloor,
            );
          }
        }
        // 后台状态归后台轮自己收敛(并发在飞时它可能正写 interrupted),
        // 主写收尾只刷新消息列表,不越权覆盖。
        // 被中断的请求同样消耗了上游计算:按已到达的用量记账(reported 为
        // false 时只计请求次数),不因中断丢账。
        final usage = TokenUsage(
          inputTokens: inTok,
          outputTokens: outTok,
          cachedInputTokens: cachedTok,
        );
        await _recordUsage(
          sessionId: sessionId,
          kind: UsageKind.main,
          config: config,
          usage: usage,
          reported: usage.hasAny,
        );
        if (owns()) state = state.copyWith(messages: messages);
        return;
      }

      // afterStream 可在落库前改写缓冲的回复文本(正则替换/过滤)。
      var finalText = buffer.toString();
      final afterStream = await _runHooks(HookTriggerPoint.afterStream, {
        'text': finalText,
      });
      if (afterStream['text'] is String) {
        finalText = afterStream['text'] as String;
      }

      // beforePersist 是落库前最后一次文本改写机会。
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
        if (owns()) {
          await _autoCompactIfDue(
            sessionId: sessionId,
            model: config.model,
            token: token,
          );
        }
      }

      // 先刷新消息与 token 统计再触发后台维护:回复立即可见,不等待后台 LLM。
      // 窗口刷新:回复落库后按当前窗口下界取回,而非全量重读。
      messages = await messageRepo.bySessionSince(
        sessionId,
        sinceSeq: windowFloor,
      );
      // 真实输入锚点重锚:inTok 即本轮主写请求(as-sent)的服务端精确计数。
      // 网关本轮未上报(0)时**整组沿用上一次已知的真实快照** —— 上下文规模与
      // 上轮几乎一致,清零只会让圆环退回字符估算(÷3.2,比已知实数更不准),还会
      // 把会话行持久化的锚点冲掉、重进会话后再也拿不回来。
      final hasUsage = inTok > 0;
      // 逐请求统计:记录本轮主写实际消耗(与下方会话级"最近一轮快照"分离)。
      final requestUsage = TokenUsage(
        inputTokens: inTok,
        outputTokens: outTok,
        cachedInputTokens: cachedTok,
      );
      await _recordUsage(
        sessionId: sessionId,
        kind: UsageKind.main,
        config: config,
        usage: requestUsage,
        reported: requestUsage.hasAny,
      );
      // 会话已切换:本轮回复已写入发起会话的库(不会丢),但 UI 状态、软挡
      // 压缩、后台维护与代次相关记账一律不能落到新会话上。
      if (!owns()) return;
      _setDraft('');
      state = state.copyWith(
        messages: messages,
        inputTokens: hasUsage ? inTok : state.inputTokens,
        outputTokens: hasUsage ? outTok : state.outputTokens,
        cachedInputTokens: hasUsage ? cachedTok : state.cachedInputTokens,
        lastSentInputTokens: hasUsage ? inTok : state.lastSentInputTokens,
      );

      // 后台维护:best-effort,仅在产出回复后执行;其 token 用量单独记账。
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
          backgroundSummary: '后台引擎已关闭,未自动维护状态',
        );
      } else {
        final features = ref.read(backgroundFeaturesProvider);
        if (!features.anyEnabled) {
          // 后台agent 开启但所有子功能都被关掉 → 无内容可维护,等价跳过。
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.disabled,
            backgroundSummary: '后台引擎未选中任何维护功能',
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
