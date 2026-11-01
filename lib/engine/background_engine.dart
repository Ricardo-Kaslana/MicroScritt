import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import '../backend/llm_backend.dart';
import '../models/app_settings.dart';
import '../models/character_card.dart';
import '../models/chat_message.dart';
import '../models/image_prompt_guide.dart';
import '../models/message.dart';
import '../models/token_usage.dart';
import '../models/worldbook_entry.dart';

/// 后台引擎一轮的结果:成功带出 [BackgroundResult];失败带细分原因
/// (C4:不再一律 null,让编排器/控制器区分"调用出错"与"解析失败")。
sealed class BackgroundRunResult {
  const BackgroundRunResult();
}

class BackgroundRunSuccess extends BackgroundRunResult {
  final BackgroundResult result;
  const BackgroundRunSuccess(this.result);
}

/// 后台一轮失败的细分原因。
enum BackgroundFailureReason {
  /// 用户中断(shouldCancel 命中):轮次被放弃,不落库。
  cancelled,

  /// 后端流报错/抛异常:网络、鉴权、限流等。
  backendError,

  /// 流正常结束但返回的文本解析不出有效 JSON 对象。
  parseFailure,
}

class BackgroundRunFailure extends BackgroundRunResult {
  final BackgroundFailureReason reason;

  /// 失败诊断摘要(已截断/压成单行):后端错误消息,或解析失败时原始响应的
  /// 开头片段("模型未返回任何内容" / "响应片段:…")。仅用于状态面板文案,
  /// 帮用户区分"网关报错 / 空响应 / 输出畸形";null 表示无可披露信息。
  final String? detail;
  const BackgroundRunFailure(this.reason, {this.detail});
}

class BackgroundResult {
  final Map<String, String> variableUpdates;

  /// LLM 显式要求删除的既有键(仅 `removeVariables`;绝不从 updates 的缺省键
  /// 推断删除)。是否真正执行由仓库按权限/上限再次裁决。
  final List<String> variableRemovals;
  final String? imagePrompt;

  /// 一次多张(「每次生图数量」>1)时,后台 LLM 产出的 N 个**同场景不同**
  /// 画面描述(景别/视角/构图/表情/动作/氛围各异)。为 null 时回退用
  /// [imagePrompt] 单条;两者皆空则本轮不生成。
  final List<String>? imagePrompts;

  /// 后台 LLM 调用的 token 用量,与主写引擎分开记账(spec §6)。
  final TokenUsage usage;

  /// 记忆初始化/重生成的产出(CW 批起记忆不再逐轮维护,只经
  /// [BackgroundEngine.runMemoryInit]/[BackgroundEngine.runMemoryRegenerate]
  /// 这两条主动路径产出,快状态轮恒为 null)。
  final String? memoryUpdate;

  /// 生图指导初始化([BackgroundEngine.runImageGuideInit])的产出;
  /// 快状态轮恒为 null。
  final String? imageGuide;

  /// 严格模式由编排器在落库后填充:本次只生成待确认提案,未真正删除的键。
  final List<String> variableRemovalProposals;

  const BackgroundResult({
    this.variableUpdates = const {},
    this.variableRemovals = const [],
    this.imagePrompt,
    this.imagePrompts,
    this.usage = const TokenUsage(),
    this.memoryUpdate,
    this.imageGuide,
    this.variableRemovalProposals = const [],
  });
}

/// `/rerun` 上下文:null = 普通后台维护;非 null 即告知后台这是用户触发的
/// 重跑(与普通增量维护区分),可携带用户的修改方向。
class RerunContext {
  /// 用户指定的修改方向(调用方 trim 后传入;空串按没有方向处理)。
  final String? direction;

  /// 上一轮落库的图片描述:仅供重跑修订参考,可能为空,也可能因人工删图/
  /// 改描述而过期 —— 提示词明确它只是上一轮输出基线,不是会话事实。
  final List<String> previousImagePrompts;

  const RerunContext({
    this.direction,
    this.previousImagePrompts = const [],
  });
}

/// 后台提示词的分段形态:稳定前缀(任务契约 + image 轮锚定段)在同一会话/功能
/// 组合下逐轮字节一致,可变尾部(重跑说明/转录/变量)每轮变化。image 轮把稳定
/// 段作为 Anthropic 缓存断点,变量-only 轮整串发送、不请求缓存。
class _BackgroundPrompt {
  final String stable;
  final String variable;
  const _BackgroundPrompt({required this.stable, required this.variable});

  String get combined => variable.isEmpty ? stable : '$stable\n\n$variable';
}

/// 后台引擎:消费结构化上下文(`<tag>` 标签分段:任务说明 + 角色卡/记忆/世界书
/// 锚定段 + 最新转录 + 变量,与主写引擎 ContextAssembler 同构),调用一次
/// LLM,把返回的 JSON 解析为状态更新。任何错误/解析失败都返回失败原因
/// (编排器据此区分跳过与出错)。
///
/// 后台只维护**快状态**:变量/生图。记忆与生图指导不逐轮改写 ——
/// 记忆由用户主动维护([runMemoryInit]/[runMemoryRegenerate]),生图指导是
/// 只读输入;二者在快状态轮以**只读锚定段**注入(仅 image 开启时,
/// 各带截断上限),让生图贴合当前剧情。
class BackgroundEngine {
  final LlmBackend backend;
  BackgroundEngine(this.backend);

  /// 后台维护是结构化 JSON 输出:压低温度提高确定性,限制输出上限防跑飞。
  static const double maxTemperature = 0.5;

  /// 快状态轮(变量/image)首试输出上限的 standard 档基准:结构化 JSON
  /// 任务防跑飞。其他档位按 [outputCapFor] 缩放。
  static const int maxOutputTokens = 2048;

  /// memory 主动轮(初始化/全量重生成)首试输出上限的 standard 档基准:产出的
  /// 是**全量**记忆文本(输入参考截断上限 [maxMemoryChars] ≈ 4000 字符,中文
  /// 内容约 1 字符/token),2048 容易在 JSON 未闭合处截断落进"解析失败"。
  /// 放宽到 4096 给足余量;主动轮由用户显式触发,成本可控。快状态轮维持
  /// [maxOutputTokens] 防跑飞。其他档位按 [outputCapFor] 缩放。
  static const int maxOutputTokensMemory = 4096;

  /// 档位 → 首试请求的输出上限。快状态轮与 memory 主动轮各按档位取值:
  /// compact 半量(省成本)/ standard 基准(历史硬编码行为)/ relaxed 倍量
  /// (长记忆、重推理场景)/ unlimited 不发送 max_tokens(与重试同待遇,
  /// 推理模型把预算烧在不可见思考上时空响应的根治选项,由 provider 兜底)。
  /// 返回值只约束**首试**;重试恒为 null(完全放开)。
  static int? outputCapFor(BackgroundOutputTier tier, {required bool memory}) =>
      switch (tier) {
        BackgroundOutputTier.compact =>
          memory ? maxOutputTokensMemory ~/ 2 : maxOutputTokens ~/ 2,
        BackgroundOutputTier.standard =>
          memory ? maxOutputTokensMemory : maxOutputTokens,
        BackgroundOutputTier.relaxed =>
          memory ? maxOutputTokensMemory * 2 : maxOutputTokens * 2,
        BackgroundOutputTier.unlimited => null,
      };

  /// 记忆主动轮送入提示的既有记忆/指导文本的最长字符数:超长时截断保留开头,
  /// 避免把几百 KB 文本塞进一次性请求;提示词已要求维持精炼,截断只是兜底。
  static const int maxMemoryChars = 4000;

  /// 每轮后台调用的最大尝试次数:首试 + 2 次自动重试(瞬态 backendError /
  /// parseFailure,以及初始化轮"缺 memory 字段")。取消不计入重试。后台维护
  /// best-effort,单次失败率 p 经三次尝试降到 p³。
  static const int maxAttemptsPerRound = 3;

  /// 失败诊断摘要的最长字符数(状态面板文案用,防止长错误刷屏)。
  static const int maxDetailChars = 120;

  /// 解析兜底的逐候选回退上限(} 切片与 { 修复各计):每次尝试是 O(n) 的
  /// substring/扫描 + jsonDecode,跑在主 isolate;重试放开 max_tokens 后的
  /// 超长响应(数百 KB、数千个括号)不设上限可卡顿数秒。合法候选几乎总在
  /// 最后几个括号里,64 绰绰有余。
  static const int _maxParseCandidates = 64;

