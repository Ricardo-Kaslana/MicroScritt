/// 设置页共享写操作:主题、对话参数、聊天背景与文本配置导入导出。
///
/// 落库与内存快照的先后关系固定在函数里,移动页与桌面工作台共用同一份,
/// 避免两套布局在持久化细节上漂移。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_config_file.dart';
import '../../data/app_settings_repository.dart';
import '../../data/database.dart';
import '../../data/llm_provider_repository.dart';
import '../../data/user_repository.dart';
import '../../engine/context_budget.dart';
import '../../models/app_settings.dart';
import '../../state/image_plugin_runtime.dart';
import '../../state/providers.dart';
import '../common/app_snack_bar.dart';
import '../common/confirm_dialog.dart';
import '../common/export_helper.dart';
import '../common/info_dialog.dart';
import '../common/pick_file_bytes.dart';

Future<void> saveThemeMode(WidgetRef ref, AppThemeMode mode) async {
  final settings = ref.read(appSettingsProvider).copyWith(themeMode: mode);
  await ref.read(appSettingsRepositoryProvider).save(settings);
  ref.read(appSettingsProvider.notifier).state = settings;
}

/// 压缩/附件上限设置统一落库(自动压缩总开关与触发线入库;目标挡与
/// 硬挡派生规则仍为固定策略)。
Future<void> saveTurnSettings(
  WidgetRef ref, {
  bool? autoCompactEnabled,
  double? autoCompactThreshold,
  int? maxAutoAttachments,
}) async {
  final settings = ref
      .read(appSettingsProvider)
      .copyWith(
        autoCompactEnabled: autoCompactEnabled,
        autoCompactThreshold: autoCompactThreshold == null
            ? null
            : AppSettings.clampAutoCompactThreshold(autoCompactThreshold),
        maxAutoAttachments: maxAutoAttachments,
      );
  await ref.read(appSettingsRepositoryProvider).save(settings);
  ref.read(appSettingsProvider.notifier).state = settings;
}

/// 「上下文自动压缩」的三挡详细说明弹层;触发线与派生硬挡按当前配置展示。
void showAutoCompactHelpDialog(BuildContext context, WidgetRef ref) {
  final threshold = ref.read(appSettingsProvider).autoCompactThreshold;
  final softPct = (threshold * 100).round();
  final hardPct = (ContextBudgetPolicy.hardFor(threshold) * 100).round();
  showInfoDialog(
    context,
    title: '上下文自动压缩 · 三挡说明',
    bullets: [
      '• 目标挡 20%:每次压缩把活跃历史压回约 20% 占用',
      '• 自动触发线 $softPct%:回复落库后占用达 $softPct%,自动摘要压缩'
          '(可在本页调整 30%–90%)',
      '• 发送前强制线 $hardPct%:由触发线派生(≥80%,且晚 5 个百分点);'
          '发送前预算检测(输入+输出预留)超容量时先压缩再发',
    ],
    note:
        '摘要失败自动重试 3 次;仍放不下时折叠最老的超限消息兜底(原文保留在会话存档)。关闭自动压缩后仍可手动 /compact,发送前仍会做机械截断兜底。',
    footnotes: const [
      '模型上下文容量未配置时按 16384 兜底估算,长上下文模型会因此提前压缩;建议在 Provider 设置中填写真实容量。',
    ],
  );
}

Future<void> saveChatBackgroundEnabled(WidgetRef ref, bool enabled) {
  return persistChatBackgroundEnabled(
    stateSetter: (val) =>
        ref.read(chatBackgroundEnabledProvider.notifier).state = val,
    appSettingsSetter: (s) => ref.read(appSettingsProvider.notifier).state = s,
    repo: ref.read(appSettingsRepositoryProvider),
    current: ref.read(appSettingsProvider),
    enabled: enabled,
  );
}

Future<void> saveChatBackgroundBlur(WidgetRef ref, double blur) {
  return persistChatBackgroundBlur(
    stateSetter: (val) =>
        ref.read(chatBackgroundBlurProvider.notifier).state = val,
    appSettingsSetter: (s) => ref.read(appSettingsProvider.notifier).state = s,
    repo: ref.read(appSettingsRepositoryProvider),
    current: ref.read(appSettingsProvider),
    blur: blur,
  );
}

