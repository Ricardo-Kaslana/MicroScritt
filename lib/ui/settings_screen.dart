/// 设置页:外观、对话与后台、LLM/生图 provider、内容扩展与配置导入导出。
///
/// 文本配置文件(`microscritt-config.json`)含明文 API Key,导入会覆盖用户名
/// 与全部 provider;列表项副标题必须保留这条警告。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/info_button.dart';
import 'common/section_header.dart';
import '../data/app_config_file.dart';
import '../data/app_settings_repository.dart';
import '../data/llm_provider_repository.dart';
import '../data/user_repository.dart';
import '../engine/context_budget.dart';
import '../models/app_settings.dart';
import '../models/image_config.dart';
import '../models/image_style_preset.dart';
import '../models/llm_provider.dart';
import '../state/app_config_sync.dart';
import '../state/providers.dart';
import 'common/export_helper.dart';
import 'common/pick_file_bytes.dart';
import 'hooks_screen.dart';
import 'image_provider_edit_screen.dart';
import 'image_plugins_screen.dart';
import 'image_styles_screen.dart';
import 'regex_scripts_screen.dart';
import 'prompt_items_screen.dart';
import 'provider_edit_screen.dart';
import 'skills_screen.dart';
import 'user_screen.dart';

/// 应用设置总入口,从角色列表右上角进入。
///
/// 本页偏好项(主题、聊天背景、压缩与后台轮次)直接落库并同步内存状态;
/// provider 与生图配置跳独立编辑页。文本配置导入成功/失败都只回 SnackBar,
/// 成功后重新水合用户/后端/设置快照。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// 触发线滑块的拖动草稿:拖动时只更新内存(即时反馈),松手才落库。
  double? _compactThresholdDraft;

  Future<void> _setTheme(AppThemeMode mode) async {
    final settings = ref.read(appSettingsProvider).copyWith(themeMode: mode);
    await ref.read(appSettingsRepositoryProvider).save(settings);
    ref.read(appSettingsProvider.notifier).state = settings;
  }

  /// 压缩/后台轮次设置统一落库(自动压缩总开关与触发线入库;目标挡与
  /// 硬挡派生规则仍为固定策略)。
  Future<void> _setTurnSettings({
    bool? autoCompactEnabled,
    double? autoCompactThreshold,
    int? imageInterval,
    int? maxAutoAttachments,
  }) async {
    final settings = ref
        .read(appSettingsProvider)
        .copyWith(
          autoCompactEnabled: autoCompactEnabled,
          autoCompactThreshold: autoCompactThreshold == null
              ? null
              : AppSettings.clampAutoCompactThreshold(autoCompactThreshold),
          imageInterval: imageInterval,
          maxAutoAttachments: maxAutoAttachments,
        );
    await ref.read(appSettingsRepositoryProvider).save(settings);
    ref.read(appSettingsProvider.notifier).state = settings;
  }

  /// 「上下文自动压缩」的三挡详细说明弹层(设置页副标题只留一行短文案,
  /// 细节经标题旁的信息按钮进入这里)。触发线与派生硬挡按当前配置展示。
  void _showAutoCompactHelp(BuildContext context) {
    final threshold = ref.read(appSettingsProvider).autoCompactThreshold;
    final softPct = (threshold * 100).round();
    final hardPct = (ContextBudgetPolicy.hardFor(threshold) * 100).round();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('上下文自动压缩 · 三挡说明'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('• 目标挡 20%:每次压缩把活跃历史压回约 20% 占用'),
            SizedBox(height: 6),
            Text('• 自动触发线 $softPct%:回复落库后占用达 $softPct%,自动摘要压缩'
                '(可在本页调整 30%–90%)'),
            SizedBox(height: 6),
            Text('• 发送前强制线 $hardPct%:发送前预算检测(输入+输出预留)'
                '超容量 $hardPct%,先压缩再发'),
            SizedBox(height: 10),
            const Text('摘要失败自动重试 3 次;仍放不下时折叠最老的超限消息兜底(原文保留在会话存档)。关闭后仍可手动 /compact。'),
            SizedBox(height: 6),
            const Text('模型上下文容量未配置时按 16384 兜底估算,长上下文模型会因此提前压缩;建议在 Provider 设置中填写真实容量。'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _setChatBackground(bool v) async {
    await persistChatBackgroundEnabled(
      stateSetter: (val) =>
          ref.read(chatBackgroundEnabledProvider.notifier).state = val,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
      enabled: v,
    );
  }

  Future<void> _setChatBackgroundBlur(double v) async {
    await persistChatBackgroundBlur(
      stateSetter: (val) =>
          ref.read(chatBackgroundBlurProvider.notifier).state = val,
      appSettingsSetter: (s) =>
          ref.read(appSettingsProvider.notifier).state = s,
      repo: ref.read(appSettingsRepositoryProvider),
      current: ref.read(appSettingsProvider),
      blur: v,
    );
  }

  /// 导出当前用户名 + LLM 后端为纯文本配置文件;文件含明文 API Key,
  /// 调用方(设置页列表项)负责提示用户妥善保管。
  Future<void> _exportConfig() async {
    final text = await AppConfigFile.snapshotText(ref.read(databaseProvider));
    if (!mounted) return;
    await saveJsonFile(
      context,
      fileName: AppConfigFile.fileName,
      content: text,
    );
  }

  /// 手动导入配置文件:应用后覆盖固定配置文件,并刷新用户/后端/设置的内存快照。
  Future<void> _importConfig() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    // 系统文件选择器的返回键是标准取消路径,取消不是失败。
    if (picked == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已取消导入')));
      return;
    }
    final bytes = await pickedFileBytes(picked.files.single);
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('导入失败:未读取到所选文件')));
      return;
    }
    if (!mounted) return;
    // 导入是覆盖式写入(用户名 + 全部 provider),不确认就直接替换属于
    // 不可逆的意外丢失;先让用户知道后果再动手。
    final confirmed = await showConfirmDialog(
      context,
      title: '导入配置?',
      message: '将覆盖当前用户名与全部 LLM Provider(含 API Key)。建议先导出备份。',
      confirmLabel: '导入',
    );
    if (!confirmed || !mounted) return;
    final db = ref.read(databaseProvider);
    try {
      final applied = await AppConfigFile.applyText(
        db,
        utf8.decode(bytes, allowMalformed: true),
      );
      final file = ref.read(appConfigFileProvider);
      if (file != null) await file.writeSnapshot(db);
      ref.read(userProfileProvider.notifier).state = await UserRepository(
        db,
      ).load();
      ref.invalidate(llmProvidersProvider);
      ref.read(backendConfigProvider.notifier).state =
          await LlmProviderRepository(db).loadBackendConfig();
      ref.read(appSettingsProvider.notifier).state =
          await AppSettingsRepository(db).load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导入配置:${applied.providerCount} 个 provider'
            '${applied.userChanged ? ',用户名已更新' : ''}',
          ),
        ),
      );
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败:${e.message}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败:$e')));
    }
  }

  Future<void> _copyConfigPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('配置文件路径已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final appSettings = ref.watch(appSettingsProvider);
    final backgroundBlur = ref.watch(chatBackgroundBlurProvider);
    final compactThreshold = AppSettings.clampAutoCompactThreshold(
      _compactThresholdDraft ?? appSettings.autoCompactThreshold,
    );
    final compactSoftPct = (compactThreshold * 100).round();
    final compactHardPct = (ContextBudgetPolicy.hardFor(compactThreshold) * 100)
        .round();
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
                  onSelectionChanged: (sel) => _setTheme(sel.first),
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
                onChanged: (v) => _setChatBackground(v),
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
                            ? _setChatBackgroundBlur
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
                    InfoButton(onTap: () => _showAutoCompactHelp(context)),
                  ],
                ),
                subtitle: Text('按窗口占用率自动压缩 · 触发线 $compactSoftPct%'),
                value: appSettings.autoCompactEnabled,
                onChanged: (v) => _setTurnSettings(autoCompactEnabled: v),
              ),
              // 触发线行:关闭自动压缩时整段置灰;拖动只更新内存(即时反馈),
              // 松手才落库。发送前强制线由触发线派生(≥80%,且晚 5 个百分点)。
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: const SizedBox.shrink(),
                title: const Text('自动压缩触发线'),
                subtitle: Text(
                  '窗口占用达 $compactSoftPct% 后,回复落库时自动摘要'
                  ' · 发送前强制线 $compactHardPct%',
                ),
                trailing: Text(
                  '$compactSoftPct%',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: appSettings.autoCompactEnabled
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
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
                          _setTurnSettings(
                            autoCompactThreshold:
                                AppSettings.clampAutoCompactThreshold(v),
                          );
                        }
                      : null,
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
                      : _setTurnSettings(maxAutoAttachments: v),
                ),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: const Icon(Icons.image_outlined),
                title: const Text('生图间隔'),
                subtitle: const Text('每隔多少轮允许后台生成一次配图'),
                trailing: DropdownButton<int>(
                  value:
                      const [1, 2, 3, 5, 10].contains(appSettings.imageInterval)
                      ? appSettings.imageInterval
                      : 1,
                  underline: const SizedBox.shrink(),
                  dropdownColor: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  menuMaxHeight: 240,
                  style: TextStyle(fontSize: 14, color: scheme.onSurface),
                  iconSize: 20,
                  iconEnabledColor: scheme.onSurfaceVariant,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('每轮')),
                    DropdownMenuItem(value: 2, child: Text('每 2 轮')),
                    DropdownMenuItem(value: 3, child: Text('每 3 轮')),
                    DropdownMenuItem(value: 5, child: Text('每 5 轮')),
                    DropdownMenuItem(value: 10, child: Text('每 10 轮')),
                  ],
                  onChanged: (v) =>
                      v == null ? null : _setTurnSettings(imageInterval: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // ===== LLM 后端 =====
          const SectionHeader('LLM 后端', icon: Icons.dns_outlined),
          const _ProviderSection(),
          const SizedBox(height: 16),
          // ===== 生图 =====
          // 生图配置是多行表:列表管理多套配置,每套自带密钥;编辑在独立
          // 页面,与上方「LLM 后端」同一套交互。
          const SectionHeader('生图', icon: Icons.image_outlined),
          const _ImageProviderSection(),
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
                onTap: _exportConfig,
              ),
              ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导入配置'),
                subtitle: const Text('从 JSON 文件恢复,覆盖当前用户名与 LLM 后端'),
                onTap: _importConfig,
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
                    : () => _copyConfigPath(configFile.path),
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

