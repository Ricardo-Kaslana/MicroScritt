/// 设置页入口:窄窗使用移动单列页,宽窗(≥1000)进入桌面分区工作台。
///
/// 文本配置文件(`microscritt-config.json`)含明文 API Key,导入会覆盖用户名
/// 与全部 provider;列表项副标题必须保留这条警告。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../state/providers.dart';
import 'common/info_button.dart';
import 'common/section_header.dart';
import 'hooks_screen.dart';
import 'prompt_items_screen.dart';
import 'regex_scripts_screen.dart';
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
              // 主题:横向三段切到宽度吃不满,直接铺整张卡,顶部留 12 padding 与卡片边缘呼吸。
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: SegmentedButton<AppThemeMode>(
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
                  selected: {appSettings.themeMode},
                  onSelectionChanged: (sel) => saveThemeMode(ref, sel.first),
                ),
              ),
              // 聊天背景:Switch 在标题行;模糊度滑块在副标题位置紧贴开关,绑成一项。
              // 关闭时整段连滑块一起置灰;拖动只更新内存(即时反馈),松手才落库。
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                secondary: const Icon(Icons.wallpaper_outlined),
                title: const Text('聊天背景'),
                subtitle: const Text('开启后聊天页显示角色卡背景图;未设置背景图时使用角色头像'),
                value: appSettings.chatBackgroundEnabled,
                onChanged: (v) => saveChatBackgroundEnabled(ref, v),
              ),
              // 模糊度行:ListTile 的 subtitle 槽位放「实时数字 + Slider」,开关关闭时禁用。
              // Row 排版与「内容与扩展」卡的 ListTile 视觉一致;数字用 onSurfaceVariant
              // 弱化,滑块横向吃满,既保持卡片基线又不让滑块独立占整行。
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: const SizedBox.shrink(),
                title: const Text('背景模糊度'),
                subtitle: Row(
                  children: [
                    Text(
                      '${backgroundBlur.round()}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: appSettings.chatBackgroundEnabled
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.5),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('chatBackgroundBlurSlider'),
                        value: backgroundBlur,
                        min: 0,
                        max: 32,
                        onChanged: appSettings.chatBackgroundEnabled
                            ? (v) =>
                                  ref
                                          .read(
                                            chatBackgroundBlurProvider.notifier,
                                          )
                                          .state =
                                      v
                            : null,
                        onChangeEnd: appSettings.chatBackgroundEnabled
                            ? (v) => saveChatBackgroundBlur(ref, v)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ===== 对话与后台 =====
          const SectionHeader('对话与后台', icon: Icons.tune_outlined),
          GroupCard(
            children: [
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                secondary: const Icon(Icons.compress_outlined),
                // 标题旁挂 InfoButton:三挡/重试/兜底细节收进弹层,不在设置页
                // 铺长段说明;副标题保持默认灰,不再用整行 primary 色链接样式。
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('上下文自动压缩'),
                    const SizedBox(width: 2),
                    InfoButton(
                      onTap: () => showAutoCompactHelpDialog(context, ref),
                    ),
                  ],
                ),
                subtitle: Text('按窗口占用率自动压缩 · 触发线 $compactSoftPct%'),
                value: appSettings.autoCompactEnabled,
                onChanged: (v) =>
                    saveTurnSettings(ref, autoCompactEnabled: v),
              ),
              // 触发线行:与「背景模糊度」同款,标题 + 值 + 滑块;行为说明与
              // 派生强制线细节收进标题旁「查看说明」弹层。关闭自动压缩时整段
              // 置灰;拖动只更新内存(即时反馈),松手才落库。
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: const SizedBox.shrink(),
                title: const Text('自动压缩触发线'),
                subtitle: Row(
                  children: [
                    Text(
                      '$compactSoftPct%',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: appSettings.autoCompactEnabled
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.5),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('autoCompactThresholdSlider'),
                        value: compactThreshold,
                        min: AppSettings.minAutoCompactThreshold,
                        max: AppSettings.maxAutoCompactThreshold,
                        divisions: 12,
                        label: '$compactSoftPct%',
                        onChanged: appSettings.autoCompactEnabled
                            ? (v) => setState(
                                () => _compactThresholdDraft =
                                    AppSettings.clampAutoCompactThreshold(v),
                              )
                            : null,
                        onChangeEnd: appSettings.autoCompactEnabled
                            ? (v) {
                                setState(() => _compactThresholdDraft = null);
                                saveTurnSettings(
                                  ref,
                                  autoCompactThreshold:
                                      AppSettings.clampAutoCompactThreshold(v),
                                );
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: const Icon(Icons.attach_file),
                title: const Text('单轮附件上限'),
                subtitle: const Text('每轮最多自动注入的世界书附件条数 · @技能与通知不受限'),
                trailing: DropdownButton<int>(
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
                  // 行尾值选择下拉:与全局菜单语言一致——无下划线、白面圆角弹出、灰色 chevron。
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
                  MaterialPageRoute(
                    builder: (_) => const RegexScriptsScreen(),
                  ),
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
                  MaterialPageRoute(
                    builder: (_) => const UsageStatsScreen(),
                  ),
                ),
              ),
            ],
          ),
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
                subtitle: const Text('用户名与 LLM 后端(含 API Key,请妥善保管)'),
                onTap: () => exportSettingsConfig(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导入配置'),
                subtitle: const Text('从 JSON 文件恢复,覆盖当前用户名与 LLM 后端'),
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
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: scheme.outline),
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