/// 导出完整配置:用户名、LLM、生图 provider、插件代码与画风。
///
/// 文件含明文 API Key 与可执行插件代码,导出前必须让用户明确确认。
Future<void> exportSettingsConfig(BuildContext context, WidgetRef ref) async {
  final confirmed = await showConfirmDialog(
    context,
    title: '导出完整配置?',
    message:
        '文件将包含用户名、LLM 后端、生图配置、插件代码与自定义风格。'
        '其中 API Key 为明文,插件代码是可执行脚本,请妥善保管,不要公开分享。',
    confirmLabel: '导出',
  );
  if (!confirmed || !context.mounted) return;
  final text = await AppConfigFile.snapshotText(ref.read(databaseProvider));
  if (!context.mounted) return;
  await saveJsonFile(context, fileName: AppConfigFile.fileName, content: text);
}

/// 导入前确认文案:列出将被覆盖的配置类别与随文件导入的自定义插件及其
/// 网络权限。插件来自用户主动选择的配置文件,但脚本权限仍需单独明示。
String _configImportMessage(AppConfigSnapshot preview) {
  final lines = <String>['文件中提供的节将完整替换当前内容(未包含条目会被删除):'];
  if (preview.userName != null) lines.add('• 用户名');
  if (preview.providers != null) {
    lines.add('• LLM Provider ${preview.providers!.length} 个');
  }
  if (preview.imageProviders != null) {
    lines.add('• 生图配置 ${preview.imageProviders!.length} 个');
  }
  if (preview.imageStyles != null) {
    lines.add('• 自定义风格 ${preview.imageStyles!.length} 个');
  }
  final plugins = preview.imagePlugins;
  if (plugins != null) {
    final custom = plugins.where((plugin) => !plugin.builtin).toList();
    lines.add('• 生图插件 ${plugins.length} 个(自定义 ${custom.length} 个)');
    for (final plugin in custom) {
      final origins = plugin.package!.permissions.allowedOrigins;
      lines.add(
        '  ${plugin.package!.name} ${plugin.package!.version}'
        '${origins.isEmpty ? '' : ' → ${origins.join(', ')}'}',
      );
    }
  }
  lines.add('文件含明文 API Key 与可执行插件代码;仅导入你信任的配置。');
  return lines.join('\n');
}

/// 生图配置直读文件的写点较少,统一在这里刷新受影响的运行期与列表状态。
Future<void> _refreshImportedConfig(WidgetRef ref, AppDatabase db) async {
  ref.read(userProfileProvider.notifier).state = await UserRepository(
    db,
  ).load();
  ref.invalidate(llmProvidersProvider);
  ref.read(backendConfigProvider.notifier).state = await LlmProviderRepository(
    db,
  ).loadBackendConfig();
  ref.read(appSettingsProvider.notifier).state = await AppSettingsRepository(
    db,
  ).load();
  final plugins = await ref.read(imagePluginRepositoryProvider).all();
  ref.read(imagePluginsProvider.notifier).state = plugins;
  final imageRepo = ref.read(imageConfigRepositoryProvider);
  ref.read(imageConfigProvider.notifier).state = await imageRepo
      .loadActiveConfig();
  ref.invalidate(imageProvidersProvider);
  ref.invalidate(imageStylesProvider);
}

