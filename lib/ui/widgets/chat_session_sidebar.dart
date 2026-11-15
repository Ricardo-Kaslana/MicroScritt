/// 桌面宽窗聊天页的会话侧栏:全部会话按角色卡分组,点击切换当前会话。
///
/// 视觉沿用应用的 iOS 分组语言:大标题与检索框对齐管理页(共用
/// [AppSearchField]),角色名作为分组标题比会话名更大(会话从属于角色,
/// 层级不能颠倒);会话行直接铺在侧栏底色上(不套卡片),靠缩进与字号
/// 表达归属;当前会话主色浅底 + 主色标题。置顶会话从角色分组抽到顶部
/// 「置顶」区(跨角色聚合、按置顶时间倒序),行内补角色名区分来源。
/// 侧栏只是导航面:数据来自 [sessionGroupsProvider](一次聚合查询 + 角色
/// 列表),切换/新建会话由宿主(ChatScreen)执行 —— 这里不直接导航、
/// 不读写消息库。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../data/character_repository.dart';
import '../../data/session_repository.dart';
import '../../state/providers.dart';
import '../common/app_menu.dart';
import '../common/app_search_field.dart';

/// 侧栏检索词(跨页面重建保留;不随侧栏卸载回收)。
final _sidebarQueryProvider = StateProvider<String>((ref) => '');

/// 会话行的「···」菜单动作(置顶 / 重命名 / 导出 / 删除),由宿主执行。
enum SessionSidebarAction { togglePin, rename, export, delete }

/// 会话侧栏:标题行 + 检索框 + 按角色分组的会话卡片。
class ChatSessionSidebar extends ConsumerStatefulWidget {
  /// 当前聊天会话 id:对应行高亮;点击同一行是空操作。
  final int currentSessionId;

  /// 选中一个会话(宿主负责切换页面)。
  final void Function(CharacterRecord character, SessionInfo session) onSelect;

  /// 在某个角色下新建会话并进入(宿主负责落库、刷新与导航)。
  final Future<void> Function(CharacterRecord character) onCreate;

  /// 会话行菜单动作(宿主负责弹窗、落库与刷新)。
  final void Function(SessionInfo session, SessionSidebarAction action)
  onSessionAction;

  /// 点击标题行的 home 键(宿主负责返回应用首页)。
  final VoidCallback onGoHome;

  const ChatSessionSidebar({
    super.key,
    required this.currentSessionId,
    required this.onSelect,
    required this.onCreate,
    required this.onSessionAction,
    required this.onGoHome,
  });

  @override
  ConsumerState<ChatSessionSidebar> createState() => _ChatSessionSidebarState();
}

class _ChatSessionSidebarState extends ConsumerState<ChatSessionSidebar> {
  late final TextEditingController _search = TextEditingController(
    text: ref.read(_sidebarQueryProvider),
  );

