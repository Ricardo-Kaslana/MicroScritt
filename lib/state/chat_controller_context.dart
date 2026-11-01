// 上下文组装与通知:快照组装、Hook 运行、记忆冻结副本与差异通知、
// 待发通知落库为附件行、记忆应用到上下文。
part of 'chat_controller.dart';

/// 上下文组装与通知:组装快照/Hook 运行/记忆冻结副本与差异通知/附件通知落库/记忆应用。
abstract class ChatControllerContext extends ChatControllerBase {
  /// 对 [ctx] 运行 [point] 触发点上已启用的 Hook,返回可能被改写后的上下文。
  /// 未配置运行时或没有 Hook 时原样返回;始终注入当前用户名 `userName`,
  /// 供默认 `{{user}}` 替换等 Hook 引用。Hook 内部失败绝不让整轮发送失败。
  Future<Map<String, dynamic>> _runHooks(
    HookTriggerPoint point,
    Map<String, dynamic> ctx,
  ) async {
    final runtime = ref.read(hookRuntimeProvider);
    if (runtime == null) return ctx;
    try {
      final hooks = await ref
          .read(hookRepositoryProvider)
          .byTriggerPoint(point);
      if (hooks.isEmpty) return ctx;
      return HookEngine(runtime).run(
        point: point,
        hooks: hooks,
        context: {...ctx, 'userName': ref.read(userProfileProvider).name},
      );
    } catch (_) {
      return ctx; // Hook 失败绝不能拖垮本轮发送
    }
  }

  /// 用当前会话的设定(角色卡/提示词项/世界书)组装上下文快照。
  /// [load] 以外的全部组装点([_generateReply]/[_reassembleContext]/预算检测/
  /// 软挡自动压缩)共用同一把组装尺子,保证估算与真实请求一致。
  /// 会话未加载(sessionId/character 缺失)时返回 null。
  ///
  /// 变量不参与主写组装(只进后台 agent 上下文);技能不进组装,只有 @技能名
  /// 主动触发的附件行(已落库在 history 里);记忆经 [_frozenMemory] 冻结副本
  /// 以"第 0 条消息"进数组。通知(压缩/记忆差异)同样落库为附件行随历史进数组。
  /// 历史对话行里的 @技能名 记号在此剥离:转录保留原话,只在 LLM 边界出口剥,
  /// 面板分段不受影响。
  Future<ContextSnapshot?> _assembleSnapshot(List<Message> history) async {
    final sessionId = state.sessionId;
    final characterId = state.characterId;
    final character = state.character;
    if (sessionId == null || characterId == null || character == null) return null;
    return ContextAssembler().assemble(
      character: character,
      items: await _assemblyPromptItems(),
      history: history,
      worldbook: state.worldbook,
      frozenMemory: _frozenMemory,
      stripSkillNames: await enabledSkillNames(),
    );
  }

  /// 组装用的提示词条目:启用条目全集。
  Future<List<PromptItem>> _assemblyPromptItems() async {
    return ref.read(promptItemRepositoryProvider).allEnabled();
  }

  /// 当前启用中的技能名集合(LLM 边界剥离 @记号用;组装/压缩/后台共用)。
  Future<Set<String>> enabledSkillNames() async {
    final skills = await ref.read(skillRepositoryProvider).allEnabled();
    return {
      for (final s in skills)
        if (s.name.trim().isNotEmpty) s.name.trim(),
    };
  }

  /// 当前在用模型的上下文容量(token)。与上下文圆环同源(active provider 的
  /// activeModel)。
  ///
  /// 容量未配置(≤0,如历史空值)时**不再整体跳过**占用率逻辑,而是
  /// 退回 [ContextBudgetPolicy.fallbackCapacity] —— 组装不做条数裁剪,跳过就等于
  /// 没有任何保护,长会话会一路涨到上游报错。用户补填真实容量后自动改用真值。
  /// 只有读取本身失败(异常)才返回 null。
  ///
  /// 直接读仓库而非 `llmProvidersProvider.future`:后者是首个被命令式读取的
  /// 场景,在 widget 测试的 FakeAsync 区会悬挂(其创建 future 不受 runAsync
  /// 窗口驱动);仓库调用与发送管线内其余 DB 读完全同构,无此问题。
  Future<int?> _resolveContextCapacity() async {
    try {
      final providers = await ref.read(llmProviderRepositoryProvider).all();
      final model = providers.where((p) => p.isActive).firstOrNull?.activeModel;
      final capacity = model?.contextCapacity ?? 0;
      return capacity > 0 ? capacity : ContextBudgetPolicy.fallbackCapacity;
    } catch (_) {
      return null;
    }
  }

