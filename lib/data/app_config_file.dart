/// 文本配置文件 `microscritt-config.json`(用户名 + LLM provider 目录 + 生图
/// 配置)的读写。
///
/// 文件与数据库同目录,启动时以文件为准应用用户名、provider、生图插件 /
/// provider / 自定义风格,UI 修改后回写;坏文件只打日志、不改库。整个应用
/// 过程在**单个 SQLite 事务**中完成:任一校验或写入失败都整体回滚,不会留下
/// 半套配置。文件含明文 API Key 与插件代码,不得随仓库分发。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/data_root.dart';
import '../models/image_config.dart';
import '../models/image_plugin.dart';
import '../models/image_plugin_seeds.dart';
import '../models/image_style_preset.dart';
import '../models/llm_provider.dart';
import 'app_settings_repository.dart';
import 'database.dart';
import 'image_config_repository.dart';
import 'image_plugin_repository.dart';
import 'image_style_repository.dart';
import 'llm_provider_repository.dart';
import 'user_repository.dart';

/// 文本配置文件:用户名 + 全部 LLM provider(含模型目录) + 生图插件 /
/// provider / 自定义风格,固定存放在数据库同目录(桌面端 `~/.microscritt`,
/// 移动端应用私有 Documents),启动时读取应用、设置修改后回写。
///
/// 文件是**启动时权威**:外部编辑后需重启生效;运行期以 UI 写回的内容为准。
/// apiKey 与插件代码以明文保存(与 SQLite 中的现状一致),文档与设置页均
/// 提示勿公开分享。
class AppConfigFile {
  static const String fileName = 'microscritt-config.json';

  /// 文件格式版本。v2 新增 `image` 节;v1 仍可导入,只应用 user / llm。
  static const int formatVersion = 2;

  /// 整份配置上限;插件包另有 1MB 单包上限,防止插件代码无限撑大启动文件。
  static const int maxConfigBytes = 32 * 1024 * 1024;
  static const int maxConfigPlugins = 32;

  final String path;
  const AppConfigFile(this.path);

  /// 内置插件 id → 种子 manifest:应用内置插件时只改 enabled,包体恒由
  /// 仓库维护,配置文件不写 code。
  static final Map<String, ImagePlugin> _builtinSeedsById = {
    for (final plugin in kDefaultImagePluginSeeds) plugin.id: plugin,
  };

  /// 与数据库同目录:桌面端固定数据根优先,移动端回退应用私有 Documents。
  static Future<AppConfigFile> openDefault() async {
    final fixed = DataRoot.desktopDir();
    final dir = fixed ?? (await getApplicationDocumentsDirectory()).path;
    return AppConfigFile(p.join(dir, fileName));
  }

  /// 从当前库生成配置文件文本(2 空格缩进,便于手动编辑)。
  static Future<String> snapshotText(AppDatabase db) async {
    final user = await UserRepository(db).name();
    final providers = await LlmProviderRepository(db).all();
    final plugins = await ImagePluginRepository(db).all();
    final imageProviders = await ImageConfigRepository(db).all();
    final styles = await ImageStyleRepository(db).all();
    final snapshot = AppConfigSnapshot(
      userName: user,
      providers: [
        for (final provider in providers)
          AppConfigProvider.fromConfig(provider),
      ],
      imagePlugins: [
        for (final plugin in plugins) AppConfigImagePlugin.fromPlugin(plugin),
      ],
      imageProviders: [
        for (final record in imageProviders)
          AppConfigImageProvider.fromRecord(record),
      ],
      imageStyles: [
        for (final style in styles) AppConfigImageStyle.fromPreset(style),
      ],
    );
    final text = const JsonEncoder.withIndent('  ').convert({
      'version': formatVersion,
      'user': {'name': snapshot.userName ?? ''},
      'llm': {
        'providers': [
          for (final provider in snapshot.providers!) provider.toJson(),
        ],
      },
      'image': {
        'plugins': [
          for (final plugin in snapshot.imagePlugins!) plugin.toJson(),
        ],
        'providers': [
          for (final provider in snapshot.imageProviders!) provider.toJson(),
        ],
        'styles': [for (final style in snapshot.imageStyles!) style.toJson()],
      },
    });
    if (utf8.encode(text).length > maxConfigBytes) {
      throw StateError('配置文件超过 32MiB 上限,请减少插件或配置数量');
    }
    return text;
  }

  /// 未完成回写的标记文件。数据库已变而配置文件尚未成功重写时存在;启动
  /// 看到它说明库比文件新,必须先重建文件,绝不能用旧文件覆盖库。
  String get dirtyPath => '$path.dirty';

  /// 在数据库配置变更前落 dirty 标记;失败不应阻断主保存流程。
  Future<void> markDirty() async {
    // 任何一次独立标脏都让在飞快照放弃删除 dirty(它可能已经落后)。
    _dirtyVersion++;
    final target = File(path);
    await target.parent.create(recursive: true);
    await File(
      dirtyPath,
    ).writeAsString(DateTime.now().toIso8601String(), flush: true);
  }

  /// 快照写队列与代次:并发保存串行执行,固定 tmp 不再互相覆盖;只有最后
  /// 一次写入(且期间没有新的标脏)才允许删除 dirty,避免旧快照把新库的
  /// dirty 删掉后,下次启动用旧文件覆盖新库。
  static Future<void> _writeTail = Future<void>.value();
  static int _writeGeneration = 0;
  static int _dirtyVersion = 0;

