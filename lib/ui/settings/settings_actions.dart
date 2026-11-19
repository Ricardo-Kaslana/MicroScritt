/// 设置页共享写操作:主题、对话参数、聊天背景与文本配置导入导出。
///
/// 落库与内存快照的先后关系固定在函数里,移动页与桌面工作台共用同一份,
/// 避免两套布局在持久化细节上漂移。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_config_file.dart';
import '../../data/app_settings_repository.dart';
import '../../data/llm_provider_repository.dart';
import '../../data/user_repository.dart';
import '../../engine/context_budget.dart';
import '../../models/app_settings.dart';
import '../../state/providers.dart';
import '../common/confirm_dialog.dart';
import '../common/export_helper.dart';
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
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('上下文自动压缩 · 三挡说明'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• 目标挡 20%:每次压缩把活跃历史压回约 20% 占用'),
          const SizedBox(height: 6),
          Text(
            '• 自动触发线 $softPct%:回复落库后占用达 $softPct%,自动摘要压缩'
            '(可在本页调整 30%–90%)',
          ),
          const SizedBox(height: 6),
          Text(
            '• 发送前强制线 $hardPct%:由触发线派生(≥80%,且晚 5 个百分点);'
            '发送前预算检测(输入+输出预留)超容量时先压缩再发',
          ),
          const SizedBox(height: 10),
          const Text(
            '摘要失败自动重试 3 次;仍放不下时折叠最老的超限消息兜底(原文保留在会话存档)。关闭后仍可手动 /compact。',
          ),
          const SizedBox(height: 6),
          const Text(
            '模型上下文容量未配置时按 16384 兜底估算,长上下文模型会因此提前压缩;建议在 Provider 设置中填写真实容量。',
          ),
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

/// 导出当前用户名 + LLM 后端为纯文本配置文件;文件含明文 API Key,
/// 调用方负责提示用户妥善保管。
Future<void> exportSettingsConfig(BuildContext context, WidgetRef ref) async {
  final text = await AppConfigFile.snapshotText(ref.read(databaseProvider));
  if (!context.mounted) return;
  await saveJsonFile(
    context,
    fileName: AppConfigFile.fileName,
    content: text,
  );
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
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已取消导入')));
    return;
  }
  final bytes = await pickedFileBytes(picked.files.single);
  if (bytes == null) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('导入失败:未读取到所选文件')));
    return;
  }
  if (!context.mounted) return;
  // 导入是覆盖式写入(用户名 + 全部 provider),不确认就直接替换属于
  // 不可逆的意外丢失;先让用户知道后果再动手。
  final confirmed = await showConfirmDialog(
    context,
    title: '导入配置?',
    message: '将覆盖当前用户名与全部 LLM Provider(含 API Key)。建议先导出备份。',
    confirmLabel: '导入',
  );
  if (!confirmed || !context.mounted) return;
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
    ref.read(backendConfigProvider.notifier).state = await LlmProviderRepository(
      db,
    ).loadBackendConfig();
    ref.read(appSettingsProvider.notifier).state = await AppSettingsRepository(
      db,
    ).load();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已导入配置:${applied.providerCount} 个 provider'
          '${applied.userChanged ? ',用户名已更新' : ''}',
        ),
      ),
    );
  } on FormatException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('导入失败:${e.message}')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('导入失败:$e')));
  }
}

Future<void> copyConfigFilePath(BuildContext context, String path) async {
  await Clipboard.setData(ClipboardData(text: path));
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('配置文件路径已复制')));
}
