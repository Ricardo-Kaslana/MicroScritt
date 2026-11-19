/// 应用级偏好模型:主题、后台维护开关、推理档位与上下文注入限额。
///
/// 对应数据库单行表 `app_settings`;所有字段都有默认值,读取时逐列
/// fail-safe 解析,坏值不得阻断启动。
library;

/// 主题模式:跟随系统 / 强制浅色 / 强制深色。
enum AppThemeMode { system, light, dark }

/// 推理等级(对话输入框的模型选择器里可设)。
/// 会透传到 LLM 请求,openai 后端映射为 `reasoning_effort`,anthropic 为 thinking budget。
enum ReasoningLevel {
  off,
  low,
  medium,
  high;

  static ReasoningLevel fromWire(String s) =>
      ReasoningLevel.values.where((r) => r.name == s).firstOrNull ??
      ReasoningLevel.off;

  /// 面向 UI 的中文标签。
  String get label => switch (this) {
    ReasoningLevel.off => '关闭',
    ReasoningLevel.low => '低',
    ReasoningLevel.medium => '中',
    ReasoningLevel.high => '高',
  };
}

/// 后台维护运行模式:legacy 单发(默认,升级零行为变化)/ agentic 多步
/// 工具循环 / hybrid 单发 + 周期审计。坏值 fail-safe 回落 legacy。
/// 设置列与 UI 选择器在 P3 接入;本期 orchestrator 按参数分流。
enum BackgroundMode {
  legacy,
  agentic,
  hybrid;

  static BackgroundMode fromWire(String s) =>
      BackgroundMode.values.where((m) => m.name == s).firstOrNull ??
      BackgroundMode.legacy;

  /// 面向 UI 的英文裸名(不带解释)。
  String get label => switch (this) {
    BackgroundMode.legacy => 'Legacy',
    BackgroundMode.agentic => 'Agentic',
    BackgroundMode.hybrid => 'Hybrid',
  };

  /// 悬停提示用的白话说明:直接描述维护行为,避免缩写 jargon。
  String get hint => switch (this) {
    BackgroundMode.legacy => '每轮一次生成,兼容性最好',
    BackgroundMode.agentic => '多步工具调用,可回查历史',
    BackgroundMode.hybrid => '常规维护 + 定期审计变量板',
  };
}

/// 后台agent 的子功能选择:开启哪些被后台引擎自动维护。
/// 各字段独立开关,用于"启用后台agent 时进一步选择要维护的功能"。
///
/// 后台agent 只维护**快状态**(变量/生图):记忆为用户主动维护(手动编辑 /
/// 主动发起全量生成,见状态面板);生图的行为规范改由会话级"生图指导"承载
/// (与记忆分离,见 image_guides 表)。HTML 状态面板功能已于 2.2 移除。
class BackgroundFeatures {
  final bool variables;
  final bool image;

  const BackgroundFeatures({this.variables = true, this.image = true});

  /// 任一功能开启就算"有可维护内容";全关等价于关闭后台agent。
  bool get anyEnabled => variables || image;

  /// 位掩码编码,用于持久化(每个功能一个 bit)。
  /// bit0 为历史保留(旧「技能」位,v37 起写入恒为 0、读入时忽略),
  /// bit2 为历史保留(旧「记忆」位;记忆已改为用户主动维护,写入恒为 0、
  /// 读入时忽略),bit3 为历史保留(旧「面板」位,2.2 起桌面面板功能移除,
  /// 写入恒为 0、读入时忽略);variables=1<<1, image=1<<4;全开=18。
  /// (旧库持久化的 31 含 bit0/bit2/bit3,读入时这些位被忽略,语义不受影响。)
  int get mask => (variables ? 1 << 1 : 0) | (image ? 1 << 4 : 0);

  /// 读入旧库位掩码:忽略已退役的 bit0(技能)/bit2(记忆)/bit3(面板)。
  static BackgroundFeatures fromMask(int? raw) {
    final m = raw ?? 31;
    return BackgroundFeatures(
      variables: (m & (1 << 1)) != 0,
      image: (m & (1 << 4)) != 0,
    );
  }

  BackgroundFeatures copyWith({bool? variables, bool? image}) =>
      BackgroundFeatures(
        variables: variables ?? this.variables,
        image: image ?? this.image,
      );

  BackgroundFeatures toggle(String name) => switch (name) {
    'variables' => copyWith(variables: !variables),
    'image' => copyWith(image: !image),
    _ => this,
  };
}

