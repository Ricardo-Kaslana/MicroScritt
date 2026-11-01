/// 应用级 Riverpod Provider 目录:数据库/仓库、设置与界面偏好、LLM 与生图后端。
///
/// [databaseProvider] 由 main() 覆盖,未覆盖时读取即抛错;仓库 Provider 只做
/// 轻量构造,后端类 Provider 从当前配置派生,配置为空返回 null 由调用方提示。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../models/backend_config.dart';
import '../backend/backend_factory.dart';
import '../backend/image_backend.dart';
import '../backend/llm_backend.dart';
import '../backend/plugin_image_backend.dart';
import '../data/app_config_file.dart';
import '../data/app_settings_repository.dart';
import '../data/character_repository.dart';
import '../data/database.dart';
import '../data/hook_repository.dart';
import '../data/image_codec.dart';
import '../data/regex_script_repository.dart';
import '../data/image_config_repository.dart';
import '../data/image_plugin_repository.dart';
import '../data/image_style_repository.dart';
import '../data/llm_provider_repository.dart';
import '../data/message_repository.dart';
import '../data/prompt_item_repository.dart';
import '../data/session_repository.dart';
import '../data/skill_repository.dart';
import '../data/ui_prefs_file.dart';
import '../data/user_repository.dart';
import '../data/variable_repository.dart';
import '../data/memory_repository.dart';
import '../data/image_guide_repository.dart';
import '../data/worldbook_repository.dart';
import '../engine/hook_runtime.dart';
import '../models/app_settings.dart';
import '../models/hook.dart';
import '../models/image_config.dart';
import '../models/image_guide.dart';
import '../models/image_plugin.dart';
import '../models/image_style_preset.dart';
import '../models/llm_provider.dart';
import '../models/memory.dart';
import '../models/prompt_item.dart';
import '../models/regex_script.dart';
import '../models/skill.dart';
import '../models/ui_prefs.dart';
import '../models/user.dart';
import '../models/variable.dart';
import '../models/worldbook_entry.dart';

/// 数据库句柄:main() 以真实 `AppDatabase` 覆盖;未覆盖时读取即抛错,
/// 保证测试漏注入时立即失败而不是静默用错库。
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('override in main()'),
);

/// 角色卡仓库。
final characterRepositoryProvider = Provider(
  (ref) => CharacterRepository(ref.watch(databaseProvider)),
);

/// 会话仓库(会话行、token 用量与列表预览)。
final sessionRepositoryProvider = Provider(
  (ref) => SessionRepository(ref.watch(databaseProvider)),
);

/// 消息仓库(流式追加、窗口化读取与图片列更新)。
final messageRepositoryProvider = Provider(
  (ref) => MessageRepository(ref.watch(databaseProvider)),
);

/// 提示词项仓库(preset/rule 两类)。
final promptItemRepositoryProvider = Provider(
  (ref) => PromptItemRepository(ref.watch(databaseProvider)),
);

/// LLM provider 与模型目录仓库。
final llmProviderRepositoryProvider = Provider(
  (ref) => LlmProviderRepository(ref.watch(databaseProvider)),
);

/// 生图配置仓库(多行配置,每行一套凭据)。
final imageConfigRepositoryProvider = Provider(
  (ref) => ImageConfigRepository(ref.watch(databaseProvider)),
);

/// 生图插件仓库(内置协议与用户导入插件)。
final imagePluginRepositoryProvider = Provider(
  (ref) => ImagePluginRepository(ref.watch(databaseProvider)),
);

/// 自定义生图风格仓库。
final imageStyleRepositoryProvider = Provider(
  (ref) => ImageStyleRepository(ref.watch(databaseProvider)),
);

/// 应用设置仓库(app_settings 单行偏好)。
final appSettingsRepositoryProvider = Provider(
  (ref) => AppSettingsRepository(ref.watch(databaseProvider)),
);

/// 世界书条目仓库。
final worldbookRepositoryProvider = Provider(
  (ref) => WorldbookRepository(ref.watch(databaseProvider)),
);

