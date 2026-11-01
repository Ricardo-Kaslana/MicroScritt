import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../engine/background_status.dart';
import '../models/app_settings.dart';
import '../models/llm_provider.dart';
import '../models/variable.dart';
import '../models/worldbook_entry.dart';
import '../state/chat_controller.dart';
import '../state/providers.dart';
import 'common/app_menu.dart';
import 'common/app_search_field.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/section_header.dart';
import 'common/text_edit_sheet.dart';
import 'common/variable_edit_sheet.dart';
import '../models/memory.dart';

/// 状态面板里变量区的预览条数:超出部分进「查看全部」的虚拟化列表。
const int _kVariablePreviewLimit = 8;

/// 后台引擎状态查看:变量 / 记忆 / 生图指导(记忆与生图指导为会话级)。
/// 变量由后台引擎自动维护;记忆(CW 批起)与生图指导由**用户主动维护**
/// (手动编辑 / 主动生成),后台只读携带,不再逐轮改写。
class StatusScreen extends ConsumerWidget {
  final int sessionId;
  const StatusScreen({super.key, required this.sessionId});

  Future<void> _clearMemory(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空记忆?',
      message: '会话的长期记忆将被删除。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    await ref.read(memoryRepositoryProvider).clear(sessionId);
    ref.invalidate(memoriesProvider(sessionId));
    // 记忆变了,上下文面板的"记忆"段也要随之刷新,否则面板显示旧的长期记忆。
    await ref.read(chatControllerProvider.notifier).refreshContext();
  }

  /// 手动填写记忆:不调用 LLM,空表时也能从零创建(与 AI 初始化解耦)。
  Future<void> _createMemory(BuildContext context, WidgetRef ref) async {
    final saved = await showTextEditSheet(
      context,
      title: '手动填写记忆',
      initialText: '',
      hintText: '输入长期记忆内容…',
      // 记忆通常较长:编辑区给到屏幕 70%、封顶 620,减少在狭小框里回看。
      editorHeightFactor: 0.7,
      maxEditorHeight: 620,
    );
    if (saved == null) return;
    await ref.read(memoryRepositoryProvider).set(sessionId, saved);
    ref.invalidate(memoriesProvider(sessionId));
    await ref.read(chatControllerProvider.notifier).refreshContext();
  }

  /// 编辑记忆:底部编辑区改写后落库。CW 批起记忆以冻结副本进上下文 —— 落库后
  /// 下一次输入会以 diff 通知送达差异;需立即整体换新时用「应用到上下文」。
  Future<void> _editMemoryEntry(
    BuildContext context,
    WidgetRef ref,
    Memory m,
  ) async {
    final saved = await showTextEditSheet(
      context,
      title: '编辑记忆',
      initialText: m.content,
      hintText: '输入新的记忆内容…',
      // 与手动填写同一高度:记忆可能很长,默认 420 的编辑区太局促。
      editorHeightFactor: 0.7,
      maxEditorHeight: 620,
    );
    if (saved == null || saved == m.content) return;
    await ref.read(memoryRepositoryProvider).update(m.id!, saved);
    ref.invalidate(memoriesProvider(sessionId));
    await ref.read(chatControllerProvider.notifier).refreshContext();
  }