  /// 快状态轮只读注入记忆的字符上限:记忆是全量剧情的锚点,但每轮都发、
  /// 不能把上万字整段塞入 —— 截断保开头(长期事实通常在头部)。
  static const int maxBackgroundMemoryChars = 4000;

  /// 快状态轮角色卡紧凑形态的字符上限(只取 Name/Description/Personality/
  /// Scenario;systemPrompt/示例对话/剧情后注不进锚定段,控制每轮成本)。
  static const int maxBackgroundCharacterChars = 1000;

  /// 快状态轮**单条**世界书条目的字符上限:逐条独立截断 —— 此前只按总量截
  /// 拼接后整块,靠后的条目会被前面的预算吃光整段消失,用户勾选多条角色外貌
  /// 设定时只有 position 最前的一条真进了上下文(EX 批后续修)。
  static const int maxBackgroundWorldbookEntryChars = 1000;

  /// 快状态轮世界书锚定段的总字符上限(逐条截断后拼合的兜底,防极端多条目
  /// 时把每轮请求撑爆)。用户自选,不再按常驻判断。
  static const int maxBackgroundWorldbookChars = 4000;

  /// 重跑修改方向 / 上一轮图片描述的提示词上限:方向是用户原文,图片描述
  /// 来自上一次 LLM 输出 —— 都可能很长,截断防止把一次性请求撑爆。
  static const int maxRerunDirectionChars = 500;
  static const int maxRerunPreviousImages = 6;
  static const int maxRerunPreviousImageChars = 500;

  /// 长期记忆的**内容定义** —— 记忆初始化与全量重生成两条主动轮共用的宪法段,
  /// 消除两处各写各的导致的口径漂移(PR 批提示词重写)。只描述"记忆装什么",
  /// 数据来源/语言等差异由各自 prompt 的上下文段补。
  static const String _memoryContract = '''
Long-term memory is the durable record reused across the whole session. Keep only facts with
lasting value:
- character identity and permanent traits, including the FIXED appearance (hair color, eye
  color, build, distinctive clothing) exactly as established — automatic image generation
  reproduces it verbatim;
- personality, established relationships and how they have evolved;
- world-setting facts, the user's stated preferences and directives, and long-term goals;
- open plot threads, and major events once resolved.
Exclude per-scene details already obvious from the recent conversation. Be thorough yet concise.''';

  /// 热点路径正则(每次解析最多 3 次尝试 × 多处调用,编译一次复用)。
  static final _thinkBlock = RegExp(r'<think>[\s\S]*?</think>');
  static final _anyWhitespace = RegExp(r'\s+');

  Future<BackgroundRunResult> run({
    required String model,
    required Map<String, String> variables,
    required List<Message> history,
    List<Message>? variableHistory,
    BackgroundFeatures features = const BackgroundFeatures(),
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,

    /// 输出上限档位(v54):按档位决定首试请求的 max_tokens(standard 时与
    /// 历史硬编码 [maxOutputTokens] 一致);unlimited 首试也不带上限。
    BackgroundOutputTier tier = BackgroundOutputTier.standard,
    int imageCount = 1,
    String? imageGuide,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    Set<String> deletableVariables = const {},
    Set<String> readonlyVariables = const {},

    /// 非 null 表示这是 `/rerun` 重跑:提示词会显式告知模型,并携带用户的
    /// 修改方向与上一轮图片描述。
    RerunContext? rerunContext,
  }) async {
    final prompt = _buildPrompt(
      variables,
      history,
      features,
      imageCount,
      imageGuide,
      variableHistory: variableHistory ?? history,
      memory: memory,
      character: character,
      worldbook: worldbook,
      deletableVariables: deletableVariables,
      readonlyVariables: readonlyVariables,
      rerunContext: rerunContext,
    );
    // image 轮才缓存:稳定段含任务契约与生图锚定(指导/角色卡/记忆/世界书),
    // 同一会话内逐轮字节一致;变量-only 轮的稳定段只有任务契约,达不到
    // Anthropic 的最小缓存段长,继续整串发送。
    final cacheStablePrompt = features.image;
    // 结构化 JSON 任务:显式压低温度、限制输出上限(与主写引擎的参数解耦)。
    final outcome = await _runJson(
      model: model,
      prompt: prompt.combined,
      stableSystemPart: cacheStablePrompt ? prompt.stable : null,
      variableSystemPart: cacheStablePrompt ? prompt.variable : null,
      cacheStableSystem: cacheStablePrompt,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      outputCap: outputCapFor(tier, memory: false),
      requireVariables: features.variables,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
    );
    if (outcome is BackgroundRunFailure) return outcome;
    final result = (outcome as BackgroundRunSuccess).result;
    // 双保险:即使 prompt 只让生成已开启功能,也把未开启功能的字段清空,
    // 编排器据此不落库(防御 LLM 多给字段)。memory 字段同理恒清空 ——
    // 快状态轮不产出记忆(记忆只经主动路径)。
    return BackgroundRunSuccess(
      BackgroundResult(
        variableUpdates: features.variables ? result.variableUpdates : const {},
        variableRemovals: features.variables
            ? result.variableRemovals
            : const [],
        imagePrompt: features.image ? result.imagePrompt : null,
        imagePrompts: features.image ? result.imagePrompts : null,
        usage: result.usage,
      ),
    );
  }

  /// 主动初始化会话长期记忆:新会话记忆为空时,用户点击「生成初始记忆」触发
  /// 一次,依据**角色卡 + 常驻(恒定)世界书**生成一份初始长期记忆并落库;
  /// 之后用户可手动编辑,或用 [runMemoryRegenerate] 依据全量对话重生成。
  ///
  /// 与 [run] 的区别:提示词只送角色卡与常驻世界书(无转录、无变量/
  /// image 块),输出只取 memory 字段(其余字段一律清空,双保险)。
  /// 失败/解析失败照常细分原因。
  ///
  /// 初始化的唯一交付物是**非空 memory**,因此这里用与 [_runJson] 相同的尝试
  /// 循环但换成功判据:解析成功却缺字段/空串/字面 null(推理模型偶发返回 `{}`
  /// 或 `{"memory":null}`)与空响应一样值得再试。首试带档位上限(与用户模型级
  /// 上限取较小者)、重试完全放开(见 [_runJson] 注释);取消不重试。
  Future<BackgroundRunResult> runMemoryInit({
    required String model,
    required CharacterCard character,
    List<WorldbookEntry> worldbook = const [],
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    BackgroundOutputTier tier = BackgroundOutputTier.standard,
  }) async {
    final prompt = _buildMemoryInitPrompt(character, worldbook);
    return _runMemoryPrompt(
      model: model,
      prompt: prompt,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      tier: tier,
    );
  }

  /// 全量重生成记忆(用户主动发起,具有**所有对话上下文**的请求):把会话
  /// 全部活跃对话(旧→新,必要时截尾保最新)连同角色卡、常驻世界书与既有
  /// 记忆一并送入,产出一份覆盖全程的新长期记忆,整段替换落库。
  Future<BackgroundRunResult> runMemoryRegenerate({
    required String model,
    required CharacterCard character,
    required List<Message> history,
    List<WorldbookEntry> worldbook = const [],
    String? currentMemory,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    BackgroundOutputTier tier = BackgroundOutputTier.standard,
  }) async {
    final prompt = _buildMemoryRegeneratePrompt(
      character,
      worldbook,
      history,
      currentMemory,
    );
    return _runMemoryPrompt(
      model: model,
      prompt: prompt,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      tier: tier,
    );
  }

