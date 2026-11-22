/// 应用入口:初始化数据库、文本配置、LLM/生图配置与 JS Hook 运行时,
/// 再通过 Riverpod overrides 启动界面。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'app.dart';
import 'data/app_config_file.dart';
import 'data/app_settings_repository.dart';
import 'data/card_studio_draft_file.dart';
import 'data/database.dart';
import 'data/image_asset_store.dart';
import 'data/image_config_repository.dart';
import 'data/image_plugin_repository.dart';
import 'data/llm_provider_repository.dart';
import 'data/ui_prefs_file.dart';
import 'data/user_repository.dart';
import 'engine/hook_runtime.dart';
import 'engine/js_hook_runtime.dart';
import 'state/image_plugin_runtime.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _bootstrap();
  } catch (e, st) {
    // 数据库/配置文件/偏好任一打开失败都不该黑屏退出:渲染最小错误页,
    // 保留可诊断的异常信息,由用户重启或修复环境。
    debugPrint('MicroScritt 启动失败:$e\n$st');
    runApp(_StartupFailureApp(message: '$e'));
  }
}

Future<void> _bootstrap() async {
  // 桌面端(以及所有非移动平台)使用 FFI;移动端使用原生 sqflite 插件。
  if (!(await _isMobile())) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final db = await AppDatabase.open();
  // 配置中的自定义插件需在写库前做运行期校验;引擎不可用时仅恢复数据。
  final hookRuntime = await _createHookRuntime();
  // 文本配置文件(用户名 + LLM + 生图):启动时以文件为准应用一次(坏文件
  // 只打日志、保留原文件),首次启动则用当前库生成文件。dirty 标记存在时
  // 说明库比文件新,改为从库重建,避免旧文件覆盖新设置。
  final configFile = await AppConfigFile.openDefault();
  await configFile.applyIfPresent(
    db,
    validatePlugin: hookRuntime == null
        ? null
        : (plugin) => validateImagePluginRuntime(hookRuntime, plugin),
  );
  try {
    await configFile.writeIfMissing(db);
  } catch (e) {
    debugPrint('创建配置文件失败(已忽略):$e');
  }
  // LLM 后端按 provider 分组:从新表解析当前在用的 provider+模型。
  final savedConfig = await LlmProviderRepository(db).loadBackendConfig();
  // 每次启动刷新内置协议插件(传播协议修复,保留启用状态),再水合插件目录
  // 与当前生图配置。
  await ImagePluginRepository(db).upsertBuiltins();
  final savedImagePlugins = await ImagePluginRepository(db).all();
  final savedImageConfig = await ImageConfigRepository(db).loadActiveConfig();
  final savedSettings = await AppSettingsRepository(db).load();
  final savedUser = await UserRepository(db).load();
  // UI 偏好(角色列表布局):坏文件一律回落默认,启动不因它失败。
  final uiPrefsFile = await UiPrefsFile.openDefault();
  final uiPrefs = await uiPrefsFile.read();
  // 制卡草稿文件:控制器进入工作台时读取,保存为尽力而为。
  final cardStudioDraftFile = await CardStudioDraftFile.openDefault();
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
      cardStudioDraftFileProvider.overrideWithValue(cardStudioDraftFile),
      characterLayoutProvider.overrideWith((ref) => uiPrefs.characterLayout),
      sidebarCollapsedProvider.overrideWith((ref) => uiPrefs.sidebarCollapsed),
      deckFrontCharacterIdProvider.overrideWith(
        (ref) => uiPrefs.deckFrontCharacterId,
      ),
      if (hookRuntime != null)
        hookRuntimeProvider.overrideWithValue(hookRuntime),
    ],
    child: const MicroScrittApp(),
  );
  runApp(app);
  // 首屏已提交后再做文件维护;先按业务表与制卡草稿真实持有对账引用,再
  // 清理 tmp、裁剪预览和回收到期零引用资产。任何失败都由维护入口记录并吞掉。
  unawaited(
    runImageAssetStartupMaintenance(
      db.images,
      externalReferences: cardStudioDraftFile.scanHeldAssetHashSets,
    ),
  );
}

/// 构造桌面 QuickJS 运行时;不可用时返回 null,启动不依赖 JS 引擎。
///
/// 探测走 [JsHookRuntime.probe]:与求值使用同一条构造降级路径。旧的
/// 「无参构造探活」检测不出 bridge 缺 `jsSetMemoryLimit` 符号的平台
/// (求值档构造失败被吞成 null,hook 全部静默失效),probe 则用与生产
/// 一致的构造档。
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

/// 启动失败时的最小界面:不依赖数据库/配置/Riverpod,只展示可诊断信息。
class _StartupFailureApp extends StatelessWidget {
  final String message;
  const _StartupFailureApp({required this.message});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 40),
                const SizedBox(height: 12),
                const Text(
                  'MicroScritt 启动失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                const Text('请检查存储权限/磁盘空间后重启应用。'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