  /// 原子写:先写同目录临时文件再替换,避免半截文件被下次启动读走。
  ///
  /// 写入开始即创建 dirty 标记,成功后删除;中途崩溃或失败会让下次启动改走
  /// 「从库重建」而不是应用旧文件。多次调用排队执行。
  Future<void> writeSnapshot(AppDatabase db) {
    final generation = ++_writeGeneration;
    final completer = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      try {
        await _writeSnapshotLocked(db, generation);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _writeSnapshotLocked(AppDatabase db, int generation) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    await markDirty();
    final dirtyVersion = _dirtyVersion;
    final text = await snapshotText(db);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(text, flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(path);
    final dirty = File(dirtyPath);
    // 期间又有保存入队或有人单独标脏:让 dirty 保留,由最后一棒负责删除。
    if (generation == _writeGeneration &&
        dirtyVersion == _dirtyVersion &&
        await dirty.exists()) {
      await dirty.delete();
    }
  }

  /// 首次启动创建样例文件;已存在(含用户手改过的坏文件)一律不动。
  Future<void> writeIfMissing(AppDatabase db) async {
    if (await File(path).exists()) return;
    await writeSnapshot(db);
  }

  /// 启动入口:文件存在则解析并应用。解析失败只打日志并保留原文件;
  /// 应用在单事务中完成,失败整体回滚。
  ///
  /// [validatePlugin] 供上层对本次自定义插件做运行期校验(如 QuickJS 探针),
  /// 返回 false 或抛错都会拒绝整份配置;data 层不 import engine,故以回调注入。
  Future<AppConfigApplyResult?> applyIfPresent(
    AppDatabase db, {
    Future<bool> Function(ImagePlugin plugin)? validatePlugin,
  }) async {
    final file = File(path);
    if (!await file.exists()) return null;
    if (await file.length() > maxConfigBytes) {
      debugPrint('配置文件超过 32MiB 上限(已忽略)');
      return null;
    }
    final dirty = File(dirtyPath);
    if (await dirty.exists()) {
      debugPrint('检测到配置回写未完成:以数据库为准重建配置文件');
      try {
        await writeSnapshot(db);
      } catch (e) {
        debugPrint('配置文件从数据库重建失败(已忽略):$e');
      }
      return null;
    }
    try {
      return await applyText(
        db,
        await file.readAsString(),
        validatePlugin: validatePlugin,
      );
    } catch (e) {
      debugPrint('配置文件读取/应用失败(已忽略):$e');
      return null;
    }
  }

  /// 手动导入:严格解析,坏文件抛 [FormatException](启动路径会自行吞掉)。
  ///
  /// 结构/设置校验与 [validatePlugin] 全部在写库前完成;随后单事务写入,
  /// 失败整体回滚。
  static Future<AppConfigApplyResult> applyText(
    AppDatabase db,
    String text, {
    Future<bool> Function(ImagePlugin plugin)? validatePlugin,
  }) async {
    final AppConfigSnapshot snapshot;
    try {
      if (utf8.encode(text).length > maxConfigBytes) {
        throw const FormatException('配置文件超过 32MiB 上限');
      }
      snapshot = AppConfigSnapshot.fromJson(jsonDecode(text));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('不是有效的配置文件:$e');
    }
    return _apply(db, snapshot, validatePlugin: validatePlugin);
  }

  // 事务前先完成全部读取、diff 与校验;事务内只写。写入顺序:
  // 用户名 → LLM provider → 后台模型引用 → 生图插件 → 生图 provider →
  // 自定义风格。provider 行按逻辑 id 匹配更新、缺失的删除,因此
  // `background_model_id` 需要在 provider 写完后按 (providerId, modelId)
  // 找回新行 id。
  static Future<AppConfigApplyResult> _apply(
    AppDatabase db,
    AppConfigSnapshot snapshot, {
    Future<bool> Function(ImagePlugin plugin)? validatePlugin,
  }) async {
    // ---------- 事务前读取 ----------
    final users = UserRepository(db);
    final currentName = await users.name();
    final userChanged =
        snapshot.userName != null && snapshot.userName != currentName;

    final llmRepo = LlmProviderRepository(db);
    final settingsRepo = AppSettingsRepository(db);
    final existingLlm = await llmRepo.all();
    final settings = await settingsRepo.load();

    final llmProviders = snapshot.providers;
    var llmChanged = false;
    if (llmProviders != null) {
      // 后台专用模型按 llm_models.id 引用;替换 provider 前先记下它的逻辑身份,
      // 应用后按 (providerId, modelId) 找回新 id,找不到则回到"跟随主写模型"。
      final currentJson = jsonEncode([
        for (final provider in existingLlm)
          AppConfigProvider.fromConfig(provider).toJson(),
      ]);
      final incomingJson = jsonEncode([
        for (final provider in llmProviders) provider.toJson(),
      ]);
      llmChanged = currentJson != incomingJson;
    }

    final imagePlugins = snapshot.imagePlugins;
    final imageProviders = snapshot.imageProviders;
    final imageStyles = snapshot.imageStyles;

    final pluginRepo = ImagePluginRepository(db);
    // 插件节用于替换自定义条目;provider 节在"未给插件节"时要对照库内已有
    // 插件校验设置,因此两种情况都先读一份。
    final existingPlugins = imagePlugins != null || imageProviders != null
        ? await pluginRepo.all()
        : const <ImagePlugin>[];

    // 自定义插件的运行期校验(内置不跑)必须在任何写库之前完成。
    if (imagePlugins != null && validatePlugin != null) {
      for (final plugin in imagePlugins) {
        if (plugin.builtin) continue;
        final ok = await validatePlugin(plugin.package!);
        if (!ok) {
          throw FormatException('插件 ${plugin.id} 未通过运行期校验,已拒绝整份配置');
        }
      }
    }

    // 目标插件集合:内置只收敛 enabled,自定义 upsert。
    final customPlugins = <ImagePlugin>[];
    final builtinEnabled = <String, bool>{};
    if (imagePlugins != null) {
      for (final plugin in imagePlugins) {
        if (plugin.builtin) {
          builtinEnabled[plugin.id] = plugin.enabled;
        } else {
          customPlugins.add(plugin.package!.copyWith(enabled: plugin.enabled));
        }
      }
    }

    // provider 的 position 归一化为数组索引(与 replaceAll 的落库口径一致)。
    final normalizedProviders = imageProviders == null
        ? null
        : [
            for (final (index, provider) in imageProviders.indexed)
              provider.copyWith(position: index),
          ];

    // 校验 provider.pluginId 与 pluginSettings 对照 manifest。
    if (normalizedProviders != null) {
      final Map<String, ImagePlugin> manifests;
      if (imagePlugins != null) {
        // 只允许引用本次插件节中出现的插件;内置包体取仓库种子。
        manifests = {
          for (final plugin in imagePlugins)
            plugin.id: plugin.builtin
                ? _builtinSeedsById[plugin.id]!
                : plugin.package!,
        };
      } else {
        manifests = {for (final plugin in existingPlugins) plugin.id: plugin};
      }
      for (final (index, provider) in normalizedProviders.indexed) {
        final pluginId = provider.config.pluginId!;
        final manifest = manifests[pluginId];
        if (manifest == null) {
          throw FormatException('image.providers[$index] 引用的插件不存在:$pluginId');
        }
        _validatePluginSettings(
          manifest,
          provider.config.pluginSettings,
          'image.providers[$index]',
        );
      }
    }

    // 自定义风格:与内置预设同名的条目跳过,绝不覆盖内置。
    final warnings = <String>[];
    var skippedStyles = 0;
    List<AppConfigImageStyle>? customStyles;
    if (imageStyles != null) {
      final builtinNames = {
        for (final preset in kImageStylePresets) preset.name,
      };
      customStyles = <AppConfigImageStyle>[];
      for (final style in imageStyles) {
        if (builtinNames.contains(style.name)) {
          skippedStyles++;
          warnings.add('已跳过与内置风格同名的自定义风格:${style.name}');
          continue;
        }
        customStyles.add(style);
      }
    }

    // image 变化判定:按"事务将写入的目标状态"与库现状比较,避免无意义重写
    // 导致 provider / style 的 id 漂移。
    final existingImageProviders = normalizedProviders != null
        ? await ImageConfigRepository(db).all()
        : const <ImageProviderRecord>[];
    final existingStyles = customStyles != null
        ? await ImageStyleRepository(db).all()
        : const <ImageStylePreset>[];
    final pluginsChanged = imagePlugins == null
        ? false
        : _pluginsChanged(existingPlugins, imagePlugins);
    final providersChanged = normalizedProviders == null
        ? false
        : _imageProvidersChanged(existingImageProviders, normalizedProviders);
    final stylesChanged = customStyles == null
        ? false
        : _imageStylesChanged(existingStyles, customStyles);
    final imageChanged = pluginsChanged || providersChanged || stylesChanged;

    // ---------- 单事务写入 ----------
    await db.transaction((txn) async {
      if (userChanged) {
        await users.updateNameInTransaction(txn, snapshot.userName!);
      }

      if (llmProviders != null) {
        String? bgProviderId;
        String? bgModelId;
        if (settings.backgroundModelId != null) {
          for (final provider in existingLlm) {
            for (final model in provider.models) {
              if (model.id == settings.backgroundModelId) {
                bgProviderId = provider.providerId;
                bgModelId = model.modelId;
              }
            }
          }
        }

        if (llmChanged) {
          final byLogicalId = {
            for (final provider in existingLlm) provider.providerId: provider,
          };
          for (final incoming in llmProviders) {
            final match = byLogicalId[incoming.providerId];
            final modelIds = {
              for (final model in match?.models ?? const <LlmModelEntry>[])
                model.modelId: model.id,
            };
            await llmRepo.saveProviderInTransaction(
              txn,
              LlmProviderConfig(
                id: match?.id ?? 0,
                providerId: incoming.providerId,
                displayName: incoming.displayName,
                baseUrl: incoming.baseUrl,
                protocol: incoming.protocol,
                apiKey: incoming.apiKey,
                isActive: incoming.isActive,
                position: incoming.position,
                extraHeaders: incoming.extraHeaders,
                modernParams: incoming.modernParams,
                models: [
                  for (final model in incoming.models)
                    LlmModelEntry(
                      id: modelIds[model.modelId] ?? 0,
                      providerId: match?.id ?? 0,
                      modelId: model.modelId,
                      displayName: model.displayName,
                      contextCapacity: model.contextCapacity,
                      maxOutput: model.maxOutput,
                      temperature: model.temperature,
                      isActive: model.isActive,
                      position: model.position,
                    ),
                ],
              ),
            );
          }
          final keep = {
            for (final provider in llmProviders) provider.providerId,
          };
          for (final old in existingLlm) {
            if (!keep.contains(old.providerId)) {
              await llmRepo.deleteProviderInTransaction(txn, old.id);
            }
          }
        }

        if (settings.backgroundModelId != null) {
          int? newId;
          if (bgProviderId != null && bgModelId != null) {
            for (final provider in await llmRepo.allWith(txn)) {
              if (provider.providerId != bgProviderId) continue;
              for (final model in provider.models) {
                if (model.modelId == bgModelId) newId = model.id;
              }
            }
          }
          if (newId != settings.backgroundModelId) {
            await settingsRepo.setBackgroundModelIdInTransaction(txn, newId);
          }
        }
      }

      if (imagePlugins != null && pluginsChanged) {
        await pluginRepo.replaceConfigInTransaction(
          txn,
          customPlugins: customPlugins,
          builtinEnabled: builtinEnabled,
        );
      }
      if (normalizedProviders != null && providersChanged) {
        await ImageConfigRepository(db).replaceAllInTransaction(txn, [
          for (final provider in normalizedProviders)
            ImageProviderRecord(
              id: 0,
              displayName: provider.displayName,
              isActive: provider.isActive,
              position: provider.position,
              config: provider.config,
            ),
        ]);
      }
      if (customStyles != null && stylesChanged) {
        await ImageStyleRepository(db).replaceAllInTransaction(txn, [
          for (final style in customStyles) style.toPreset(),
        ]);
      }
      // 反向引用校验:配置省略 providers 节时库内既有 provider 会保留,而
      // 插件节可能删掉它引用的自定义插件。任何孤儿 provider 都让整份配置回滚,
      // 与单条删除的 in-use 保护保持一致。仅在有生图配置写入时校验,避免
      // 历史遗留脏数据阻塞纯用户/LLM 配置导入。
      if (imagePlugins != null || normalizedProviders != null) {
        final orphanRows = await txn.rawQuery(
          'SELECT COUNT(*) AS n FROM image_providers p '
          'LEFT JOIN image_plugins pl ON pl.id = p.plugin_id '
          'WHERE pl.id IS NULL',
        );
        final orphanCount = (orphanRows.first['n'] as int?) ?? 0;
        if (orphanCount > 0) {
          throw FormatException(
            '配置会使 $orphanCount 个生图 provider 引用不存在的插件,已拒绝整份配置',
          );
        }
      }
    });

    return AppConfigApplyResult(
      userChanged: userChanged,
      llmChanged: llmChanged,
      providerCount: llmProviders?.length ?? 0,
      imageChanged: imageChanged,
      imageProviderCount: normalizedProviders?.length ?? 0,
      pluginCount: imagePlugins?.length ?? 0,
      styleCount: customStyles?.length ?? 0,
      skippedStyles: skippedStyles,
      warnings: warnings,
    );
  }

  /// 插件目录是否真的会变:内置只比较 enabled(包体由仓库维护),自定义比较
  /// 完整包体与 enabled,文件未列出的自定义会被删除。
  static bool _pluginsChanged(
    List<ImagePlugin> existing,
    List<AppConfigImagePlugin> incoming,
  ) {
    final incomingById = {for (final plugin in incoming) plugin.id: plugin};
    final existingById = {for (final plugin in existing) plugin.id: plugin};
    for (final old in existing) {
      final next = incomingById[old.id];
      if (next == null) {
        if (!kBuiltinImagePluginIds.contains(old.id)) return true;
        continue;
      }
      if (next.enabled != old.enabled) return true;
      if (!next.builtin &&
          next.package!.toPackageJson() != old.toPackageJson()) {
        return true;
      }
    }
    for (final next in incoming) {
      if (next.builtin) continue;
      if (!existingById.containsKey(next.id)) return true;
    }
    return false;
  }

  static bool _imageProvidersChanged(
    List<ImageProviderRecord> existing,
    List<AppConfigImageProvider> incoming,
  ) {
    final current = jsonEncode([
      for (final record in existing)
        AppConfigImageProvider.fromRecord(record).toJson(),
    ]);
    final next = jsonEncode([
      for (final provider in incoming) provider.toJson(),
    ]);
    return current != next;
  }

  static bool _imageStylesChanged(
    List<ImageStylePreset> existing,
    List<AppConfigImageStyle> incoming,
  ) {
    String key(Iterable<AppConfigImageStyle> styles) {
      final list = styles.toList()..sort((a, b) => a.name.compareTo(b.name));
      return jsonEncode([for (final style in list) style.toJson()]);
    }

    return key([
          for (final style in existing) AppConfigImageStyle.fromPreset(style),
        ]) !=
        key(incoming);
  }

  /// 对照插件 manifest 校验落库前的动态设置:
  /// required 缺失/空、类型不匹配、select 值不在 options、url 非 HTTP(S)。
  /// 未在 manifest 声明的键(宿主注入项等)不校验。
  static void _validatePluginSettings(
    ImagePlugin plugin,
    Map<String, dynamic> settings,
    String where,
  ) {
    for (final field in plugin.fields) {
      final value = settings[field.key];
      final empty = value == null || (value is String && value.trim().isEmpty);
      if (empty) {
        if (field.required) {
          throw FormatException('$where 缺少必填设置 ${field.key}');
        }
        continue;
      }
      switch (field.type) {
        case ImagePluginFieldType.text:
        case ImagePluginFieldType.password:
          if (value is! String) {
            throw FormatException('$where 的设置 ${field.key} 必须是字符串');
          }
        case ImagePluginFieldType.url:
          if (value is! String) {
            throw FormatException('$where 的设置 ${field.key} 必须是字符串');
          }
          final uri = Uri.tryParse(value);
          if (uri == null ||
              !(uri.isScheme('http') || uri.isScheme('https')) ||
              uri.host.isEmpty) {
            throw FormatException('$where 的设置 ${field.key} 必须是 HTTP(S) 地址');
          }
        case ImagePluginFieldType.integer:
          if (value is! int) {
            throw FormatException('$where 的设置 ${field.key} 必须是整数');
          }
        case ImagePluginFieldType.number:
          if (value is! num) {
            throw FormatException('$where 的设置 ${field.key} 必须是数值');
          }
        case ImagePluginFieldType.boolean:
          if (value is! bool) {
            throw FormatException('$where 的设置 ${field.key} 必须是布尔值');
          }
        case ImagePluginFieldType.select:
          if (value is! String ||
              !field.options.any((option) => option.value == value)) {
            throw FormatException('$where 的设置 ${field.key} 不在可选值内');
          }
      }
    }
  }
}

/// 配置文件的应用结果:哪些节发生了变化、文件提供了多少条目。
class AppConfigApplyResult {
  final bool userChanged;
  final bool llmChanged;
  final int providerCount;

  /// 生图节(插件 / provider / 风格任一)是否发生变化。
  final bool imageChanged;

  /// 文件中的生图 provider 数量。
  final int imageProviderCount;

  /// 文件中的插件数量(含内置)。
  final int pluginCount;

  /// 实际应用的自定义风格数量(已过滤内置同名)。
  final int styleCount;

  /// 因与内置预设同名而被跳过的自定义风格数量。
  final int skippedStyles;

  /// 可展示给用户的非致命提示(如跳过的同名风格)。
  final List<String> warnings;

  const AppConfigApplyResult({
    required this.userChanged,
    required this.llmChanged,
    required this.providerCount,
    this.imageChanged = false,
    this.imageProviderCount = 0,
    this.pluginCount = 0,
    this.styleCount = 0,
    this.skippedStyles = 0,
    this.warnings = const [],
  });

  bool get changed => userChanged || llmChanged || imageChanged;
}

/// 配置文件内存表示。null 字段表示"文件未提供该节",与应用语义一致。
class AppConfigSnapshot {
  final String? userName;
  final List<AppConfigProvider>? providers;
  final List<AppConfigImagePlugin>? imagePlugins;
  final List<AppConfigImageProvider>? imageProviders;
  final List<AppConfigImageStyle>? imageStyles;

  const AppConfigSnapshot({
    this.userName,
    this.providers,
    this.imagePlugins,
    this.imageProviders,
    this.imageStyles,
  });

  /// 严格解析:结构不合法抛 [FormatException]。启动路径会自行吞掉并保留
  /// 原文件,手动导入则向用户报错。
  ///
  /// v1 文件只解析 user / llm(即使带 `image` 也忽略);v2 起解析 image 节。
  static AppConfigSnapshot fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('不是有效的配置文件(缺少顶层对象)');
    }
    final version = raw['version'];
    if (version is! int || version < 1) {
      throw const FormatException('配置文件缺少有效的 version');
    }
    if (version > AppConfigFile.formatVersion) {
      throw const FormatException('配置文件版本过新,请升级应用');
    }
    String? userName;
    final user = raw['user'];
    if (user != null) {
      if (user is! Map<String, dynamic>) {
        throw const FormatException('user 节必须是对象');
      }
      final name = user['name'];
      if (name != null && name is! String) {
        throw const FormatException('user.name 必须是字符串');
      }
      userName = name as String?;
    }
    List<AppConfigProvider>? providers;
    final llm = raw['llm'];
    if (llm != null) {
      if (llm is! Map<String, dynamic>) {
        throw const FormatException('llm 节必须是对象');
      }
      final list = llm['providers'];
      if (list != null) {
        if (list is! List) throw const FormatException('llm.providers 必须是数组');
        providers = [
          for (final (i, item) in list.indexed)
            AppConfigProvider.fromJson(item, i),
        ];
        // 与库快照(按 position 排序)同序,避免文件顺序不同导致每次启动都判定"有变化"。
        providers.sort((a, b) => a.position.compareTo(b.position));
        providers = _normalizeActives(providers);
      }
    }

    List<AppConfigImagePlugin>? imagePlugins;
    List<AppConfigImageProvider>? imageProviders;
    List<AppConfigImageStyle>? imageStyles;
    if (version >= 2) {
      final image = raw['image'];
      if (image != null) {
        if (image is! Map<String, dynamic>) {
          throw const FormatException('image 节必须是对象');
        }
        final rawPlugins = image['plugins'];
        if (rawPlugins != null) {
          if (rawPlugins is! List) {
            throw const FormatException('image.plugins 必须是数组');
          }
          final list = [
            for (final (i, item) in rawPlugins.indexed)
              AppConfigImagePlugin.fromJson(item, i),
          ];
          if (list.length > AppConfigFile.maxConfigPlugins) {
            throw const FormatException('image.plugins 超过 32 个上限');
          }
          final ids = <String>{};
          for (final plugin in list) {
            if (!ids.add(plugin.id)) {
              throw FormatException('image.plugins 中插件 id 重复:${plugin.id}');
            }
          }
          imagePlugins = list;
        }
        final rawProviders = image['providers'];
        if (rawProviders != null) {
          if (rawProviders is! List) {
            throw const FormatException('image.providers 必须是数组');
          }
          final list = [
            for (final (i, item) in rawProviders.indexed)
              AppConfigImageProvider.fromJson(item, i),
          ];
          imageProviders = _normalizeImageProviderActives(list);
        }
        final rawStyles = image['styles'];
        if (rawStyles != null) {
          if (rawStyles is! List) {
            throw const FormatException('image.styles 必须是数组');
          }
          final list = [
            for (final (i, item) in rawStyles.indexed)
              AppConfigImageStyle.fromJson(item, i),
          ];
          final names = <String>{};
          for (final style in list) {
            if (!names.add(style.name)) {
              throw FormatException('image.styles 中风格名重复:${style.name}');
            }
          }
          imageStyles = list;
        }
      }
    }

    if (userName == null &&
        providers == null &&
        imagePlugins == null &&
        imageProviders == null &&
        imageStyles == null) {
      throw const FormatException('配置文件没有可应用的配置(user / llm / image 均缺失)');
    }
    return AppConfigSnapshot(
      userName: userName,
      providers: providers,
      imagePlugins: imagePlugins,
      imageProviders: imageProviders,
      imageStyles: imageStyles,
    );
  }