/// 应用级偏好的不可变快照;写入方通过 [copyWith] 生成新实例。
///
/// `schema v22` 起后台模型、`v48` 起后台推理档位均可独立于主写配置;
/// 读取旧行时缺失列按构造默认值处理。
class AppSettings {
  /// 主题模式;null 行或未知值由仓库回落到 [AppThemeMode.system]。
  final AppThemeMode themeMode;

  /// 后台agent(BackgroundEngine/Orchestrator 的每轮状态维护)是否启用。
  /// 关闭后对话仍正常,但不再自动维护变量/生图(记忆由用户主动维护,
  /// 不经此开关)。
  final bool backgroundEnabled;

  /// 后台agent 启用时,具体维护哪些功能(变量/生图)。
  final BackgroundFeatures features;

  /// 后台agent 专用模型(对应 llm_models 表的整型 id);null 表示跟随主写引擎当前模型。
  /// 持久化于 app_settings.background_model_id(schema v22)。
  /// 选中后后台状态维护走该模型,与主写模型解耦(可分别挑更廉价或更强力的模型)。
  final int? backgroundModelId;

  /// 后台agent 请求的推理强度(schema v48)。独立于主对话的 [reasoningLevel]:
  /// 后台维护是结构化 JSON 产出任务,通常不需要(甚至不适合)开高推理 ——
  /// 与专用模型一样按需单独调。默认 off,与历史行为一致(后台请求从不带推理参数)。
  final ReasoningLevel backgroundReasoningLevel;

  /// 后台维护运行模式(schema v71):legacy 单发 / agentic 多步工具循环 /
  /// hybrid 单发 + 周期审计(审计 P4 接入,本期按 legacy 跑)。默认 legacy,
  /// 升级零行为变化;脏值读入回落 legacy。
  final BackgroundMode backgroundMode;

  /// 角色卡是否进入后台agent 上下文锚定段(默认开,保持历史行为)。
  /// 关闭后快状态轮不再注入 `<character>` 段。
  final bool backgroundCharacterAnchor;

  /// 会话记忆是否进入后台agent 上下文锚定段(默认开,保持历史行为)。
  /// 关闭后快状态轮不读库、不注入 `<memory>` 段,进一步压缩每轮请求体积。
  final bool backgroundMemoryAnchor;

  /// 后台建议删除变量时是否先进入待确认列表(默认关 = 自动删除可恢复)。
  /// 开启后 `removeVariables` 只生成 `variable_deletion_proposals`,由用户在
  /// 状态面板确认后才移入回收站。
  final bool backgroundDeletionConfirm;

  /// 当前 LLM 推理等级(对话输入框的模型选择器里设置)。
  final ReasoningLevel reasoningLevel;

  /// 聊天背景总开关(默认关闭)。开启后聊天页显示角色卡专属背景图;
  /// 未设置背景图时回退角色头像。pure 显示层,不进上下文。
  final bool chatBackgroundEnabled;

  /// 聊天背景模糊度(0–32,默认 18,与 v18 硬编码值一致)。0 = 不模糊。
  final double chatBackgroundBlur;

  /// 内置对话高亮(`“…”`/`「…」`/`"…"` 台词斜体+强调色)开关(默认开启)。
  /// 这是渲染管线内建行为而非正则脚本,故单独落库;纯正则脚本页入口切换。
  final bool dialogueHighlightEnabled;

  /// 上下文自动压缩总开关(默认开启)。
  /// 开启后自动压缩按**上下文窗口占用量**触发(回复落库后达到
  /// [autoCompactThreshold] 自动摘要、发送前超过强制线先压再发、每次压回
  /// ≈20% 目标挡);关闭后只剩手动 /compact 与发送前机械截断兜底。
  final bool autoCompactEnabled;

  /// 自动压缩触发线(窗口占用率,默认 0.60)。回复落库后的占用率估算达到
  /// 该值即触发一次自动摘要压缩;发送前的强制线取
  /// `max(0.80, 触发线 + 0.05)`,保证硬挡总比软挡晚一步。
  ///
  /// 可调范围 [minAutoCompactThreshold]–[maxAutoCompactThreshold]。持久化于
  /// `app_settings.auto_compact_threshold`(schema v68);脏值/越界读入回落默认。
  final double autoCompactThreshold;

  /// 自动压缩触发线的可选下限。
  static const double minAutoCompactThreshold = 0.30;