/// LLM 后端设置:按 provider 分组的配置列表。
///
/// 列表只显示名称;删除当前在用 provider 后重解析运行时配置并回写文本
/// 配置文件,避免运行链路继续指向已删除的 provider。
class _ProviderSection extends ConsumerWidget {
  const _ProviderSection();

  Future<void> _deleteProvider(
    BuildContext context,
    WidgetRef ref,
    LlmProviderConfig p,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除 Provider?',
      message: '「${p.displayName}」及其全部模型都会被删除。',
    );
    if (!confirmed || !context.mounted) return;
    final wasActive = p.isActive;
    await ref.read(llmProviderRepositoryProvider).deleteProvider(p.id);
    if (wasActive) {
      // 删除当前在用 provider 后,重新解析可用的当前配置。
      final backend = await ref
          .read(llmProviderRepositoryProvider)
          .loadBackendConfig();
      ref.read(backendConfigProvider.notifier).state = backend;
    }
    ref.invalidate(llmProvidersProvider);
    await syncAppConfigFile(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(llmProvidersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        providersAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => EmptyState(
            compact: true,
            icon: Icons.error_outline,
            title: '加载失败',
            message: '$e',
            action: FilledButton.tonalIcon(
              onPressed: () => ref.invalidate(llmProvidersProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
          data: (providers) {
            if (providers.isEmpty) {
              return const SurfaceCard(
                child: EmptyState(
                  compact: true,
                  icon: Icons.dns_outlined,
                  title: '暂无 LLM Provider',
                  message: '还没有配置任何 LLM provider,点击"添加 Provider"开始。',
                ),
              );
            }
            return Column(
              children: [
                for (final (i, p) in providers.indexed) ...[
                  _ProviderTile(
                    provider: p,
                    onEdit: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProviderEditScreen(existing: p),
                      ),
                    ).then((_) => ref.invalidate(llmProvidersProvider)),
                    onDelete: () => _deleteProvider(context, ref, p),
                  ),
                  if (i != providers.length - 1) const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ProviderEditScreen()),
          ).then((_) => ref.invalidate(llmProvidersProvider)),
          icon: const Icon(Icons.add),
          label: const Text('添加 Provider'),
        ),
      ],
    );
  }
}

class _ProviderTile extends ConsumerWidget {
  final LlmProviderConfig provider;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _ProviderTile({
    required this.provider,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onEdit,
        leading: Icon(Icons.dns_outlined, color: scheme.onSurfaceVariant),
        title: Text(provider.displayName),
        // 只显示 provider 名称;详情(协议/地址/模型个数)进了编辑页。
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 生图配置列表(多行 `image_providers`):每行一套完整配置,**各自带 api_key**。
///
/// 与上方 [_ProviderSection] 同一套交互 —— 列表只显示名称与服务/在用状态,参数
/// 细节进编辑页。「设为当前使用」决定 `imageConfigProvider` 水合哪一套,而运行
/// 链路(编排器 / 后台引擎)只读它。
class _ImageProviderSection extends ConsumerWidget {
  const _ImageProviderSection();

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ImageProviderRecord p,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除生图配置?',
      message: '「${p.displayName}」及其连接参数都会被删除。',
    );
    if (!confirmed || !context.mounted) return;
    final repo = ref.read(imageConfigRepositoryProvider);
    await repo.deleteProvider(p.id);
    // 删掉的若是当前在用那套,repository 会顺位补一条为活跃 —— 重解析让运行
    // 链路立刻跟上,否则 `imageConfigProvider` 还指向已删除的配置。
    ref.read(imageConfigProvider.notifier).state = await repo
        .loadActiveConfig();
    ref.invalidate(imageProvidersProvider);
  }

  Future<void> _setActive(WidgetRef ref, ImageProviderRecord p) async {
    final repo = ref.read(imageConfigRepositoryProvider);
    await repo.setActive(p.id);
    ref.read(imageConfigProvider.notifier).state = await repo
        .loadActiveConfig();
    ref.invalidate(imageProvidersProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(imageProvidersProvider);
    final activeConfig = ref.watch(imageConfigProvider);
    // 新建自定义风格时用当前生效参数预填;未配置生图时给空初值。
    final stylePrefill = ImageStylePreset(
      name: '',
      artist: activeConfig?.artist,
      sampler: activeConfig?.sampler,
      noiseSchedule: activeConfig?.noiseSchedule,
      scale: activeConfig?.scale,
      cfg: activeConfig?.cfg,
      negative: activeConfig?.negative,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        providersAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => EmptyState(
            compact: true,
            icon: Icons.error_outline,
            title: '加载失败',
            message: '$e',
            action: FilledButton.tonalIcon(
              onPressed: () => ref.invalidate(imageProvidersProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ),
          data: (providers) {
            if (providers.isEmpty) {
              return const SurfaceCard(
                child: EmptyState(
                  compact: true,
                  icon: Icons.image_outlined,
                  title: '暂无生图服务',
                  message: '还没有配置生图服务,点击"添加生图配置"开始。',
                ),
              );
            }
            return Column(
              children: [
                for (final (i, p) in providers.indexed) ...[
                  _ImageProviderTile(
                    record: p,
                    onEdit: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ImageProviderEditScreen(existing: p),
                      ),
                    ).then((_) => ref.invalidate(imageProvidersProvider)),
                    onDelete: () => _delete(context, ref, p),
                    onSetActive: () => _setActive(ref, p),
                  ),
                  if (i != providers.length - 1) const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ImageProviderEditScreen()),
          ).then((_) => ref.invalidate(imageProvidersProvider)),
          icon: const Icon(Icons.add),
          label: const Text('添加生图配置'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ImagePluginsScreen()),
          ),
          icon: const Icon(Icons.extension_outlined),
          label: const Text('管理生图插件'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          // 风格此前只能从生图配置编辑页底部进入;设置页给出直达入口。
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ImageStylesScreen(prefill: stylePrefill),
            ),
          ),
          icon: const Icon(Icons.palette_outlined),
          label: const Text('管理自定义风格'),
        ),
      ],
    );
  }
}

class _ImageProviderTile extends ConsumerWidget {
  final ImageProviderRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSetActive;
  const _ImageProviderTile({
    required this.record,
    required this.onEdit,
    required this.onDelete,
    required this.onSetActive,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final plugins = ref.watch(imagePluginsProvider);
    final service =
        plugins
            .where((plugin) => plugin.id == record.config.pluginId)
            .firstOrNull
            ?.name ??
        '生图插件';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onEdit,
        leading: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
        title: Text(record.displayName),
        // 副标题只报插件与"是否在用";密钥/地址/模型等细节进编辑页。
        subtitle: Text(
          record.isActive ? '$service · 当前使用' : service,
          style: TextStyle(
            color: record.isActive ? scheme.primary : scheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!record.isActive)
              IconButton(
                icon: const Icon(Icons.radio_button_unchecked),
                tooltip: '设为当前使用',
                onPressed: onSetActive,
              ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