  /// 同一时刻只保留一个活跃 provider 与其下一个活跃模型,与运行链路一致。
  static List<AppConfigProvider> _normalizeActives(
    List<AppConfigProvider> providers,
  ) {
    final out = <AppConfigProvider>[];
    var providerTaken = false;
    for (final provider in providers) {
      if (!provider.isActive || providerTaken) {
        out.add(
          provider.copyWith(
            isActive: false,
            models: [
              for (final model in provider.models)
                model.copyWith(isActive: false),
            ],
          ),
        );
        continue;
      }
      providerTaken = true;
      var modelTaken = false;
      final models = <AppConfigModel>[];
      for (final model in provider.models) {
        if (model.isActive && !modelTaken) {
          modelTaken = true;
          models.add(model);
        } else {
          models.add(model.copyWith(isActive: false));
        }
      }
      out.add(provider.copyWith(isActive: true, models: models));
    }
    return out;
  }

  /// 生图 provider 同样只保留一个活跃项:多个 active 保留第一个;一个都
  /// 没有时有配置就让首条活跃(与 `ImageConfigRepository.saveProvider` 的
  /// "首条自动活跃"一致,避免出现"有配置但无活跃、生图静默跳过")。
  static List<AppConfigImageProvider> _normalizeImageProviderActives(
    List<AppConfigImageProvider> providers,
  ) {
    var activeTaken = false;
    final out = <AppConfigImageProvider>[];
    for (final provider in providers) {
      final active = provider.isActive && !activeTaken;
      if (active) activeTaken = true;
      out.add(provider.copyWith(isActive: active));
    }
    if (!activeTaken && out.isNotEmpty) {
      out[0] = out[0].copyWith(isActive: true);
    }
    return out;
  }
}