/// 手动导入配置文件:应用后覆盖固定配置文件,并刷新用户/后端/设置的内存快照。
Future<void> importSettingsConfig(BuildContext context, WidgetRef ref) async {
  final picked = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  // 系统文件选择器的返回键是标准取消路径,取消不是失败。
  if (picked == null) {
    if (!context.mounted) return;
    showAppSnack(context, '已取消导入');
    return;
  }
  // 读取/解码/解析都可能在用户侧产生可预期的失败(超大文件、非 UTF-8、
  // 坏 JSON):全部纳入提示范围,不能让异常逃逸成「点击无反应」。
  final ({String rawText, AppConfigSnapshot preview}) parsed;
  try {
    final bytes = await pickedFileBytes(picked.files.single);
    if (bytes == null) {
      if (!context.mounted) return;
      showAppSnack(context, '导入失败:未读取到所选文件');
      return;
    }
    final rawText = utf8.decode(bytes);
    parsed = (
      rawText: rawText,
      preview: AppConfigSnapshot.fromJson(jsonDecode(rawText)),
    );
  } on FormatException catch (e) {
    if (!context.mounted) return;
    showAppSnack(context, '导入失败:${e.message}');
    return;
  } catch (e) {
    if (!context.mounted) return;
    showAppSnack(context, '导入失败:$e');
    return;
  }
  if (!context.mounted) return;
  final db = ref.read(databaseProvider);
  final rawText = parsed.rawText;
  final preview = parsed.preview;
  final confirmed = await showConfirmDialog(
    context,
    title: '导入完整配置?',
    message: _configImportMessage(preview),
    confirmLabel: '导入',
  );
  if (!confirmed || !context.mounted) return;
  final file = ref.read(appConfigFileProvider);
  var hadDirty = true;
  if (file != null) {
    try {
      hadDirty = await File(file.dirtyPath).exists();
    } catch (_) {
      // 无法确认既有标记时按「存在」处理:宁可多保留,也不能误删。
      hadDirty = true;
    }
  }
  try {
    final runtime = ref.read(hookRuntimeProvider);
    final customPlugins =
        preview.imagePlugins?.where((plugin) => !plugin.builtin) ??
        const <AppConfigImagePlugin>[];
    // 先落 dirty 标记:即使数据库提交后回写失败,下次启动也会从库重建。
    if (file != null) await file.markDirty();
    final applied = await AppConfigFile.applyText(
      db,
      rawText,
      validatePlugin: runtime == null
          ? null
          : (plugin) => validateImagePluginRuntime(runtime, plugin),
    );
    var fileWriteFailed = false;
    if (file != null) {
      try {
        await file.writeSnapshot(db);
      } catch (_) {
        fileWriteFailed = true;
      }
    }
    await _refreshImportedConfig(ref, db);
    if (!context.mounted) return;
    final summary = <String>[
      if (preview.providers != null) 'LLM ${applied.providerCount} 个',
      if (preview.imageProviders != null) '生图 ${applied.imageProviderCount} 个',
      if (preview.imagePlugins != null) '插件 ${applied.pluginCount} 个',
      if (preview.imageStyles != null) '风格 ${applied.styleCount} 个',
    ];
    final warnings = [
      ...applied.warnings,
      if (runtime == null && customPlugins.isNotEmpty) '当前平台无法运行 JS,自定义插件仅恢复数据',
      if (fileWriteFailed) '数据库已更新,但配置文件回写失败;下次启动将自动重建',
    ];
    showAppSnack(
      context,
      '已导入配置${summary.isEmpty ? '' : ':${summary.join('、')}'}'
      '${applied.userChanged ? ',用户名已更新' : ''}'
      '${warnings.isEmpty ? '' : '\n${warnings.join('\n')}'}',
    );
  } on FormatException catch (e) {
    await _discardFailedImportDirty(file, hadDirty: hadDirty);
    if (!context.mounted) return;
    showAppSnack(context, '导入失败:${e.message}');
  } catch (e) {
    // applyText 是单事务:失败时库没有任何变化,本次新建的 dirty 必须撤销,
    // 否则下次启动会用库快照覆盖用户手改的配置文件。
    await _discardFailedImportDirty(file, hadDirty: hadDirty);
    if (!context.mounted) return;
    showAppSnack(context, '导入失败:$e');
  }
}

/// 导入校验失败时撤销本次创建的 dirty 标记;导入前已存在的标记保持原样。
Future<void> _discardFailedImportDirty(
  AppConfigFile? file, {
  required bool hadDirty,
}) async {
  if (file == null || hadDirty) return;
  try {
    final dirty = File(file.dirtyPath);
    if (await dirty.exists()) await dirty.delete();
  } catch (_) {}
}

Future<void> copyConfigFilePath(BuildContext context, String path) async {
  await Clipboard.setData(ClipboardData(text: path));
  if (!context.mounted) return;
  showAppSnack(context, '配置文件路径已复制');
}