  /// 主动初始化会话生图指导(类似记忆初始化):依据**角色卡 + 常驻世界书**
  /// 生成一份初始生图指导并落库 —— 角色的定妆外貌(发色/瞳色/体型/服装的
  /// 英文 tag)、画风基调与构图偏好。用户之后可随时手动编辑。
  ///
  /// 输出 JSON 形状为 `{"imageGuide": "<...>"}`;成功判据同记忆主动轮
  /// (解析成功且带非空字段),重试语义一致。
  Future<BackgroundRunResult> runImageGuideInit({
    required String model,
    required CharacterCard character,
    List<WorldbookEntry> worldbook = const [],
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    BackgroundOutputTier tier = BackgroundOutputTier.standard,
  }) async {
    final characterText = _characterCardText(character);
    final constantEntries =
        worldbook.where((e) => e.constant && e.enabled).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    final constantText = constantEntries.map((e) => e.content).join('\n\n');

    final instruction = StringBuffer()
      ..writeln(
        'You are composing the initial image direction guide for a roleplay session. The guide is '
        'a compact, reusable instruction that drives automatic image generation every turn.',
      )
      ..writeln()
      ..writeln('# Output contract')
      ..writeln(
        '- A single JSON object and nothing else: {"imageGuide": "<the initial image direction guide>"}',
      )
      ..writeln('- No markdown fences, no prose, no extra keys.')
      ..writeln()
      ..writeln('# What the guide must pin down (FIXED, never drifting)')
      ..writeln(
        '- each character\'s FIXED appearance as weighted English NovelAI tags (identity '
        'such as 1girl/1boy, hair color, eye color, build, distinctive clothing);',
      )
      ..writeln(
        '- the standing art style and quality tags, and camera/composition preferences;',
      )
      ..writeln(
        '- content rules (e.g. never show the user\'s face — use POV prompts).',
      )
      ..writeln(
        'Only objective, fixed attributes; scene-specific details are decided per turn, not here. '
        'Compose it from the character card and the standing worldbook facts below. Write the '
        'guide itself in English tags/instructions regardless of the card\'s language, under ~60 lines.',
      )
      ..writeln()
      ..writeln('Character card:')
      ..write(characterText);
    if (constantText.isNotEmpty) {
      instruction
        ..writeln()
        ..writeln('Standing worldbook facts (constant, always active):')
        ..write(constantText);
    }

    BackgroundRunFailure? last;
    for (var attempt = 1; attempt <= maxAttemptsPerRound; attempt++) {
      final outcome = await _attempt(
        model: model,
        prompt: instruction.toString(),
        temperature: temperature,
        maxTokens: maxTokens,
        reasoningLevel: reasoningLevel,
        outputCap: attempt == 1 ? outputCapFor(tier, memory: true) : null,
        shouldCancel: shouldCancel,
        cancelSignal: cancelSignal,
      );
      if (outcome is BackgroundRunSuccess) {
        final guide = outcome.result.imageGuide;
        if (guide != null) {
          return BackgroundRunSuccess(
            BackgroundResult(imageGuide: guide, usage: outcome.result.usage),
          );
        }
        last = const BackgroundRunFailure(
          BackgroundFailureReason.parseFailure,
          detail: '模型返回了 JSON 但没有有效的 imageGuide 字段',
        );
        continue;
      }
      final failure = outcome as BackgroundRunFailure;
      if (failure.reason == BackgroundFailureReason.cancelled) return failure;
      last = failure;
    }
    return last!;
  }

  /// memory 主动轮(初始化/重生成)的公共执行体:与 [_runJson] 同款尝试循环,
  /// 但成功判据是"解析成功且带非空 memory 字段"。
  Future<BackgroundRunResult> _runMemoryPrompt({
    required String model,
    required String prompt,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    BackgroundOutputTier tier = BackgroundOutputTier.standard,
  }) async {
    BackgroundRunFailure? last;
    for (var attempt = 1; attempt <= maxAttemptsPerRound; attempt++) {
      final outcome = await _attempt(
        model: model,
        prompt: prompt,
        temperature: temperature,
        maxTokens: maxTokens,
        reasoningLevel: reasoningLevel,
        // 首试用 memory 档上限给足复述余量;重试放开(null = 不发送 max_tokens)。
        outputCap: attempt == 1 ? outputCapFor(tier, memory: true) : null,
        shouldCancel: shouldCancel,
        cancelSignal: cancelSignal,
      );
      if (outcome is BackgroundRunSuccess) {
        final result = outcome.result;
        if (result.memoryUpdate != null) {
          // 主动轮只产出 memory:其余字段一律清空(防御 LLM 多给字段)。
          return BackgroundRunSuccess(
            BackgroundResult(
              memoryUpdate: result.memoryUpdate,
              usage: result.usage,
            ),
          );
        }
        last = const BackgroundRunFailure(
          BackgroundFailureReason.parseFailure,
          detail: '模型返回了 JSON 但没有有效的 memory 字段',
        );
        continue;
      }
      final failure = outcome as BackgroundRunFailure;
      if (failure.reason == BackgroundFailureReason.cancelled) return failure;
      last = failure;
    }
    return last!;
  }

  /// 一次后台 LLM 调用的公共执行体:发请求 → 流式收集 → 解析 JSON → 带出
  /// [BackgroundResult](未做功能门控,由调用方决定取舍哪些字段)。
  ///
  /// 瞬态失败(backendError / parseFailure)自动重试([maxAttemptsPerRound]
  /// 次尝试):后台维护是 best-effort,网关闪断、限流、偶发空响应不该让整轮
  /// 状态更新报废 —— 单次失败率 p 在三次尝试后降到 p³。取消(cancelled)不
  /// 重试,立即返回。
  ///
  /// **重试时完全放开输出上限**:首试按功能档设 `max_tokens`(防跑飞,与用户
  /// 配置的模型级上限取较小者);重试**不发送任何 max_tokens** —— 包括调用方
  /// 透传的模型级 maxTokens。不少 OpenAI 兼容推理模型把**不可见的推理 token
  /// 也计入 max_tokens**,首试预算被思考烧尽时正文为空(用户实测"模型返回为
  /// 空")或刚吐出 `{"memory":` 就被掐断(修复器补 null → "未产出有效记忆")。
  /// 主写不带上限所以从不触发,后台每轮必带故高发;放开后与主写同待遇,由
  /// provider 自身上限兜底。
  Future<BackgroundRunResult> _runJson({
    required String model,
    required String prompt,
    String? stableSystemPart,
    String? variableSystemPart,
    bool cacheStableSystem = false,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    required int? outputCap,
    bool requireVariables = false,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
  }) async {
    BackgroundRunFailure? last;
    for (var attempt = 1; attempt <= maxAttemptsPerRound; attempt++) {
      final outcome = await _attempt(
        model: model,
        prompt: prompt,
        stableSystemPart: stableSystemPart,
        variableSystemPart: variableSystemPart,
        cacheStableSystem: cacheStableSystem,
        temperature: temperature,
        maxTokens: maxTokens,
        reasoningLevel: reasoningLevel,
        // 首试用档位上限,重试放开(null = 不发送 max_tokens)。
        outputCap: attempt == 1 ? outputCap : null,
        requireVariables: requireVariables,
        shouldCancel: shouldCancel,
        cancelSignal: cancelSignal,
      );
      if (outcome is BackgroundRunSuccess) return outcome;
      final failure = outcome as BackgroundRunFailure;
      if (failure.reason == BackgroundFailureReason.cancelled) return failure;
      last = failure;
    }
    return last!;
  }