/// 文件中的一个 LLM provider(含模型目录),是落库配置的可编辑镜像。
///
/// 逻辑身份是 [providerId];应用时按它匹配既有行,避免重插导致模型 id
/// 漂移、`background_model_id` 等引用悬空。
class AppConfigProvider {
  final String providerId;
  final String displayName;
  final String baseUrl;
  final LlmProtocol protocol;
  final String apiKey;
  final bool isActive;
  final int position;
  final Map<String, String> extraHeaders;
  final bool modernParams;
  final List<AppConfigModel> models;

  const AppConfigProvider({
    required this.providerId,
    required this.displayName,
    required this.baseUrl,
    required this.protocol,
    required this.apiKey,
    required this.isActive,
    required this.position,
    required this.extraHeaders,
    required this.modernParams,
    required this.models,
  });

  factory AppConfigProvider.fromConfig(LlmProviderConfig config) =>
      AppConfigProvider(
        providerId: config.providerId,
        displayName: config.displayName,
        baseUrl: config.baseUrl,
        protocol: config.protocol,
        apiKey: config.apiKey,
        isActive: config.isActive,
        position: config.position,
        extraHeaders: Map<String, String>.from(config.extraHeaders),
        modernParams: config.modernParams,
        models: [
          for (final model in config.models)
            AppConfigModel(
              modelId: model.modelId,
              displayName: model.displayName,
              contextCapacity: model.contextCapacity,
              maxOutput: model.maxOutput,
              temperature: model.temperature,
              isActive: model.isActive,
              position: model.position,
            ),
        ]..sort((a, b) => a.position.compareTo(b.position)),
      );

