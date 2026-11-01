import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'app.dart';
import 'data/app_config_file.dart';
import 'data/app_settings_repository.dart';
import 'data/database.dart';
import 'data/image_config_repository.dart';
import 'data/image_plugin_repository.dart';
import 'data/llm_provider_repository.dart';
import 'data/ui_prefs_file.dart';
import 'data/user_repository.dart';
import 'engine/hook_runtime.dart';
import 'engine/js_hook_runtime.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Desktop (and any non-mobile) uses FFI; mobile uses the native sqflite plugin.
  if (!(await _isMobile())) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final db = await AppDatabase.open();
  // 文本配置文件(用户名 + LLM provider):启动时以文件为准应用一次(坏文件
  // 只打日志、保留原文件),首次启动则用当前库生成样例文件。
  final configFile = await AppConfigFile.openDefault();
  await configFile.applyIfPresent(db);
  try {
    await configFile.writeIfMissing(db);
  } catch (e) {
    debugPrint('创建配置文件失败(已忽略):$e');
  }
  // LLM 后端按 provider 分组:从新表解析当前在用的 provider+模型。
  final savedConfig = await LlmProviderRepository(db).loadBackendConfig();
  // 生图配置同样多行化(v60):启动只水合"当前在用那一套"。
  final savedImageConfig = await ImageConfigRepository(db).loadActiveConfig();
  // 每次启动刷新内置协议插件(传播协议修复,保留启用状态),再水合插件目录。
  await ImagePluginRepository(db).upsertBuiltins();
  final savedImagePlugins = await ImagePluginRepository(db).all();
  final savedSettings = await AppSettingsRepository(db).load();
  final savedUser = await UserRepository(db).load();
  // UI 偏好(角色列表布局):坏文件一律回落默认,启动不因它失败。
  final uiPrefsFile = await UiPrefsFile.openDefault();
  final uiPrefs = await uiPrefsFile.read();
  // Wire a real JS hook runtime. Non-fatal: if the native QuickJS bridge can't
  // load on this platform, leave hookRuntimeProvider null and the app still
  // boots (hooks are simply inert).
  final hookRuntime = await _createHookRuntime();
  final app = ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Seed the persisted LLM config so backendProvider resolves on startup.
      backendConfigProvider.overrideWith((ref) => savedConfig),
      // Seed the active image provider so the background engine can dispatch
      // image generation without visiting settings first.
      imageConfigProvider.overrideWith((ref) => savedImageConfig),
      imagePluginsProvider.overrideWith((ref) => savedImagePlugins),
      // 主题等应用偏好从 app_settings 恢复。
      appSettingsProvider.overrideWith((ref) => savedSettings),
      // 用户档案(用户名+头像)从 user_profile 恢复,供 Hook 替换与头像展示。
      userProfileProvider.overrideWith((ref) => savedUser),
      // 配置文件回写/设置页导出导入使用同一实例。
      appConfigFileProvider.overrideWithValue(configFile),
      // UI 偏好:恢复角色列表布局,切换时回写同一文件。
      uiPrefsFileProvider.overrideWithValue(uiPrefsFile),
      characterLayoutProvider.overrideWith((ref) => uiPrefs.characterLayout),
      if (hookRuntime != null)
        hookRuntimeProvider.overrideWithValue(hookRuntime),
    ],
    child: const MicroScrittApp(),
  );
  runApp(app);
}

/// Instantiates the desktop QuickJS runtime; returns null if it can't be built
/// (e.g. missing native bridge), so app boot never depends on the JS engine.
/// 探测走 [JsHookRuntime.probe] —— 与求值同一条构造降级路径(EL 修):旧的
/// "无参构造探活"检测不出 bridge 缺 jsSetMemoryLimit 符号的平台(求值档构造
/// 失败被吞成 null,hook 全部静默失效),probe 则用与生产一致的构造档。
Future<HookRuntime?> _createHookRuntime() async {
  final runtime = await JsHookRuntime.probe();
  if (runtime == null) {
    debugPrint('Failed to initialize JS hook runtime (hooks will be inert)');
  }
  return runtime;
}

Future<bool> _isMobile() async {
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
