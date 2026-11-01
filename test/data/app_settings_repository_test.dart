// app_settings 单行表的默认值、字段往返与旧功能掩码位兼容。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/models/app_settings.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late AppSettingsRepository repo;

  setUp(() async {
    db = await openTestDb();
    repo = AppSettingsRepository(db);
  });

  // app_settings 是单行表,共享内存库会跨测试泄漏;用完必须关连接。
  tearDown(() => db.db.close());

  test('load returns system default when nothing is saved', () async {
    final s = await repo.load();
    expect(s.themeMode, AppThemeMode.system);
    // 后台agent 按钮默认启用。
    expect(s.backgroundEnabled, isTrue);
    // 默认所有快状态功能全开。
    expect(s.features.anyEnabled, isTrue);
    // bit0(旧技能)/bit2(旧记忆)/bit3(旧面板)为历史保留,全开 = 18。
    expect(s.features.mask, 18);
    // 聊天背景默认关闭。
    expect(s.chatBackgroundEnabled, isFalse);
    // 聊天背景模糊度默认 18。
    expect(s.chatBackgroundBlur, 18.0);
  });

  test('defaults and roundtrips for compact/background turn settings', () async {
    // 未保存过 → 自动压缩默认开启,生图间隔与旧硬编码一致(慢变间隔已随
    // 逐轮记忆维护退役,不再可设)。
    expect((await repo.load()).autoCompactEnabled, isTrue);
    expect((await repo.load()).imageInterval, 1);

    await repo.save(const AppSettings(
      autoCompactEnabled: false,
      imageInterval: 2,
    ));
    final s = await repo.load();
    expect(s.autoCompactEnabled, isFalse); // 关闭自动压缩,须原样往返。
    expect(s.imageInterval, 2);

    await repo.save(const AppSettings(autoCompactEnabled: true));
    expect((await repo.load()).autoCompactEnabled, isTrue);
  });

  test('roundtrips the chat background switch', () async {
    await repo.save(const AppSettings(chatBackgroundEnabled: true));
    expect((await repo.load()).chatBackgroundEnabled, isTrue);
    await repo.save(const AppSettings(themeMode: AppThemeMode.dark, chatBackgroundEnabled: false));
    final s = await repo.load();
    expect(s.chatBackgroundEnabled, isFalse);
    expect(s.themeMode, AppThemeMode.dark);
  });

  test('roundtrips the chat background blur', () async {
    await repo.save(const AppSettings(chatBackgroundBlur: 8));
    expect((await repo.load()).chatBackgroundBlur, 8.0);
    await repo.save(const AppSettings(themeMode: AppThemeMode.dark, chatBackgroundBlur: 26));
    final s = await repo.load();
    expect(s.chatBackgroundBlur, 26.0);
    expect(s.themeMode, AppThemeMode.dark);
  });

  test('roundtrips the variable deletion confirmation mode (default off)', () async {
    expect((await repo.load()).backgroundDeletionConfirm, isFalse);
    await repo.save(const AppSettings(backgroundDeletionConfirm: true));
    expect((await repo.load()).backgroundDeletionConfirm, isTrue);
    await repo.save(const AppSettings(backgroundDeletionConfirm: false));
    expect((await repo.load()).backgroundDeletionConfirm, isFalse);
  });

  test('roundtrips the background feature mask', () async {
    await repo.save(
      const AppSettings(
        features: BackgroundFeatures(variables: false, image: true),
      ),
    );
    final s = await repo.load();
    expect(s.features.variables, isFalse);
    expect(s.features.image, isTrue);

    // 全关 → anyEnabled 为假。
    await repo.save(
      const AppSettings(
        features: BackgroundFeatures(variables: false, image: false),
      ),
    );
    final allOff = await repo.load();
    expect(allOff.features.anyEnabled, isFalse);
  });

  test('feature mask keeps the legacy skill/memory bits reserved but ignored', () async {
    // 先落一行,后续直接改库里的原始掩码。
    await repo.save(const AppSettings());

    // 旧版本(v37-)持久化的掩码 bit0 是"技能"、bit2 是"记忆";2.2 起 bit3
    // (面板)同样退役 —— 读入时忽略,其余位的语义保持不变(31 = 旧全开掩码,
    // 读入后应得全开的 variables/image)。
    await db.db.update('app_settings', {'background_features': 31}, where: 'id = 1');
    final withLegacyBits = await repo.load();
    expect(withLegacyBits.features.variables, isTrue);
    expect(withLegacyBits.features.image, isTrue);

    await db.db.update('app_settings', {'background_features': (1 << 1)}, where: 'id = 1');
    final varsOnly = await repo.load();
    expect(varsOnly.features.variables, isTrue);
    expect(varsOnly.features.image, isFalse);
  });

  test('save then load roundtrips the theme mode', () async {
    await repo.save(const AppSettings(themeMode: AppThemeMode.dark));
    final s = await repo.load();
    expect(s.themeMode, AppThemeMode.dark);
  });

  test('roundtrips the background-agent switch', () async {
    await repo.save(const AppSettings(backgroundEnabled: false));
    expect((await repo.load()).backgroundEnabled, isFalse);
    await repo.save(const AppSettings(themeMode: AppThemeMode.dark, backgroundEnabled: true));
    final s = await repo.load();
    expect(s.backgroundEnabled, isTrue);
    expect(s.themeMode, AppThemeMode.dark);
  });

  test('roundtrips the background agent model selection', () async {
    // 未选 → null(跟随主写)。
    expect((await repo.load()).backgroundModelId, isNull);

    await repo.save(const AppSettings(backgroundModelId: 42));
    expect((await repo.load()).backgroundModelId, 42);
    // 其它字段在保存专用模型时保持默认/既有值不外泄。
    expect((await repo.load()).backgroundEnabled, isTrue);

    // 清空(显式回 null = 跟随主写)。
    await repo.save(const AppSettings(backgroundModelId: null));
    expect((await repo.load()).backgroundModelId, isNull);
  });

  test('roundtrips the background agent reasoning level (default off)', () async {
    // 默认 off:后台请求历史上从不带推理参数,升级/新建库行为不变。
    expect((await repo.load()).backgroundReasoningLevel, ReasoningLevel.off);

    await repo.save(const AppSettings(backgroundReasoningLevel: ReasoningLevel.medium));
    expect((await repo.load()).backgroundReasoningLevel, ReasoningLevel.medium);

    // 与主对话的推理等级互相独立:改后台值不动主对话值,反之亦然。
    await repo.save(const AppSettings(backgroundReasoningLevel: ReasoningLevel.low, reasoningLevel: ReasoningLevel.high));
    final s = await repo.load();
    expect(s.backgroundReasoningLevel, ReasoningLevel.low);
    expect(s.reasoningLevel, ReasoningLevel.high);
  });

  test('save replaces the previous settings row', () async {
    await repo.save(const AppSettings(themeMode: AppThemeMode.dark));
    await repo.save(const AppSettings(themeMode: AppThemeMode.light));
    final s = await repo.load();
    expect(s.themeMode, AppThemeMode.light);
    // 仍然是单行
    final count = (await db.db.query('app_settings')).length;
    expect(count, 1);
  });

  test('roundtrips the dialogue highlight switch (default on)', () async {
    // 未保存过 → 默认开启。
    expect((await repo.load()).dialogueHighlightEnabled, isTrue);
    await repo.save(const AppSettings(dialogueHighlightEnabled: false));
    expect((await repo.load()).dialogueHighlightEnabled, isFalse);
    await repo.save(const AppSettings(dialogueHighlightEnabled: true));
    expect((await repo.load()).dialogueHighlightEnabled, isTrue);
  });

  test('roundtrips the single-turn attachment budget (default 5, 0 = off)', () async {
    // 未保存过 → 默认 5。
    expect((await repo.load()).maxAutoAttachments, 5);

    await repo.save(const AppSettings(maxAutoAttachments: 2));
    expect((await repo.load()).maxAutoAttachments, 2);

    // 0 合法(= 关闭世界书自动附件)。
    await repo.save(const AppSettings(maxAutoAttachments: 0));
    expect((await repo.load()).maxAutoAttachments, 0);

    // 旧库脏值(负数)读入回退默认 5。
    await db.db.update('app_settings', {'max_auto_attachments': -3}, where: 'id = 1');
    expect((await repo.load()).maxAutoAttachments, 5);
  });
}