  /// 自动压缩触发线的可选上限(硬挡仍留出 5 个百分点的缓冲)。
  static const double maxAutoCompactThreshold = 0.90;

  /// 自动压缩触发线默认值(与历史硬编码软挡一致)。
  static const double defaultAutoCompactThreshold = 0.60;

  /// 把触发线归一化到百分比精度(两位小数);越界返回 null。
  ///
  /// Slider 按 divisions 计算时会产生 `0.9000000000000001` 这类浮点尾差,
  /// 既可能让 `Slider` 的 value 超出 max 断言,也可能把合法值误判为越界。
  static double? normalizeAutoCompactThreshold(double value) {
    final rounded = (value * 100).round() / 100;
    if (rounded < minAutoCompactThreshold ||
        rounded > maxAutoCompactThreshold) {
      return null;
    }
    return rounded;
  }

  /// 同 [normalizeAutoCompactThreshold],但越界时夹到可选范围(供 UI 使用)。
  static double clampAutoCompactThreshold(double value) =>
      ((value * 100).round() / 100)
          .clamp(minAutoCompactThreshold, maxAutoCompactThreshold)
          .toDouble();

  /// 单轮自动附件注入上限:每次发送最多新注入多少条**占名额**的自动附件
  /// (现为世界书触发条目),超出按命中顺序丢弃尾部。0 = 关闭自动附件注入。
  /// @技能(用户主动调用)与系统通知(压缩/记忆差异)豁免名额。
  /// 持久化于 app_settings.max_auto_attachments(schema v41)。
  final int maxAutoAttachments;

  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.backgroundEnabled = true,
    this.features = const BackgroundFeatures(),
    this.reasoningLevel = ReasoningLevel.off,
    this.chatBackgroundEnabled = false,
    this.chatBackgroundBlur = 18.0,
    this.dialogueHighlightEnabled = true,
    this.backgroundModelId,
    this.backgroundReasoningLevel = ReasoningLevel.off,
    this.backgroundMode = BackgroundMode.legacy,
    this.backgroundCharacterAnchor = true,
    this.backgroundMemoryAnchor = true,
    this.backgroundDeletionConfirm = false,
    this.autoCompactEnabled = true,
    this.autoCompactThreshold = defaultAutoCompactThreshold,
    this.maxAutoAttachments = 5,
  });

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? backgroundEnabled,
    BackgroundFeatures? features,
    ReasoningLevel? reasoningLevel,
    bool? chatBackgroundEnabled,
    double? chatBackgroundBlur,
    bool? dialogueHighlightEnabled,
    bool? autoCompactEnabled,
    double? autoCompactThreshold,
    int? maxAutoAttachments,
    ReasoningLevel? backgroundReasoningLevel,
    BackgroundMode? backgroundMode,
    bool? backgroundCharacterAnchor,
    bool? backgroundMemoryAnchor,
    bool? backgroundDeletionConfirm,
    // 用哨兵区分「未传(保留旧值)」与「显式清空(null = 跟随主写)」。
    Object? backgroundModelId = _unset,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
    features: features ?? this.features,
    reasoningLevel: reasoningLevel ?? this.reasoningLevel,
    chatBackgroundEnabled: chatBackgroundEnabled ?? this.chatBackgroundEnabled,
    chatBackgroundBlur: chatBackgroundBlur ?? this.chatBackgroundBlur,
    dialogueHighlightEnabled:
        dialogueHighlightEnabled ?? this.dialogueHighlightEnabled,
    autoCompactEnabled: autoCompactEnabled ?? this.autoCompactEnabled,
    autoCompactThreshold: autoCompactThreshold ?? this.autoCompactThreshold,
    maxAutoAttachments: maxAutoAttachments ?? this.maxAutoAttachments,
    backgroundReasoningLevel:
        backgroundReasoningLevel ?? this.backgroundReasoningLevel,
    backgroundMode: backgroundMode ?? this.backgroundMode,
    backgroundCharacterAnchor:
        backgroundCharacterAnchor ?? this.backgroundCharacterAnchor,
    backgroundMemoryAnchor:
        backgroundMemoryAnchor ?? this.backgroundMemoryAnchor,
    backgroundDeletionConfirm:
        backgroundDeletionConfirm ?? this.backgroundDeletionConfirm,
    backgroundModelId: identical(backgroundModelId, _unset)
        ? this.backgroundModelId
        : backgroundModelId as int?,
  );

  static const Object _unset = Object();
}
