/// 文本配置文件 `microscritt-config.json`(用户名 + LLM provider 目录)的读写。
///
/// 文件与数据库同目录,启动时以文件为准应用用户名与 provider,UI 修改后
/// 回写;坏文件只打日志、不改库。文件含明文 API Key,不得随仓库分发。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/data_root.dart';
import '../models/endpoint_compat.dart';
import '../models/llm_provider.dart';
import 'app_settings_repository.dart';
import 'database.dart';
import 'llm_provider_repository.dart';
import 'user_repository.dart';

/// 文本配置文件:用户名 + 全部 LLM provider(含模型目录),固定存放在
/// 数据库同目录(桌面端 `~/.microscritt`,移动端应用私有 Documents),
/// 启动时读取应用、设置修改后回写。
///
/// 文件是**启动时权威**:外部编辑后需重启生效;运行期以 UI 写回的内容为准。
/// apiKey 以明文保存(与 SQLite 中的现状一致),文档与设置页均提示勿公开分享。
class AppConfigFile {
  static const String fileName = 'microscritt-config.json';
  static const int formatVersion = 1;

  final String path;
  const AppConfigFile(this.path);

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
    final snapshot = AppConfigSnapshot(
      userName: user,
      providers: [for (final provider in providers) AppConfigProvider.fromConfig(provider)],
    );
    return const JsonEncoder.withIndent('  ').convert({
      'version': formatVersion,
      'user': {'name': snapshot.userName ?? ''},
      'llm': {'providers': [for (final provider in snapshot.providers!) provider.toJson()]},
    });
  }

  /// 原子写:先写同目录临时文件再替换,避免半截文件被下次启动读走。
  Future<void> writeSnapshot(AppDatabase db) async {
    final text = await snapshotText(db);
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(text, flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(path);
  }

  /// 首次启动创建样例文件;已存在(含用户手改过的坏文件)一律不动。
  Future<void> writeIfMissing(AppDatabase db) async {
    if (await File(path).exists()) return;
    await writeSnapshot(db);
  }

  /// 启动入口:文件存在则解析并应用。解析失败只打日志并保留原文件;
  /// 应用中途失败同样只打日志,已写入的节不回滚(按节顺序提交)。
  Future<AppConfigApplyResult?> applyIfPresent(AppDatabase db) async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      return await applyText(db, await file.readAsString());
    } catch (e) {
      debugPrint('配置文件读取/应用失败(已忽略):$e');
      return null;
    }
  }

  /// 手动导入:严格解析,坏文件抛 [FormatException](启动路径会自行吞掉)。
  static Future<AppConfigApplyResult> applyText(AppDatabase db, String text) async {
    final AppConfigSnapshot snapshot;
    try {
      snapshot = AppConfigSnapshot.fromJson(jsonDecode(text));
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('不是有效的配置文件:$e');
    }
    return _apply(db, snapshot);
  }

  // 应用顺序:用户名 → provider 目录 → 后台模型引用。provider 行按逻辑 id
  // 匹配更新、缺失的删除,因此 `background_model_id` 需要最后按
  // (providerId, modelId) 找回新行 id。
  static Future<AppConfigApplyResult> _apply(AppDatabase db, AppConfigSnapshot snapshot) async {
    final users = UserRepository(db);
    var userChanged = false;
    if (snapshot.userName != null && snapshot.userName != await users.name()) {
      await users.updateName(snapshot.userName!);
      userChanged = true;
    }

    var llmChanged = false;
    var providerCount = 0;
    final providers = snapshot.providers;
    if (providers != null) {
      providerCount = providers.length;
      final repo = LlmProviderRepository(db);
      final existing = await repo.all();
      final settingsRepo = AppSettingsRepository(db);
      final settings = await settingsRepo.load();

      // 后台专用模型按 llm_models.id 引用;替换 provider 前先记下它的逻辑身份,
      // 应用后按 (providerId, modelId) 找回新 id,找不到则回到"跟随主写模型"。
      String? bgProviderId;
      String? bgModelId;
      if (settings.backgroundModelId != null) {
        for (final provider in existing) {
          for (final model in provider.models) {
            if (model.id == settings.backgroundModelId) {
              bgProviderId = provider.providerId;
              bgModelId = model.modelId;
            }
          }
        }
      }

      final currentJson = jsonEncode([
        for (final provider in existing) AppConfigProvider.fromConfig(provider).toJson(),
      ]);
      final incomingJson = jsonEncode([for (final provider in providers) provider.toJson()]);
      if (currentJson != incomingJson) {
        llmChanged = true;
        final byLogicalId = {for (final provider in existing) provider.providerId: provider};
        for (final incoming in providers) {
          final match = byLogicalId[incoming.providerId];
          final modelIds = {for (final model in match?.models ?? const <LlmModelEntry>[]) model.modelId: model.id};
          await repo.saveProvider(
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
              compat: incoming.compat,
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
        final keep = {for (final provider in providers) provider.providerId};
        for (final old in existing) {
          if (!keep.contains(old.providerId)) await repo.deleteProvider(old.id);
        }
      }

      if (settings.backgroundModelId != null) {
        int? newId;
        if (bgProviderId != null && bgModelId != null) {
          for (final provider in await repo.all()) {
            if (provider.providerId != bgProviderId) continue;
            for (final model in provider.models) {
              if (model.modelId == bgModelId) newId = model.id;
            }
          }
        }
        if (newId != settings.backgroundModelId) {
          await settingsRepo.save(settings.copyWith(backgroundModelId: newId));
        }
      }
    }

    return AppConfigApplyResult(
      userChanged: userChanged,
      llmChanged: llmChanged,
      providerCount: providerCount,
    );
  }
}

/// 配置文件的应用结果:哪些节发生了变化、文件里提供了几个 provider。
class AppConfigApplyResult {
  final bool userChanged;
  final bool llmChanged;
  final int providerCount;

  const AppConfigApplyResult({
    required this.userChanged,
    required this.llmChanged,
    required this.providerCount,
  });

  bool get changed => userChanged || llmChanged;
}

/// 配置文件内存表示。null 字段表示"文件未提供该节",与应用语义一致。
class AppConfigSnapshot {
  final String? userName;
  final List<AppConfigProvider>? providers;

  const AppConfigSnapshot({this.userName, this.providers});

  /// 严格解析:结构不合法抛 [FormatException]。启动路径会自行吞掉并保留
  /// 原文件,手动导入则向用户报错。
  static AppConfigSnapshot fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('不是有效的配置文件(缺少顶层对象)');
    }
    final version = raw['version'];
    if (version is int && version > AppConfigFile.formatVersion) {
      throw const FormatException('配置文件版本过新,请升级应用');
    }
    String? userName;
    final user = raw['user'];
    if (user != null) {
      if (user is! Map<String, dynamic>) throw const FormatException('user 节必须是对象');
      final name = user['name'];
      if (name != null && name is! String) throw const FormatException('user.name 必须是字符串');
      userName = name as String?;
    }
    List<AppConfigProvider>? providers;
    final llm = raw['llm'];
    if (llm != null) {
      if (llm is! Map<String, dynamic>) throw const FormatException('llm 节必须是对象');
      final list = llm['providers'];
      if (list != null) {
        if (list is! List) throw const FormatException('llm.providers 必须是数组');
        providers = [
          for (final (i, item) in list.indexed) AppConfigProvider.fromJson(item, i),
        ];
        // 与库快照(按 position 排序)同序,避免文件顺序不同导致每次启动都判定"有变化"。
        providers.sort((a, b) => a.position.compareTo(b.position));
        providers = _normalizeActives(providers);
      }
    }
    if (userName == null && providers == null) {
      throw const FormatException('配置文件没有可应用的配置(user / llm 均缺失)');
    }
    return AppConfigSnapshot(userName: userName, providers: providers);
  }

  /// 同一时刻只保留一个活跃 provider 与其下一个活跃模型,与运行链路一致。
  static List<AppConfigProvider> _normalizeActives(List<AppConfigProvider> providers) {
    final out = <AppConfigProvider>[];
    var providerTaken = false;
    for (final provider in providers) {
      if (!provider.isActive || providerTaken) {
        out.add(provider.copyWith(
          isActive: false,
          models: [for (final model in provider.models) model.copyWith(isActive: false)],
        ));
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
  final EndpointCompat compat;
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
    required this.compat,
    required this.models,
  });

  factory AppConfigProvider.fromConfig(LlmProviderConfig config) => AppConfigProvider(
    providerId: config.providerId,
    displayName: config.displayName,
    baseUrl: config.baseUrl,
    protocol: config.protocol,
    apiKey: config.apiKey,
    isActive: config.isActive,
    position: config.position,
    extraHeaders: Map<String, String>.from(config.extraHeaders),
    modernParams: config.modernParams,
    compat: config.compat,
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
    if (raw is! Map<String, dynamic>) throw FormatException('llm.providers[$index] 必须是对象');
    String text(String key, {bool required = true}) {
      final value = raw[key];
      if (value is String && (!required || value.trim().isNotEmpty)) return value;
      if (!required && value == null) return '';
      throw FormatException('provider.$key 必须是非空字符串');
    }

    final rawHeaders = raw['extraHeaders'];
    final headers = <String, String>{};
    if (rawHeaders != null) {
      if (rawHeaders is! Map) throw const FormatException('provider.extraHeaders 必须是对象');
      for (final entry in rawHeaders.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }    final rawCompat = raw['compat'];
    var compat = EndpointCompat.standard;
    if (rawCompat is Map) {
      compat = EndpointCompat(
        replyViaTool: rawCompat['replyViaTool'] == true,
        noncePrefix: rawCompat['noncePrefix'] == true,
      );
    }
    final rawModels = raw['models'];
    final models = <AppConfigModel>[];
    if (rawModels != null) {
      if (rawModels is! List) throw const FormatException('provider.models 必须是数组');
      for (final (i, model) in rawModels.indexed) {
        models.add(AppConfigModel.fromJson(model, i));
      }
    }
    models.sort((a, b) => a.position.compareTo(b.position));
    return AppConfigProvider(
      providerId: text('providerId'),
      displayName: text('displayName'),
      baseUrl: text('baseUrl'),
      protocol: LlmProtocol.fromWire(raw['protocol'] is String ? raw['protocol'] as String : ''),
      apiKey: raw['apiKey'] is String ? raw['apiKey'] as String : '',
      isActive: raw['isActive'] == true,
      position: raw['position'] is int ? raw['position'] as int : index,
      // 与落库口径一致(键小写/去空白),保证"库快照 vs 文件快照"的可比性。
      extraHeaders: LlmProviderConfig.normalizeExtraHeaders(headers),
      modernParams: raw['modernParams'] == true,
      compat: compat,
      models: models,
    );
  }

  AppConfigProvider copyWith({bool? isActive, List<AppConfigModel>? models}) => AppConfigProvider(
    providerId: providerId,
    displayName: displayName,
    baseUrl: baseUrl,
    protocol: protocol,
    apiKey: apiKey,
    isActive: isActive ?? this.isActive,
    position: position,
    extraHeaders: extraHeaders,
    modernParams: modernParams,
    compat: compat,
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
    'extraHeaders': {for (final key in extraHeaders.keys.toList()..sort()) key: extraHeaders[key]},
    'modernParams': modernParams,
    'compat': {
      'replyViaTool': compat.replyViaTool,
      'noncePrefix': compat.noncePrefix,
    },
    'models': [for (final model in models) model.toJson()],
  };
}

/// 文件中的一个模型条目;`modelId` 是逻辑身份,`position` 决定下拉顺序。
class AppConfigModel {
  final String modelId;
  final String displayName;
  final int contextCapacity;
  final int? maxOutput;
  final double? temperature;
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
    if (raw is! Map<String, dynamic>) throw FormatException('models[$index] 必须是对象');
    final modelId = raw['modelId'];
    if (modelId is! String || modelId.trim().isEmpty) {
      throw const FormatException('model.modelId 必须是非空字符串');
    }
    return AppConfigModel(
      modelId: modelId,
      displayName: raw['displayName'] is String && (raw['displayName'] as String).trim().isNotEmpty
          ? raw['displayName'] as String
          : modelId,
      contextCapacity: raw['contextCapacity'] is int ? raw['contextCapacity'] as int : 0,
      maxOutput: raw['maxOutput'] is int ? raw['maxOutput'] as int : null,
      temperature: raw['temperature'] is num ? (raw['temperature'] as num).toDouble() : null,
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
