/// 会话状态面板:后台 agent 的启停与参数,以及变量 / 记忆 / 生图指导的人工
/// 维护入口。
///
/// 变量只供后台请求使用,不进主写上下文,所以这里的变量写操作只失效变量
/// 相关 provider;记忆以冻结副本占据上下文第 0 条,手工编辑/清空后只更新
/// 库与列表,需点「应用到上下文」才整体换新(因此也不重算上下文快照)。
/// 变量删除一律先进回收站;严格模式(`background_deletion_confirm`)下后台
/// 的删除提议只写待确认建议,由本页确认后才移入回收站。
library;

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
import 'common/info_button.dart';
import 'common/section_header.dart';
import 'common/sheet_header.dart';
import 'common/text_edit_sheet.dart';
import 'common/variable_edit_sheet.dart';
import 'status/status_desktop_screen.dart';
import 'status/status_layout.dart';
import 'status/status_widgets.dart';
import '../models/memory.dart';

/// 状态面板里变量区的预览条数:超出部分进「查看全部」的虚拟化列表。
const int _kVariablePreviewLimit = 8;

/// 状态面板统一入口:窄窗走移动单列页,宽窗走桌面分区工作台。
class StatusScreen extends StatelessWidget {
  /// 要展示的会话 id(变量 / 记忆 / 生图指导都按它取数)。
  final int sessionId;
  const StatusScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return MediaQuery.sizeOf(context).width >= kStatusDesktopBreakpoint
        ? StatusDesktopScreen(sessionId: sessionId)
        : StatusMobileScreen(sessionId: sessionId);
  }
}

/// 移动端状态面板(窄窗):后台 agent 的启停与参数,以及变量 / 记忆 / 生图
/// 指导的人工维护入口。
///
/// 变量只供后台请求使用,不进主写上下文,所以这里的变量写操作只失效变量
/// 相关 provider;记忆以冻结副本占据上下文第 0 条,手工编辑/清空后只更新
/// 库与列表,需点「应用到上下文」才整体换新(因此也不重算上下文快照)。
/// 变量删除一律先进回收站;严格模式(`background_deletion_confirm`)下后台
/// 的删除提议只写待确认建议,由本页确认后才移入回收站。
class StatusMobileScreen extends ConsumerWidget {
  /// 要展示的会话 id(变量 / 记忆 / 生图指导都按它取数)。
  final int sessionId;
  const StatusMobileScreen({super.key, required this.sessionId});