  /// 单次尝试:真实发起请求并收集/解析;失败带诊断摘要返回。
  Future<BackgroundRunResult> _attempt({
    required String model,
    required String prompt,
    String? stableSystemPart,
    String? variableSystemPart,
    bool cacheStableSystem = false,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    required int? outputCap,
    bool requireVariables = false,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
  }) async {
    final request = LlmRequest(
      model: model,
      systemPrompt: prompt,
      messages: [ChatMessage(ChatRole.user, _userMessage)],
      temperature: (temperature ?? 0.7).clamp(0.0, maxTemperature).toDouble(),
      // 后台推理强度(v48):默认 off 不发送;开启后 openai 兼容端点映射
      // reasoning_effort、anthropic 映射 thinking 预算(其内部会连带省略
      // temperature 并抬高 max_tokens,见 anthropic_backend)。
      reasoningLevel: reasoningLevel,
      // outputCap 为 null(重试)= **完全**不设输出上限 —— 连调用方透传的
      // 模型级 maxTokens(用户在模型配置里的「最大输出 tokens」)也不带:
      // BL 批只放开了档位上限,用户配置过 max_output 时它仍原样发进每次
      // 重试,三次尝试带同一个 max_tokens,推理模型把预算烧在不可见思考上
      // 时正文恒为空 → "模型未返回任何内容"三连败(BN 批实测残留根因)。
      // 首试取用户值与档位的较小者。
      maxTokens: outputCap == null
          ? null
          : (maxTokens == null ? outputCap : math.min(maxTokens, outputCap)),
      // image 轮只缓存稳定的 system 前缀(任务契约 + 生图锚定);末条消息上
      // 不再打全前缀断点 —— 后台只有一条固定 user 指令,把每轮变化的转录/
      // 变量尾部写入缓存只会白付写入溢价。变量-only 轮不请求缓存。
      cacheContext: cacheStableSystem,
      cacheMessageBreakpoint: false,
      stableSystemPart: cacheStableSystem ? stableSystemPart : null,
      variableSystemPart: cacheStableSystem ? variableSystemPart : null,
    );

    final buffer = StringBuffer();
    var inTok = 0, outTok = 0, cachedTok = 0;
    // CR 批:与主写同款竞速唤醒。LLM 思考期不吐首块,旧实现 `await for` 只能
    // 等下一个流事件到达才轮询到 shouldCancel —— 后台场景下中断按钮要等模型
    // 终于吐第一个 token(可能 5~30 秒)才生效。引入 cancelSignal 镜像主写
    // 的 _interrupt.whenCancelled:中断令牌触发即可立刻解除等待 + 关掉底层
    // HTTP 订阅(sub.cancel),与主写行为完全一致。
    final completer = Completer<BackgroundRunResult>();
    StreamSubscription<LlmEvent>? sub;
    var cancelled = false;
    sub = backend
        .generate(request)
        .listen(
          (event) {
            if (cancelled) return;
            switch (event) {
              case TextDelta(:final text):
                buffer.write(text);
              case UsageEvent(:final usage):
                inTok += usage.inputTokens;
                outTok += usage.outputTokens;
                cachedTok += usage.cachedInputTokens;
              case DoneEvent():
                break;
              case ErrorEvent(:final message):
                if (!completer.isCompleted) {
                  completer.complete(
                    BackgroundRunFailure(
                      BackgroundFailureReason.backendError,
                      detail: _oneLine(message, maxDetailChars),
                    ),
                  );
                }
            }
          },
          onError: (Object e) {
            if (!completer.isCompleted) {
              completer.complete(
                BackgroundRunFailure(
                  BackgroundFailureReason.backendError,
                  detail: _oneLine('$e', maxDetailChars),
                ),
              );
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              // 流自然结束后再确认一次:中断可能正好发生在末事件与解析之间。
              if (shouldCancel?.call() ?? false) {
                completer.complete(
                  const BackgroundRunFailure(BackgroundFailureReason.cancelled),
                );
              } else {
                completer.complete(
                  _parseOutcome(
                    buffer.toString(),
                    inTok,
                    outTok,
                    cachedTok,
                    requireVariables: requireVariables,
                  ),
                );
              }
            }
          },
          cancelOnError: true,
        );

    void onCancel() {
      if (cancelled || completer.isCompleted) return;
      cancelled = true;
      completer.complete(
        const BackgroundRunFailure(BackgroundFailureReason.cancelled),
      );
      // 关闭底层 HTTP 流(协作式中断:令牌取消 + 显式关闭订阅,与主写一致)。
      // 不 await —— async* 生成器在零事件期会停在 `await client.send()`,
      // 等其收敛会拖回"等请求自然结束";这里只作善后,UI 状态立即往下走。
      unawaited(sub?.cancel());
    }

    if (cancelSignal != null) {
      // 中断已在发生时立即触发,不等流事件。whenComplete 在 cancelSignal
      // 已完成时同步回调 —— 进入本函数时已取消的场景也立即生效。
      cancelSignal.whenComplete(() {
        if (shouldCancel?.call() ?? false) onCancel();
      });
    }
    return completer.future;
  }

  /// 解析流式累积文本为结果,抽出来让 [BackgroundEngine._attempt] 主体保持
  /// 监听+竞速的简洁性:onDone 完成时直接 return 此处的产物。
  BackgroundRunResult _parseOutcome(
    String raw,
    int inTok,
    int outTok,
    int cachedTok, {
    bool requireVariables = false,
  }) {
    // 推理模型常把 <think>…</think> 混在正文里(OpenAI 兼容网关直接塞 content),
    // 先剥离再解析;思考烧掉全部输出预算时正文可能为空。
    final parsed = _parse(
      _stripThinking(raw),
      requireVariables: requireVariables,
    );
    if (parsed == null) {
      return BackgroundRunFailure(
        BackgroundFailureReason.parseFailure,
        detail: _parseDetail(raw),
      );
    }
    return BackgroundRunSuccess(
      BackgroundResult(
        variableUpdates: parsed.variableUpdates,
        variableRemovals: parsed.variableRemovals,
        memoryUpdate: parsed.memoryUpdate,
        imagePrompt: parsed.imagePrompt,
        imagePrompts: parsed.imagePrompts,
        imageGuide: parsed.imageGuide,
        usage: TokenUsage(
          inputTokens: inTok,
          outputTokens: outTok,
          cachedInputTokens: cachedTok,
        ),
      ),
    );
  }

  /// 后台轮的用户消息:指令主体在 system(稳定段 + 可变段),这里只给一句短指令
  /// 充当请求的 messages 数组(各家 API 都要求至少一条消息)。
  static const _userMessage =
      'Emit the JSON state update now for the conversation above.';