/// 全局技能仓库。
final skillRepositoryProvider = Provider(
  (ref) => SkillRepository(ref.watch(databaseProvider)),
);

/// 变量仓库(含回收站与严格模式待确认删除)。
final variableRepositoryProvider = Provider(
  (ref) => VariableRepository(ref.watch(databaseProvider)),
);

/// 会话记忆仓库。
final memoryRepositoryProvider = Provider(
  (ref) => MemoryRepository(ref.watch(databaseProvider)),
);

/// 会话生图指导仓库。
final imageGuideRepositoryProvider = Provider(
  (ref) => ImageGuideRepository(ref.watch(databaseProvider)),
);

/// Hook 仓库。
final hookRepositoryProvider = Provider(
  (ref) => HookRepository(ref.watch(databaseProvider)),
);

/// 显示层正则脚本仓库。
final regexScriptRepositoryProvider = Provider(
  (ref) => RegexScriptRepository(ref.watch(databaseProvider)),
);

/// 用户档案仓库(用户名与头像)。
final userRepositoryProvider = Provider(
  (ref) => UserRepository(ref.watch(databaseProvider)),
);

/// 文本配置文件(用户名 + LLM provider)。main() 注入真实文件;测试默认 null,
/// 所有写点经 syncAppConfigFile 调用时自动跳过,不产生文件 IO。
final appConfigFileProvider = Provider<AppConfigFile?>((ref) => null);

/// 轻量 UI 偏好文件(角色列表布局等)。main() 注入真实文件;测试默认 null,
/// 切换布局时跳过着盘。
final uiPrefsFileProvider = Provider<UiPrefsFile?>((ref) => null);

/// 角色列表布局:main() 按 [UiPrefsFile] 恢复,页面切换时回写文件。
final characterLayoutProvider = StateProvider<CharacterLayout>(
  (ref) => CharacterLayout.list,
);

/// Hook 的 JS 运行时。main() 注入真实实现;测试默认 null,
/// 此时 Hook 求值被跳过(不执行任何 JS)。
final hookRuntimeProvider = Provider<HookRuntime?>((ref) => null);

/// 角色卡列表(含描述预览)。超大行由仓库按 id 补读整列,读不动才降级成只剩名字。
final charactersProvider = FutureProvider<List<CharacterRecord>>(
  (ref) => ref.watch(characterRepositoryProvider).all(hydrateOversized: true),
);

/// 角色卡列表预览图:按 id 惰性读头像列并离主线程解码(大卡 base64 解码
/// 会掉帧)。编辑保存后必须 invalidate 对应 id —— 列表项 State 会被复用,
/// 仅刷新 [charactersProvider] 不会重读头像(旧实现要导出重导入才换图)。
/// 读取/解码失败一律回 null(占位图),不让超大历史行触发 Riverpod 自动重试。
final characterAvatarProvider = FutureProvider.autoDispose
    .family<Uint8List?, int>((ref, id) async {
      try {
        final base64 = await ref
            .watch(characterRepositoryProvider)
            .avatarBase64For(id);
        if (base64 == null || base64.isEmpty) return null;
        final bytes = await compute(safeBase64Decode, base64);
        return bytes == null || bytes.isEmpty ? null : bytes;
      } catch (_) {
        return null;
      }
    });

/// 应用级偏好(主题等)。main() 从 app_settings 表恢复。
final appSettingsProvider = StateProvider<AppSettings>(
  (ref) => const AppSettings(),
);

/// 用户档案(用户名+头像)。main() 从 user_profile 表恢复;设置页保存后更新。
final userProfileProvider = StateProvider<UserProfile>(
  (ref) => const UserProfile(),
);

/// 后台 agent(每轮状态维护)启用开关,随 AppSettings 持久化。
/// 读取 appSettingsProvider 派生;UI 切换时经 [persistBackgroundEnabled] 写回设置并落库。
final backgroundEnabledProvider = StateProvider<bool>(
  (ref) => ref.watch(appSettingsProvider).backgroundEnabled,
);

