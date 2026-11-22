/// 聊天页消息操作:多选批量栏、长按菜单、图片下载/重绘、编辑与重写。
///
/// 同库 part 扩展共享 ChatScreen 的选择状态与灵动岛通知中枢。

part of '../chat_screen.dart';

extension _ChatScreenMessageOps on _ChatScreenState {
  /// 进入消息多选模式;[seed] 为长按菜单触发时预选的那一条。
  void _enterSelectionMode({Message? seed}) {
    final chat = ref.read(chatControllerProvider);
    if (chat.streaming || chat.busyCommand != null) {
      showAppSnack(context, '生成或命令执行中,暂不能多选消息');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _messageActionsOpen.value = false;
    final seedId = seed?.id;
    _selectedMessageIds.value = seedId == null ? const {} : {seedId};
    if (!_selectionMode) _rebuild(() => _selectionMode = true);
    // 页面级焦点接管 Esc/键盘;勾选回执由轻触觉反馈。
    _selectionFocus.requestFocus();
    HapticFeedback.selectionClick();
  }

  void _exitSelectionMode() {
    if (!_selectionMode) return;
    HapticFeedback.selectionClick();
    _selectionFocus.unfocus();
    _rebuild(() => _selectionMode = false);
    _selectedMessageIds.value = const {};
    if (_desktopPlatform) _inputFocus.requestFocus();
  }

  /// 当前已加载到列表、可参与多选的可见消息(与 MessageList 的显示口径一致)。
  List<Message> _loadedVisibleMessages() => [
    for (final message in ref.read(chatControllerProvider).messages)
      if (message.role != 'system' && message.isChat && message.id != null)
        message,
  ];

  void _selectAllMessages() {
    _selectedMessageIds.value = {
      for (final message in _loadedVisibleMessages()) message.id!,
    };
  }

  void _clearMessageSelection() {
    if (_selectedMessageIds.value.isEmpty) return;
    HapticFeedback.selectionClick();
    _selectedMessageIds.value = const {};
  }

  void _selectImageMessages() {
    _selectedMessageIds.value = {
      for (final message in _loadedVisibleMessages())
        if (message.hasVisualImage) message.id!,
    };
  }

  void _selectTextMessages() {
    _selectedMessageIds.value = {
      for (final message in _loadedVisibleMessages())
        if (!message.hasVisualImage) message.id!,
    };
  }

  void _toggleMessageSelection(int id) {
    final next = Set<int>.of(_selectedMessageIds.value);
    if (!next.add(id)) next.remove(id);
    _selectedMessageIds.value = next;
    HapticFeedback.selectionClick();
  }

  /// 删除选中消息:确认后走控制器批量删除,退出多选并给一次撤销入口。
  Future<void> _deleteSelectedMessages() async {
    final ids = Set<int>.of(_selectedMessageIds.value);
    if (ids.isEmpty) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除 ${ids.length} 条消息?',
      message: '删除后可在提示条中撤销。',
    );
    if (!confirmed || !mounted) return;
    final snapshots = await ref
        .read(chatControllerProvider.notifier)
        .deleteMessages(ids);
    if (!mounted) return;
    if (snapshots == null || snapshots.isEmpty) {
      showAppSnack(context, '当前无法删除消息');
      return;
    }
    _exitSelectionMode();
    // SnackBar 走应用级 ScaffoldMessenger,页面可能在提示条存活期间退出;
    // 先捕获 notifier,避免撤销回调在已销毁的 ConsumerState.ref 上执行。
    final controller = ref.read(chatControllerProvider.notifier);
    showAppSnack(
      context,
      '已删除 ${snapshots.length} 条消息',
      action: SnackBarAction(
        label: '撤销',
        onPressed: () => controller.restoreMessages(snapshots),
      ),
    );
  }

  /// 把选中消息导出为会话归档(含图片、角色与状态),可直接重新导入。
  Future<void> _exportSelectedMessages() async {
    final ids = Set<int>.of(_selectedMessageIds.value);
    if (ids.isEmpty) return;
    final title = '${_character.name}-${widget.sessionId}-选中${ids.length}条';
    await saveSessionArchive(
      context,
      fileName: '$title.msarc',
      build: (staging, {onProgress, isCancelled}) =>
          SessionExporter(ref.read(databaseProvider)).exportToFile(
            sessionId: widget.sessionId,
            file: staging,
            messageIds: ids,
            onProgress: onProgress,
            isCancelled: isCancelled,
          ),
    );
  }

