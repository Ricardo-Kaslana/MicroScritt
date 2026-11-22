/// 聊天页会话入口:搜索定位、角色编辑、导出/删除、侧栏动作与切会话。
///
/// 同库 part 扩展共享 ChatScreen 的导航与控制器引用。

part of '../chat_screen.dart';

extension _ChatScreenSessionOps on _ChatScreenState {
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
          characterAvatarHash: _avatarHash,
          initialQuery: _lastSearchQuery,
          onQueryChanged: (query) => _lastSearchQuery = query,
        ),
      ),
    );
    if (messageId == null || !mounted) return;
    // 与桌面导航点击走同一条链路:扩窗 → 定位 → 锚点锁定 → 短暂高亮。
    // 重复实现两遍曾让搜索路径缺掉定位态与锚点锁定(高亮在落定瞬间指错)。
    await _jumpToUserMessage(messageId);
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
    _rebuild(() => _character = card);
    await _loadVisuals();
    if (!mounted) return;
    if (ref.read(chatControllerProvider).sessionId == widget.sessionId) {
      await ref.read(chatControllerProvider.notifier).updateCharacter(card);
    }
  }

  /// 导出会话为 v5 归档:桌面端直接选路径并流式写出,移动端先写临时文件再
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
      fileName: '$title.msarc',
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
      showAppSnack(context, '置顶状态更新失败:$e');
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
      showAppSnack(context, '会话标题不能为空');
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

  /// 侧栏「新建会话」:与角色页新建同口径 —— 仅单条开场白自动落库;
  /// 多条开场白留空会话,由用户在空态选择。刷新侧栏数据后进入新会话。
  Future<void> _createSessionFor(CharacterRecord character) async {
    try {
      final id = await ref
          .read(sessionRepositoryProvider)
          .createWithDefaultTitle(character.id);
      if (!character.card.hasMultipleGreetings &&
          character.card.firstMessage.isNotEmpty) {
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
      showAppSnack(context, '新建会话失败:$e');
    }
  }
}
