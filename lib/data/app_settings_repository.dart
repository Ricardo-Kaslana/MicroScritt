/// 应用级偏好(`app_settings` 单行表)的读写。
library;

import 'package:sqflite/sqflite.dart';
import '../models/app_settings.dart';
import 'database.dart';

/// 应用级偏好(单行表,id 恒为 1)。未保存过时 [load] 返回系统默认值。
class AppSettingsRepository {
  final AppDatabase db;
  AppSettingsRepository(this.db);

  /// 读取偏好并逐列做类型校验;未保存过或个别列缺失/损坏时回落默认值,
  /// 不允许脏数据阻断启动水合。
  Future<AppSettings> load() async {
    final rows = await db.db.query('app_settings', where: 'id = 1');
    if (rows.isEmpty) return const AppSettings();
    final raw = rows.first['theme_mode'] as String? ?? '';
    final mode =
        AppThemeMode.values.where((m) => m.name == raw).firstOrNull ??
        AppThemeMode.system;
    final bgRaw = rows.first['background_enabled'];
    final enabled = bgRaw is int ? bgRaw != 0 : true;
    final featureRaw = rows.first['background_features'];
    final reasoningRaw = rows.first['reasoning_level'];
    final chatBgRaw = rows.first['chat_background_enabled'];
    final chatBgBlurRaw = rows.first['chat_background_blur'];
    final dialogueRaw = rows.first['dialogue_highlight_enabled'];
    final bgModelRaw = rows.first['background_model_id'];
    final bgReasoningRaw = rows.first['background_reasoning_level'];
    final bgTierRaw = rows.first['background_output_tier'];
    final compactEnabledRaw = rows.first['auto_compact_enabled'];
    final imageIntervalRaw = rows.first['image_interval'];
    final maxAutoRaw = rows.first['max_auto_attachments'];
    final charAnchorRaw = rows.first['background_character_anchor'];
    final memAnchorRaw = rows.first['background_memory_anchor'];
    final deletionConfirmRaw = rows.first['background_deletion_confirm'];
    return AppSettings(
      themeMode: mode,
      backgroundEnabled: enabled,
      features: BackgroundFeatures.fromMask(
        featureRaw is int ? featureRaw : null,
      ),
      reasoningLevel: reasoningRaw is String
          ? ReasoningLevel.fromWire(reasoningRaw)
          : ReasoningLevel.off,
      chatBackgroundEnabled: chatBgRaw is int ? chatBgRaw != 0 : false,
      chatBackgroundBlur: chatBgBlurRaw is num
          ? chatBgBlurRaw.toDouble()
          : 18.0,
      dialogueHighlightEnabled: dialogueRaw is int ? dialogueRaw != 0 : true,
      backgroundModelId: bgModelRaw is int ? bgModelRaw : null,
      backgroundReasoningLevel: bgReasoningRaw is String
          ? ReasoningLevel.fromWire(bgReasoningRaw)
          : ReasoningLevel.off,
      // 脏值/缺失回落 standard,与列默认一致。
      backgroundOutputTier: bgTierRaw is String
          ? BackgroundOutputTier.fromWire(bgTierRaw)
          : BackgroundOutputTier.standard,
      autoCompactEnabled: compactEnabledRaw is int
          ? compactEnabledRaw != 0
          : true,
      imageInterval: imageIntervalRaw is int && imageIntervalRaw > 0
          ? imageIntervalRaw
          : 1,
      maxAutoAttachments: maxAutoRaw is int && maxAutoRaw >= 0 ? maxAutoRaw : 5,
      // 脏值/缺失回落默认开,与列默认一致。
      backgroundCharacterAnchor: charAnchorRaw is int
          ? charAnchorRaw != 0
          : true,
      backgroundMemoryAnchor: memAnchorRaw is int ? memAnchorRaw != 0 : true,
      backgroundDeletionConfirm: deletionConfirmRaw is int
          ? deletionConfirmRaw != 0
          : false,
    );
  }

  /// 整行 upsert(id 恒为 1)。
  Future<void> save(AppSettings s) async {
    await db.db.insert('app_settings', {
      'id': 1,
      'theme_mode': s.themeMode.name,
      'background_enabled': s.backgroundEnabled ? 1 : 0,
      'background_features': s.features.mask,
      'reasoning_level': s.reasoningLevel.name,
      'chat_background_enabled': s.chatBackgroundEnabled ? 1 : 0,
      'chat_background_blur': s.chatBackgroundBlur,
      'dialogue_highlight_enabled': s.dialogueHighlightEnabled ? 1 : 0,
      'background_model_id': s.backgroundModelId,
      'background_reasoning_level': s.backgroundReasoningLevel.name,
      'background_output_tier': s.backgroundOutputTier.name,
      // `auto_compact_chunk` / `slow_state_interval` 两列随对应功能退役:
      // 基线 DDL 保留(带 DEFAULT)但不再写入,缺省插入即回填历史默认值,
      // 无需为删列重建数据库。
      'auto_compact_enabled': s.autoCompactEnabled ? 1 : 0,
      'image_interval': s.imageInterval,
      'max_auto_attachments': s.maxAutoAttachments,
      'background_character_anchor': s.backgroundCharacterAnchor ? 1 : 0,
      'background_memory_anchor': s.backgroundMemoryAnchor ? 1 : 0,
      'background_deletion_confirm': s.backgroundDeletionConfirm ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