/// 聊天背景总开关(默认关闭)。开启后聊天页铺角色卡专属背景图;未设置背景图时
/// 回退角色头像。读取 appSettingsProvider 派生,UI 切换经 [persistChatBackgroundEnabled] 落库。
final chatBackgroundEnabledProvider = StateProvider<bool>(
  (ref) => ref.watch(appSettingsProvider).chatBackgroundEnabled,
);

/// 切换聊天背景总开关并落库。与后台开关同理:同步 chatBackgroundEnabledProvider
/// 与 appSettingsProvider(单一真相),再经 repo 持久化。
Future<void> persistChatBackgroundEnabled({
  required void Function(bool) stateSetter,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
  required bool enabled,
}) async {
  stateSetter(enabled);
  appSettingsSetter(current.copyWith(chatBackgroundEnabled: enabled));
  await repo.save(current.copyWith(chatBackgroundEnabled: enabled));
}

/// 聊天背景模糊度(0–32,默认 18),随 AppSettings 持久化。
final chatBackgroundBlurProvider = StateProvider<double>(
  (ref) => ref.watch(appSettingsProvider).chatBackgroundBlur,
);

/// 切换聊天背景模糊度并落库。与背景开关同理:同步 chatBackgroundBlurProvider 与
/// appSettingsProvider(单一真相),再经 repo 持久化。滑块拖动期间只改
/// chatBackgroundBlurProvider(即时反馈),onChangeEnd 才走这里落库。
Future<void> persistChatBackgroundBlur({
  required void Function(double) stateSetter,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
  required double blur,
}) async {
  stateSetter(blur);
  appSettingsSetter(current.copyWith(chatBackgroundBlur: blur));
  await repo.save(current.copyWith(chatBackgroundBlur: blur));
}

/// 切换后台 agent 开关并落库。stateSetter 用于写入 backgroundEnabledProvider
/// (UI 传入 (v) => ref.read(provider.notifier).state = v),repo 持久化。
/// 同时用 appSettingsSetter 更新 appSettingsProvider,保证内存里两个派生源一致,
/// 否则 appSettings(backgroundEnabled 单一真相)落后于后台开关 provider,重启前
/// 依赖 appSettingsProvider 的地方(lable/派生)会读到旧值。
Future<void> persistBackgroundEnabled({
  required void Function(bool) stateSetter,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
  required bool enabled,
}) async {
  stateSetter(enabled);
  appSettingsSetter(current.copyWith(backgroundEnabled: enabled));
  await repo.save(current.copyWith(backgroundEnabled: enabled));
}

/// 更新推理等级并落库。
///
/// **先落库、成功后再同步内存**:写库失败时 `appSettingsProvider` 保持旧值,
/// 不会出现"界面已切换、重启后又变回去"的假成功。
Future<void> persistReasoningLevel({
  required ReasoningLevel level,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
}) async {
  final updated = current.copyWith(reasoningLevel: level);
  await repo.save(updated);
  appSettingsSetter(updated);
}

/// 后台 agent 启用的子功能选择,随 appSettingsProvider 派生。
final backgroundFeaturesProvider = StateProvider<BackgroundFeatures>(
  (ref) => ref.watch(appSettingsProvider).features,
);

/// 更新某项后台功能(on/off)并落库。featureSetter 用于写 backgroundFeaturesProvider,
/// appSettingsSetter 用于同步 appSettingsProvider,repo 持久化位掩码。
Future<void> persistBackgroundFeature({
  required BackgroundFeatures Function(BackgroundFeatures) mutate,
  required void Function(BackgroundFeatures) featureSetter,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
}) async {
  final next = mutate(current.features);
  featureSetter(next);
  appSettingsSetter(current.copyWith(features: next));
  await repo.save(current.copyWith(features: next));
}

/// 更新后台 agent 专用模型并落库。modelId 为 llm_models 表中的整型 id;
/// null 表示后台跟随主写引擎当前模型。同步 appSettingsProvider(app_settings
/// 单一真相)与库。
Future<void> persistBackgroundModel({
  required int? modelId,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
}) async {
  final next = current.copyWith(backgroundModelId: modelId);
  appSettingsSetter(next);
  await repo.save(next);
}