  /// 严格解析单个 provider:`providerId`/`displayName`/`baseUrl` 必须为
  /// 非空字符串,`apiKey` 缺省按空串;不合法时抛 [FormatException]。
  static AppConfigProvider fromJson(Object? raw, int index) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException('llm.providers[$index] 必须是对象');
    }
    String text(String key, {bool required = true}) {
      final value = raw[key];
      if (value is String && (!required || value.trim().isNotEmpty)) {
        return value;
      }
      if (!required && value == null) return '';
      throw FormatException('provider.$key 必须是非空字符串');
    }

    final rawHeaders = raw['extraHeaders'];
    final headers = <String, String>{};
    if (rawHeaders != null) {
      if (rawHeaders is! Map) {
        throw const FormatException('provider.extraHeaders 必须是对象');
      }
      for (final entry in rawHeaders.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }
    final rawModels = raw['models'];
    final models = <AppConfigModel>[];
    if (rawModels != null) {
      if (rawModels is! List) {
        throw const FormatException('provider.models 必须是数组');
      }
      for (final (i, model) in rawModels.indexed) {
        models.add(AppConfigModel.fromJson(model, i));
      }
    }
    models.sort((a, b) => a.position.compareTo(b.position));
    return AppConfigProvider(
      providerId: text('providerId'),
      displayName: text('displayName'),
      baseUrl: text('baseUrl'),
      protocol: LlmProtocol.fromWire(
        raw['protocol'] is String ? raw['protocol'] as String : '',
      ),
      apiKey: raw['apiKey'] is String ? raw['apiKey'] as String : '',
      isActive: raw['isActive'] == true,
      position: raw['position'] is int ? raw['position'] as int : index,
      // 与落库口径一致(键小写/去空白),保证"库快照 vs 文件快照"的可比性。
      extraHeaders: LlmProviderConfig.normalizeExtraHeaders(headers),
      modernParams: raw['modernParams'] == true,
      models: models,
    );
  }

  AppConfigProvider copyWith({bool? isActive, List<AppConfigModel>? models}) =>
      AppConfigProvider(
        providerId: providerId,
        displayName: displayName,
        baseUrl: baseUrl,
        protocol: protocol,
        apiKey: apiKey,
        isActive: isActive ?? this.isActive,
        position: position,
        extraHeaders: extraHeaders,
        modernParams: modernParams,
        models: models ?? this.models,
      );

  Map<String, dynamic> toJson() => {
    'providerId': providerId,
    'displayName': displayName,
    'baseUrl': baseUrl,
    'protocol': protocol.wire,
    'apiKey': apiKey,
    'isActive': isActive,
    'position': position,
    // 键排序保证与库快照比较时不受 Map 插入顺序影响。
    'extraHeaders': {
      for (final key in extraHeaders.keys.toList()..sort())
        key: extraHeaders[key],
    },
    'modernParams': modernParams,
    'models': [for (final model in models) model.toJson()],
  };
}

