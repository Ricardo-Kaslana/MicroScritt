/// 设置工作台的九个分区:用户、外观、对话与后台、LLM 后端、生图、内容与
/// 扩展、统计、配置、关于。
///
/// 全部写操作走 `settings_actions.dart` 的共享函数;子页面(技能、提示词、
/// Hooks、正则、统计、生图插件/风格)沿用各自原有的独立页面。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
import '../../state/providers.dart';
import '../common/form_row.dart';
import '../common/info_button.dart';
import '../common/section_header.dart';
import '../hooks_screen.dart';
import '../image_plugins_screen.dart';
import '../image_provider_edit_screen.dart';
import '../image_styles_screen.dart';
import '../prompt_items_screen.dart';
import '../provider_edit_screen.dart';
import '../regex_scripts_screen.dart';
import '../skills_screen.dart';
import '../usage_stats_screen.dart';
import '../user_profile_form.dart';
import 'settings_actions.dart';
import 'settings_layout.dart';
import 'settings_provider_sections.dart';
import 'settings_workspace.dart';

/// 按分区构建正文;壳层用 IndexedStack 保留已访问分区的状态。
class SettingsDesktopWorkspace extends StatelessWidget {
  final SettingsDesktopSection section;

  const SettingsDesktopWorkspace({super.key, required this.section});

  @override
  Widget build(BuildContext context) {
    return switch (section) {
      SettingsDesktopSection.user => _UserWorkspace(section),
      SettingsDesktopSection.appearance => _AppearanceWorkspace(section),
      SettingsDesktopSection.conversation => _ConversationWorkspace(section),
      SettingsDesktopSection.llm => _LlmWorkspace(section),
      SettingsDesktopSection.image => _ImageWorkspace(section),
      SettingsDesktopSection.extensions => _ExtensionsWorkspace(section),
      SettingsDesktopSection.stats => _StatsWorkspace(section),
      SettingsDesktopSection.config => _ConfigWorkspace(section),
      SettingsDesktopSection.about => _AboutWorkspace(section),
    };
  }
}

class _UserWorkspace extends StatelessWidget {
  final SettingsDesktopSection section;
  const _UserWorkspace(this.section);

  @override
  Widget build(BuildContext context) {
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_user'),
        padding: const EdgeInsets.only(bottom: 24),
        children: const [
          SurfaceCard(
            padding: EdgeInsets.zero,
            child: UserProfileForm(wide: true),
          ),
        ],
      ),
    );
  }
}

class _AppearanceWorkspace extends StatelessWidget {
  final SettingsDesktopSection section;
  const _AppearanceWorkspace(this.section);

  @override
  Widget build(BuildContext context) {
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_appearance'),
        padding: const EdgeInsets.only(bottom: 24),
        children: const [_AppearanceSettingsCard()],
      ),
    );
  }
}