  /// 只在需要的功能块上构建 prompt:关闭的功能既不进 JSON 形状、也不送其上下文,
  /// 让单功能维护的请求明显变小、变快。
  ///
  /// 结构化上下文(与主写引擎 ContextAssembler 同构):各段一律以
  /// `<tag>说明行\n正文</tag>` 包裹,让弱模型明确分辨「设定锚定」与「对话内容」
  /// 的边界 —— `<background_task>` 任务说明 + JSON 形状;image 开启时
  /// 追加 `<character>`/`<memory>`/`<worldbook_background>` 三个只读锚定段
  /// (各带截断上限,剧情地点/情境/人物关系由此而来);`<recent_conversation>`
  /// 最新真实对话;`<variables>` 变量块。纯 variables 轮不注入锚定三段,维持
  /// 低成本;生图指导 `<image_guide>` 仅 image 开启时注入(空则回退内置英文
  /// tag 规范)。
  ///
  /// 返回稳定/可变两段:任务契约与 image 锚定段在同一会话内字节稳定,作为
  /// Anthropic 缓存前缀;重跑说明、转录与变量每轮变化,留在可变尾部。
  _BackgroundPrompt _buildPrompt(
    Map<String, String> variables,
    List<Message> history,
    BackgroundFeatures features,
    int imageCount,
    String? imageGuide, {
    required List<Message> variableHistory,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    Set<String> deletableVariables = const {},
    Set<String> readonlyVariables = const {},
    RerunContext? rerunContext,
  }) {
    final stableSections = <String>[];
    final variableSections = <String>[];

    final enabledFields = <String>[
      if (features.variables)
        '"variables": {"<key>": "<value>", ...}, "removeVariables": ["<exact existing key>", ...]',
      if (features.image)
        imageCount > 1
            ? '"imagePrompts": ["<scene description 1>", ..., "<scene description $imageCount>"]'
            : '"imagePrompt": "<current scene description>"',
    ].join(', ');

    // 静态「宪法段」:角色与使命 → 输出协议(硬约束)→ 本次输出形状 →
    // 上下文读法(段职责与优先级)→ 各字段规则(按 features 裁剪)。整段在
    // 同一 features 组合下逐轮字节一致(缓存友好的稳定前缀);对锚定段的引用
    // 一律用「出现即只读、可能缺失」的通用措辞,不再硬点名未注入的段。
    final instruction = StringBuffer()
      ..writeln(
        'You are the background state-maintenance agent for a roleplay session. After each '
        'assistant reply you inspect the latest conversation and emit ONE machine-readable JSON '
        'object of state changes. You are not a chat participant: never write prose, never reply '
        'to the user, never explain.',
      )
      ..writeln()
      ..writeln('# Output contract (hard rules)')
      ..writeln('- Reply with a single JSON object and NOTHING else.')
      ..writeln(
        '- No markdown fences, no preamble, no trailing commentary, no thinking tags.',
      )
      ..writeln(
        '- Use exactly the keys listed in the output shape, valid JSON only (double quotes, no '
        'trailing commas). A key may be null only where null is explicitly allowed below.',
      )
      ..writeln()
      ..writeln('# Output shape for this run')
      ..writeln('{$enabledFields}')
      ..writeln()
      ..writeln('# How to read the context sections')
      ..writeln(
        '- The recent_conversation section is the ONLY source of truth for the current image scene; '
        'it is read-only context, not a source of variable updates.',
      )
      ..writeln(
        '- Any memory, character, worldbook_background or image_guide section that appears below '
        'is durable, read-only background: never contradict it, never copy it into your output, '
        'and never invent facts that fight it. These sections may be absent — work with what is '
        'present.',
      )
      ..writeln();
    if (features.variables) {
      instruction
        ..writeln('# variables')
        ..writeln(
          '- Variables are the session\'s durable state board: short key-value pairs for facts that '
          'persist and can change across the story (location, time, condition, goals, relationships, '
          'possessions, ongoing effects). They are not a per-scene summary.',
        )
        ..writeln(
          '- Update variables ONLY from the variable_delta section, the unprocessed turns for this run.',
        )
        ..writeln(
          '- Never replay old changes from the read-only recent_conversation section.',
        )
        ..writeln(
          '- Emit only the keys whose value CHANGED in variable_delta, as {"key": new_value}.',
        )
        ..writeln(
          '- YOU MAY AND SHOULD CREATE NEW KEYS: when variable_delta establishes a durable fact of '
          'this kind that no existing key covers, add it with a short, stable key and reuse that '
          'exact key in later runs. Prefer updating an existing key over creating a near-duplicate '
          'or synonym, and do not track transient scene details that will not matter again.',
        )
        ..writeln(
          '- Preserve existing keys exactly, including whitespace; keys must not be empty or whitespace-only.',
        )
        ..writeln(
          '- Values must be JSON scalars: strings, finite numbers or booleans; never null, objects or arrays.',
        )
        ..writeln(
          '- Always include the variables object. Do NOT restate unchanged keys; use {} when nothing changed.',
        )
        ..writeln(
          '- To delete a key, list its EXACT existing key in removeVariables. Remove only when '
          'variable_delta shows the fact it tracks has ended, been left behind, or been permanently '
          'superseded. Never remove a key merely because it is absent from variable_delta or because the '
          'context looks cluttered; prefer updating it to a neutral value when the key still describes state.',
        )
        ..writeln(
          '- Only existing keys listed under variable_access.deletable may be removed; readonly '
          'keys must never be updated or removed. All other existing keys may be updated but never '
          'removed. New keys may always be created.',
        )
        ..writeln(
          '- A key must never appear in both variables and removeVariables. At most 5 removals per run; '
          'use [] when none.',
        )
        ..writeln();
    }
    if (features.image) {
      instruction
        ..writeln('# image')
        ..writeln(
          '- Always fill this field — never null, never a generic or stale image. Describe the '
          'CURRENT scene read from the recent_conversation section: who is present, where, the '
          'action, lighting and mood.',
        )
        ..writeln(
          '- Reproduce each character\'s established appearance EXACTLY as pinned by the '
          'image_guide (and the character / memory sections when present); never alter what those '
          'fix. Vary only scene-specific pose, expression, action and mood.',
        )
        ..writeln(
          '- Write it as the English NovelAI tag format defined in the image_guide: one '
          'comma-separated tag string, not a sentence.',
        );
      if (imageCount > 1) {
        // 一次多张 = 同场景的 N 个不同画面(不是同一描述复制 N 份)。
        instruction
          ..writeln()
          ..writeln(
            '- The user wants $imageCount images: return exactly $imageCount DIFFERENT tag strings '
            'in "imagePrompts", each a distinct framing (shot size / angle / composition / focus / '
            'mood) of the SAME current scene, mutually consistent and each independently usable.',
          );
      }
      instruction.writeln();
    }
    stableSections.add(
      _tag(
        'background_task',
        'Background maintenance contract: the output format and rules for this run.',
        instruction.toString().trimRight(),
      ),
    );

    // 锚定三段:仅 image 需要剧情语境时注入;纯 variables 轮保持便宜。
    if (features.image) {
      final guide = imageGuide != null && imageGuide.trim().isNotEmpty
          ? imageGuide.trim()
          : kImageTagGuideEn;
      stableSections.add(
        _tag(
          'image_guide',
          'Authoritative image direction guide (user-maintained). Reproduce the fixed appearance and style it pins down exactly.',
          guide,
        ),
      );
      final charText = _compactCharacterText(character);
      if (charText.isNotEmpty) {
        stableSections.add(
          _tag(
            'character',
            'Active character card (read-only reference): name, description, personality, scenario.',
            charText,
          ),
        );
      }
      final mem = memory?.trim() ?? '';
      if (mem.isNotEmpty) {
        stableSections.add(
          _tag(
            'memory',
            'Session long-term memory (read-only; established facts and continuity; never copy into output).',
            _truncate(mem, maxBackgroundMemoryChars),
          ),
        );
      }
      final wbText = _backgroundWorldbookText(
        worldbook,
        maxBackgroundWorldbookChars,
      );
      if (wbText.isNotEmpty) {
        stableSections.add(
          _tag(
            'worldbook_background',
            'User-selected worldbook lore for this session (read-only reference).',
            wbText,
          ),
        );
      }
    }

    final transcript = history.map((m) => '${m.role}: ${m.content}').join('\n');
    variableSections.add(
      _tag(
        'recent_conversation',
        'The most recent conversation turns — read-only context for variables; the source of truth for the current image scene.',
        transcript,
      ),
    );

    if (features.variables) {
      variableSections.add(
        _tag(
          'variable_delta',
          'Unprocessed conversation turns for this run — the ONLY source of variable changes; not an image scene source.',
          variableHistory.map((m) => '${m.role}: ${m.content}').join('\n'),
        ),
      );
      variableSections.add(
        _tag(
          'variables',
          'Current session variables as JSON. Reuse existing keys with their exact spelling; a key you add that is not listed here creates a new variable.',
          jsonEncode(variables),
        ),
      );
      final deletable = deletableVariables.toList()..sort();
      final readonly = readonlyVariables.toList()..sort();
      variableSections.add(
        _tag(
          'variable_access',
          'Variable permissions for EXISTING keys: "deletable" lists the exact keys you may remove; '
              '"readonly" keys must never be updated or removed; all other existing keys may be updated '
              'but never removed. New keys are always allowed and are not restricted here.',
          jsonEncode({'deletable': deletable, 'readonly': readonly}),
        ),
      );
    }

    // 重跑说明置于提示词最末:既是可变尾部(稳定前缀不因重跑而变),又让用户的
    // 修改方向成为模型最后读到的内容,保持最高注意力。普通维护不出现该段。
    final rerun = rerunContext;
    if (rerun != null) {
      variableSections.add(
        _tag(
          'rerun_instruction',
          'Rerun context for this run (user-triggered; final instruction, applied after the context above).',
          _rerunInstruction(rerun, features),
        ),
      );
    }
    return _BackgroundPrompt(
      stable: stableSections.join('\n\n'),
      variable: variableSections.join('\n\n'),
    );
  }

  /// 重跑说明段正文:重跑标识 + 用户修改方向 + 上一轮图片描述(仅 image
  /// 开启时注入)。方向与描述都截断,防止一次性请求被超长文本撑爆。
  static String _rerunInstruction(
    RerunContext context,
    BackgroundFeatures features,
  ) {
    final lines = <String>[
      'This run is a RERUN of the previous background maintenance for the same conversation '
          'window, requested by the user. The previous run\'s choices are not final: re-evaluate '
          'the conversation above and emit a fresh, complete state update in the output shape '
          'above. The variables shown above are the current state (usually including the previous '
          'run\'s applied changes); emit only what this rerun changes.',
    ];
    final direction = context.direction?.trim() ?? '';
    if (direction.isNotEmpty) {
      lines
        ..add('')
        ..add('The user requested this change in direction:')
        ..add(_truncate(direction, maxRerunDirectionChars))
        ..add('')
        ..add(
          'Apply it to the fields you emit: when it implies durable state changes, emit matching '
          'variable updates (new keys are allowed; permissions still apply); when it implies a '
          'visual change, reflect it in the new scene description while keeping the fixed '
          'appearance and style pinned by the image_guide. It never overrides the hard rules '
          'above — valid JSON, variable permissions and the image tag format stay mandatory — '
          'and it does not turn the recent_conversation section into a variable source.',
        );
    }
    final previous = <String>[
      for (final prompt in context.previousImagePrompts)
        if (prompt.trim().isNotEmpty)
          _truncate(prompt, maxRerunPreviousImageChars),
    ].take(maxRerunPreviousImages).toList();
    if (features.image && previous.isNotEmpty) {
      lines
        ..add('')
        ..add(
          'Image descriptions produced by the previous maintenance (reference only — the '
          'previous output, not established facts; this run replaces those images):',
        );
      for (var i = 0; i < previous.length; i++) {
        lines.add('${i + 1}. ${previous[i]}');
      }
      lines.add(
        'Use them as the baseline to revise rather than text to copy; keep the established scene '
        'facts and image_guide constraints.',
      );
    }
    return lines.join('\n');
  }

