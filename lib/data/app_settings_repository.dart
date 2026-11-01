import 'package:sqflite/sqflite.dart';
import '../models/app_settings.dart';
import 'database.dart';

/// 应用级偏好(单行表,id 恒为 1)。未保存过时 load 返回系统默认值。
class AppSettingsRepository {
  final AppDatabase db;
  AppSettingsRepository(this.db);

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
      // 缺列(旧库未迁移)回退 standard,与升级前行为一致。
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
      // 缺列(旧库未迁移)回退默认开,与升级前行为一致。
      backgroundCharacterAnchor: charAnchorRaw is int
          ? charAnchorRaw != 0
          : true,
      backgroundMemoryAnchor: memAnchorRaw is int ? memAnchorRaw != 0 : true,
      backgroundDeletionConfirm: deletionConfirmRaw is int
          ? deletionConfirmRaw != 0
          : false,
    );
  }

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
      // 旧列 auto_compact_chunk(v34)与 slow_state_interval(v33)随对应功能
      // 退役:不再写入,列定义带 DEFAULT,插入缺省即回填历史默认值,无需破坏性迁移。
      'auto_compact_enabled': s.autoCompactEnabled ? 1 : 0,
      'image_interval': s.imageInterval,
      'max_auto_attachments': s.maxAutoAttachments,
      'background_character_anchor': s.backgroundCharacterAnchor ? 1 : 0,
      'background_memory_anchor': s.backgroundMemoryAnchor ? 1 : 0,
      'background_deletion_confirm': s.backgroundDeletionConfirm ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