  /// 正在新建会话的角色 id(按钮转圈并禁用,防重复点击建出多条空会话)。
  int? _creatingFor;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _create(CharacterRecord character) async {
    if (_creatingFor != null) return;
    setState(() => _creatingFor = character.id);
    try {
      await widget.onCreate(character);
    } finally {
      if (mounted) setState(() => _creatingFor = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = ref.watch(sessionGroupsProvider);
    final query = ref.watch(_sidebarQueryProvider).trim().toLowerCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 与右窗 AppBar 同高的标题行,两侧文字基线齐平;右端 home 键
            // 一键回到应用首页(角色列表),不必逐层返回。
            SizedBox(
              height: kToolbarHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '会话',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '返回首页',
                      onPressed: widget.onGoHome,
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.home_outlined),
                    ),
                  ],
                ),
              ),
            ),
            AppSearchField(
              controller: _search,
              onChanged: (value) {
                ref.read(_sidebarQueryProvider.notifier).state = value;
              },
              hint: '搜索会话或角色',
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            ),
            Expanded(
              child: groups.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '会话加载失败',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.error,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () =>
                              ref.invalidate(sessionGroupsProvider),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
                data: (all) {
                  final entries = _entries(all, query);
                  if (entries.isEmpty) {
                    return Center(
                      child: Text(
                        query.isEmpty ? '还没有会话' : '没有匹配的会话',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: entries,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 把分组摊平成列表项:置顶区 + 区段标题 + 该角色会话行(空分组给一条
  /// 弱化占位提示;新建入口统一收在组头「+」,不另设蓝色行动行 —— 否则
  /// 与选中会话的主色标题同色,分不清哪个是当前会话)。置顶会话从角色
  /// 分组抽出,跨角色聚到顶部「置顶」区,行内补角色名区分来源;分组里
  /// 不再重复展示。检索只匹配角色名与会话标题 —— 侧栏不展示消息内容,
  /// 按内容检索会造成「命中了却看不到原因」;检索时只保留含命中会话的
  /// 分组。相邻分组之间垫一条 hairline 分割线,组与组的边界不靠间距猜。
  List<Widget> _entries(List<SessionGroup> groups, String query) {
    final entries = <Widget>[];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    bool matches(CharacterRecord character, SessionInfo session) =>
        query.isEmpty ||
        _title(session).toLowerCase().contains(query) ||
        _characterName(character).toLowerCase().contains(query);

    final pinned = [
      for (final group in groups)
        for (final session in group.sessions)
          if (session.pinnedAt != null && matches(group.character, session))
            (group.character, session),
    ]..sort((a, b) => b.$2.pinnedAt!.compareTo(a.$2.pinnedAt!));
    if (pinned.isNotEmpty) {
      entries.add(
        Padding(
          key: const ValueKey('sidebar-pinned-header'),
          padding: const EdgeInsets.fromLTRB(16, 4, 10, 6),
          child: Row(
            children: [
              // 24 宽占位对齐组头头像,区段标题与会话行文字同列。
              SizedBox(
                width: 24,
                height: 24,
                child: Icon(
                  Icons.push_pin_outlined,
                  size: 16,
                  color: scheme.outline,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '置顶',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ),
      );
      for (final (character, session) in pinned) {
        entries.add(_sessionRow(character, session, pinned: true));
      }
    }

    var first = pinned.isEmpty;
    for (final group in groups) {
      final nameMatches =
          query.isEmpty ||
          _characterName(group.character).toLowerCase().contains(query);
      final sessions = query.isEmpty || nameMatches
          ? group.sessions
          : group.sessions
                .where((s) => _title(s).toLowerCase().contains(query))
                .toList();
      // 检索找的是会话,空分组不参与;常规视图保留空分组作为新建入口。
      if (query.isNotEmpty && sessions.isEmpty) continue;
      // 置顶会话已在上方置顶区展示,分组里不再重复。
      final visible = [
        for (final s in sessions)
          if (s.pinnedAt == null) s,
      ];
      if (query.isNotEmpty && visible.isEmpty) continue;
      final creating = _creatingFor == group.character.id;
      if (!first) {
        entries.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(
              key: ValueKey('sidebar-group-divider-${group.character.id}'),
              height: 16,
              thickness: 0.5,
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        );
      }
      entries.add(
        Padding(
          padding: EdgeInsets.fromLTRB(16, first ? 4 : 12, 10, 6),
          child: _GroupHeader(
            key: ValueKey('sidebar-group-${group.character.id}'),
            character: group.character,
            creating: creating,
            // 组头「+」是唯一的新建入口,空分组同样可用(此前空分组禁用,
            // 点按无反应)。
            onCreate: _creatingFor == null
                ? () => _create(group.character)
                : null,
          ),
        ),
      );
      first = false;
      // 会话行不套卡片:扁平列表直接铺在侧栏底色上,靠左缩进(对齐组头
      // 名称,即头像右侧)表达从属关系;选中/悬停底色全宽,与侧栏的贴边
      // 面板风格一致。
      if (visible.isEmpty) {
        // 角色确实没有会话才提示「还没有会话」;会话全部置顶时给一条
        // 弱化说明,避免组头下出现无解释的空白。
        entries.add(
          _EmptyGroupHint(
            key: ValueKey('sidebar-empty-${group.character.id}'),
            text: group.sessions.isEmpty ? '还没有会话' : '会话已全部置顶',
          ),
        );
      } else {
        for (final session in visible) {
          entries.add(_sessionRow(group.character, session, pinned: false));
        }
      }
    }
    return entries;
  }

  Widget _sessionRow(
    CharacterRecord character,
    SessionInfo session, {
    required bool pinned,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return _SessionRow(
      key: ValueKey(
        pinned
            ? 'sidebar-pinned-session-${session.id}'
            : 'sidebar-session-${session.id}',
      ),
      title: _title(session),
      // 置顶区跨角色聚合,行内补角色名区分来源;分组内无需重复。
      characterName: pinned ? _characterName(character) : null,
      messageCount: session.messageCount,
      selected: session.id == widget.currentSessionId,
      onTap: () => widget.onSelect(character, session),
      menu: SizedBox(
        // 收窄 IconButton 默认 48 的命中盒,行高保持紧凑;
        // 悬停行时 AnimatedOpacity 淡入,选中行常驻。
        width: 30,
        height: 30,
        child: AppPopupMenuButton<SessionSidebarAction>(
          key: ValueKey(
            pinned
                ? 'sidebar-pinned-menu-${session.id}'
                : 'sidebar-menu-${session.id}',
          ),
          tooltip: '更多操作',
          icon: Icons.more_horiz,
          iconSize: 18,
          iconColor: scheme.onSurfaceVariant,
          padding: EdgeInsets.zero,
          onSelected: (action) => widget.onSessionAction(session, action),
          actions: [
            MenuAction(
              value: SessionSidebarAction.togglePin,
              label: pinned ? '取消置顶' : '置顶',
              icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
            ),
            const MenuAction(
              value: SessionSidebarAction.rename,
              label: '重命名',
              icon: Icons.edit_outlined,
            ),
            const MenuAction(
              value: SessionSidebarAction.export,
              label: '导出',
              icon: Icons.file_download_outlined,
            ),
            const MenuAction(
              value: SessionSidebarAction.delete,
              label: '删除',
              icon: Icons.delete_outline,
              destructive: true,
            ),
          ],
        ),
      ),
    );
  }

  static String _title(SessionInfo s) =>
      s.title.trim().isEmpty ? '会话 #${s.id}' : s.title;
}

/// 角色展示名:名片为空时回落到 id,避免组头/置顶行出现空白标题。
String _characterName(CharacterRecord c) {
  final name = c.card.name.trim();
  return name.isEmpty ? '角色 #${c.id}' : name;
}

/// 分组标题:角色头像 + 名称 + 快捷新建。名称刻意大于组内会话名
/// (titleMedium 16 > bodyMedium 14),从视觉上表明会话从属于角色。
/// 「+」与行尾「···」同节奏:鼠标悬浮组头才浮现,平时不占视觉噪声。
class _GroupHeader extends ConsumerStatefulWidget {
  final CharacterRecord character;
  final bool creating;
  final VoidCallback? onCreate;

  const _GroupHeader({
    super.key,
    required this.character,
    required this.creating,
    required this.onCreate,
  });

  @override
  ConsumerState<_GroupHeader> createState() => _GroupHeaderState();
}

class _GroupHeaderState extends ConsumerState<_GroupHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final character = widget.character;
    final avatar = ref.watch(characterAvatarProvider(character.id));
    final bytes = avatar.value;
    final name = _characterName(character);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(
        children: [
          // 头像 24(此前 16 太小,缩小截图或字体缩放后几乎看不清)。组头
          // 行高与右侧「+」键(28)对齐。
          CircleAvatar(
            radius: 12,
            backgroundColor: scheme.secondaryContainer,
            foregroundImage: bytes == null ? null : MemoryImage(bytes),
            onForegroundImageError: bytes == null ? null : (_, __) {},
            child: Text(
              name.characters.first,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (widget.creating)
            Padding(
              padding: const EdgeInsets.all(6),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            // 隐藏时同时退出命中测试:悬停前点不可见区域不应误建会话;
            // 透明度过渡保留 28 宽占位,浮出时名字不跳动。
            IgnorePointer(
              ignoring: !_hovered,
              child: AnimatedOpacity(
                opacity: _hovered ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: IconButton(
                  tooltip: '新建会话',
                  onPressed: widget.onCreate,
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  padding: EdgeInsets.zero,
                  color: scheme.outline,
                  icon: const Icon(Icons.add),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 会话行:标题 + 消息条数尾注。刻意不展示消息内容,信息位留给可扫读的
/// 元数据;「···」操作菜单悬停或选中时浮现,避免每行常驻一枚图标拉高噪声。
/// 置顶区的行额外在标题后带角色名(跨角色聚合时区分来源)。
class _SessionRow extends StatefulWidget {
  final String title;
  final int messageCount;
  final bool selected;
  final VoidCallback onTap;

  /// 置顶区行内展示的角色名;分组内为 null(组头已表明归属)。
  final String? characterName;

  /// 行尾操作菜单(由宿主构建的动作项)。
  final Widget menu;

  const _SessionRow({
    super.key,
    required this.title,
    required this.messageCount,
    required this.selected,
    required this.onTap,
    required this.menu,
    this.characterName,
  });

  @override
  State<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends State<_SessionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.09)
            : Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          hoverColor: scheme.primary.withValues(alpha: 0.04),
          // 铺满侧栏宽、左缘缩进对齐组头名称(16 页边距 + 24 头像 + 10
          // 间距):选中底色与悬停反馈全宽,文字与会话从属关系一眼可见。
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(50, 0, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text.rich(
                        TextSpan(
                          text: widget.title,
                          children: [
                            if (widget.characterName != null)
                              TextSpan(
                                text: '  ${widget.characterName}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: selected ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                  if (widget.messageCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        '${widget.messageCount} 条',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                    ),
                  AnimatedOpacity(
                    opacity: _hovered || selected ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: widget.menu,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 空分组(或会话全部置顶)的弱化占位行:新建入口在组头「+」,这里只说明
/// 该角色当前没有可列出的会话,刻意不用主色/可点击样式,避免与选中会话的
/// 蓝色标题混淆。
class _EmptyGroupHint extends StatelessWidget {
  final String text;
  const _EmptyGroupHint({super.key, this.text = '还没有会话'});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 同会话行:铺满侧栏宽,文案缩进对齐组头名称。
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(50, 10, 16, 10),
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