/// 文件中的一个模型条目;`modelId` 是逻辑身份,`position` 决定下拉顺序。
class AppConfigModel {
  final String modelId;
  final String displayName;
  final int contextCapacity;
  final int? maxOutput;

  /// 采样温度;文件缺省/非法时回落模型默认 1.0,与库内解析同口径。
  final double temperature;
  final bool isActive;
  final int position;

  const AppConfigModel({
    required this.modelId,
    required this.displayName,
    required this.contextCapacity,
    required this.maxOutput,
    required this.temperature,
    required this.isActive,
    required this.position,
  });

  /// 严格解析单个模型;`modelId` 缺失即抛 [FormatException],displayName
  /// 缺省回退到 `modelId`。
  static AppConfigModel fromJson(Object? raw, int index) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException('models[$index] 必须是对象');
    }
    final modelId = raw['modelId'];
    if (modelId is! String || modelId.trim().isEmpty) {
      throw const FormatException('model.modelId 必须是非空字符串');
    }
    return AppConfigModel(
      modelId: modelId,
      displayName:
          raw['displayName'] is String &&
              (raw['displayName'] as String).trim().isNotEmpty
          ? raw['displayName'] as String
          : modelId,
      contextCapacity: raw['contextCapacity'] is int
          ? raw['contextCapacity'] as int
          : 0,
      maxOutput: raw['maxOutput'] is int ? raw['maxOutput'] as int : null,
      temperature: raw['temperature'] is num
          ? (raw['temperature'] as num).toDouble()
          : LlmModelEntry.defaultTemperature,
      isActive: raw['isActive'] == true,
      position: raw['position'] is int ? raw['position'] as int : index,
    );
  }

  AppConfigModel copyWith({bool? isActive}) => AppConfigModel(
    modelId: modelId,
    displayName: displayName,
    contextCapacity: contextCapacity,
    maxOutput: maxOutput,
    temperature: temperature,
    isActive: isActive ?? this.isActive,
    position: position,
  );

  Map<String, dynamic> toJson() => {
    'modelId': modelId,
    'displayName': displayName,
    'contextCapacity': contextCapacity,
    'maxOutput': maxOutput,
    'temperature': temperature,
    'isActive': isActive,
    'position': position,
  };
}

/// 文件中的一个生图插件条目。
///
/// 内置插件只携带 `{id,builtin:true,version,enabled}`,包体由仓库种子维护;
/// 自定义插件携带完整单文件包 `package`(含 code)。
class AppConfigImagePlugin {
  final String id;
  final bool builtin;
  final String? version;
  final bool enabled;