  /// 消息操作统一分发(气泡下方按钮与长按/右键菜单共用)。
  Future<void> _messageAction(Message m, MessageAction action) async {
    final controller = ref.read(chatControllerProvider.notifier);
    switch (action) {
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: m.content));
        if (mounted) {
          showAppSnack(context, '已复制到剪贴板');
        }
      case MessageAction.edit:
        await _editMessage(m);
      case MessageAction.download:
        await _downloadMessageImage(m);
      case MessageAction.delete:
        final id = m.id;
        if (id == null) return;
        final snapshot = await controller.deleteMessage(id);
        if (snapshot == null || !mounted) return;
        // 删除即时生效但保留撤销窗口:快照含图片字节,撤销后原位置/内容复原;
        // 撤销窗口内又有新消息落库时恢复行排到末尾,不留重复 seq。
        showAppSnack(
          context,
          '已删除消息',
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => controller.restoreMessage(snapshot),
          ),
        );
      case MessageAction.select:
        _enterSelectionMode(seed: m);
      case MessageAction.regenerate:
        final id = m.id;
        if (id == null) return;
        if (!await _confirmTruncateAfter(m)) return;
        await controller.regenerate(id);
      case MessageAction.rewrite:
        await _rewriteMessage(m);
      case MessageAction.resend:
        final id = m.id;
        if (id == null) return;
        if (!await _confirmTruncateAfter(m)) return;
        await controller.resend(id);
      case MessageAction.regenerateImage:
        await _regenerateImage(m);
      case MessageAction.reviseImagePrompt:
        await _reviseImagePrompt(m);
    }
  }

  /// 重新生成/重新发送会物理删除目标之后的全部记录(含附件与压缩摘要),
  /// 且没有撤销入口。目标不是最新一条时必须先确认,避免误触截断历史。
  Future<bool> _confirmTruncateAfter(Message m) async {
    final later = ref
        .read(chatControllerProvider)
        .messages
        .where((x) => x.seq > m.seq)
        .length;
    if (later == 0) return true;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除后续消息?',
      message: '该消息之后还有 $later 条记录(含附件与压缩摘要)。继续将删除这些记录且无法撤销。',
      confirmLabel: '继续',
    );
    return confirmed && mounted;
  }

  /// 从本地资产或远程 URL 读取原图并交给系统保存(气泡底部与长按菜单共用)。
  ///
  /// 本地文件缺失时回退 URL;两者都不可用才提示失败,与全屏查看器的下载
  /// 语义保持一致。
  Future<void> _downloadMessageImage(Message m) async {
    final hash = m.imageHash;
    if (hash != null) {
      final file = ref.read(databaseProvider).images.fileFor(hash);
      if (await file.exists()) {
        if (!mounted) return;
        await saveChatImage(context, file: file);
        return;
      }
    }
    final url = m.imageUrl;
    if (url == null || url.isEmpty) {
      if (!mounted) return;
      showAppSnack(context, '下载失败:图片数据不可用');
      return;
    }
    if (!mounted) return;
    await saveChatImage(context, url: url);
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

  /// 按落库的原始描述重新生成某张图片的提示词,先收一句修改要求交后台引擎
  /// 改写,再让用户确认/手动编辑新描述,最后只重绘这一张。第一张单取消不发
  /// 请求,第二张单取消不生成图片;结果经灵动岛闪示。
  Future<void> _reviseImagePrompt(Message m) async {
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
    final direction = await showTextEditSheet(
      context,
      title: '按要求重新生成',
      initialText: '',
      hintText: '描述这张图哪里不对、希望怎么改…',
      submitLabel: '生成描述',
      description: '只改写这一张图的描述，不改生图指导。',
      editorHeightFactor: 0.3,
      maxEditorHeight: 220,
    );
    if (direction == null || direction.trim().isEmpty || !mounted) return;
    _islandHub.push('正在按要求改写图片描述…', tone: IslandTone.info);
    final suggestion = await ref
        .read(chatControllerProvider.notifier)
        .suggestImagePromptRevision(id, direction);
    if (!mounted) return;
    if (suggestion.error != null) {
      _islandHub.push(suggestion.error!, tone: IslandTone.danger);
      return;
    }
    final newPrompt = suggestion.prompt;
    final basePrompt = suggestion.basePrompt;
    if (newPrompt == null || basePrompt == null) return;
    final edited = await showTextEditSheet(
      context,
      title: '确认图片描述',
      initialText: newPrompt,
      hintText: '新的图片描述…',
      submitLabel: '重新生成',
      description: '可继续手动修改；确认后只重绘这张图片。',
      editorHeightFactor: 0.35,
      maxEditorHeight: 280,
    );
    if (edited == null || !mounted) return;
    _islandHub.push('正在按要求重新生成图片…', tone: IslandTone.info);
    final error = await ref
        .read(chatControllerProvider.notifier)
        .regenerateImageWithPrompt(
          id,
          newPrompt: edited,
          expectedPrompt: basePrompt,
        );
    if (!mounted) return;
    _islandHub.push(
      error ?? '图片已按要求重新生成',
      tone: error == null ? IslandTone.success : IslandTone.danger,
    );
  }

  /// 长按/右键菜单:按消息角色与内容动态给出操作项 —— 空正文不提供复制/
  /// 编辑,「重新生成」与「按要求重新生成」只在助手消息带图且留有原始描述时
  /// 出现(没有描述就无法重画);「按要求重写」只给最新一条有正文的助手回复(其后允许跟
  /// 图片消息);删除恒定提供。
  Future<void> _messageActions(Message m) async {
    HapticFeedback.mediumImpact();
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
        if (m.hasVisualImage)
          const MenuAction(
            value: MessageAction.download,
            label: '下载图片',
            icon: Icons.download_outlined,
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
        if (!isUser &&
            m.hasVisualImage &&
            (m.imagePrompt?.trim().isNotEmpty ?? false))
          const MenuAction(
            value: MessageAction.reviseImagePrompt,
            label: '按要求重新生成',
            icon: Icons.auto_fix_high,
          ),
        if (isUser && hasText)
          const MenuAction(
            value: MessageAction.resend,
            label: '重新发送',
            icon: Icons.send_outlined,
          ),
        const MenuAction(
          value: MessageAction.select,
          label: '多选消息',
          icon: Icons.checklist_outlined,
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
    showAppSheet<void>(
      context,
      isScrollControlled: false,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return Padding(
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
}
