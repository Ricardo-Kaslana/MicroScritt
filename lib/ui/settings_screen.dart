/// 设置页入口:窄窗使用移动单列页,宽窗(≥1000)进入桌面分区工作台。
///
/// 文本配置文件(`microscritt-config.json`)含明文 API Key,导入会覆盖用户名
/// 与全部 provider;列表项副标题必须保留这条警告。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../state/providers.dart';
import 'common/form_row.dart';
import 'common/info_button.dart';
import 'common/section_header.dart';
import 'hooks_screen.dart';
import 'prompt_items_screen.dart';
import 'regex_scripts_screen.dart';
import 'settings/image_storage_section.dart';
import 'settings/settings_actions.dart';
import 'settings/settings_desktop_screen.dart';
import 'settings/settings_layout.dart';
import 'settings/settings_provider_sections.dart';
import 'skills_screen.dart';
import 'usage_stats_screen.dart';
import 'user_screen.dart';

/// 设置入口,从角色列表与模型选择器进入。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MediaQuery.sizeOf(context).width >= kSettingsDesktopBreakpoint
        ? const SettingsDesktopScreen()
        : const SettingsMobileScreen();
  }
}

/// 移动端设置页:一条 iOS 分组表单。
///
/// 本页偏好项(主题、聊天背景、压缩与附件上限)直接落库并同步内存状态;
/// provider 与生图配置跳独立编辑页。文本配置导入成功/失败都只回 SnackBar,
/// 成功后重新水合用户/后端/设置快照。
class SettingsMobileScreen extends ConsumerStatefulWidget {
  const SettingsMobileScreen({super.key});

  @override
  ConsumerState<SettingsMobileScreen> createState() =>
      _SettingsMobileScreenState();
}

class _SettingsMobileScreenState extends ConsumerState<SettingsMobileScreen> {
  /// 触发线滑块的拖动草稿:拖动时只更新内存(即时反馈),松手才落库。
  double? _compactThresholdDraft;