  /// 自定义插件解析后的包;内置为 null。
  final ImagePlugin? package;

  const AppConfigImagePlugin({
    required this.id,
    required this.builtin,
    required this.enabled,
    this.version,
    this.package,
  });

  factory AppConfigImagePlugin.fromPlugin(ImagePlugin plugin) =>
      AppConfigImagePlugin(
        id: plugin.id,
        builtin: kBuiltinImagePluginIds.contains(plugin.id),
        version: plugin.version,
        enabled: plugin.enabled,
        package: kBuiltinImagePluginIds.contains(plugin.id) ? null : plugin,
      );

  /// 严格解析:内置 id 必须在仓库种子集合内且不得带 package;自定义必须
  /// 带对象 package,经 [ImagePlugin.fromPackageJson] 完整解析且 id 一致。
  static AppConfigImagePlugin fromJson(Object? raw, int index) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException('image.plugins[$index] 必须是对象');
    }
    final id = raw['id'];
    if (id is! String || id.trim().isEmpty) {
      throw FormatException('image.plugins[$index].id 必须是非空字符串');
    }
    final rawBuiltin = raw['builtin'];
    if (rawBuiltin != null && rawBuiltin is! bool) {
      throw FormatException('image.plugins[$index].builtin 必须是布尔值');
    }
    final builtin = rawBuiltin == true;
    final rawEnabled = raw['enabled'];
    if (rawEnabled != null && rawEnabled is! bool) {
      throw FormatException('image.plugins[$index].enabled 必须是布尔值');
    }
    final enabled = rawEnabled as bool? ?? true;
    final rawVersion = raw['version'];
    if (rawVersion != null && rawVersion is! String) {
      throw FormatException('image.plugins[$index].version 必须是字符串');
    }
    final version = rawVersion as String?;
    final rawPackage = raw['package'];

    if (builtin) {
      if (!kBuiltinImagePluginIds.contains(id)) {
        throw FormatException('image.plugins[$index] 的内置插件 id 未知:$id');
      }
      if (rawPackage != null) {
        throw FormatException('内置插件 $id 不得包含 package');
      }
      return AppConfigImagePlugin(
        id: id,
        builtin: true,
        version: version,
        enabled: enabled,
      );
    }

    // 内置 id 只能以 builtin 形式出现,防止配置文件覆盖仓库维护的协议代码。
    if (kBuiltinImagePluginIds.contains(id)) {
      throw FormatException('内置插件 $id 必须以 builtin:true 声明');
    }
    if (rawPackage is! Map<String, dynamic>) {
      throw FormatException('插件 $id 的 package 必须是对象');
    }
    final ImagePlugin parsed;
    try {
      parsed = ImagePlugin.fromPackageJson(jsonEncode(rawPackage));
    } on FormatException catch (e) {
      throw FormatException('插件 $id 的 package 无效:${e.message}');
    }
    if (parsed.id != id) {
      throw FormatException('插件 $id 的 package.id 与 id 不一致');
    }
    return AppConfigImagePlugin(
      id: id,
      builtin: false,
      version: version,
      enabled: enabled,
      package: parsed,
    );
  }

  Map<String, dynamic> toJson() => builtin
      ? {
          'id': id,
          'builtin': true,
          if (version != null) 'version': version,
          'enabled': enabled,
        }
      : {
          'id': id,
          'builtin': false,
          'enabled': enabled,
          'package': jsonDecode(package!.toPackageJson()),
        };
}

/// 文件中的一条生图 provider;配置字段与 `image_providers` 落库列一一对应
/// (不含自增 id,也不含未持久化的 nocache / token)。
class AppConfigImageProvider {
  final String displayName;
  final bool isActive;
  final int position;
  final ImageConfig config;

  const AppConfigImageProvider({
    required this.displayName,
    required this.isActive,
    required this.position,
    required this.config,
  });

  factory AppConfigImageProvider.fromRecord(ImageProviderRecord record) =>
      AppConfigImageProvider(
        displayName: record.displayName,
        isActive: record.isActive,
        position: record.position,
        config: record.config,
      );