  /// 段落标签包裹:与主写引擎 ContextAssembler._wrap 同构 ——
  /// `<标签>说明行\n正文</标签>`,让模型明确分辨设定锚定与对话内容的边界。
  static String _tag(String tag, String description, String content) =>
      '<$tag>$description\n$content</$tag>';

  /// 快状态轮的角色卡紧凑形态(只取 Name/Description/Personality/Scenario;
  /// systemPrompt/示例对话/剧情后注不进锚定段)。
  static String _compactCharacterText(CharacterCard? character) {
    final c = character;
    if (c == null) return '';
    final text = [
      if (c.name.isNotEmpty) 'Name: ${c.name}',
      if (c.description.isNotEmpty) 'Description:\n${c.description}',
      if (c.personality.isNotEmpty) 'Personality:\n${c.personality}',
      if (c.scenario.isNotEmpty) 'Scenario:\n${c.scenario}',
    ].join('\n\n');
    return _truncate(text, maxBackgroundCharacterChars);
  }

  /// 后台锚定世界书内容:取用户选定(`background`,状态面板后台agent 区
  /// 多选)且启用的条目,按 position 排序,**逐条截断**后拼合再套总量兜底。
  /// 逐条截断是显式语义:用户勾了几条,每条都要真进锚定段(哪怕被夹到
  /// [maxBackgroundWorldbookEntryChars]),不能让 position 靠后的外貌条目
  /// 被前面吃光预算整段清零。EU 批起不再按常驻判断;初始化路径(记忆/生图
  /// 指导)仍按常驻取数,不走此函数。
  static String _backgroundWorldbookText(
    List<WorldbookEntry> worldbook,
    int maxChars,
  ) {
    final entries = worldbook.where((e) => e.background && e.enabled).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    if (entries.isEmpty) return '';
    final joined = entries
        .map((e) => _truncate(e.content, maxBackgroundWorldbookEntryChars))
        .join('\n\n');
    return _truncate(joined, maxChars);
  }

  /// 截断保开头并加省略标记(锚定段兜底,防超长文本塞满每轮请求)。
  static String _truncate(String text, int maxChars) {
    final t = text.trim();
    if (t.length <= maxChars) return t;
    return '${t.substring(0, maxChars)}…(超长已截断)';
  }

  /// 记忆初始化提示词:只送**角色卡 + 常驻(恒定)世界书**,不含会话转录与其它
  /// 功能块 —— 全新会话没有任何对话可依据,初始记忆完全来自这两份设定源。
  ///
  /// 常驻世界书取 `constant && enabled` 条目(恒定、始终生效,字节稳定),按
  /// position 排序;触发型条目由对话关键词驱动,不参与初始化。
  static String _buildMemoryInitPrompt(
    CharacterCard character,
    List<WorldbookEntry> worldbook,
  ) {
    final characterText = _characterCardText(character);

    final constantEntries =
        worldbook.where((e) => e.constant && e.enabled).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    final constantText = constantEntries.map((e) => e.content).join('\n\n');

    final instruction = StringBuffer()
      ..writeln(
        'You are composing the initial long-term memory for a NEW roleplay session. It has no '
        'conversation yet, so build the memory solely from the character card and the standing '
        '(constant) worldbook facts below.',
      )
      ..writeln()
      ..writeln('# Output contract')
      ..writeln(
        '- A single JSON object and nothing else: {"memory": "<the initial durable memory>"}',
      )
      ..writeln('- No markdown fences, no prose, no extra keys.')
      ..writeln()
      ..writeln('# What long-term memory holds')
      ..writeln(_memoryContract)
      ..writeln()
      ..writeln('Write in the same language as the character card.')
      ..writeln()
      ..writeln('Character card:')
      ..write(characterText);
    if (constantText.isNotEmpty) {
      instruction
        ..writeln()
        ..writeln('Standing worldbook facts (constant, always active):')
        ..write(constantText);
    }
    return instruction.toString();
  }

  /// 全量重生成记忆的提示词([runMemoryRegenerate] 用):角色卡 + 常驻世界书 +
  /// **全部活跃对话**(旧→新)+ 既有记忆(只读参考)。转录超长时保最新
  /// [maxRegenerateMessages] 条 —— 记忆重生成是低频主动操作,截尾只是防止
  /// 一次性请求超窗,更早剧情若有价值应已沉淀在既有记忆里。
  static const int maxRegenerateMessages = 500;