  @override
  Widget build(BuildContext context) {
    final appSettings = ref.watch(appSettingsProvider);
    final backgroundBlur = ref.watch(chatBackgroundBlurProvider);
    final compactThreshold = AppSettings.clampAutoCompactThreshold(
      _compactThresholdDraft ?? appSettings.autoCompactThreshold,
    );
    final compactSoftPct = (compactThreshold * 100).round();
    final configFile = ref.watch(appConfigFileProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ===== 用户 =====
          const SectionHeader('用户', icon: Icons.person_outline),
          GroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('用户管理'),
                subtitle: const Text('设置用户名与头像 · 正文 {{user}} 替换'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const UserScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ===== 外观 =====
          const SectionHeader('外观', icon: Icons.palette_outlined),
          GroupCard(
            children: [
              // 主题:三段等分铺满整张卡。移动端不显示图标与选中勾,并把段内
              // 水平 padding 收紧 —— 带图标时窄屏/大字号会撑出卡片,只能靠
              // 横向滚动兜底;现在超出段宽的文字在段内换行(按钮变高),不会
              // 再产生横向滚动。
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: SegmentedButton<AppThemeMode>(
                  key: const ValueKey('settings_theme_selector'),
                  expandedInsets: EdgeInsets.zero,
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: AppThemeMode.system,
                      label: Text('跟随系统'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.light,
                      label: Text('浅色'),
                    ),
                    ButtonSegment(
                      value: AppThemeMode.dark,
                      label: Text('深色'),
                    ),
                  ],
                  selected: {appSettings.themeMode},
                  onSelectionChanged: (sel) => saveThemeMode(ref, sel.first),
                ),
              ),
              // 聊天背景:Switch 在标题行;模糊度滑块在副标题位置紧贴开关,绑成一项。
              // 关闭时整段连滑块一起置灰;拖动只更新内存(即时反馈),松手才落库。
              SettingsSwitchTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                icon: Icons.wallpaper_outlined,
                title: '聊天背景',
                description: '开启后聊天页显示角色卡背景图;未设置背景图时使用角色头像',
                value: appSettings.chatBackgroundEnabled,
                onChanged: (v) => saveChatBackgroundEnabled(ref, v),
              ),
              // 模糊度行:滑块与实时数字共用 subtitle 槽位,开关关闭时整段禁用。
              SettingsSliderTile(
                title: '背景模糊度',
                valueLabel: '${backgroundBlur.round()}',
                value: backgroundBlur,
                min: 0,
                max: 32,
                sliderKey: const ValueKey('chatBackgroundBlurSlider'),
                enabled: appSettings.chatBackgroundEnabled,
                onChanged: (v) =>
                    ref.read(chatBackgroundBlurProvider.notifier).state = v,
                onChangeEnd: (v) => saveChatBackgroundBlur(ref, v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ===== 对话与后台 =====
          const SectionHeader('对话与后台', icon: Icons.tune_outlined),
          GroupCard(
            children: [
              SettingsSwitchTile(
                // 三挡/重试/兜底细节收进标题旁的说明弹层,副标题只留一行状态。
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                icon: Icons.compress_outlined,
                title: '上下文自动压缩',
                titleTrailing: InfoButton(
                  onTap: () => showAutoCompactHelpDialog(context, ref),
                ),
                description: '按窗口占用率自动压缩 · 触发线 $compactSoftPct%',
                value: appSettings.autoCompactEnabled,
                onChanged: (v) => saveTurnSettings(ref, autoCompactEnabled: v),
              ),
              // 触发线行:拖动只更新内存(即时反馈),松手才落库。
              SettingsSliderTile(
                title: '自动压缩触发线',
                valueLabel: '$compactSoftPct%',
                value: compactThreshold,
                min: AppSettings.minAutoCompactThreshold,
                max: AppSettings.maxAutoCompactThreshold,
                divisions: 12,
                sliderLabel: '$compactSoftPct%',
                sliderKey: const ValueKey('autoCompactThresholdSlider'),
                enabled: appSettings.autoCompactEnabled,
                onChanged: (v) => setState(
                  () => _compactThresholdDraft =
                      AppSettings.clampAutoCompactThreshold(v),
                ),
                onChangeEnd: (v) {
                  setState(() => _compactThresholdDraft = null);
                  saveTurnSettings(
                    ref,
                    autoCompactThreshold: AppSettings.clampAutoCompactThreshold(
                      v,
                    ),
                  );
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: const Icon(Icons.attach_file),
                title: const Text('单轮附件上限'),
                subtitle: const Text('每轮最多自动注入的世界书附件条数 · @技能与通知不受限'),
                trailing: SettingsDropdown<int>(
                  value:
                      const [
                        0,
                        2,
                        5,
                        10,
                        20,
                      ].contains(appSettings.maxAutoAttachments)
                      ? appSettings.maxAutoAttachments
                      : 5,
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
          const SizedBox(height: 16),
          // ===== LLM 后端 =====
          const SectionHeader('LLM 后端', icon: Icons.dns_outlined),
          const LlmProviderSection(),
          const SizedBox(height: 16),
          // ===== 生图 =====
          // 生图配置是多行表:列表管理多套配置,每套自带密钥;编辑在独立
          // 页面,与上方「LLM 后端」同一套交互。
          const SectionHeader('生图', icon: Icons.image_outlined),
          const ImageProviderSection(),
          const SizedBox(height: 16),
          // ===== 内容与扩展 =====
          const SectionHeader('内容与扩展', icon: Icons.extension_outlined),
          GroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.extension_outlined),
                title: const Text('技能'),
                subtitle: const Text('全局技能目录,所有会话生效'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SkillsScreen()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.notes_outlined),
                title: const Text('全局提示词'),
                subtitle: const Text('预设 / 规则,拼进系统提示词'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PromptItemsScreen()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.code_outlined),
                title: const Text('Hooks'),
                subtitle: const Text('JS 脚本改写输入/提示词/回复'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HooksScreen()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.manage_search_outlined),
                title: const Text('正则脚本'),
                subtitle: const Text('气泡显示层的查找替换与高亮标记'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RegexScriptsScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ===== 统计 =====
          // 独立页面:逐请求用量明细的全量总览、热力图、趋势与模型分布。
          const SectionHeader('统计', icon: Icons.bar_chart_outlined),
          GroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.insights_outlined),
                title: const Text('用量统计'),
                subtitle: const Text('累计 Token / 请求次数 / 缓存命中与每日趋势'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const UsageStatsScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ===== 图片与存储 =====
          const SectionHeader('图片与存储', icon: Icons.cleaning_services_outlined),
          const ImageStorageSection(),
          const SizedBox(height: 16),
          // ===== 配置 =====
          // 用户名与 LLM 后端另存一份纯文本配置文件(启动读取、修改回写),
          // 这里提供手动导出/导入,方便换机与外部编辑。
          const SectionHeader('配置', icon: Icons.settings_outlined),
          GroupCard(
            children: [
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('导出配置'),
                subtitle: const Text(
                  '用户名、LLM、生图配置、插件代码与画风'
                  '(含明文 API Key,请妥善保管)',
                ),
                onTap: () => exportSettingsConfig(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导入配置'),
                subtitle: const Text('从 JSON 文件恢复完整配置并覆盖对应配置节'),
                onTap: () => importSettingsConfig(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('配置文件'),
                subtitle: Text(
                  configFile?.path ?? '未启用',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: configFile == null
                    ? null
                    : const Icon(Icons.copy, size: 18),
                onTap: configFile == null
                    ? null
                    : () => copyConfigFilePath(context, configFile.path),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ===== 关于 =====
          const SectionHeader('关于', icon: Icons.info_outline),
          GroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Text(
                  'MicroScritt · 移动端优先的极简 AI 角色扮演应用。\n'
                  '纯客户端运行:对话、生图、Hook 与数据全部在本地,LLM 只接收纯文本上下文。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