  static AppConfigImageProvider fromJson(Object? raw, int index) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException('image.providers[$index] 必须是对象');
    }
    final displayName = _requiredString(
      raw['displayName'],
      'image.providers[$index].displayName',
    );
    final rawActive = raw['isActive'];
    if (rawActive != null && rawActive is! bool) {
      throw FormatException('image.providers[$index].isActive 必须是布尔值');
    }
    final isActive = rawActive as bool? ?? false;
    final rawPosition = raw['position'];
    if (rawPosition != null && rawPosition is! int) {
      throw FormatException('image.providers[$index].position 必须是整数');
    }
    final position = rawPosition as int? ?? index;

    final cfg = raw['config'];
    if (cfg is! Map<String, dynamic>) {
      throw FormatException('image.providers[$index].config 必须是对象');
    }
    final rawKind = cfg['kind'];
    if (rawKind != null && rawKind != 'plugin') {
      throw FormatException('image.providers[$index].config.kind 仅支持 plugin');
    }
    final baseUrl = _requiredString(
      cfg['baseUrl'],
      'image.providers[$index].config.baseUrl',
    );
    final pluginId = _requiredString(
      cfg['pluginId'],
      'image.providers[$index].config.pluginId',
    );
    final apiKey =
        _optionalString(
          cfg['apiKey'],
          'image.providers[$index].config.apiKey',
        ) ??
        '';
    final model =
        _optionalString(cfg['model'], 'image.providers[$index].config.model') ??
        '';
    final rawCount = cfg['count'];
    final int count;
    if (rawCount == null) {
      count = 1;
    } else if (rawCount is int) {
      count = rawCount.clamp(1, 6).toInt();
    } else {
      throw FormatException('image.providers[$index].config.count 必须是整数');
    }
    final rawCfg = cfg['cfg'];
    final double? cfgValue;
    if (rawCfg == null) {
      cfgValue = null;
    } else if (rawCfg is num) {
      cfgValue = rawCfg.toDouble();
    } else {
      throw FormatException('image.providers[$index].config.cfg 必须是数值');
    }

    return AppConfigImageProvider(
      displayName: displayName,
      isActive: isActive,
      position: position,
      config: ImageConfig(
        kind: ImageBackendKind.plugin,
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        size: _optionalString(
          cfg['size'],
          'image.providers[$index].config.size',
        ),
        scale: _optionalInt(
          cfg['scale'],
          'image.providers[$index].config.scale',
        ),
        cfg: cfgValue,
        negative: _optionalString(
          cfg['negative'],
          'image.providers[$index].config.negative',
        ),
        sampler: _optionalString(
          cfg['sampler'],
          'image.providers[$index].config.sampler',
        ),
        artist: _optionalString(
          cfg['artist'],
          'image.providers[$index].config.artist',
        ),
        noiseSchedule: _optionalString(
          cfg['noiseSchedule'],
          'image.providers[$index].config.noiseSchedule',
        ),
        steps: _optionalInt(
          cfg['steps'],
          'image.providers[$index].config.steps',
        ),
        count: count,
        pluginId: pluginId,
        pluginSettings: _parsePluginSettings(
          cfg['pluginSettings'],
          'image.providers[$index].config.pluginSettings',
        ),
      ),
    );
  }

  AppConfigImageProvider copyWith({bool? isActive, int? position}) =>
      AppConfigImageProvider(
        displayName: displayName,
        isActive: isActive ?? this.isActive,
        position: position ?? this.position,
        config: config,
      );

  /// 稳定键序,保证与库快照比较时不受 Map 插入顺序影响。
  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    'isActive': isActive,
    'position': position,
    'config': {
      'kind': config.kind.wire,
      'baseUrl': config.baseUrl,
      'apiKey': config.apiKey,
      'model': config.model,
      'size': config.size,
      'scale': config.scale,
      'cfg': config.cfg,
      'negative': config.negative,
      'sampler': config.sampler,
      'artist': config.artist,
      'noiseSchedule': config.noiseSchedule,
      'steps': config.steps,
      'count': config.count,
      'pluginId': config.pluginId,
      'pluginSettings': _sortedJson(config.pluginSettings),
    },
  };

  /// 插件动态设置必须是 JSON 对象,值只允许 JSON 标量 / 列表 / 对象。
  /// 非字符串键、非有限数等脏值一律拒绝。
  static Map<String, dynamic> _parsePluginSettings(Object? raw, String where) {
    if (raw == null) return const {};
    if (raw is! Map) throw FormatException('$where 必须是对象');
    final out = <String, dynamic>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) {
        throw FormatException('$where 的键必须是字符串');
      }
      out[entry.key as String] = _parseJsonValue(
        entry.value,
        '$where.${entry.key}',
      );
    }
    return out;
  }

  static Object? _parseJsonValue(Object? value, String where) {
    if (value == null || value is String || value is bool) return value;
    if (value is int) return value;
    if (value is double) {
      if (!value.isFinite) throw FormatException('$where 含非有限数值');
      return value;
    }
    if (value is List) {
      return [
        for (final (index, item) in value.indexed)
          _parseJsonValue(item, '$where[$index]'),
      ];
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw FormatException('$where 的键必须是字符串');
        }
        out[entry.key as String] = _parseJsonValue(
          entry.value,
          '$where.${entry.key}',
        );
      }
      return out;
    }
    throw FormatException('$where 含不支持的值类型');
  }

  /// 递归按键排序,供导出与 diff 使用。
  static Object? _sortedJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.whereType<String>().toList()..sort();
      return {for (final key in keys) key: _sortedJson(value[key])};
    }
    if (value is List) return [for (final item in value) _sortedJson(item)];
    return value;
  }

  static String _requiredString(Object? value, String where) {
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$where 必须是非空字符串');
    }
    return value;
  }

  static String? _optionalString(Object? value, String where) {
    if (value == null) return null;
    if (value is! String) throw FormatException('$where 必须是字符串');
    return value;
  }

  static int? _optionalInt(Object? value, String where) {
    if (value == null) return null;
    if (value is! int) throw FormatException('$where 必须是整数');
    return value;
  }
}

/// 文件中的一条自定义生图风格(不含库内自增 id)。
class AppConfigImageStyle {
  final String name;
  final String? artist;
  final String? sampler;
  final String? noiseSchedule;
  final int? scale;
  final double? cfg;
  final String? negative;

  const AppConfigImageStyle({
    required this.name,
    this.artist,
    this.sampler,
    this.noiseSchedule,
    this.scale,
    this.cfg,
    this.negative,
  });

  factory AppConfigImageStyle.fromPreset(ImageStylePreset preset) =>
      AppConfigImageStyle(
        name: preset.name,
        artist: preset.artist,
        sampler: preset.sampler,
        noiseSchedule: preset.noiseSchedule,
        scale: preset.scale,
        cfg: preset.cfg,
        negative: preset.negative,
      );

  static AppConfigImageStyle fromJson(Object? raw, int index) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException('image.styles[$index] 必须是对象');
    }
    String? optionalString(String key) {
      final value = raw[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('image.styles[$index].$key 必须是字符串');
      }
      return value;
    }

    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) {
      throw FormatException('image.styles[$index].name 必须是非空字符串');
    }
    final rawScale = raw['scale'];
    if (rawScale != null && rawScale is! int) {
      throw FormatException('image.styles[$index].scale 必须是整数');
    }
    final rawCfg = raw['cfg'];
    final double? cfg;
    if (rawCfg == null) {
      cfg = null;
    } else if (rawCfg is num) {
      cfg = rawCfg.toDouble();
    } else {
      throw FormatException('image.styles[$index].cfg 必须是数值');
    }
    return AppConfigImageStyle(
      name: name,
      artist: optionalString('artist'),
      sampler: optionalString('sampler'),
      noiseSchedule: optionalString('noiseSchedule'),
      scale: rawScale as int?,
      cfg: cfg,
      negative: optionalString('negative'),
    );
  }

  ImageStylePreset toPreset() => ImageStylePreset(
    name: name,
    artist: artist,
    sampler: sampler,
    noiseSchedule: noiseSchedule,
    scale: scale,
    cfg: cfg,
    negative: negative,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'artist': artist,
    'sampler': sampler,
    'noiseSchedule': noiseSchedule,
    'scale': scale,
    'cfg': cfg,
    'negative': negative,
  };
}