  /// 清空会话记忆:确认后删库并失效列表缓存。
  ///
  /// 不重算上下文:第 0 条记忆取自冻结副本,清库不会立刻改变提示前缀 ——
  /// 差异由「待应用」入口暴露,用户点应用后才整体换新。
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
  }

  /// 编辑记忆:底部编辑区改写后落库。记忆以冻结副本进上下文 —— 落库后下一次
  /// 输入会以 diff 通知送达差异;需立即整体换新时走「应用到上下文」。
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
      // 禁用期间给出原因:置灰的按钮不说明"为什么点不了",用户只能反复点。
      subtitle: enabled
          ? (pending
                ? Text(
                    pendingHint,
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  )
                : null)
          : Text(
              pending ? '$pendingHint · 后台运行中,结束后可应用' : '后台运行中,结束后可应用',
              style: TextStyle(
                fontSize: 12,
                color: pending ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
      enabled: enabled,
      onTap: enabled
          ? () => _confirmApplyMemory(context, ref, pending: pending)
          : null,
    );
  }

  /// 「应用到上下文」的确认弹层:第 0 条记忆整体换新会改变提示前缀,缓存
  /// 只能重新预热,因此不静默执行。确认后刷新冻结副本并重算快照。
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

  /// 后台引擎合并按钮的四态循环:关闭 → Legacy → Agentic → Hybrid → 关闭。
  /// 从关闭态启用时回到 Legacy;关闭时保留当前模式。启停与模式一次落库,
  /// 避免两次写整行互相覆盖。
  Future<void> _cycleBackground(WidgetRef ref) async {
    final current = ref.read(appSettingsProvider);
    final (enabled, mode) = switch ((
      current.backgroundEnabled,
      current.backgroundMode,
    )) {
      (false, _) => (true, BackgroundMode.legacy),
      (true, BackgroundMode.legacy) => (true, BackgroundMode.agentic),
      (true, BackgroundMode.agentic) => (true, BackgroundMode.hybrid),
      (true, BackgroundMode.hybrid) => (false, BackgroundMode.hybrid),
    };
    await persistBackgroundEngineState(
      enabled: enabled,
      mode: mode,
      enabledSetter: (v) =>
          ref.read(backgroundEnabledProvider.notifier).state = v,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: current,
    );
  }

  /// 设置后台 agent 专用模型(id 为 llm_models 表整型 id)并落库;
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

  /// 设置后台 agent 请求的推理强度并落库(仅影响后台维护/主动轮,不动主对话)。
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

  /// 切换后台 agent 上下文锚定段开关(角色卡/记忆)并落库。
  Future<void> _toggleAnchor(WidgetRef ref, String key) async {
    await persistBackgroundAnchor(
      key: key,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 切换某项后台功能(on/off)并落库。[name] 是功能标识而非界面文案。
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

  /// 清空生图指导:清空后后台生图回退内置 tag 规范,定妆外貌可能漂移,
  /// 所以先确认。指导不进主写上下文,无需重算快照。
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

  // ===== 变量的人工维护 =====
  //
  // 变量本只由后台 agent 自动写入,面板补齐人工的新增 / 编辑 / 删除 / 清空。
  // 关键约束:**改完不要调 refreshContext()** —— 变量不进主写组装,只作为
  // 后台下一轮的输入;失效变量相关 provider 就够了。加上 refreshContext
  // 只会白跑一次组装,还会给人「变量会影响正文」的错觉。

  /// active 变量视图与其它派生面板的刷新。变量不进主写上下文,无需
  /// `refreshContext()`。
  void _refreshVariables(WidgetRef ref) {
    refreshVariableViews(ref, sessionId);
  }

  /// 回收站与待确认建议的刷新:人工增删改会顺带清掉同键的建议,
  /// 所以每次写变量后都要连这两份视图一起失效。
  void _refreshVariableAux(WidgetRef ref) {
    refreshVariableAuxViews(ref, sessionId);
  }

  /// 新增一条变量(空表按钮与标题行菜单共用)。人工新增默认 protected:
  /// 后台可更新值,但不会删除;需要自动清理时在底单里改成「可改可删」。
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

  /// 编辑一条变量:键可改(改名在仓库事务里删旧插新,不留旧行);键、值与
  /// 权限都没变时不碰库。目标键已被占用时按仓库语义覆盖,冲突在编辑底单里
  /// 先行提示。
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
      // 冲突集合要排除自己,否则单纯改值就会误报「将覆盖同名变量」。
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

  /// 变量回收站底部弹层:逐条恢复或彻底删除,入口只在回收站非空时出现。
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
    final memoryPendingApply = isMemoryPendingApply(
      chatState,
      sessionId,
      memories,
    );
    // 当前会话角色(后台世界书条目选择按角色取数)。
    final characterId =
        ref.watch(chatControllerProvider.select((s) => s.characterId)) ?? -1;
    final scheme = Theme.of(context).colorScheme;
    final running = backgroundStatus == BackgroundStatus.running;

    // 控制区(后台引擎 + 设置)与数据区(变量/记忆/生图指导)分开组织,
    // 移动单列按原顺序拼接。
    final engineCards = <Widget>[
      _BackgroundAgentCard(
        enabled: backgroundEnabled,
        status: backgroundStatus,
        summary: backgroundSummary,
        mode: ref.watch(appSettingsProvider).backgroundMode,
        onCycle: () => _cycleBackground(ref),
      ),
      // 与页面各节统一的 16 间距,避免状态卡与设置卡贴成一块。
      const SizedBox(height: 16),
      // 后台 agent 启用时:维护功能 / 请求参数 / 上下文锚定 归入一张设置卡,
      // 世界书条目选择也收进同卡的上下文节,避免多张卡堆叠。
      if (backgroundEnabled)
        _BackgroundFeatureSelector(
          features: backgroundFeatures,
          onToggle: (name) => _toggleFeature(ref, name),
          // 当前后台专用模型(llm_models.id;null = 跟随主写)。
          backgroundModelId: ref.watch(appSettingsProvider).backgroundModelId,
          onModelSelected: (id) => _setBackgroundModel(ref, id),
          // 后台请求的推理强度(独立于主对话的设置)。
          backgroundReasoningLevel: ref
              .watch(appSettingsProvider)
              .backgroundReasoningLevel,
          onReasoningSelected: (level) => _setBackgroundReasoning(ref, level),
          // 上下文锚定段开关:角色卡/记忆是否进后台上下文。
          characterAnchor: ref
              .watch(appSettingsProvider)
              .backgroundCharacterAnchor,
          memoryAnchor: ref.watch(appSettingsProvider).backgroundMemoryAnchor,
          onAnchorToggle: (key) => _toggleAnchor(ref, key),
          // 变量删除前确认严格模式。
          deletionConfirm: deletionConfirm,
          onDeletionConfirmChanged: (v) =>
              _setBackgroundDeletionConfirm(ref, v),
          characterId: characterId,
        ),
    ];
    final dataSections = <Widget>[
      // ===== 变量(后台自动维护 + 用户手动增删改) =====
      Row(
        children: [
          const Expanded(child: SectionHeader('变量', icon: Icons.data_object)),
          variableRows.maybeWhen(
            data: (rows) => rows.isEmpty && trashCount == 0
                ? const SizedBox.shrink()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 回收站改为常驻入口(带数量角标):此前埋在三点菜单
                      // 里,删除后想恢复的用户很难再找到。
                      if (trashCount > 0)
                        IconButton(
                          tooltip: '已删除的变量($trashCount)',
                          icon: Badge(
                            label: Text('$trashCount'),
                            child: const Icon(
                              Icons.restore_from_trash_outlined,
                            ),
                          ),
                          onPressed: () => _showTrash(context),
                        ),
                      _sectionMenu(
                        scheme: scheme,
                        tooltip: '变量操作',
                        actions: [
                          const MenuAction(
                            value: 'add',
                            label: '新增变量',
                            icon: Icons.add,
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
                          } else if (action == 'clear') {
                            _clearVariables(context, ref);
                          }
                        },
                      ),
                    ],
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
                  const EmptyState(
                    compact: true,
                    icon: Icons.data_object,
                    title: '暂无变量',
                    message: '后台引擎尚未写入变量。也可以手动新增,作为后台维护的起始状态。',
                  ),
                  const SizedBox(height: 4),
                  // 与记忆/生图指导空态同一语言:动作作为卡内操作行,
                  // 不再用独立按钮与卡片混排。
                  GroupCard(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        leading: Icon(
                          Icons.add,
                          size: 20,
                          color: scheme.primary,
                        ),
                        title: const Text('新增变量'),
                        onTap: () => _addVariable(context, ref, rows),
                      ),
                    ],
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
                          VariableAccessBadge(access: variable.agentAccess),
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
                      onTap: () => _editVariable(context, ref, rows, variable),
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
        error: (e, _) => _EmptyHint('$e', isError: true),
        loading: () => const _SectionSkeleton(),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: PendingVariableDeletions(sessionId: sessionId),
      ),
      const SizedBox(height: 16),
      // ===== 记忆(用户主动维护) =====
      Row(
        children: [
          const Expanded(
            child: SectionHeader('记忆', icon: Icons.psychology_outlined),
          ),
          // 记忆每会话仅一条(schema UNIQUE(session_id)):点内容行直接编辑,
          // 重生成与清空都收进标题行菜单;非空时卡内只留「应用到上下文」。
          memories.maybeWhen(
            data: (list) => list.isEmpty
                ? const SizedBox.shrink()
                : _sectionMenu(
                    scheme: scheme,
                    tooltip: '记忆操作',
                    actions: [
                      MenuAction(
                        value: 'regenerate',
                        label: '重新生成',
                        icon: Icons.auto_awesome,
                        enabled: !running,
                      ),
                      const MenuAction(
                        value: 'clear',
                        label: '清空',
                        icon: Icons.delete_sweep_outlined,
                        destructive: true,
                      ),
                    ],
                    onSelected: (action) {
                      if (action == 'regenerate') {
                        ref
                            .read(chatControllerProvider.notifier)
                            .regenerateMemory();
                      } else if (action == 'clear') {
                        _clearMemory(context, ref);
                      }
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
                  const EmptyState(
                    compact: true,
                    icon: Icons.psychology_outlined,
                    title: '暂无记忆',
                    message: '尚无记忆。记忆是给主写模型的长期事实底本,可由 AI 依据角色卡生成,也可手动填写。',
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
                      // 记忆是状态面板里用户最常回看的长文本:给到 10 行,
                      // 与生图指导同高,仍不足以撑爆面板。
                      title: Text(
                        m.content,
                        maxLines: 10,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _editMemoryEntry(context, ref, m),
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
        error: (e, _) => _EmptyHint('$e', isError: true),
        loading: () => const _SectionSkeleton(),
      ),
      const SizedBox(height: 16),
      // ===== 生图指导(后台生图每轮携带) =====
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
                  const EmptyState(
                    compact: true,
                    icon: Icons.palette_outlined,
                    title: '暂无生图指导',
                    message: '尚无生图指导。指导固定角色外貌与画风,由后台生图每轮携带;可由 AI 生成,也可手动填写。',
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
                        onTap: () => _editImageGuide(context, ref, null),
                      ),
                    ],
                  ),
                ],
              )
            : GroupCard(
                // 点内容行直接编辑(与记忆行同一交互);清空在标题行菜单。
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(
                      list.first.content,
                      maxLines: 10,
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
        error: (e, _) => _EmptyHint('$e', isError: true),
        loading: () => const _SectionSkeleton(),
      ),
      // 生图指导是页面末区块:额外留出底部间隙,不贴屏幕底边。
      const SizedBox(height: 24),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('状态面板')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [...engineCards, const SizedBox(height: 16), ...dataSections],
      ),
    );
  }
}

/// 区块加载骨架:固定三行灰条,数据到达时的高度变化远小于一颗居中转圈,
/// 面板内三个区块加载时不再整体跳动。
class _SectionSkeleton extends StatelessWidget {
  const _SectionSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double widthFactor) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: 12,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
    return GroupCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [bar(0.4), bar(0.85), bar(0.65)],
          ),
        ),
      ],
    );
  }
}

