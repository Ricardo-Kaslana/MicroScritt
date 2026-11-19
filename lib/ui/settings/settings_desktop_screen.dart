/// 设置桌面工作台:分组侧栏 + 分区正文。
///
/// 宽窗(≥1000)使用本页;窄窗由 `SettingsScreen` 分发到移动单列页。分区
/// 首次访问才构建,已访问分区留在 IndexedStack 里保留滚动与表单状态。
library;

import 'package:flutter/material.dart';

import 'settings_desktop_workspaces.dart';
import 'settings_layout.dart';

const List<(String, List<SettingsDesktopSection>)> _sidebarGroups = [
  ('账户', [SettingsDesktopSection.user]),
  (
    '通用',
    [SettingsDesktopSection.appearance, SettingsDesktopSection.conversation],
  ),
  (
    '模型服务',
    [SettingsDesktopSection.llm, SettingsDesktopSection.image],
  ),
  (
    '内容与数据',
    [
      SettingsDesktopSection.extensions,
      SettingsDesktopSection.stats,
      SettingsDesktopSection.config,
    ],
  ),
];

class SettingsDesktopScreen extends StatefulWidget {
  const SettingsDesktopScreen({super.key});

  @override
  State<SettingsDesktopScreen> createState() => _SettingsDesktopScreenState();
}

class _SettingsDesktopScreenState extends State<SettingsDesktopScreen> {
  SettingsDesktopSection _section = SettingsDesktopSection.user;
  final Set<SettingsDesktopSection> _visited = {SettingsDesktopSection.user};

  void _openSection(SettingsDesktopSection section) {
    if (_section == section) return;
    setState(() {
      _section = section;
      _visited.add(section);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('settings_desktop_sidebar'),
            width: kSettingsDesktopSidebarWidth,
            child: _SettingsSidebar(
              section: _section,
              onSelect: _openSection,
            ),
          ),
          Expanded(
            key: const ValueKey('settings_desktop_workspace'),
            child: IndexedStack(
              index: _section.index,
              children: [
                for (final section in SettingsDesktopSection.values)
                  KeyedSubtree(
                    key: ValueKey('settings_section_${section.name}'),
                    child: _visited.contains(section)
                        ? SettingsDesktopWorkspace(section: section)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSidebar extends StatelessWidget {
  final SettingsDesktopSection section;
  final ValueChanged<SettingsDesktopSection> onSelect;

  const _SettingsSidebar({required this.section, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              primary: false,
              padding: const EdgeInsets.only(top: 6, bottom: 8),
              children: [
                for (final (title, sections) in _sidebarGroups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                    child: Text(
                      title,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  for (final item in sections)
                    _SettingsNavTile(
                      key: ValueKey('settings_nav_${item.name}'),
                      icon: item.icon,
                      label: item.label,
                      selected: section == item,
                      onTap: () => onSelect(item),
                    ),
                ],
              ],
            ),
          ),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
            child: _SettingsNavTile(
              key: const ValueKey('settings_nav_about'),
              icon: SettingsDesktopSection.about.icon,
              label: SettingsDesktopSection.about.label,
              selected: section == SettingsDesktopSection.about,
              onTap: () => onSelect(SettingsDesktopSection.about),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsNavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsNavTile({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          hoverColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 19,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected ? scheme.primary : scheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
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