  static String _buildMemoryRegeneratePrompt(
    CharacterCard character,
    List<WorldbookEntry> worldbook,
    List<Message> history,
    String? currentMemory,
  ) {
    final characterText = _characterCardText(character);
    final constantEntries =
        worldbook.where((e) => e.constant && e.enabled).toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    final constantText = constantEntries.map((e) => e.content).join('\n\n');

    // 活跃对话 = 真实对话行(排除 system 摘要/已压缩/空内容/附件行)。
    final active = history
        .where(
          (m) =>
              m.isChat &&
              m.role != 'system' &&
              !m.isCompacted &&
              m.content.isNotEmpty,
        )
        .toList();
    final transcriptRows = active.length > maxRegenerateMessages
        ? active.sublist(active.length - maxRegenerateMessages)
        : active;
    final transcript = transcriptRows
        .map((m) => '${m.role}: ${m.content}')
        .join('\n');

    final hasMemory = currentMemory != null && currentMemory.trim().isNotEmpty;

    final instruction = StringBuffer()
      ..writeln(
        'You are recomposing the long-term memory for an ONGOING roleplay session. Fold the '
        'entire conversation below into one durable record.',
      )
      ..writeln()
      ..writeln('# Output contract')
      ..writeln(
        '- A single JSON object and nothing else: {"memory": "<the recomposed durable memory>"}',
      )
      ..writeln('- No markdown fences, no prose, no extra keys.')
      ..writeln()
      ..writeln('# What long-term memory holds')
      ..writeln(_memoryContract)
      ..writeln()
      ..writeln(
        'Recompose from the FULL transcript below (oldest to newest), checked against the '
        'character card and standing worldbook'
        '${hasMemory ? ' and the existing memory used as a draft — keep what still matters, '
                  'merge in what the transcript adds, prune what is stale or contradicted' : ''}. '
        'This is the single durable record for the whole session, NOT a per-scene summary. '
        'Write in the same language as the conversation.',
      )
      ..writeln()
      ..writeln('Character card:')
      ..write(characterText);
    if (constantText.isNotEmpty) {
      instruction
        ..writeln()
        ..writeln('Standing worldbook facts (constant, always active):')
        ..write(constantText);
    }
    if (hasMemory) {
      final draft = currentMemory;
      instruction
        ..writeln()
        ..writeln('Existing memory (read-only draft to correct and extend):')
        ..write(
          draft.length > maxMemoryChars
              ? '${draft.substring(0, maxMemoryChars)}\n…(超出 $maxMemoryChars 字符,已截断,保留开头)'
              : draft,
        );
    }
    instruction
      ..writeln()
      ..writeln('Full conversation transcript (oldest first):')
      ..write(transcript);
    return instruction.toString();
  }

  /// 角色卡的纯文本形态(记忆主动轮共用)。
  static String _characterCardText(CharacterCard character) {
    return [
      if (character.name.isNotEmpty) 'Name: ${character.name}',
      if (character.description.isNotEmpty)
        'Description:\n${character.description}',
      if (character.personality.isNotEmpty)
        'Personality:\n${character.personality}',
      if (character.scenario.isNotEmpty) 'Scenario:\n${character.scenario}',
      if (character.systemPrompt.isNotEmpty)
        'System prompt:\n${character.systemPrompt}',
      if (character.postHistoryInstructions.isNotEmpty)
        'Post-history instructions:\n${character.postHistoryInstructions}',
      if (character.mesExample.isNotEmpty)
        'Example dialogue:\n${character.mesExample}',
    ].join('\n\n');
  }

  /// 剥离推理模型混在正文里的 `<think>…</think>` 段(不少 OpenAI 兼容网关把
  /// 思考文本直接塞进 content 字符串,不剥离会污染 JSON 解析;思考段里还常含
  /// `{}`,会让"首个 { 切片"兜底取错起点)。已配对的 think 块整体删除;
  /// 未配对但存在闭合标签时(思考被 max_tokens 截断、正文在其后),取最后一个
  /// `</think>` 之后的部分 —— 其中没有 `{` 时维持原文,交回常规解析链判失败;
  /// 只有开标签、连 `</think>` 都没吐出时,正文尚未开始(正文约定在闭合标签
  /// 之后),返回空串 → 按"只返回了思考内容"的解析失败处理,不从思考文本里
  /// 碰巧捞 `{` 解析出错误对象。
  static String _stripThinking(String text) {
    final stripped = text.replaceAll(_thinkBlock, '');
    if (stripped != text) return stripped;
    final idx = text.lastIndexOf('</think>');
    if (idx >= 0) {
      final after = text.substring(idx + '</think>'.length);
      if (after.contains('{')) return after;
    }
    if (text.contains('<think>')) return '';
    return text;
  }

  /// 解析失败的诊断摘要:区分"空响应"(常见于推理模型把输出预算全部烧在思考
  /// 上、或网关静默断流)与"畸形响应",后者给出开头片段帮助定位(围栏/说明文/
  /// 截断位置一目了然)。只做展示,不影响失败判定。
  static String _parseDetail(String raw) {
    final body = _stripThinking(raw).trim();
    if (body.isEmpty) {
      return raw.trim().isEmpty ? '模型未返回任何内容' : '模型只返回了思考内容,没有正文';
    }
    final oneLine = _oneLine(body, maxDetailChars);
    return '响应片段:$oneLine';
  }

  /// 压成单行并截断到 [maxChars](诊断文案用):换行/连续空白折叠为单空格,
  /// 超长取头部加省略号。
  static String _oneLine(String text, int maxChars) {
    final oneLine = text.replaceAll(_anyWhitespace, ' ').trim();
    if (oneLine.length <= maxChars) return oneLine;
    return '${oneLine.substring(0, maxChars)}…';
  }

  /// 解析后台 LLM 返回的 JSON。任何错误/解析失败返回 null(编排器据此跳过)。
  ///
  /// 健壮化:
  /// 1. 先整串 `jsonDecode` —— 模型直接输出纯 JSON 的常见情形,字符串值里含 `}`
  ///    也不受影响;
  /// 2. 失败再回退切片:从首个 `{` 开始,从末尾 `}` 往前逐个尝试 —— 覆盖"JSON
  ///    对象后又追加了含 `}` 的文本"(markdown 围栏 / 模型追加说明)的畸形输出;
  /// 3. 切片也失败时做宽容修复(_repairJson):截断/未转义控制字符/裸键等;
  /// 4. 顶层非 Map(如数组/标量)视为无效。
  ///
  /// 字段级容错(C2):定位出 JSON 对象后,每个字段**独立**提取 —— 某个字段坏了
  /// (如 activeSkills 是字符串而非数组)只丢弃该字段,其余字段照常落库,不再
  /// 因一个坏字段丢弃整轮状态更新。
  BackgroundResult? _parse(String text, {bool requireVariables = false}) {
    if (requireVariables) {
      final json = _parseCompleteObject(text);
      return json == null ? null : _parseFields(json, requireVariables: true);
    }
    final t = text.trim();
    if (t.isEmpty) return null;
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(t);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      json = null;
    }
    if (json == null) {
      final start = t.indexOf('{');
      if (start < 0) return null;
      // 逐 } 回退候选设上限:重试路径放开 max_tokens 后响应可达数百 KB、数千个 },
      // 每次尝试是 O(n) 的 substring+jsonDecode 且跑在主 isolate —— 不设上限可
      // 卡顿数秒。合法候选(对象后又追加文本)几乎总在最后几个 } 里。
      var end = t.lastIndexOf('}');
      for (
        var tries = 0;
        end >= start && tries < _maxParseCandidates;
        tries++
      ) {
        try {
          final decoded = jsonDecode(t.substring(start, end + 1));
          if (decoded is Map<String, dynamic>) {
            json = decoded;
            break;
          }
        } on FormatException {
          // 该 } 不是对象结尾,继续尝试更早的 }。
        }
        end = t.lastIndexOf('}', end - 1);
      }
      if (json == null) {
        // 整串与切片都失败:做最后兜底的宽容修复 —— 截断/未转义控制字符/裸键
        // 等常见畸形输出(见 _repairJson 注释)。仍修不出可解析对象才判解析失败。
        json = _repairJson(t);
        if (json == null) return null;
      }
    }
    return _parseFields(json);
  }

  static Map<String, dynamic>? _parseCompleteObject(String text) {
    final t = text.trim();
    try {
      final decoded = jsonDecode(t);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      final start = t.indexOf('{');
      final arrayStart = t.indexOf('[');
      if (start < 0 || (arrayStart >= 0 && arrayStart < start)) return null;
      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var i = start; i < t.length; i++) {
        final c = t[i];
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (c == r'\') {
            escaped = true;
          } else if (c == '"') {
            inString = false;
          }
          continue;
        }
        if (c == '"') {
          inString = true;
        } else if (c == '{') {
          depth++;
        } else if (c == '}') {
          depth--;
          if (depth == 0) {
            try {
              final decoded = jsonDecode(t.substring(start, i + 1));
              return decoded is Map<String, dynamic> ? decoded : null;
            } on FormatException {
              return null;
            }
          }
        }
      }
      return null;
    }
  }

  /// 最后兜底的宽容修复解析:整串与切片兜底都失败后,把常见畸形输出修成可解析
  /// 的 JSON 对象 ——
  /// ① 字符串值里的未转义换行/回车/制表符(模型常把多行记忆直接写进 JSON
  ///    字符串,整串解码直接炸);
  /// ② 输出被 max_tokens 截断的残缺尾巴:未闭合的字符串补收尾引号、悬空的
  ///    键/值补 null 或丢弃、未闭合的容器补右括号 —— 救出对象前半段里能用的
  ///    字段(记忆在形状最前,通常能整段活下来);
  /// ③ 裸键漏引号(如 `imagePrompt:` 直接写)。
  /// 修复只求"救出可解析字段",字段级容错(C2)照常过滤;修不出可解析对象返回
  /// null(维持 parseFailure)。候选起点从**最靠后的 `{`** 往前逐个尝试(与切片
  /// 兜底"取最后一个有效对象"同向:推理在前、目标 JSON 在后时优先命中后者;
  /// `{` 落在字符串内容里的伪候选修不出自然失败)。
  static Map<String, dynamic>? _repairJson(String text) {
    // 逐 { 候选回退同样设上限(与 _parse 的 } 回退同因:候选数 × O(n) 修复扫描)。
    var start = text.lastIndexOf('{');
    for (var tries = 0; start >= 0 && tries < _maxParseCandidates; tries++) {
      final repaired = _repairFrom(text, start);
      if (repaired != null) {
        try {
          final decoded = jsonDecode(repaired);
          if (decoded is Map<String, dynamic>) return decoded;
        } on FormatException {
          // 该起点修出的文本仍不可解析,试更早的 {。
        }
      }
      if (start == 0) break; // 已到文本头,没有更早的 { 候选。
      start = text.lastIndexOf('{', start - 1);
    }
    return null;
  }

  /// 从 [start]('{')起做一遍宽容扫描,产出尽量闭合、可解析的 JSON 文本;
  /// 根对象闭合后的后续文本整体丢弃(模型追加的说明/第二个对象)。修不出
  /// (如起点实际落在字符串内容里)返回 null,由调用方试更早的候选起点。
  static String? _repairFrom(String text, int start) {
    if (start < 0 || start >= text.length) return null;
    final out = StringBuffer();
    final stack = <String>[]; // 未闭合容器(入 '}' 或 ']',关闭时匹配)
    final keyBuf = StringBuffer(); // 裸键/进行中字符串的暂存(闭合前不落出)
    var inString = false;
    var escaped = false;
    var afterColon = false; // 刚见过 ':'(或数组内 ','),期待一个值
    var valueStarted = false; // 期待的值位置是否已写出内容(用于截断时补 null)
    var rootClosed = false;

    /// 引号键已完整落出(flushKey 后 keyBuf 已清空)、但还没等到它的 ':'。
    /// 裸键仍留在 keyBuf 里由 [endPendingKey] 兜底;引号键在落出瞬间就丢失了
    /// "还在等冒号"的状态,必须在分隔/收尾处单独补 ":null"(BC 批后实测残留
    /// 的解析失败主因:输出掐在 `{"activeSkills"` / `{"memory":null,"imagePrompt"`
    /// 这类"键已闭合、值未开始"的位置,修出的 `{"key"}` 无法解析)。
    var awaitingColon = false;

    // 暂存内容落出:已带引号的(引号键/值字符串)原样写;裸键补引号(去首尾空白)。
    void flushKey() {
      final k = keyBuf.toString();
      if (k.isEmpty) return;
      keyBuf.clear();
      out.write(k.startsWith('"') ? k : '"${k.trim()}"');
    }

    // 键的收尾:裸键仍在暂存 → 补引号 + ":null";引号键已成文但无 ':' → 补 ":null"。
    // (值位置不受影响:等待值的对象/数组在此不落 out。)
    void endPendingKey() {
      if (keyBuf.isNotEmpty && !afterColon) {
        flushKey();
        out.write(':null');
      } else if (awaitingColon && !afterColon) {
        out.write(':null');
      }
      awaitingColon = false;
    }

    // 去掉悬在输出末尾的 ','(值在逗号后被截断留下的尾逗号)。
    void dropTrailingComma() {
      final s = out.toString().trimRight();
      if (s.endsWith(',')) {
        out.clear();
        out.write(s.substring(0, s.length - 1));
      }
    }

    for (var i = start; i < text.length; i++) {
      if (rootClosed) break;
      final c = text[i];
      if (inString) {
        if (escaped) {
          keyBuf.write(c);
          escaped = false;
          continue;
        }
        if (c == r'\') {
          keyBuf.write(c);
          escaped = true;
          continue;
        }
        if (c == '"') {
          keyBuf.write(c);
          if (afterColon) {
            out.write(keyBuf.toString()); // 值字符串:整体落出(已带引号)
            keyBuf.clear();
            awaitingColon = false; // 值完成,键已等到它的值
          } else {
            flushKey(); // 引号键:flushKey 原样写(已带引号)
            awaitingColon = true; // 键已成文,等 ':'(或由 endPendingKey 补 ":null")
          }
          inString = false;
          afterColon = false; // 值已完成
          valueStarted = false;
          continue;
        }
        // 字符串内未转义控制字符:按 JSON 转义 —— \n\r\t 用短形式,其余 C0
        // (如 \b \f \v \0)只能写 \uXXXX,否则 jsonDecode 直接拒绝(实测残留
        // 解析失败之一:记忆/描述文本里混入制表符以外的控制字符)。
        final code = c.codeUnitAt(0);
        if (code < 0x20) {
          keyBuf.write(switch (c) {
            '\n' => r'\n',
            '\r' => r'\r',
            '\t' => r'\t',
            _ => '\\u${code.toRadixString(16).padLeft(4, '0')}',
          });
          continue;
        }
        keyBuf.write(c);
        continue;
      }
      switch (c) {
        case '"':
          flushKey(); // 先落出可能积压的裸键(异常情形,原样处理)
          keyBuf.write(c);
          inString = true;
          valueStarted = afterColon; // 值字符串起点
          continue;
        case '{':
        case '[':
          endPendingKey();
          out.write(c);
          stack.add(c == '{' ? '}' : ']');
          valueStarted = afterColon; // 对象/数组作为值出现时也算值已开始
          afterColon = c == '['; // 对象后期待键,数组后期待值
          continue;
        case '}':
        case ']':
          endPendingKey();
          dropTrailingComma();
          if (stack.isNotEmpty && stack.last == c) {
            out.write(c);
            stack.removeLast();
            if (stack.isEmpty) rootClosed = true;
          } else {
            // 不匹配的多余右括号:忽略(模型追加的括号不破坏已修文本)。
          }
          afterColon = false;
          valueStarted = false;
          continue;
        case ':':
          flushKey(); // 裸键在此闭合:补引号
          out.write(':');
          afterColon = true;
          awaitingColon = false; // 键已迎来 ':',接下来期待值
          valueStarted = false;
          continue;
        case ',':
          endPendingKey();
          out.write(',');
          // 数组内逗号后期待值(栈里存的是**闭合**括号,数组是 ']',对象是 '}';
          // 旧判断 `stack.last == '['` 恒为 false,导致数组逗号后的裸值(null/
          // 数字)被当成键、修出 `["one","42":null]` 这类废文本 —— 实测残留
          // 解析失败之一)。
          afterColon = stack.isNotEmpty && stack.last == ']';
          valueStarted = false;
          continue;
        default:
          if (afterColon) {
            // 值位置:原样落出(token/数字/空白);裸控制字符跳过。
            if (c.codeUnitAt(0) < 0x20) continue;
            out.write(c);
            if (c != ' ') valueStarted = true;
          } else if (stack.isNotEmpty) {
            // 键位置:裸键字符先暂存,等 ':' 或分隔再决定。
            if (c.codeUnitAt(0) < 0x20) continue;
            keyBuf.write(c);
          }
          continue;
      }
    }
    // 文本已尽:处理未闭合尾巴。
    if (inString) {
      if (escaped) {
        keyBuf.write(r'\'); // 末尾孤立反斜杠(转义未完成)改为转义反斜杠
      }
      if (afterColon) {
        keyBuf.write('"'); // 值字符串被截断:补收尾引号救回整个值
        out.write(keyBuf.toString());
        keyBuf.clear();
        awaitingColon = false;
      } else {
        keyBuf.clear(); // 键被截断:整段丢弃(补引号也无 ':' 无值,救不回)
      }
      inString = false;
    } else if (afterColon) {
      if (!valueStarted) out.write('null'); // ':' 后没有值就被截断:补 null
    } else {
      endPendingKey(); // 悬空的裸键/已落出的引号键:补 ":null"
    }
    dropTrailingComma();
    while (stack.isNotEmpty) {
      out.write(stack.removeLast()); // 未闭合容器逐个补右括号
    }
    return out.isEmpty ? null : out.toString();
  }

  static BackgroundResult? _parseFields(
    Map<String, dynamic> json, {
    bool requireVariables = false,
  }) {
    // activeSkills 字段已随 v37 退役:LLM 若仍返回该键,这里直接忽略。
    final vars = _asStringMap(json['variables']);
    if (requireVariables && vars == null) return null;
    final mem = json['memory'];
    // memory 通常为字符串;推理模型偶尔给结构化对象/数组 —— 序列化为文本保留
    // 内容,不再判"未产出有效记忆"(BL 批实测:初始化高发)。
    String? memStr;
    if (mem is String && mem.isNotEmpty && mem != 'null') {
      memStr = mem;
    } else if (mem is Map || mem is List) {
      memStr = jsonEncode(mem);
    }
    final ip = json['imagePrompt'];
    final imagePrompt = (ip is String && ip.isNotEmpty && ip != 'null')
        ? ip
        : null;
    final ig = json['imageGuide'];
    final imageGuide = (ig is String && ig.isNotEmpty && ig != 'null')
        ? ig
        : null;
    return BackgroundResult(
      variableUpdates: vars ?? const {},
      variableRemovals: _asRemovalKeys(json['removeVariables']),
      memoryUpdate: memStr,
      imagePrompt: imagePrompt,
      imagePrompts: _asPromptList(json['imagePrompts']),
      imageGuide: imageGuide,
    );
  }

  /// `removeVariables` 解析:只收非空字符串项,去重但**不 trim** —— 删除必须
  /// 与既有键逐字节一致,任何"顺手规范化"都可能删错键。非法项/非数组一律
  /// 视为没有删除,不影响同一响应里的变量更新。
  static List<String> _asRemovalKeys(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! String || entry.trim().isEmpty) continue;
      if (seen.add(entry)) out.add(entry);
    }
    return out;
  }

  /// `imagePrompts` 数组解析:只收非空字符串项(非字符串/空串/字面 "null" 丢弃,
  /// 坏项不报废整轮,C2);非数组或解析后为空 → null(视同没有多张)。
  static List<String>? _asPromptList(Object? raw) {
    if (raw is! List) return null;
    final out = <String>[];
    for (final e in raw) {
      if (e is String) {
        final t = e.trim();
        if (t.isNotEmpty && t != 'null') out.add(t);
      }
    }
    return out.isEmpty ? null : out;
  }

  /// 变量映射:保留原键,仅转换标量值;任一字段无效则整批失败。
  static Map<String, String>? _asStringMap(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (entry.key.trim().isEmpty ||
          !(value is String ||
              value is bool ||
              (value is num && value.isFinite))) {
        return null;
      }
      out[entry.key] = value.toString();
    }
    return out;
  }
}