class _AppearanceSettingsCard extends ConsumerWidget {
  const _AppearanceSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final blur = ref.watch(chatBackgroundBlurProvider);
    final enabled = settings.chatBackgroundEnabled;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsFormRow(
            key: const ValueKey('settings_theme_row'),
            icon: Icons.brightness_6_outlined,
            title: '主题',
            description: '选择应用整体明暗;跟随系统会随操作系统切换。',
            control: SegmentedButton<AppThemeMode>(
              key: const ValueKey('settings_theme_selector'),
              segments: const [
                ButtonSegment(
                  value: AppThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto),
                ),
                ButtonSegment(
                  value: AppThemeMode.light,
                  label: Text('浅色'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: AppThemeMode.dark,
                  label: Text('深色'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {settings.themeMode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  saveThemeMode(ref, selection.first),
            ),
          ),
          const SettingsFormDivider(),
          SettingsFormRow(
            icon: Icons.wallpaper_outlined,
            title: '聊天背景',
            description: '开启后聊天页显示角色卡背景图;未设置背景图时使用角色头像。',
            stackBreakpoint: 0,
            control: Switch(
              key: const ValueKey('settings_chat_background_switch'),
              value: enabled,
              onChanged: (v) => saveChatBackgroundEnabled(ref, v),
            ),
          ),
          const SettingsFormDivider(),
          SettingsFormRow(
            icon: Icons.blur_on_outlined,
            title: '背景模糊度',
            description: '仅作用于聊天页背景图;关闭聊天背景时不可调整。',
            control: SettingsSliderControl(
              sliderKey: const ValueKey('chatBackgroundBlurSlider'),
              valueLabel: '${blur.round()}',
              value: blur,
              min: 0,
              max: 32,
              enabled: enabled,
              onChanged: (v) =>
                  ref.read(chatBackgroundBlurProvider.notifier).state = v,
              onChangeEnd: (v) => saveChatBackgroundBlur(ref, v),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationWorkspace extends StatelessWidget {
  final SettingsDesktopSection section;
  const _ConversationWorkspace(this.section);

  @override
  Widget build(BuildContext context) {
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_conversation'),
        padding: const EdgeInsets.only(bottom: 24),
        children: const [_ConversationSettingsCard()],
      ),
    );
  }
}

class _ConversationSettingsCard extends ConsumerStatefulWidget {
  const _ConversationSettingsCard();

  @override
  ConsumerState<_ConversationSettingsCard> createState() =>
      _ConversationSettingsCardState();
}

class _ConversationSettingsCardState
    extends ConsumerState<_ConversationSettingsCard> {
  /// 拖动触发线时只更新草稿(即时反馈),松手才落库。
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final threshold = AppSettings.clampAutoCompactThreshold(
      _draft ?? settings.autoCompactThreshold,
    );
    final pct = (threshold * 100).round();
    final enabled = settings.autoCompactEnabled;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsFormRow(
            key: const ValueKey('settings_auto_compact_row'),
            icon: Icons.compress_outlined,
            title: '上下文自动压缩',
            description: '按窗口占用率自动压缩 · 触发线 $pct%',
            titleTrailing: InfoButton(
              onTap: () => showAutoCompactHelpDialog(context, ref),
            ),
            stackBreakpoint: 0,
            control: Switch(
              key: const ValueKey('settings_auto_compact_switch'),
              value: enabled,
              onChanged: (v) =>
                  saveTurnSettings(ref, autoCompactEnabled: v),
            ),
          ),
          const SettingsFormDivider(),
          SettingsFormRow(
            icon: Icons.percent,
            title: '自动压缩触发线',
            description: '占用率达到该线后自动摘要压缩;发送前预算检测也会使用派生强制线。',
            control: SettingsSliderControl(
              sliderKey: const ValueKey('autoCompactThresholdSlider'),
              valueLabel: '$pct%',
              value: threshold,
              min: AppSettings.minAutoCompactThreshold,
              max: AppSettings.maxAutoCompactThreshold,
              divisions: 12,
              enabled: enabled,
              onChanged: (v) => setState(
                () => _draft = AppSettings.clampAutoCompactThreshold(v),
              ),
              onChangeEnd: (v) {
                setState(() => _draft = null);
                saveTurnSettings(
                  ref,
                  autoCompactThreshold:
                      AppSettings.clampAutoCompactThreshold(v),
                );
              },
            ),
          ),
          const SettingsFormDivider(),
          SettingsFormRow(
            icon: Icons.attach_file,
            title: '单轮附件上限',
            description: '每轮最多自动注入的世界书附件条数;@技能与通知不受限。',
            stackBreakpoint: 0,
            control: DropdownButton<int>(
              key: const ValueKey('settings_attachment_dropdown'),
              value: const [0, 2, 5, 10, 20].contains(
                settings.maxAutoAttachments,
              )
                  ? settings.maxAutoAttachments
                  : 5,
              underline: const SizedBox.shrink(),
              dropdownColor: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              menuMaxHeight: 240,
              style: TextStyle(fontSize: 14, color: scheme.onSurface),
              iconSize: 20,
              iconEnabledColor: scheme.onSurfaceVariant,
              items: const [
                DropdownMenuItem(value: 0, child: Text('关闭')),
                DropdownMenuItem(value: 2, child: Text('最多 2 条')),
                DropdownMenuItem(value: 5, child: Text('最多 5 条')),
                DropdownMenuItem(value: 10, child: Text('最多 10 条')),
                DropdownMenuItem(value: 20, child: Text('最多 20 条')),
              ],
              onChanged: (v) => v == null
                  ? null
                  : saveTurnSettings(ref, maxAutoAttachments: v),
            ),
          ),
        ],
      ),
    );
  }
}

class _LlmWorkspace extends ConsumerWidget {
  final SettingsDesktopSection section;
  const _LlmWorkspace(this.section);

  void _openEditor(BuildContext context, WidgetRef ref) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProviderEditScreen()),
    ).then((_) {
      if (context.mounted) ref.invalidate(llmProvidersProvider);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
        actions: [
          FilledButton.tonalIcon(
            key: const ValueKey('settings_add_provider'),
            onPressed: () => _openEditor(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('添加 Provider'),
          ),
        ],
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_llm'),
        padding: const EdgeInsets.only(bottom: 24),
        children: const [LlmProviderSection(showAddButton: false)],
      ),
    );
  }
}

class _ImageWorkspace extends ConsumerWidget {
  final SettingsDesktopSection section;
  const _ImageWorkspace(this.section);