  /// 「应用到上下文」入口:记忆有未应用修改时整行上底色并挂「待应用」徽标,
  /// 让用户一眼看到(避免忘记应用);点按一律先过确认弹层。
  Widget _applyMemoryTile(
    BuildContext context,
    WidgetRef ref, {
    required bool pending,
    required bool enabled,
    String pendingHint = '记忆已修改,尚未应用到上下文',
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      tileColor: pending ? scheme.primary.withValues(alpha: 0.08) : null,
      leading: Icon(Icons.publish, size: 20, color: scheme.primary),
      title: Row(
        children: [
          const Text('应用到上下文'),
          if (pending) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '待应用',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: pending
          ? Text(
              pendingHint,
              style: TextStyle(fontSize: 12, color: scheme.primary),
            )
          : null,
      enabled: enabled,
      onTap: enabled
          ? () => _confirmApplyMemory(context, ref, pending: pending)
          : null,
    );
  }

  /// 应用到上下文前的确认:第 0 条记忆整体换新会改变提示前缀(缓存重新预热)。
  Future<void> _confirmApplyMemory(
    BuildContext context,
    WidgetRef ref, {
    required bool pending,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('应用到上下文?'),
        content: Text(
          pending
              ? '库中记忆已修改,上下文开头仍是旧版本。应用后记忆整体换新,提示前缀会变化(缓存重新预热);改动的差异此前已以通知送达。'
              : '上下文里的记忆已是最新,应用只会重新组装一次上下文。仍要继续吗?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(chatControllerProvider.notifier).applyMemoryToContext();
  }

  Future<void> _toggleBackground(WidgetRef ref, bool enabled) async {
    await persistBackgroundEnabled(
      stateSetter: (v) =>
          ref.read(backgroundEnabledProvider.notifier).state = v,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
      enabled: enabled,
    );
  }

  /// 设置后台agent 专用模型(id 为 llm_models 表整型 id)并落库;
  /// 传 null 表示跟随主写引擎当前模型。
  Future<void> _setBackgroundModel(WidgetRef ref, int? modelId) async {
    await persistBackgroundModel(
      modelId: modelId,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 设置后台agent 请求的推理强度并落库(仅影响后台维护/主动轮,不动主对话)。
  Future<void> _setBackgroundReasoning(
    WidgetRef ref,
    ReasoningLevel level,
  ) async {
    await persistBackgroundReasoningLevel(
      level: level,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 设置变量删除前确认严格模式并落库。
  Future<void> _setBackgroundDeletionConfirm(
    WidgetRef ref,
    bool enabled,
  ) async {
    await persistBackgroundDeletionConfirm(
      enabled: enabled,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 设置后台agent 输出上限档位并落库(仅约束首试请求,重试恒放开)。
  Future<void> _setBackgroundOutputTier(
    WidgetRef ref,
    BackgroundOutputTier tier,
  ) async {
    await persistBackgroundOutputTier(
      tier: tier,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 切换后台agent 上下文锚定段开关(角色卡/记忆)并落库。
  Future<void> _toggleAnchor(WidgetRef ref, String key) async {
    await persistBackgroundAnchor(
      key: key,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 切换某项后台功能(on/off)并落库。
  Future<void> _toggleFeature(WidgetRef ref, String name) async {
    await persistBackgroundFeature(
      mutate: (f) => f.toggle(name),
      featureSetter: (f) =>
          ref.read(backgroundFeaturesProvider.notifier).state = f,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 编辑生图指导:改写落库即生效(后台每轮直接读库,无冻结语义)。
  /// [initial] 为 null 表示空态手动创建,标题相应改为「手动填写」。
  Future<void> _editImageGuide(
    BuildContext context,
    WidgetRef ref,
    String? initial,
  ) async {
    final saved = await showTextEditSheet(
      context,
      title: initial == null ? '手动填写生图指导' : '编辑生图指导',
      initialText: initial ?? '',
      hintText: '生图指导:定妆外貌 tag、画风与构图偏好…(英文 NovelAI tag 为佳)',
      // 与记忆编辑底单同高:指导常见长 tag 串,默认 420 的编辑区太局促。
      editorHeightFactor: 0.7,
      maxEditorHeight: 620,
    );
    if (saved == null || saved == initial) return;
    final repo = ref.read(imageGuideRepositoryProvider);
    if (saved.trim().isEmpty) {
      await repo.clear(sessionId);
    } else {
      await repo.set(sessionId, saved);
    }
    ref.invalidate(imageGuideProvider(sessionId));
  }

  Future<void> _clearImageGuide(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空生图指导?',
      message: '清空后后台生图将回退内置 tag 规范,定妆外貌可能漂移。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    await ref.read(imageGuideRepositoryProvider).clear(sessionId);
    ref.invalidate(imageGuideProvider(sessionId));
  }

  // ── 变量的人工维护(新增 / 编辑 / 删除 / 清空)──────────────────
  //
  // 变量此前只由后台 agent 自动写入,面板只能看。这里补齐人工入口。
  // 关键约束:**改完不要调 refreshContext()** —— 变量自 CL 批起不进主写
  // 组装,只作为后台下一轮的输入;失效 variablesProvider 就够了。加上
  // refreshContext 只会白跑一次组装(且给人"变量会影响正文"的错觉)。

  /// active 变量视图与其它派生面板的刷新。变量不进主写上下文,无需
  /// `refreshContext()`。
  void _refreshVariables(WidgetRef ref) {
    ref.invalidate(variablesProvider(sessionId));
    ref.invalidate(variableRowsProvider(sessionId));
  }

  void _refreshVariableAux(WidgetRef ref) {
    ref.invalidate(variableTrashProvider(sessionId));
    ref.invalidate(pendingVariableDeletionsProvider(sessionId));
  }

  /// 新增一条变量(空表按钮与标题行菜单共用)。人工新增默认 protected:
  /// 后台可更新值,但不会删除;需要自动清理时在底单里改成"可改可删"。
  Future<void> _addVariable(
    BuildContext context,
    WidgetRef ref,
    List<Variable> current,
  ) async {
    final result = await showVariableEditSheet(
      context,
      title: '新增变量',
      existingKeys: {for (final v in current) v.key},
    );
    if (result == null) return;
    await ref
        .read(variableRepositoryProvider)
        .upsert(sessionId, result.key, result.value, access: result.access);
    _refreshVariables(ref);
    // upsert 会清掉同键的待确认删除建议。
    _refreshVariableAux(ref);
  }

  /// 编辑一条变量:键可改(改名走事务,不留旧行);键、值与权限都没变时不碰库。
  Future<void> _editVariable(
    BuildContext context,
    WidgetRef ref,
    List<Variable> current,
    Variable variable,
  ) async {
    final result = await showVariableEditSheet(
      context,
      title: '编辑变量',
      initialKey: variable.key,
      initialValue: variable.value,
      initialAccess: variable.agentAccess,
      // 冲突集合要排除自己,否则单纯改值就会误报"将覆盖同名变量"。
      existingKeys: {
        for (final v in current)
          if (v.key != variable.key) v.key,
      },
    );
    if (result == null) return;
    if (result.key == variable.key &&
        result.value == variable.value &&
        result.access == variable.agentAccess) {
      return;
    }
    await ref
        .read(variableRepositoryProvider)
        .update(
          sessionId,
          oldKey: variable.key,
          newKey: result.key,
          value: result.value,
          access: result.access,
        );
    _refreshVariables(ref);
    _refreshVariableAux(ref);
  }

  /// 删除一条变量:移入回收站,可在「已删除」里恢复。
  Future<void> _deleteVariable(
    BuildContext context,
    WidgetRef ref,
    String key,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除变量?',
      message: '将把「$key」移入回收站,可在状态面板恢复到当前会话。',
      confirmLabel: '删除',
    );
    if (!confirmed) return;
    await ref.read(variableRepositoryProvider).delete(sessionId, key);
    _refreshVariables(ref);
    _refreshVariableAux(ref);
  }

  /// 清空本会话全部变量:全部移入回收站。
  Future<void> _clearVariables(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空全部变量?',
      message: '本会话的变量将全部移入回收站,可在「已删除」中逐条恢复。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    await ref.read(variableRepositoryProvider).clear(sessionId);
    _refreshVariables(ref);
    _refreshVariableAux(ref);
  }

  Future<void> _showTrash(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _VariableTrashSheet(sessionId: sessionId),
    );
  }

  /// 变量全量视图:状态面板只预览前几条,条目多时在这里用虚拟化列表滚动查看。
  Future<void> _showAllVariables(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _VariableListSheet(
        sessionId: sessionId,
        onEdit: (ctx, sheetRef, rows, variable) =>
            _editVariable(ctx, sheetRef, rows, variable),
        onDelete: (ctx, sheetRef, key) => _deleteVariable(ctx, sheetRef, key),
      ),
    );
  }

  /// 区段标题行右侧的小三点菜单。不传 [actions] 时是记忆/生图指导共用的
  /// 「清空」(编辑改为直接点内容行);变量节传入自己的「新增变量 / 清空」。
  Widget _sectionMenu({
    required ColorScheme scheme,
    required String tooltip,
    required void Function(String action) onSelected,
    List<MenuAction<String>>? actions,
  }) {
    return AppPopupMenuButton<String>(
      tooltip: tooltip,
      iconSize: 20,
      iconColor: scheme.outline,
      onSelected: onSelected,
      actions:
          actions ??
          const [
            MenuAction(
              value: 'clear',
              label: '清空',
              icon: Icons.delete_sweep_outlined,
              destructive: true,
            ),
          ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final variableRows = ref.watch(variableRowsProvider(sessionId));
    final variableTrash = ref.watch(variableTrashProvider(sessionId));
    final deletionConfirm = ref
        .watch(appSettingsProvider)
        .backgroundDeletionConfirm;
    final trashCount = variableTrash.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );
    final memories = ref.watch(memoriesProvider(sessionId));
    final imageGuide = ref.watch(imageGuideProvider(sessionId));
    final backgroundEnabled = ref.watch(backgroundEnabledProvider);
    final backgroundFeatures = ref.watch(backgroundFeaturesProvider);
    final chatState = ref.watch(chatControllerProvider);
    final backgroundStatus = chatState.backgroundStatus;
    final backgroundSummary = chatState.backgroundSummary;
    // 记忆已修改但尚未应用到上下文:库中最新记忆与上下文冻结副本不一致。
    // 只在控制器已装载本会话时判定,避免拿别的会话的冻结副本误报。
    final memoryPendingApply =
        chatState.sessionId == sessionId &&
        memories.hasValue &&
        (memories.value?.firstOrNull?.content.trim() ?? '') !=
            (chatState.frozenMemory?.trim() ?? '');
    // 当前会话角色(后台世界书条目选择按角色取数)。
    final characterId =
        ref.watch(chatControllerProvider.select((s) => s.characterId)) ?? -1;
    final scheme = Theme.of(context).colorScheme;
    final running = backgroundStatus == BackgroundStatus.running;

    return Scaffold(
      appBar: AppBar(title: const Text('状态面板')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _BackgroundAgentCard(
            enabled: backgroundEnabled,
            status: backgroundStatus,
            summary: backgroundSummary,
            onToggle: (v) => _toggleBackground(ref, v),
          ),
          // 状态卡与下方维护设置分开呼吸,避免两张白卡贴成一块。
          const SizedBox(height: 12),
          // 后台agent 启用时:维护功能 / 请求参数 / 上下文锚定 归入一张设置卡,
          // 世界书条目选择也收进同卡上下文节(EX 批 UI 整理,不再三张卡堆叠)。
          if (backgroundEnabled)
            _BackgroundFeatureSelector(
              features: backgroundFeatures,
              onToggle: (name) => _toggleFeature(ref, name),
              // 当前后台专用模型(llm_models.id;null = 跟随主写)。
              backgroundModelId: ref
                  .watch(appSettingsProvider)
                  .backgroundModelId,
              onModelSelected: (id) => _setBackgroundModel(ref, id),
              // 后台请求的推理强度(独立于主对话的设置)。
              backgroundReasoningLevel: ref
                  .watch(appSettingsProvider)
                  .backgroundReasoningLevel,
              onReasoningSelected: (level) =>
                  _setBackgroundReasoning(ref, level),
              // 输出上限档位(独立于推理强度,仅约束首试请求)。
              backgroundOutputTier: ref
                  .watch(appSettingsProvider)
                  .backgroundOutputTier,
              onOutputTierSelected: (tier) =>
                  _setBackgroundOutputTier(ref, tier),
              // 上下文锚定段开关:角色卡/记忆是否进后台上下文。
              characterAnchor: ref
                  .watch(appSettingsProvider)
                  .backgroundCharacterAnchor,
              memoryAnchor: ref
                  .watch(appSettingsProvider)
                  .backgroundMemoryAnchor,
              onAnchorToggle: (key) => _toggleAnchor(ref, key),
              // 变量删除前确认严格模式。
              deletionConfirm: deletionConfirm,
              onDeletionConfirmChanged: (v) =>
                  _setBackgroundDeletionConfirm(ref, v),
              characterId: characterId,
            ),
          const SizedBox(height: 16),
          // ── 变量(后台自动维护 + 用户手动增删改)────────────────
          Row(
            children: [
              const Expanded(
                child: SectionHeader('变量', icon: Icons.data_object),
              ),
              variableRows.maybeWhen(
                data: (rows) => rows.isEmpty && trashCount == 0
                    ? const SizedBox.shrink()
                    : _sectionMenu(
                        scheme: scheme,
                        tooltip: '变量操作',
                        actions: [
                          const MenuAction(
                            value: 'add',
                            label: '新增变量',
                            icon: Icons.add,
                          ),
                          if (trashCount > 0)
                            MenuAction(
                              value: 'trash',
                              label: '已删除 ($trashCount)',
                              icon: Icons.restore_from_trash_outlined,
                            ),
                          if (rows.isNotEmpty)
                            const MenuAction(
                              value: 'clear',
                              label: '清空',
                              icon: Icons.delete_sweep_outlined,
                              destructive: true,
                            ),
                        ],
                        onSelected: (action) {
                          if (action == 'add') {
                            _addVariable(context, ref, rows);
                          } else if (action == 'trash') {
                            _showTrash(context);
                          } else if (action == 'clear') {
                            _clearVariables(context, ref);
                          }
                        },
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
          variableRows.when(
            data: (rows) => rows.isEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _EmptyHint('后台引擎尚未写入变量。也可以手动新增,作为后台维护的起始状态。'),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: FilledButton.tonalIcon(
                          onPressed: () => _addVariable(context, ref, rows),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('新增变量'),
                        ),
                      ),
                    ],
                  )
                : GroupCard(
                    // 点一行 = 编辑该条;行尾垃圾桶 = 移入回收站。
                    // 只预览前几条:变量由后台长期维护,数量可能很多 ——
                    // 全量塞进一个 Card(Column)会让状态面板一次性布局所有行。
                    // 更长的文本也一律限行,避免单个大变量把整行撑高。
                    children: [
                      for (final variable in rows.take(_kVariablePreviewLimit))
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  variable.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              _VariableAccessBadge(
                                access: variable.agentAccess,
                              ),
                            ],
                          ),
                          subtitle: Text(
                            variable.value,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '删除变量',
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: scheme.error,
                            ),
                            onPressed: () =>
                                _deleteVariable(context, ref, variable.key),
                          ),
                          onTap: () =>
                              _editVariable(context, ref, rows, variable),
                        ),
                      if (rows.length > _kVariablePreviewLimit)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          leading: const Icon(Icons.list_alt_outlined),
                          title: Text('查看全部 ${rows.length} 个变量'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _showAllVariables(context),
                        ),
                    ],
                  ),
            error: (e, _) => _EmptyHint('$e'),
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _PendingVariableDeletions(sessionId: sessionId),
          ),
          const SizedBox(height: 16),
          // ── 记忆(用户主动维护)──────────────────────────────
          Row(
            children: [
              const Expanded(
                child: SectionHeader('记忆', icon: Icons.psychology_outlined),
              ),
              // 记忆每会话仅一条(schema UNIQUE(session_id)):点内容行直接编辑,
              // 清空收进标题行菜单;非空时另有「重生成/应用到上下文」内联按钮。
              memories.maybeWhen(
                data: (list) => list.isEmpty
                    ? const SizedBox.shrink()
                    : _sectionMenu(
                        scheme: scheme,
                        tooltip: '记忆操作',
                        onSelected: (action) {
                          if (action == 'clear') _clearMemory(context, ref);
                        },
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
          memories.when(
            data: (list) => list.isEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _EmptyHint(
                        '尚无记忆。记忆是给主写模型的长期事实底本,可由 AI 依据角色卡生成,也可手动填写。',
                      ),
                      const SizedBox(height: 4),
                      // 空态动作与卡内操作行同一种语言:生成/手动填写/待应用
                      // 最多三行排在同一张卡里,不再按钮与独立卡片混排。
                      GroupCard(
                        children: [
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            leading: Icon(
                              Icons.psychology_outlined,
                              size: 20,
                              color: scheme.primary,
                            ),
                            title: const Text('生成初始记忆'),
                            enabled: !running,
                            onTap: running
                                ? null
                                : () => ref
                                      .read(chatControllerProvider.notifier)
                                      .initializeMemory(),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            leading: Icon(
                              Icons.edit_outlined,
                              size: 20,
                              color: scheme.primary,
                            ),
                            title: const Text('手动填写记忆'),
                            onTap: () => _createMemory(context, ref),
                          ),
                          // 记忆被清空但上下文仍冻结着旧版本:保留高亮的应用
                          // 入口,否则旧记忆只能等压缩时才移出上下文。
                          if (memoryPendingApply)
                            _applyMemoryTile(
                              context,
                              ref,
                              pending: true,
                              enabled: !running,
                              pendingHint: '记忆已清空,上下文仍保留旧版本',
                            ),
                        ],
                      ),
                    ],
                  )
                : GroupCard(
                    children: [
                      // 点内容行直接编辑(与变量行同一交互);清空在标题行菜单。
                      for (final m in list)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          // 记忆是状态面板里用户最常回看的长文本:给到 6 行,
                          // 与生图指导同高,仍不足以撑爆面板。
                          title: Text(
                            m.content,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _editMemoryEntry(context, ref, m),
                        ),
                      // 主动维护动作(CW 批):全量重生成(带全部上下文的请求)与
                      // 应用到上下文(把库中最新记忆立即作为第 0 条消息冻结副本)。
                      // 作为卡片内操作行而非独立按钮行:标签较长,窄屏不再换行错位;
                      // 运行时禁用与按钮态一致。
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        leading: Icon(
                          Icons.auto_awesome,
                          size: 20,
                          color: scheme.primary,
                        ),
                        title: const Text('依据全部对话重生成'),
                        enabled: !running,
                        onTap: running
                            ? null
                            : () => ref
                                  .read(chatControllerProvider.notifier)
                                  .regenerateMemory(),
                      ),
                      // 未应用的记忆修改在这里持续高亮,直到应用或压缩换新。
                      _applyMemoryTile(
                        context,
                        ref,
                        pending: memoryPendingApply,
                        enabled: !running,
                      ),
                    ],
                  ),
            error: (e, _) => _EmptyHint('$e'),
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          const SizedBox(height: 16),
          // ── 生图指导(与记忆分离,后台生图每轮携带)────────────
          Row(
            children: [
              const Expanded(
                child: SectionHeader('生图指导', icon: Icons.palette_outlined),
              ),
              imageGuide.maybeWhen(
                data: (list) => list.isEmpty
                    ? const SizedBox.shrink()
                    : _sectionMenu(
                        scheme: scheme,
                        tooltip: '生图指导操作',
                        onSelected: (action) {
                          if (action == 'clear') _clearImageGuide(context, ref);
                        },
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
          imageGuide.when(
            data: (list) => list.isEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _EmptyHint(
                        '尚无生图指导。指导固定角色外貌与画风,由后台生图每轮携带;可由 AI 生成,也可手动填写。',
                      ),
                      const SizedBox(height: 4),
                      // 与记忆空态同一语言:两条动作排成卡内操作行。
                      GroupCard(
                        children: [
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            leading: Icon(
                              Icons.palette_outlined,
                              size: 20,
                              color: scheme.primary,
                            ),
                            title: const Text('生成初始指导'),
                            enabled: !running,
                            onTap: running
                                ? null
                                : () => ref
                                      .read(chatControllerProvider.notifier)
                                      .initializeImageGuide(),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            leading: Icon(
                              Icons.edit_outlined,
                              size: 20,
                              color: scheme.primary,
                            ),
                            title: const Text('手动填写指导'),
                            onTap: () =>
                                _editImageGuide(context, ref, null),
                          ),
                        ],
                      ),
                    ],
                  )
                : GroupCard(
                    // 点内容行直接编辑(与记忆行同一交互);清空在标题行菜单。
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        title: Text(
                          list.first.content,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                        onTap: () =>
                            _editImageGuide(context, ref, list.first.content),
                      ),
                    ],
                  ),
            error: (e, _) => _EmptyHint('$e'),
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          // 生图指导是页面末区块:额外留出底部间隙,不贴屏幕底边。
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      text,
      style: TextStyle(color: Theme.of(context).colorScheme.outline),
    ),
  );
}

/// 变量行的后台权限徽标:图标 + 长按/悬停提示,不额外占一行文字。
class _VariableAccessBadge extends StatelessWidget {
  final VariableAccess access;
  const _VariableAccessBadge({required this.access});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (access) {
      VariableAccess.full => (Icons.auto_awesome_outlined, scheme.primary),
      VariableAccess.protected => (
        Icons.verified_user_outlined,
        scheme.onSurfaceVariant,
      ),
      VariableAccess.readonly => (Icons.lock_outline, scheme.error),
    };
    return Tooltip(
      message: '${access.label}:${access.description}',
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// 严格模式下的待确认删除卡片。确认后移入回收站(可恢复)。
class _PendingVariableDeletions extends ConsumerWidget {
  final int sessionId;
  const _PendingVariableDeletions({required this.sessionId});

  void _refresh(WidgetRef ref) {
    ref.invalidate(pendingVariableDeletionsProvider(sessionId));
    ref.invalidate(variablesProvider(sessionId));
    ref.invalidate(variableRowsProvider(sessionId));
    ref.invalidate(variableTrashProvider(sessionId));
  }

  Future<void> _approveOne(
    BuildContext context,
    WidgetRef ref,
    VariableDeletionProposal proposal,
  ) async {
    final result = await ref
        .read(variableRepositoryProvider)
        .approveDeletion(sessionId, proposal.id!);
    if (!context.mounted) return;
    _refresh(ref);
    final message = result.removed > 0
        ? '已移除「${proposal.key}」,可在「已删除」中恢复'
        : '「${proposal.key}」已变化或不再是可删状态,建议已失效';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _dismissOne(
    BuildContext context,
    WidgetRef ref,
    VariableDeletionProposal proposal,
  ) async {
    await ref
        .read(variableRepositoryProvider)
        .dismissDeletion(sessionId, proposal.id!);
    if (!context.mounted) return;
    _refresh(ref);
  }

  Future<void> _approveAll(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '执行全部删除?',
      message: '将把 $count 个变量移入回收站,可在「已删除」中恢复。',
      confirmLabel: '执行',
    );
    if (!confirmed) return;
    final result = await ref
        .read(variableRepositoryProvider)
        .approveAllDeletions(sessionId);
    if (!context.mounted) return;
    _refresh(ref);
    final stale = result.stale > 0 ? ',${result.stale} 个建议已失效' : '';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已移除 ${result.removed} 个变量$stale')));
  }

  Future<void> _dismissAll(BuildContext context, WidgetRef ref) async {
    await ref.read(variableRepositoryProvider).dismissAllDeletions(sessionId);
    if (!context.mounted) return;
    _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingVariableDeletionsProvider(sessionId));
    return pending.maybeWhen(
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Card(
          color: scheme.errorContainer.withValues(alpha: 0.35),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.fact_check_outlined,
                      size: 18,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '后台建议删除的变量 (${list.length})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '这些删除建议尚未执行:确认后移入回收站,可恢复。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                for (final proposal in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      proposal.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      proposal.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '忽略建议',
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => _dismissOne(context, ref, proposal),
                        ),
                        IconButton(
                          tooltip: '执行删除',
                          icon: Icon(
                            Icons.check,
                            size: 20,
                            color: scheme.error,
                          ),
                          onPressed: () => _approveOne(context, ref, proposal),
                        ),
                      ],
                    ),
                  ),
                if (list.length > 1)
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => _dismissAll(context, ref),
                        child: const Text('全部忽略'),
                      ),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        onPressed: () => _approveAll(context, ref, list.length),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: const Text('全部执行'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// 变量全量底部弹层:用虚拟化列表承载任意数量的变量,避免状态面板
/// 为每条变量都构建一行。编辑/删除复用状态面板的既有流程。
/// 顶部检索框按键名与值过滤(内存过滤,数据本就全量加载)。
class _VariableListSheet extends ConsumerStatefulWidget {
  final int sessionId;
  final Future<void> Function(
    BuildContext context,
    WidgetRef ref,
    List<Variable> rows,
    Variable variable,
  )
  onEdit;
  final Future<void> Function(BuildContext context, WidgetRef ref, String key)
  onDelete;

  const _VariableListSheet({
    required this.sessionId,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  ConsumerState<_VariableListSheet> createState() => _VariableListSheetState();
}

class _VariableListSheetState extends ConsumerState<_VariableListSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Variable> _filter(List<Variable> rows) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return rows;
    return rows
        .where(
          (v) =>
              v.key.toLowerCase().contains(query) ||
              v.value.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(variableRowsProvider(widget.sessionId));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hasRows = rowsAsync.value?.isNotEmpty ?? false;
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '全部变量',
                        style: text.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Text(
                    '点一行编辑;值仅预览前两行。',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (hasRows)
                  AppSearchField(
                    controller: _search,
                    hint: '搜索变量键名/值',
                    padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
                    onChanged: (v) {
                      if (_query != v) setState(() => _query = v);
                    },
                  ),
                Flexible(
                  child: rowsAsync.when(
                    data: (rows) {
                      if (rows.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('还没有变量')),
                        );
                      }
                      final filtered = _filter(rows);
                      if (filtered.isEmpty) {
                        return const EmptyState(
                          icon: Icons.search_off,
                          title: '没有匹配项',
                          message: '换一个关键词试试。',
                        );
                      }
                      return ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: scheme.outlineVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        itemBuilder: (_, i) {
                          final variable = filtered[i];
                          return ListTile(
                            key: ValueKey('variable-row-${variable.key}'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    variable.key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                _VariableAccessBadge(
                                  access: variable.agentAccess,
                                ),
                              ],
                            ),
                            subtitle: Text(
                              variable.value,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: '删除变量',
                              icon: Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: scheme.error,
                              ),
                              onPressed: () => widget.onDelete(
                                context,
                                ref,
                                variable.key,
                              ),
                            ),
                            onTap: () => widget.onEdit(
                              context,
                              ref,
                              rows,
                              variable,
                            ),
                          );
                        },
                      );
                    },
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('$e'),
                    ),
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 回收站底部弹层:列出已删除变量并支持逐条恢复、彻底删除与清空。
class _VariableTrashSheet extends ConsumerWidget {
  final int sessionId;
  const _VariableTrashSheet({required this.sessionId});

  void _refreshTrash(WidgetRef ref) {
    ref.invalidate(variableTrashProvider(sessionId));
  }

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    VariableTrashEntry entry,
  ) async {
    final restored = await ref
        .read(variableRepositoryProvider)
        .restore(sessionId, entry.id!);
    if (!context.mounted) return;
    ref.invalidate(variableTrashProvider(sessionId));
    ref.invalidate(variableRowsProvider(sessionId));
    ref.invalidate(variablesProvider(sessionId));
    ref.invalidate(pendingVariableDeletionsProvider(sessionId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(restored ? '已恢复「${entry.key}」并设为受保护' : '同名变量仍存在,无法恢复'),
      ),
    );
  }

  /// 彻底删除单条:不走软删除,确认后不可恢复。
  Future<void> _purge(
    BuildContext context,
    WidgetRef ref,
    VariableTrashEntry entry,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '彻底删除「${entry.key}」?',
      message: '该变量将从回收站永久删除,无法恢复。',
      confirmLabel: '删除',
    );
    if (!confirmed) return;
    final removed = await ref
        .read(variableRepositoryProvider)
        .purgeTrashEntry(sessionId, entry.id!);
    if (!context.mounted) return;
    _refreshTrash(ref);
    if (removed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已彻底删除「${entry.key}」')));
    }
  }

  /// 清空本会话回收站:整批永久删除。
  Future<void> _clearAll(BuildContext context, WidgetRef ref, int count) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '清空回收站?',
      message: '回收站内的 $count 条变量将被永久删除,无法恢复。',
      confirmLabel: '清空',
    );
    if (!confirmed) return;
    final removed = await ref
        .read(variableRepositoryProvider)
        .clearTrash(sessionId);
    if (!context.mounted) return;
    _refreshTrash(ref);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已清空回收站($removed 条)')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final trash = ref.watch(variableTrashProvider(sessionId));
    final count = trash.maybeWhen(data: (list) => list.length, orElse: () => 0);
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '已删除的变量',
                        style: text.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (count > 0)
                      IconButton(
                        tooltip: '清空回收站',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.delete_sweep_outlined,
                          size: 20,
                          color: scheme.error,
                        ),
                        onPressed: () => _clearAll(context, ref, count),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Text(
                    '恢复后自动设为受保护,避免再次被后台删除;彻底删除后不可恢复。',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Flexible(
                  child: trash.when(
                    data: (list) => list.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text('回收站是空的')),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: list.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: scheme.outlineVariant.withValues(
                                alpha: 0.5,
                              ),
                            ),
                            itemBuilder: (_, i) {
                              final entry = list[i];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                title: Text(
                                  entry.key,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  '${entry.value}\n${entry.byAgent ? '后台移除' : '手动删除'}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: '恢复变量',
                                      icon: const Icon(Icons.restore, size: 20),
                                      onPressed: () =>
                                          _restore(context, ref, entry),
                                    ),
                                    IconButton(
                                      tooltip: '彻底删除变量',
                                      icon: Icon(
                                        Icons.delete_outline,
                                        size: 20,
                                        color: scheme.error,
                                      ),
                                      onPressed: () =>
                                          _purge(context, ref, entry),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('$e'),
                    ),
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 后台agent 状态卡:启用开关 + 最近一轮运行状态与一句话摘要。
class _BackgroundAgentCard extends StatelessWidget {
  final bool enabled;
  final BackgroundStatus status;
  final String summary;
  final ValueChanged<bool> onToggle;
  const _BackgroundAgentCard({
    required this.enabled,
    required this.status,
    required this.summary,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = enabled && status == BackgroundStatus.running;
    final label = enabled
        ? backgroundStatusLabel(status)
        : backgroundStatusLabel(BackgroundStatus.disabled);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 图标、标题/状态、开关固定在同一行;摘要另起一行放在下方,
            // 不再把标题行和开关挤得上下错位。
            Row(
              children: [
                Icon(
                  active ? Icons.autorenew : Icons.psychology_outlined,
                  color: active
                      ? scheme.primary
                      : (enabled ? scheme.primary : scheme.outline),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        '后台agent',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: enabled
                                    ? scheme.primary
                                    : scheme.outline,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(value: enabled, onChanged: onToggle),
              ],
            ),
            if (summary.isNotEmpty)
              Padding(
                // 与「模型与参数」里的下拉框同宽:卡片内再缩进 14,
                // 叠加卡片左右 16/8 后,灰块左右边缘与模型选择框对齐。
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                // 成功摘要可能列出本轮全部变更(新增变量/技能/生图…),
                // 很长时默认折叠到 3 行,需要时再展开;失败等其它状态的
                // 引擎诊断摘要保持全文,便于直接回看错误(EO 批)。
                child: _BackgroundSummaryText(
                  text: summary,
                  collapsible: status == BackgroundStatus.succeeded,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 后台摘要文本:成功状态且超过 3 行时默认折叠,提供展开/收起。
/// 失败/跳过等状态保持全文 —— 那些摘要常含引擎诊断,截断会看不全错误。
class _BackgroundSummaryText extends StatefulWidget {
  final String text;
  final bool collapsible;

  const _BackgroundSummaryText({required this.text, required this.collapsible});

  @override
  State<_BackgroundSummaryText> createState() => _BackgroundSummaryTextState();
}

class _BackgroundSummaryTextState extends State<_BackgroundSummaryText> {
  static const int _collapsedLines = 3;
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _BackgroundSummaryText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.collapsible != widget.collapsible) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // 与「模型与参数」里的输入框同款填充灰:摘要从白色卡片背景中
    // 独立成一块可读区域,而不是浮在标题下方的一串灰字。
    final fill =
        theme.inputDecorationTheme.fillColor ??
        theme.colorScheme.surfaceContainerHighest;
    return Container(
      key: const ValueKey('background-summary-box'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _content(context, style),
    );
  }

  Widget _content(BuildContext context, TextStyle? style) {
    if (!widget.collapsible) {
      return Text(widget.text, style: style);
    }
    if (_expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topLeft,
            child: Text(widget.text, style: style),
          ),
          _toggle(context),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_overflows(context, constraints.maxWidth, style)) {
          return Text(widget.text, style: style);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _collapsedLines,
              overflow: TextOverflow.ellipsis,
            ),
            _toggle(context),
          ],
        );
      },
    );
  }

  bool _overflows(BuildContext context, double maxWidth, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: _collapsedLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final overflows = painter.didExceedMaxLines;
    painter.dispose();
    return overflows;
  }

  Widget _toggle(BuildContext context) {
    return TextButton.icon(
      onPressed: () => setState(() => _expanded = !_expanded),
      icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16),
      label: Text(_expanded ? '收起' : '展开'),
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(vertical: 2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// 后台agent 设置卡:一张卡承载三个小节(维护功能/模型与参数/上下文锚定),
/// 细线分隔取代此前"每张一小卡"的碎堆感,视觉上让相关控制彼此贴紧、
/// 无关小节之间拉开距离。(EX 批 UI 整理)
/// (CW 批起记忆不再由后台逐轮维护 —— 主动维护入口在上方「记忆」区,
/// 不属于这里的快状态功能。)
class _BackgroundFeatureSelector extends ConsumerWidget {
  final BackgroundFeatures features;
  final void Function(String name) onToggle;

  /// 当前后台专用模型(llm_models 的整型 id);null = 跟随主写。
  final int? backgroundModelId;

  /// 用户选择了一个模型(id;null 表示切回"跟随主写")。
  final ValueChanged<int?> onModelSelected;

  /// 当前后台请求的推理强度;与主对话的推理等级互相独立。
  final ReasoningLevel backgroundReasoningLevel;

  /// 用户选择了推理强度。
  final ValueChanged<ReasoningLevel> onReasoningSelected;

  /// 当前后台输出上限档位(schema v54);仅约束首试请求,重试恒放开。
  final BackgroundOutputTier backgroundOutputTier;

  /// 用户选择了输出上限档位。
  final ValueChanged<BackgroundOutputTier> onOutputTierSelected;

  /// 角色卡/记忆是否进入后台上下文锚定段(后台agent 区开关)。
  final bool characterAnchor;
  final bool memoryAnchor;

  /// 用户切换了锚定段开关([key]:'character' / 'memory')。
  final ValueChanged<String> onAnchorToggle;

  /// 变量删除前确认严格模式。
  final bool deletionConfirm;
  final ValueChanged<bool> onDeletionConfirmChanged;

  /// 当前会话所属角色 id(上下文锚定节的「后台世界书条目」按角色取数)。
  final int characterId;

  const _BackgroundFeatureSelector({
    required this.features,
    required this.onToggle,
    required this.backgroundModelId,
    required this.onModelSelected,
    required this.backgroundReasoningLevel,
    required this.onReasoningSelected,
    required this.backgroundOutputTier,
    required this.onOutputTierSelected,
    required this.characterAnchor,
    required this.memoryAnchor,
    required this.onAnchorToggle,
    required this.deletionConfirm,
    required this.onDeletionConfirmChanged,
    required this.characterId,
  });

  /// 展平的模型目录:每项携带所属 provider 显示名(用于下拉标签区分同名模型)。
  List<({int id, String label})> _flatten(List<LlmProviderConfig> providers) {
    final out = <({int id, String label})>[];
    for (final p in providers) {
      for (final m in p.models) {
        out.add((
          id: m.id,
          label: providers.length > 1
              ? '${m.displayName} · ${p.displayName}'
              : m.displayName,
        ));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(llmProvidersProvider);
    final providers = providersAsync.maybeWhen(
      data: (p) => p,
      orElse: () => const <LlmProviderConfig>[],
    );
    final models = _flatten(providers);
    // 持久化的专用模型可能已被删除(设置页删 provider/模型):此时 value 不在
    // items 里会让 DropdownButton 断言崩溃。落到"跟随主写"并显示兜底;
    // ChatController 侧同样会因 loadConfigForModel 返回 null 而回退主写模型。
    final selected =
        backgroundModelId != null &&
            models.any((m) => m.id == backgroundModelId)
        ? backgroundModelId
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardSection(context, icon: Icons.tune, title: '维护功能'),
            _feature(
              context,
              name: 'variables',
              label: '变量',
              icon: Icons.data_object,
              value: features.variables,
            ),
            _feature(
              context,
              name: 'image',
              label: '生图',
              icon: Icons.image_outlined,
              value: features.image,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              secondary: const Icon(Icons.fact_check_outlined, size: 20),
              title: Text(
                '删除前确认',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              subtitle: Text(
                '开启后建议先待确认;关闭后直接执行并进入回收站',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              value: deletionConfirm,
              onChanged: onDeletionConfirmChanged,
            ),
            _cardDivider(context),
            _cardSection(context, icon: Icons.memory, title: '模型与参数'),
            const SizedBox(height: 4),
            FormDropdownField<int?>(
              fieldKey: ValueKey(
                'background_model_${backgroundModelId?.toString() ?? 'follow'}',
              ),
              value: selected,
              label: '专用模型',
              helperText: '未选择时跟随主写引擎当前模型。',
              menuMaxHeight: 280,
              items: [null, for (final m in models) m.id],
              labelOf: (id) => id == null
                  ? '跟随主写引擎'
                  : models.firstWhere((m) => m.id == id).label,
              onChanged: onModelSelected,
            ),
            FormDropdownField<ReasoningLevel>(
              fieldKey: ValueKey(
                'background_reasoning_${backgroundReasoningLevel.name}',
              ),
              value: backgroundReasoningLevel,
              label: '推理强度',
              helperText:
                  'OpenAI 兼容端点映射 reasoning_effort,Anthropic 映射 thinking 预算;默认关闭。',
              items: ReasoningLevel.values,
              labelOf: (level) => level.label,
              onChanged: (level) {
                if (level != null) onReasoningSelected(level);
              },
            ),
            FormDropdownField<BackgroundOutputTier>(
              fieldKey: ValueKey(
                'background_output_tier_${backgroundOutputTier.name}',
              ),
              value: backgroundOutputTier,
              label: '输出上限',
              helperText: '首试请求的 max_tokens(快状态轮/记忆主动轮);失败重试恒放开,由服务商兜底。',
              items: BackgroundOutputTier.values,
              labelOf: _outputTierCaption,
              onChanged: (tier) {
                if (tier != null) onOutputTierSelected(tier);
              },
            ),
            _cardDivider(context),
            _cardSection(context, icon: Icons.link, title: '上下文锚定'),
            _feature(
              context,
              name: 'character',
              label: '角色卡进入上下文',
              icon: Icons.person_outline,
              value: characterAnchor,
              onToggleOverride: onAnchorToggle,
            ),
            _feature(
              context,
              name: 'memory',
              label: '记忆进入上下文',
              icon: Icons.psychology_outlined,
              value: memoryAnchor,
              onToggleOverride: onAnchorToggle,
            ),
            // 后台世界书条目:同属"什么进后台上下文",与上方两开关并列一行。
            _BackgroundWorldbookRow(characterId: characterId),
          ],
        ),
      ),
    );
  }

  /// 输出上限档位在 items 里显示「档位 · 快/记 数值」,用户不必去 helper 里查表。
  String _outputTierCaption(BackgroundOutputTier tier) => switch (tier) {
    BackgroundOutputTier.compact => '紧凑 · 1024 / 2048',
    BackgroundOutputTier.standard => '标准 · 2048 / 4096',
    BackgroundOutputTier.relaxed => '宽松 · 4096 / 8192',
    BackgroundOutputTier.unlimited => '不限(服务商兜底)',
  };

  Widget _feature(
    BuildContext context, {
    required String name,
    required String label,
    required IconData icon,
    required bool value,
    ValueChanged<String>? onToggleOverride,
  }) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      dense: true,
      secondary: Icon(icon, size: 20),
      title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      value: value,
      onChanged: (_) => (onToggleOverride ?? onToggle)(name),
    );
  }
}

/// 设置卡内的小节头:主色小图标 + 标题,label 灰底,与外层卡形成层级。
/// (EX 批 UI 整理:此前小节之间无分隔,视觉上像堆叠 —— 现在每节一个 header。)
Widget _cardSection(
  BuildContext context, {
  required IconData icon,
  required String title,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
    child: Row(
      children: [
        Icon(icon, size: 14, color: scheme.primary),
        const SizedBox(width: 6),
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ],
    ),
  );
}

/// 设置卡内的细分隔线:hairline 高度,左右缩进与开关行齐。
Widget _cardDivider(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return Divider(
    height: 20,
    thickness: 0.5,
    color: scheme.outlineVariant.withValues(alpha: 0.5),
  );
}

/// 选择进入后台agent 上下文的世界书条目(角色级,EU 批):多选当前角色的条目,
/// 选定的进快状态轮(生图)的锚定段,落 [WorldbookEntry.background] 列。
/// 空选 = 快状态轮不注入世界书锚定段。
///
/// EX 批 UI 整理:此前独立一张卡,现归入设置卡的「上下文锚定」小节尾行,
/// 与角色卡/记忆两开关并列 —— 三项同属"什么进后台上下文"这一维度。
class _BackgroundWorldbookRow extends ConsumerWidget {
  final int characterId;
  const _BackgroundWorldbookRow({required this.characterId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries =
        ref.watch(worldbookProvider(characterId)).value ??
        const <WorldbookEntry>[];
    // 生效口径必须与引擎一致:后台锚定段取 `background && enabled`,停用条目勾了也不进
    // 上下文(BackgroundEngine._backgroundWorldbookText 静默过滤,不报错)。这里只把
    // **已选且启用**的条数进「进入后台上下文」的计数,否则用户勾了几条停用条目会看到
    // "已选 4 / 4 条进入后台上下文",而实际进上下文的是 0 条 —— 排查时被带偏。
    final selected = entries.where((e) => e.background).toList();
    final effective = selected.where((e) => e.enabled).length;
    final inert = selected.length - effective;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      dense: true,
      leading: const Icon(Icons.menu_book_outlined, size: 20),
      title: Text('后台世界书条目', style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(
        entries.isEmpty
            ? '该角色暂无世界书条目'
            : '已选 $effective / ${entries.length} 条进入后台上下文'
                  '${inert > 0 ? ' · $inert 条已停用不生效' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: entries.isEmpty
          ? null
          : const Icon(Icons.chevron_right, size: 20),
      onTap: entries.isEmpty ? null : () => _pick(context, ref, entries),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    List<WorldbookEntry> entries,
  ) async {
    // 底部弹层(移动端友好):返回选定的 id 集合;取消/下滑关闭返回 null。
    final selected = await showModalBottomSheet<Set<int?>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BackgroundWorldbookSheet(entries),
    );
    if (selected == null) return;
    final updated = entries
        .map((e) => e.copyWith(background: selected.contains(e.id)))
        .toList();
    await ref
        .read(worldbookRepositoryProvider)
        .replaceForCharacter(characterId, updated);
    ref.invalidate(worldbookProvider(characterId));
  }
}

/// 后台世界书条目多选底单(EW 批):与其余底单同款形态(拖拽把手 + 标题 +
/// 取消,圆角顶,高度封顶 85%)。每行 = 勾选圆标 + 名称 + 两行内容预览,
/// 行尾箭头展开/收起完整内容(长文内滚);标题行下带实时已选计数与
/// 全选/取消全选,底部保存键同样带计数。
class _BackgroundWorldbookSheet extends StatefulWidget {
  final List<WorldbookEntry> entries;
  const _BackgroundWorldbookSheet(this.entries);

  @override
  State<_BackgroundWorldbookSheet> createState() =>
      _BackgroundWorldbookSheetState();
}

class _BackgroundWorldbookSheetState extends State<_BackgroundWorldbookSheet> {
  late final Set<int?> _selected = {
    for (final e in widget.entries)
      if (e.background) e.id,
  };

  /// 展开完整内容预览的条目(行尾箭头切换)。
  final Set<int?> _expanded = {};

  /// 已勾选但处于停用的条目数:引擎取数 `background && enabled`,这些勾了也不会
  /// 进入后台上下文。选择处当场提示,别让用户带着"勾了就生效"的错觉保存。
  int get _inertSelected => widget.entries
      .where((e) => _selected.contains(e.id) && !e.enabled)
      .length;

  void _toggleSelected(int? id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  void _toggleExpanded(int? id) => setState(() {
    if (!_expanded.remove(id)) _expanded.add(id);
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.bottomCenter,
      // heightFactor=1:按内容高度收缩,不撑满整屏(与文本编辑底单同款)。
      heightFactor: 1,
      child: Material(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 拖拽把手 + 标题 + 取消。
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '后台世界书条目',
                        style: text.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                  ],
                ),
                // 实时已选计数 + 全选/取消全选。
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 0, 2),
                  child: Row(
                    children: [
                      Text(
                        '已选 ${_selected.length} / ${widget.entries.length} 条',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Expanded(child: SizedBox.shrink()),
                      TextButton(
                        onPressed: () => setState(
                          () =>
                              _selected.addAll(widget.entries.map((e) => e.id)),
                        ),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: () => setState(_selected.clear),
                        child: const Text('取消全选'),
                      ),
                    ],
                  ),
                ),
                // 勾了停用条目时点明"不会生效"(行内已有红色「已停用」徽章,但徽章
                // 说的是条目状态,这里说的是本次勾选的后果 —— 后者才会被误解成生效)。
                if (_inertSelected > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                    child: Text(
                      '其中 $_inertSelected 条已停用,勾选也不会进入后台上下文',
                      style: text.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: widget.entries.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    itemBuilder: (_, i) {
                      final e = widget.entries[i];
                      final selected = _selected.contains(e.id);
                      final expanded = _expanded.contains(e.id);
                      return InkWell(
                        onTap: () => _toggleSelected(e.id),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Icon(
                                  selected
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  size: 22,
                                  color: selected
                                      ? scheme.primary
                                      : scheme.outline,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            e.displayLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: text.bodyLarge,
                                          ),
                                        ),
                                        if (!e.enabled) ...[
                                          const SizedBox(width: 6),
                                          Text(
                                            '已停用',
                                            style: text.labelSmall?.copyWith(
                                              color: scheme.error,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    // 内容预览:默认两行摘要,展开后完整内容内滚。
                                    if (expanded)
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxHeight: 240,
                                        ),
                                        child: SingleChildScrollView(
                                          child: Text(
                                            e.content,
                                            style: text.bodySmall,
                                          ),
                                        ),
                                      )
                                    else
                                      Text(
                                        e.content,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.bodySmall?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: expanded ? '收起预览' : '展开预览',
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  expanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 20,
                                ),
                                onPressed: () => _toggleExpanded(e.id),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, Set<int?>.of(_selected)),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text('保存(${_selected.length})'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