/// 更新后台 agent 请求的推理强度并落库(schema v48)。与专用模型一样是后台
/// 独立参数:仅影响后台维护/主动轮的 LLM 请求,不动主对话的 reasoningLevel。
Future<void> persistBackgroundReasoningLevel({
  required ReasoningLevel level,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
}) async {
  final next = current.copyWith(backgroundReasoningLevel: level);
  appSettingsSetter(next);
  await repo.save(next);
}

/// 更新后台 agent 输出上限档位并落库(schema v54)。与推理强度一样是后台
/// 独立参数:仅影响后台维护/主动轮首试请求的 max_tokens,重试恒放开。
Future<void> persistBackgroundOutputTier({
  required BackgroundOutputTier tier,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
}) async {
  final next = current.copyWith(backgroundOutputTier: tier);
  appSettingsSetter(next);
  await repo.save(next);
}

/// 切换后台变量删除前确认严格模式并落库。
Future<void> persistBackgroundDeletionConfirm({
  required bool enabled,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
}) async {
  final next = current.copyWith(backgroundDeletionConfirm: enabled);
  appSettingsSetter(next);
  await repo.save(next);
}

/// 切换后台 agent 上下文锚定段开关(角色卡/记忆)并落库。
/// [key]:'character' 或 'memory'。
Future<void> persistBackgroundAnchor({
  required String key,
  required void Function(AppSettings) appSettingsSetter,
  required AppSettingsRepository repo,
  required AppSettings current,
}) async {
  final next = key == 'character'
      ? current.copyWith(
          backgroundCharacterAnchor: !current.backgroundCharacterAnchor,
        )
      : current.copyWith(
          backgroundMemoryAnchor: !current.backgroundMemoryAnchor,
        );
  appSettingsSetter(next);
  await repo.save(next);
}

/// 角色的会话列表(含消息数与最后一条预览),供会话列表屏展示。
final sessionInfosProvider = FutureProvider.family<List<SessionInfo>, int>(
  (ref, characterId) =>
      ref.watch(sessionRepositoryProvider).infosByCharacter(characterId),
);

/// 全局提示词项列表(管理页)。
final promptItemsProvider = FutureProvider<List<PromptItem>>(
  (ref) => ref.watch(promptItemRepositoryProvider).all(),
);

/// 自定义生图风格列表(设置页「画面风格」下拉混排 + 管理页)。
final imageStylesProvider = FutureProvider<List<ImageStylePreset>>(
  (ref) => ref.watch(imageStyleRepositoryProvider).all(),
);

/// Hook 列表(管理页)。
final hooksProvider = FutureProvider<List<Hook>>(
  (ref) => ref.watch(hookRepositoryProvider).all(),
);

/// 正则脚本列表(管理页)。
final regexScriptsProvider = FutureProvider<List<RegexScript>>(
  (ref) => ref.watch(regexScriptRepositoryProvider).all(),
);

// 注意:脚本/词典的"已编译"结果**不做成派生 Provider**(Provider 里 watch
// FutureProvider 再取 .value)—— 曾这样实现时,聊天页(长生命周期路由)被
// 其它路由覆盖再返回的瞬间 TickerMode 重启用订阅,resume 的 flush 链上
// `Ref.watch → invalidateSelf → scheduleRefresh` 会在 build 期间对根 scope
// setState,抛 "setState() called during build"。现由 chat_screen 直接 watch
// 这里的 FutureProvider,再用按列表实例记忆化的 compileDisplayScripts /
// compileGlossary 就地编译(流式每帧重建不重编)。

/// 角色的世界书条目(管理页)。
final worldbookProvider = FutureProvider.family<List<WorldbookEntry>, int>(
  (ref, characterId) =>
      ref.watch(worldbookRepositoryProvider).byCharacter(characterId),
);

/// 全局技能目录(设置页管理;启用中的技能在所有会话全局生效)。
final skillsProvider = FutureProvider<List<Skill>>(
  (ref) => ref.watch(skillRepositoryProvider).all(),
);