  void _openAdd(BuildContext context, WidgetRef ref) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ImageProviderEditScreen()),
    ).then((_) {
      if (context.mounted) ref.invalidate(imageProvidersProvider);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeConfig = ref.watch(imageConfigProvider);
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
        actions: [
          FilledButton.tonalIcon(
            key: const ValueKey('settings_add_image_provider'),
            onPressed: () => _openAdd(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('添加生图配置'),
          ),
        ],
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_image'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const ImageProviderSection(
            showAddButton: false,
            showManageButtons: false,
          ),
          const SizedBox(height: 16),
          SettingsResponsiveColumns(
            children: [
              SettingsLinkCard(
                key: const ValueKey('settings_plugins_entry'),
                icon: Icons.extension_outlined,
                title: '管理生图插件',
                description: '内置协议与自定义插件;导入 JSON 即可扩展服务',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ImagePluginsScreen()),
                ),
              ),
              SettingsLinkCard(
                key: const ValueKey('settings_styles_entry'),
                icon: Icons.palette_outlined,
                title: '管理自定义风格',
                description: '为生图提示词追加画风前缀与采样参数',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ImageStylesScreen(
                      prefill: stylePrefillFromConfig(activeConfig),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExtensionsWorkspace extends StatelessWidget {
  final SettingsDesktopSection section;
  const _ExtensionsWorkspace(this.section);

  @override
  Widget build(BuildContext context) {
    void open(Widget page) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    }

    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_extensions'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SettingsResponsiveColumns(
            children: [
              SettingsLinkCard(
                icon: Icons.extension_outlined,
                title: '技能',
                description: '全局技能目录,所有会话生效',
                onTap: () => open(const SkillsScreen()),
              ),
              SettingsLinkCard(
                icon: Icons.notes_outlined,
                title: '全局提示词',
                description: '预设 / 规则,拼进系统提示词',
                onTap: () => open(const PromptItemsScreen()),
              ),
              SettingsLinkCard(
                icon: Icons.code_outlined,
                title: 'Hooks',
                description: 'JS 脚本改写输入/提示词/回复',
                onTap: () => open(const HooksScreen()),
              ),
              SettingsLinkCard(
                icon: Icons.manage_search_outlined,
                title: '正则脚本',
                description: '气泡显示层的查找替换与高亮标记',
                onTap: () => open(const RegexScriptsScreen()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatsWorkspace extends StatelessWidget {
  final SettingsDesktopSection section;
  const _StatsWorkspace(this.section);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_stats'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SettingsLinkCard(
            key: const ValueKey('settings_open_usage_stats'),
            icon: Icons.insights_outlined,
            title: '用量统计',
            description: '累计 Token / 请求次数 / 缓存命中与每日趋势',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const UsageStatsScreen()),
            ),
          ),
          const SizedBox(height: 16),
          SurfaceCard(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '数据来源是逐请求用量明细:每条请求记录输入/输出 Token、'
                    '缓存命中与耗时;总览为应用使用至今的累计值,趋势与模型分布'
                    '可切换 7 / 30 天。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfigWorkspace extends ConsumerWidget {
  final SettingsDesktopSection section;
  const _ConfigWorkspace(this.section);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final configFile = ref.watch(appConfigFileProvider);
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_config'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SettingsResponsiveColumns(
            children: [
              SettingsActionCard(
                key: const ValueKey('settings_config_export'),
                icon: Icons.file_download_outlined,
                title: '导出配置',
                description: '用户名与 LLM 后端(含 API Key,请妥善保管)',
                actionLabel: '导出',
                onPressed: () => exportSettingsConfig(context, ref),
              ),
              SettingsActionCard(
                key: const ValueKey('settings_config_import'),
                icon: Icons.file_upload_outlined,
                title: '导入配置',
                description: '从 JSON 文件恢复,覆盖当前用户名与 LLM 后端',
                actionLabel: '导入',
                onPressed: () => importSettingsConfig(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SurfaceCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SettingsCardTitle(
                  icon: Icons.folder_outlined,
                  title: '配置文件',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        configFile?.path ?? '未启用',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('settings_config_copy'),
                      tooltip: '复制路径',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: configFile == null
                          ? null
                          : () => copyConfigFilePath(context, configFile.path),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '启动时以该文件为准应用用户名与 LLM provider;页面修改会回写。'
                  '文件含明文 API Key,请勿公开分享。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutWorkspace extends StatelessWidget {
  final SettingsDesktopSection section;
  const _AboutWorkspace(this.section);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SettingsWorkspaceFrame(
      header: SettingsWorkspaceHeader(
        title: section.label,
        description: section.description,
      ),
      child: ListView(
        primary: false,
        key: const ValueKey('settings_scroll_about'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SurfaceCard(
            padding: const EdgeInsets.all(24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.auto_stories_outlined,
                    size: 26,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MicroScritt',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '移动端优先的极简 AI 角色扮演应用。',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '纯客户端运行:对话、生图、Hook 与数据全部保存在本地;'
                        'LLM 只接收纯文本上下文,图片只留在消息记录与界面渲染中。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