/// 面板内的错误提示行(变量 / 记忆 / 生图指导三区块共用)。
/// 空态已统一为 [EmptyState] 紧凑档,这里只承担加载失败的红色提示。
class _EmptyHint extends StatelessWidget {
  final String text;
  final bool isError;
  const _EmptyHint(this.text, {this.isError = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(color: isError ? scheme.error : scheme.outline),
      ),
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
                const SheetHeader(title: '全部变量'),
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
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
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
                                VariableAccessBadge(
                                  access: variable.agentAccess,
                                  showLabel: false,
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
                                  widget.onDelete(context, ref, variable.key),
                            ),
                            onTap: () =>
                                widget.onEdit(context, ref, rows, variable),
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

  /// 恢复一条回收站变量:同名 active 变量仍存在时仓库拒绝,这里把两种结果
  /// 都提示出来;恢复后的权限固定为 protected,避免下一轮又被后台删掉。
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

  /// 清空本会话回收站:全部永久删除,不可恢复。
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
                SheetHeader(
                  title: '已删除的变量',
                  actions: [
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

/// 后台 agent 状态卡:合并的启停/模式按钮 + 最近一轮运行状态与一句话摘要。
class _BackgroundAgentCard extends StatelessWidget {
  final bool enabled;
  final BackgroundStatus status;
  final String summary;

  /// 当前后台运行模式与四态循环回调(关闭 → Legacy → Agentic → Hybrid → 关闭)。
  final BackgroundMode mode;
  final VoidCallback onCycle;
  const _BackgroundAgentCard({
    required this.enabled,
    required this.status,
    required this.summary,
    required this.mode,
    required this.onCycle,
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
            // 图标、标题/状态与合并按钮固定在同一行;摘要另起一行放在下方。
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
                        '后台引擎',
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
                const SizedBox(width: 8),
                _BackgroundEngineButton(
                  enabled: enabled,
                  mode: mode,
                  onPressed: onCycle,
                ),
              ],
            ),
            if (summary.isNotEmpty)
              Padding(
                // 与「模型与参数」里的下拉框同宽:卡片内再缩进 14,
                // 叠加卡片左右 16/8 后,灰块左右边缘与模型选择框对齐。
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                // 成功摘要可能列出本轮全部变更(变量增删改、图片生成中…),
                // 很长时默认折叠到 3 行,需要时再展开;失败等其它状态的
                // 引擎诊断摘要保持全文,便于直接回看错误。
                child: BackgroundSummaryView(
                  text: summary,
                  status: status,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 后台引擎合并按钮:胶囊同时承载启停与运行模式,点按循环四态
/// 关闭 → Legacy → Agentic → Hybrid → 关闭。
///
/// 胶囊高 32,密度显式取 standard,避免桌面主题默认 compact 再压低;
/// 关闭态转灰并换电源图标,悬停提示说明下一步动作。
class _BackgroundEngineButton extends StatelessWidget {
  final bool enabled;
  final BackgroundMode mode;
  final VoidCallback onPressed;
  const _BackgroundEngineButton({
    required this.enabled,
    required this.mode,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = enabled ? scheme.primary : scheme.onSurfaceVariant;
    final label = enabled ? mode.label : '已关闭';
    final nextAction = switch (mode) {
      BackgroundMode.legacy => '切换到 Agentic',
      BackgroundMode.agentic => '切换到 Hybrid',
      BackgroundMode.hybrid => '关闭后台引擎',
    };
    final tooltip = enabled
        ? '运行模式:${mode.label},${mode.hint};点击$nextAction'
        : '后台引擎已关闭;点击启用 Legacy 模式';
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        key: ValueKey('background_engine_${enabled ? mode.name : 'off'}'),
        onPressed: onPressed,
        icon: Icon(
          enabled ? Icons.swap_horiz : Icons.power_settings_new,
          size: 18,
        ),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          foregroundColor: foreground,
          iconColor: foreground,
          backgroundColor: foreground.withValues(alpha: enabled ? 0.12 : 0.06),
          side: BorderSide(
            color: foreground.withValues(alpha: enabled ? 0.5 : 0.35),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 后台 agent 设置卡:一张卡承载三个小节(维护功能 / 模型与参数 / 上下文
/// 锚定),小节间用细线分隔,相关控制彼此贴紧。
///
/// 维护功能只有变量与生图 —— 记忆与生图指导由用户主动维护,入口在上方
/// 各自区块,不属于这里的快状态功能。
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

  /// 角色卡/记忆是否进入后台上下文锚定段(后台 agent 区开关)。
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
    required this.characterAnchor,
    required this.memoryAnchor,
    required this.onAnchorToggle,
    required this.deletionConfirm,
    required this.onDeletionConfirmChanged,
    required this.characterId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(llmProvidersProvider);
    final providers = providersAsync.maybeWhen(
      data: (p) => p,
      orElse: () => const <LlmProviderConfig>[],
    );
    final models = flattenLlmModels(providers);
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
              // 严格模式只作用于后台变量删除:标题点明对象,说明全部收进弹层,
              // 开关行不再保留副标题。
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '变量删除前确认',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(width: 2),
                  InfoButton(
                    onTap: () => showDeletionConfirmHelpDialog(context),
                  ),
                ],
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
              helperText: '仅影响后台请求,与主对话的推理等级互相独立;默认关闭。',
              items: ReasoningLevel.values,
              labelOf: (level) => level.label,
              onChanged: (level) {
                if (level != null) onReasoningSelected(level);
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

/// 设置卡内的小节头:主色小图标 + 灰底标题,与外层卡形成层级。
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

/// 选择进入后台上下文的世界书条目(角色级):多选当前角色的条目,选定的
/// 进快状态轮的锚定段,落 [WorldbookEntry.background] 列;空选 = 不注入
/// 该锚定段。
///
/// 它排在设置卡「上下文锚定」小节的尾行,与角色卡 / 记忆两开关并列 ——
/// 三项同属「什么进后台上下文」这一维度。
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

/// 后台世界书条目多选底单:拖拽把手 + 标题 + 取消,圆角顶,高度封顶 85%。
/// 每行 = 勾选圆标 + 名称 + 两行内容预览,行尾箭头展开/收起完整内容
/// (长文内滚);标题行下带实时已选计数与全选/取消全选,底部保存键同样
/// 带计数。
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