/// 会话级记忆列表(状态面板与后台读取)。
final memoriesProvider = FutureProvider.family<List<Memory>, int>(
  (ref, sessionId) => ref.watch(memoryRepositoryProvider).bySession(sessionId),
);

/// 会话级变量键值(后台与状态面板使用,主写不消费)。
final variablesProvider = FutureProvider.family<Map<String, String>, int>(
  (ref, sessionId) =>
      ref.watch(variableRepositoryProvider).bySession(sessionId),
);

/// 状态面板用:带权限元数据的变量行。
final variableRowsProvider = FutureProvider.family<List<Variable>, int>(
  (ref, sessionId) =>
      ref.watch(variableRepositoryProvider).rowsBySession(sessionId),
);

/// 变量回收站(手动删除与后台删除都进这里,可恢复)。
final variableTrashProvider =
    FutureProvider.family<List<VariableTrashEntry>, int>(
      (ref, sessionId) =>
          ref.watch(variableRepositoryProvider).trash(sessionId),
    );

/// 严格模式下的待确认删除建议。
final pendingVariableDeletionsProvider =
    FutureProvider.family<List<VariableDeletionProposal>, int>(
      (ref, sessionId) =>
          ref.watch(variableRepositoryProvider).pendingDeletions(sessionId),
    );

/// 会话级生图指导:后台 agent 生图维护每轮携带的最新文本;用户在
/// 状态面板编辑/初始化后失效刷新。
final imageGuideProvider = FutureProvider.family<List<ImageGuide>, int>(
  (ref, sessionId) =>
      ref.watch(imageGuideRepositoryProvider).bySession(sessionId),
);

/// 当前主写后端的运行时配置(设置页/启动水合写入);null 表示未配置。
final backendConfigProvider = StateProvider<BackendConfig?>((ref) => null);

/// 按 provider 分组的 LLM 后端配置列表(设置页展示)。
/// 设置页保存后 `ref.invalidate(llmProvidersProvider)` 刷新。
final llmProvidersProvider = FutureProvider<List<LlmProviderConfig>>(
  (ref) => ref.watch(llmProviderRepositoryProvider).all(),
);

/// 由 [backendConfigProvider] 派生主写后端;配置为 null 时返回 null,
/// 调用方据此给出"后端未配置"提示。
final backendProvider = Provider<LlmBackend?>((ref) {
  final config = ref.watch(backendConfigProvider);
  return config == null ? null : createBackend(config);
});

/// **当前活跃**的生图配置(设置页写入,main() 从库恢复)。`kind` 决定它承载
/// 哪家的凭据与参数。
///
/// 多套配置由 [imageProvidersProvider] 管理;这里只镜像"当前在用那一套",
/// 运行链路(编排器/后台引擎)只读这个 Provider。
final imageConfigProvider = StateProvider<ImageConfig?>((ref) => null);

/// 启动时同步水合的插件目录;后端路由不能等待异步列表,否则首次生图会瞬时空配置。
final imagePluginsProvider = StateProvider<List<ImagePlugin>>(
  (ref) => const [],
);

/// 全部生图配置(设置页列表;一行一套,各自带 api_key)。保存/删除/切换当前
/// 使用后 `ref.invalidate(imageProvidersProvider)` 刷新。
final imageProvidersProvider = FutureProvider<List<ImageProviderRecord>>(
  (ref) => ref.watch(imageConfigRepositoryProvider).all(),
);

/// 生图 provider:统一走插件路径(内置协议亦为仓库自带插件)。未配置返回 null;
/// 插件缺失/停用/JS 不可用由 [PluginImageBackend] 在生成时抛出明确错误。
final imageBackendProvider = Provider<ImageBackend?>((ref) {
  final config = ref.watch(imageConfigProvider);
  if (config == null) return null;
  final pluginId = config.pluginId;
  final plugins = ref.watch(imagePluginsProvider);
  final runtime = ref.watch(hookRuntimeProvider);
  return PluginImageBackend(
    config: config,
    plugin: plugins.where((plugin) => plugin.id == pluginId).firstOrNull,
    evaluator: runtime?.evaluate,
  );
});