  /// 压缩/折叠后刷新记忆冻结副本(压缩点本就是缓存断点,顺带把"第 0 条"记忆
  /// 换成库中最新版;diff 通知基准同步重置)。
  Future<void> _refreshFrozenMemory(int sessionId) async {
    final rows = await ref.read(memoryRepositoryProvider).bySession(sessionId);
    _frozenMemory = rows.isEmpty ? null : rows.first.content;
    _memoryDiffNotifiedHash = null;
    if (ref.mounted) {
      state = state.copyWith(frozenMemory: _frozenMemory);
    }
  }

  /// 记忆修改差异通知(冻结语义的另一半):库中记忆与 [_frozenMemory] 不同、
  /// 且该库中版本尚未通知过时,返回 diff 内容与版本哈希;第 0 条消息**保持
  /// 旧字节不动**,差异只经通知送达 —— 直到压缩触发或用户主动刷新
  /// ([applyMemoryToContext])才整体换新。
  ///
  /// 通知落库为附件行:去重账本 [_memoryDiffNotifiedHash] 由调用方
  /// ([_persistPendingNotices])在**落库成功后**置位,DB 写入失败时不吞通知;
  /// 库内容再次变化则下次输入再通知。
  Future<({int hash, String content})?> _memoryDiffNotice(int sessionId) async {
    final rows = await ref.read(memoryRepositoryProvider).bySession(sessionId);
    final latest = rows.isEmpty ? '' : rows.first.content;
    final frozen = _frozenMemory ?? '';
    if (latest == frozen) return null;
    if (frozen.isEmpty) {
      // 上下文里尚无记忆(首次初始化后第一次发送):直接采纳为冻结副本 ——
      // 第 0 条消息从无到有本就是一次性的前缀变化,无缓存可保护,不必走 diff。
      _frozenMemory = latest.isEmpty ? null : latest;
      _memoryDiffNotifiedHash = null;
      if (ref.mounted) {
        state = state.copyWith(frozenMemory: _frozenMemory);
      }
      return null;
    }
    final hash = latest.hashCode;
    if (hash == _memoryDiffNotifiedHash) return null; // 该版本已通知过
    // 行集合差:新增 = 新版本有而冻结副本没有的行;删除反之。记忆是逐行事实,
    // 集合差足够表达"哪些事实变了",且对行序重排不误报。
    final oldLines = frozen
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final newLines = latest
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final added = newLines.difference(oldLines).toList();
    final removed = oldLines.difference(newLines).toList();
    if (added.isEmpty && removed.isEmpty) return null; // 只有空白/行序差异,不值得通知
    return (
      hash: hash,
      content: ContextAssembler.memoryDiffNotice(added, removed),
    );
  }

