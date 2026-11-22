/// 会话状态面板:后台 agent 的启停与参数,以及变量 / 记忆 / 生图指导的人工
/// 维护入口。
///
/// 变量默认只供后台请求使用,不进主写上下文(Agentic 注入在下一条用户输入时
/// 以附件行生效),所以这里的变量写操作只失效变量
/// 相关 provider;记忆以冻结副本占据上下文第 0 条,手工编辑/清空后只更新
/// 库与列表,需点「应用到上下文」才整体换新(因此也不重算上下文快照)。
/// 变量删除一律先进回收站;严格模式(`background_deletion_confirm`)下后台
/// 的删除提议只写待确认建议,由本页确认后才移入回收站。
///
/// 页面组装留在本文件;变量弹层、后台引擎组件与区块骨架按同库 part 拆在
/// `status/` 下。
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
import 'common/app_sheet.dart';
import 'common/async_section.dart';
import 'common/app_snack_bar.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/form_field.dart';
import 'common/form_row.dart';
import 'common/info_button.dart';
import 'common/section_header.dart';
import 'common/sheet_header.dart';
import 'common/text_edit_sheet.dart';
import 'common/variable_edit_sheet.dart';
import 'status/status_desktop_screen.dart';
import 'status/status_dialogs.dart';
import 'status/status_layout.dart';
import 'status/status_widgets.dart';
import '../models/memory.dart';

part 'status/status_panel_widgets.dart';
part 'status/status_variable_sheets.dart';
part 'status/status_background_widgets.dart';

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
/// 变量默认只供后台请求使用,不进主写上下文(Agentic 注入在下一条用户输入时
/// 以附件行生效),所以这里的变量写操作只失效变量
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
    final confirmed = await confirmApplyMemoryToContext(
      context,
      pending: pending,
    );
    if (!confirmed) return;
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

  /// 设置 Agentic 变量注入主写附件开关并落库。
  Future<void> _setBackgroundVariableInjection(
    WidgetRef ref,
    bool enabled,
  ) async {
    await persistBackgroundVariableInjection(
      enabled: enabled,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
    );
  }

  /// 设置 Agentic 下一步建议开关并落库。
  Future<void> _setBackgroundNextSuggestions(
    WidgetRef ref,
    bool enabled,
  ) async {
    await persistBackgroundNextSuggestions(
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
  // 关键约束:**改完不要调 refreshContext()** —— 变量默认不进主写组装,
  // 只作为后台下一轮的输入(Agentic 注入在发送时消费);失效变量相关 provider
  // 就够了。加上 refreshContext 只会白跑一次组装,还会给人「变量会影响正文」
  // 的错觉。

  /// active 变量视图与其它派生面板的刷新。变量默认不进主写上下文,无需
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
    return showAppSheet<void>(
      context,
      builder: (_) => _VariableTrashSheet(sessionId: sessionId),
    );
  }

  /// 变量全量视图:状态面板只预览前几条,条目多时在这里用虚拟化列表滚动查看。
  Future<void> _showAllVariables(BuildContext context) {
    return showAppSheet<void>(
      context,
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
          // Agentic 增强:注入依赖变量维护,建议依赖 Agentic 模式。
          mode: ref.watch(appSettingsProvider).backgroundMode,
          variableInjection: ref
              .watch(appSettingsProvider)
              .backgroundVariableInjection,
          onVariableInjectionChanged: (v) =>
              _setBackgroundVariableInjection(ref, v),
          nextSuggestions: ref
              .watch(appSettingsProvider)
              .backgroundNextSuggestions,
          onNextSuggestionsChanged: (v) =>
              _setBackgroundNextSuggestions(ref, v),
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
      if (chatState.memoryProposal != null) ...[
        MemoryProposalCard(
          proposal: chatState.memoryProposal!,
          enabled: !running,
          onAccept: () => ref
              .read(chatControllerProvider.notifier)
              .acceptMemoryProposal(),
          onDismiss: () => ref
              .read(chatControllerProvider.notifier)
              .dismissMemoryProposal(),
        ),
        const SizedBox(height: 8),
      ],
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
                            .regenerateImageGuide();
                      } else if (action == 'clear') {
                        _clearImageGuide(context, ref);
                      }
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