  /// 消费待发通知并落库为附件行(替代原合成插入的统一收口)。
  ///
  /// 压缩通知消费 [_compactNoticePending] 标志(ref 含发生时刻,每次压缩唯一);
  /// 记忆差异经 [_memoryDiffNotice] 判定(ref 含版本哈希),去重账本在落库
  /// **成功后**置位。调用点:_sendPipeline/_appendAndGenerate 在落用户消息
  /// **前**(通知天然排在用户输入之前);regenerate 与硬挡中途压缩在其后
  /// (组装期由位置校正挪到最新用户行之前,字节对齐旧合成位置)。
  Future<void> _persistPendingNotices(int sessionId) async {
    final messageRepo = ref.read(messageRepositoryProvider);
    if (_compactNoticePending) {
      _compactNoticePending = false;
      await messageRepo.append(
        sessionId: sessionId,
        role: 'user',
        content: ContextAssembler.compactNoticeText,
        kind: MessageKind.attachment,
        refId: AttachmentRef.noticeCompact(
          DateTime.now().millisecondsSinceEpoch,
        ).value,
      );
    }
    final diff = await _memoryDiffNotice(sessionId);
    if (diff != null) {
      await messageRepo.append(
        sessionId: sessionId,
        role: 'user',
        content: diff.content,
        kind: MessageKind.attachment,
        refId: AttachmentRef.noticeMemoryDiff(diff.hash).value,
      );
      _memoryDiffNotifiedHash = diff.hash;
    }
  }

  /// 用户主动把库中最新记忆应用到上下文(状态面板「应用到上下文」按钮):
  /// 刷新冻结副本并重算上下文快照。下一次请求的第 0 条消息即换为新记忆 ——
  /// 与压缩后刷新同语义,是会话中途更换冻结副本的两个合法时机之一。
  Future<void> applyMemoryToContext() async {
    final sessionId = state.sessionId;
    if (sessionId == null) return;
    await _refreshFrozenMemory(sessionId);
    // 换第 0 条记忆对整体规模的改动有限,保留上轮真实锚点(圆环不退回估算);
    // 快照照常重算,上下文面板与下一次请求保持一致。
    await _reassembleContext();
  }

  /// 用当前会话状态重新组装一次上下文快照并写入 `lastContext`。
  /// [load]/[send]/[/compact] 之后让上下文面板与真实请求保持一致。
  ///
  /// 组装输入取 `MessageRepository.activeWindow`(全部未折叠活跃行),而**不是**
  /// `state.messages` —— 后者是 UI 显示窗口,会被分页游标下移;共用它会让
  /// "用户翻阅历史"改变发给 LLM 的上下文(显示/组装窗口刻意分离)。
  Future<void> _reassembleContext() async {
    final sessionId = state.sessionId;
    if (sessionId == null) return;
    final history = await ref.read(messageRepositoryProvider).activeWindow(sessionId);
    final snapshot = await _assembleSnapshot(history);
    if (snapshot == null || !ref.mounted) return;
    state = state.copyWith(
      lastContext: snapshot,
      prevStableSystemHash: state.lastContext?.stableSystemHash,
    );
  }

  /// 公开的上下文重算入口:当记忆等在聊天页外(如状态面板)被增删改后,
  /// 调用它让上下文面板(`lastContext`)立即反映最新内容,而不必等下一轮发送。
  /// 会话尚未加载(character/session 缺失)时是安全的 no-op。
  Future<void> refreshContext() async {
    await _syncWorldbook();
    await _reassembleContext();
  }

  /// 把 ChatState 的世界书快照与库对齐。
  ///
  /// 世界书可以在聊天页外被改。**真正会踩中的路径是状态面板** —— 它是从聊天页
  /// `push` 进去的,pop 回来 `ChatScreen` 不重建(`initState` 不再跑),而面板里
  /// 就有「后台世界书锚定」的 `replaceForCharacter`;那个入口只
  /// `invalidate(worldbookProvider)`,那是 UI 用的只读视图。**引擎读的是
  /// ChatState 里的快照,只在 `load` 时刷新**,于是改完要等重进会话才生效。
  ///
  /// (世界书页走的是「角色列表 → 世界书」,不经过聊天页;回来时会重新 push
  /// `ChatScreen` 并重新 load,那条路径本就没问题。这里同时兜住未来新增的
  /// 「从聊天页 push 出去、又能改世界书」的入口。)
  ///
  /// 发送前与 `refreshContext` 各调一次,成本是一次几十行的库读。
  Future<void> _syncWorldbook() async {
    final characterId = state.characterId;
    if (characterId == null) return;
    final entries = await ref.read(worldbookRepositoryProvider).byCharacter(characterId);
    if (!ref.mounted) return;
    state = state.copyWith(worldbook: entries);
  }
}
