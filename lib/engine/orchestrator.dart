/// 后台维护编排器:读取候选上下文 → 驱动 `BackgroundEngine` → 变量条件写回
/// → 拆分后台生图任务。
///
/// 只维护快状态(变量/生图);记忆与生图指导仅经用户主动的初始化/重生成
/// 路径。维护失败返回可区分的原因,不写变量、不推进游标;生图失败是
/// best-effort,只经回调提示。写入的最终权限与上限由 `VariableRepository`
/// 在其事务内裁定。
library;

import 'dart:async';
import 'dart:io' show Platform;

import '../backend/image_backend.dart';
import '../backend/image_downloader.dart';
import '../context/context_assembler.dart';
import '../data/image_guide_repository.dart';
import '../data/memory_repository.dart';
import '../data/message_repository.dart';
import '../data/variable_repository.dart';
import '../models/app_settings.dart';
import '../models/character_card.dart';
import '../models/image_result.dart';
import '../models/message.dart';
import '../models/token_usage.dart';
import '../models/variable.dart';
import '../models/worldbook_entry.dart';
import 'background_engine.dart';

/// 编排器一轮后台维护的结果。
///
/// 三种形态互斥:成功带出 [result](可能附带游标/生图任务);良性跳过
/// [skipped]=true(无对话可维护、功能未选中或无可写内容);失败时
/// [failureReason] 非空(引擎调用出错/解析失败/被取消)。变量在写回期间被
/// 人工修改时以 [skipped]+[variableConflict] 返回,整轮结果丢弃。调用方据此
/// 区分"可维护内容为空"与"调用出错",并且只在成功轮次推进变量游标、记录
/// `/rerun` 重放窗口。
class BackgroundTurnResult {
  /// 成功轮次的状态更新;跳过/失败时为 null。
  final BackgroundResult? result;

  /// 本轮是否良性跳过(不是错误,展示跳过文案即可)。
  final bool skipped;

  /// 跳过原因(面向状态的单行说明);仅 [skipped] 时有值。
  final String skippedReason;

  /// 失败细分原因:仅 [skipped]=false 且 [result]=null 时有值(引擎失败)。
  final BackgroundFailureReason? failureReason;

  /// 引擎失败的诊断摘要(后端错误消息 / 解析失败响应片段),供状态面板披露;
  /// 仅 [failureReason] 非空时可能有值。
  final String? failureDetail;

  /// 变量增量游标:本批最后一条消息的 seq;仅变量真正执行时非空。
  /// 调用方只在成功轮次写回它,失败不推进进度。
  final int? cursorSeq;

  /// 是否还有未处理的变量增量(本批被 [maxVariableMessages] 截断)。
  final bool hasMoreVariables;

  /// 本轮实际送给后台的变量增量窗口(前一条 seq / 末条 seq)。仅变量真正执行时
  /// 非空 —— 控制器记下它,`/rerun` 才能忠实重放同一批对话;从 [cursorSeq] 与
  /// [hasMoreVariables] 反推会在无游标 bootstrap / 补批场景下失真。
  final int? processedAfterSeq;
  final int? processedThroughSeq;

  /// 本轮是否**真正启动了**后台生图(已拿到场景描述并发出请求)。仅"轮到生图"
  /// 不算消费:模型漏掉图像描述或变量补批把生图推到后续轮次时保持 false,
  /// 由控制器把生图机会留给之后的轮次。
  final bool imageHandled;

  /// 版本条件写回失败(期间变量被人工修改),本轮结果整体丢弃。
  final bool variableConflict;

  /// 本轮拆出去的后台生图任务(与状态写回解耦)。调用方可选地 await 它
  /// 以收敛图片落库(测试用);控制器无需等待 —— 图片落库后经 [onImagePlaced]
  /// 通知刷新。
  final Future<void>? imageTask;

  BackgroundTurnResult._({
    this.result,
    this.skipped = false,
    this.skippedReason = '',
    this.failureReason,
    this.failureDetail,
    this.cursorSeq,
    this.hasMoreVariables = false,
    this.processedAfterSeq,
    this.processedThroughSeq,
    this.imageHandled = false,
    this.variableConflict = false,
    this.imageTask,
  });

  /// 成功轮:带出状态更新与可选游标/生图任务。
  factory BackgroundTurnResult.applied(
    BackgroundResult r, {
    int? cursorSeq,
    bool hasMoreVariables = false,
    int? processedAfterSeq,
    int? processedThroughSeq,
    bool imageHandled = false,
    Future<void>? imageTask,
  }) => BackgroundTurnResult._(
    result: r,
    cursorSeq: cursorSeq,
    hasMoreVariables: hasMoreVariables,
    processedAfterSeq: processedAfterSeq,
    processedThroughSeq: processedThroughSeq,
    imageHandled: imageHandled,
    imageTask: imageTask,
  );

  /// 良性跳过:无内容可维护或功能未选中,[reason] 面向状态展示。
  factory BackgroundTurnResult.skipped(String reason) =>
      BackgroundTurnResult._(skipped: true, skippedReason: reason);

  /// 版本条件写回失败:变量期间被人工修改,整轮结果丢弃。
  factory BackgroundTurnResult.conflict() => BackgroundTurnResult._(
    skipped: true,
    variableConflict: true,
    skippedReason: '变量已被修改,已丢弃旧后台结果',
  );

  /// 失败轮:带细分原因与可选诊断摘要,调用方不得推进游标。
  factory BackgroundTurnResult.failed([
    BackgroundFailureReason reason = BackgroundFailureReason.backendError,
    String? detail,
  ]) => BackgroundTurnResult._(failureReason: reason, failureDetail: detail);
}

/// 后台一张图片落库的位置:新追加的行或原地替换的既有行(后者带原行 messageId)。
/// 控制器据此刷新消息列表、累计"上一轮后台生成的图片"(供 `/rerun` 原地重绘)。
typedef BackgroundImagePlacement = ({
  int messageId,
  String prompt,
  bool replaced,
});

/// 后台重跑时"原地替换"的目标:消息 id + 该行当前的生图描述(条件更新的并发保护)。
typedef ImageReplaceTarget = ({int messageId, String expectedPrompt});

/// 编排器:主写引擎产出后驱动后台引擎做一次**快状态**维护(变量/生图)。
///
/// 读取候选(当前变量 / 最近对话增量 + 会话生图指导)→ 后台引擎 → 落库。
/// 记忆与生图指导不逐轮改写,只经用户主动的 [initializeMemory] /
/// [regenerateMemory] / [initializeImageGuide] 路径;快状态轮里它们只作为
/// 生图的只读锚定输入。
class Orchestrator {
  /// 后台 LLM 引擎(一轮 JSON 状态维护)。
  final BackgroundEngine engine;

  /// 变量仓库;条件写回、权限二次校验与删除上限都在其事务内完成。
  final VariableRepository variables;

  /// 长期记忆仓库(仅主动初始化/重生成路径使用)。
  final MemoryRepository memories;

  /// 消息仓库;读取增量窗口、落库后台生图。
  final MessageRepository messages;

  /// 会话级生图指导仓库(生图轮的只读输入)。
  final ImageGuideRepository imageGuides;

  /// 后台生图后端;null 表示不执行生图(变量维护不受影响)。
  final ImageBackend? imageBackend;

  /// 后台生图**每张落库后**回调(控制器据此刷新消息列表;多张时逐张触发)。
  /// 不传则图片落库后无通知。
  final void Function(BackgroundImagePlacement placement)? onImagePlaced;

  /// 后台生图生成/下载失败时回调(控制器据此把「图片生成中」改为失败文案)。
  /// 失败本身仍是 best-effort 静默 —— 该回调只用于状态展示,不影响已生效的
  /// 状态更新(变量)。[detail] 是首个失败原因的单行摘要(可能为空)。
  final void Function(String? detail)? onImageFailed;

  Orchestrator(
    this.engine,
    this.variables,
    this.memories,
    this.messages,
    this.imageGuides, {
    this.imageBackend,
    this.onImagePlaced,
    this.onImageFailed,
  });

  /// 执行一轮快状态维护:组装候选上下文 → 后台引擎(必要时补一次仅图像
  /// 调用)→ 变量版本条件写回 → 拆出后台生图任务。
  ///
  /// 约束与失败语义:
  /// - 每批变量增量至多 [maxVariableMessages] 条;有剩余时生图推迟到后续
  ///   轮次(控制器同一会话内最多连续两轮,剩余增量留待下次触发);
  /// - 变量写回以快照 revision 做条件更新:期间人工改动会让整轮结果失效并
  ///   返回 [BackgroundTurnResult.conflict],不写任何数据;
  /// - `agent_access` 三档权限与单轮删除上限 5 个由 `VariableRepository`
  ///   在事务内二次校验,这里传入的可删/只读列表只用于提示词;LLM 只能经
  ///   显式 `removeVariables` 请求删除,`variableRemovals` 为空即不删;
  /// - [confirmVariableDeletions] 为严格模式:可删键只写待确认提案,用户
  ///   在状态面板确认后才移入回收站;非严格模式下执行的删除同样先进
  ///   `variable_trash`(可恢复);
  /// - 引擎错误/解析失败/取消返回 [BackgroundTurnResult.failed],此时本轮
  ///   未写变量,调用方不得推进游标;生图任务与状态写回解耦,单张失败只
  ///   跳过该张;
  /// - `/rerun` 由 [rerunContext] 标识,[imageReplaceTargets] 给出上一轮
  ///   图片落点:条件更新(id + 原描述 + 仍有图)成功则原地替换,否则追加,
  ///   不静默删除用户可见的消息行。
  ///
  /// [afterSeq]/[throughSeq] 限定本轮重放窗口(变量增量游标);
  /// [temperature]/[maxTokens]/[reasoningLevel]/[tier] 只影响后台请求,
  /// 与主写设置解耦。
  Future<BackgroundTurnResult> runAfterTurn({
    required int sessionId,
    required String model,
    BackgroundFeatures features = const BackgroundFeatures(),
    bool confirmVariableDeletions = false,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double? temperature,
    int? maxTokens,

    /// 后台请求的推理强度(独立于主对话的设置):openai 兼容端点映射
    /// reasoning_effort,anthropic 映射 thinking 预算;默认 off 不发送。
    ReasoningLevel reasoningLevel = ReasoningLevel.off,

    /// 输出上限档位:透传给后台引擎,决定首试请求的 max_tokens。
    BackgroundOutputTier tier = BackgroundOutputTier.standard,
    int? afterSeq,
    int? throughSeq,
    int imageCount = 1,
    Set<String> stripSkillNames = const {},
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    bool characterAnchor = true,
    bool memoryAnchor = true,

    /// 后台重跑:按位置尝试原地替换这些既有图片消息(目标被删/清图/描述已改时
    /// 该位置回退为追加)。普通维护不传,全部追加。
    List<ImageReplaceTarget> imageReplaceTargets = const [],

    /// 非 null 表示这次是 `/rerun`:后台提示词据此告知模型并携带用户方向/
    /// 上一轮图片描述。普通维护不传。
    RerunContext? rerunContext,
  }) async {
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    if (!features.variables && !(features.image && imageBackend != null)) {
      return BackgroundTurnResult.skipped('未选中可执行的维护功能,后台维护已跳过');
    }
    final allMessages = await messages.bySession(sessionId);
    final conversation = allMessages
        .where(
          (m) =>
              m.isChat &&
              m.role != 'system' &&
              m.content.isNotEmpty &&
              (throughSeq == null || m.seq <= throughSeq),
        )
        .toList();
    if (conversation.isEmpty) {
      return BackgroundTurnResult.skipped('无对话可维护,后台维护已跳过');
    }
    final recent = conversation.where((m) => !m.isCompacted).toList();
    final delta = features.variables
        ? (afterSeq == null
              ? _trim(conversation, 3)
              : conversation.where((m) => m.seq > afterSeq).toList())
        : const <Message>[];
    final batch = delta.take(maxVariableMessages).toList();
    final hasMore = delta.length > batch.length;
    final imageDue = features.image && !hasMore;
    final runFeatures = BackgroundFeatures(
      variables: features.variables && batch.isNotEmpty,
      image: imageDue && imageBackend != null && recent.isNotEmpty,
    );
    if (!runFeatures.anyEnabled ||
        (!features.variables &&
            afterSeq != null &&
            !recent.any((m) => m.seq > afterSeq))) {
      return BackgroundTurnResult.skipped('无新对话可维护,本轮快状态维护已跳过');
    }
    final (snapshot, guideList, memoryRows) = await (
      runFeatures.variables
          ? variables.snapshot(sessionId)
          : Future.value((
              values: const <String, String>{},
              access: const <String, VariableAccess>{},
              revision: 0,
            )),
      runFeatures.image
          ? imageGuides.bySession(sessionId)
          : Future.value(const <Never>[]),
      runFeatures.image && memoryAnchor
          ? memories.bySession(sessionId)
          : Future.value(const <Never>[]),
    ).wait;
    final reference = runFeatures.image
        ? _trim(recent, 6)
        : _trim(conversation.where((m) => m.seq < batch.first.seq).toList(), 2);
    List<Message> strip(List<Message> rows) => [
      for (final m in rows)
        m.copyWith(
          content: ContextAssembler.withoutSkillTokens(
            m.content,
            stripSkillNames,
          ),
        ),
    ];
    final deletableVariables = <String>{
      for (final entry in snapshot.access.entries)
        if (entry.value == VariableAccess.full) entry.key,
    };
    final readonlyVariables = <String>{
      for (final entry in snapshot.access.entries)
        if (entry.value == VariableAccess.readonly) entry.key,
    };
    final outcome = await engine.run(
      model: model,
      variables: snapshot.values,
      history: strip(reference),
      variableHistory: strip(batch),
      features: runFeatures,
      deletableVariables: deletableVariables,
      readonlyVariables: readonlyVariables,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      tier: tier,
      imageCount: imageCount,
      imageGuide: guideList.isEmpty ? null : guideList.first.content,
      memory: memoryRows.isEmpty
          ? null
          : memoryRows.map((m) => m.content).join('\n'),
      character: characterAnchor ? character : null,
      worldbook: worldbook,
      rerunContext: rerunContext,
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(outcome.reason, outcome.detail);
    }
    var result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    if (runFeatures.variables) {
      final applied = await variables.compareAndApply(
        sessionId,
        expectedRevision: snapshot.revision,
        updates: result.variableUpdates,
        removals: result.variableRemovals,
        confirmRemovals: confirmVariableDeletions,
        shouldCancel: shouldCancel,
      );
      if (!applied.applied) {
        return (shouldCancel?.call() ?? false)
            ? BackgroundTurnResult.failed(BackgroundFailureReason.cancelled)
            : BackgroundTurnResult.conflict();
      }
      // 摘要与落库结果必须一致:被权限拒绝的更新、超过上限的删除、严格模式
      // 下只生成提案的删除,都不能在摘要里冒充"已应用"。
      result = BackgroundResult(
        variableUpdates: applied.updates,
        variableRemovals: applied.removals,
        variableRemovalProposals: applied.proposedRemovals,
        imagePrompt: result.imagePrompt,
        imagePrompts: result.imagePrompts,
        usage: result.usage,
        memoryUpdate: result.memoryUpdate,
        imageGuide: result.imageGuide,
      );
    }
    var prompts = _imagePrompts(result);
    // 变量与生图同开时,模型偶发只回变量对象、把图像描述整段漏掉:
    // 变量任务成功不能顺带作废本轮生图机会。这里补一次**仅图像**的调用 ——
    // 没有变量块分散注意力,也不受"整个响应只取到第一个 JSON 对象"的解析
    // 边界影响;产出并入本轮结果、用量累加。补调仍拿不到描述才把机会保留
    // (imageHandled=false),由后续轮次继续尝试。
    if (runFeatures.variables &&
        runFeatures.image &&
        prompts.isEmpty &&
        !(shouldCancel?.call() ?? false)) {
      final retry = await engine.run(
        model: model,
        variables: snapshot.values,
        history: strip(reference),
        features: const BackgroundFeatures(variables: false, image: true),
        shouldCancel: shouldCancel,
        cancelSignal: cancelSignal,
        temperature: temperature,
        maxTokens: maxTokens,
        reasoningLevel: reasoningLevel,
        tier: tier,
        imageCount: imageCount,
        imageGuide: guideList.isEmpty ? null : guideList.first.content,
        memory: memoryRows.isEmpty
            ? null
            : memoryRows.map((m) => m.content).join('\n'),
        character: characterAnchor ? character : null,
        worldbook: worldbook,
        rerunContext: rerunContext,
      );
      if (retry is BackgroundRunSuccess) {
        final retried = retry.result;
        final retriedPrompts = _imagePrompts(retried);
        if (retriedPrompts.isNotEmpty) {
          prompts = retriedPrompts;
          result = BackgroundResult(
            variableUpdates: result.variableUpdates,
            variableRemovals: result.variableRemovals,
            variableRemovalProposals: result.variableRemovalProposals,
            imagePrompt: retried.imagePrompt,
            imagePrompts: retried.imagePrompts,
            usage: TokenUsage(
              inputTokens: result.usage.inputTokens + retried.usage.inputTokens,
              outputTokens:
                  result.usage.outputTokens + retried.usage.outputTokens,
              cachedInputTokens:
                  result.usage.cachedInputTokens +
                  retried.usage.cachedInputTokens,
            ),
          );
        }
      }
    }
    final backend = imageBackend;
    final imageTask = backend != null && runFeatures.image && prompts.isNotEmpty
        ? _generateImage(
            sessionId,
            prompts,
            backend,
            replaceTargets: imageReplaceTargets,
          )
        : null;
    return BackgroundTurnResult.applied(
      result,
      cursorSeq: runFeatures.variables ? batch.last.seq : null,
      hasMoreVariables: hasMore,
      processedAfterSeq: runFeatures.variables ? batch.first.seq - 1 : null,
      processedThroughSeq: runFeatures.variables ? batch.last.seq : null,
      imageHandled: imageTask != null,
      imageTask: imageTask,
    );
  }

  /// 结果里的图像描述:优先多描述数组,回退单描述;都没有时为空列表。
  static List<String> _imagePrompts(BackgroundResult result) =>
      result.imagePrompts ??
      (result.imagePrompt == null ? const <String>[] : [result.imagePrompt!]);

  /// 主动初始化会话长期记忆:新会话记忆为空时,用户点击「生成初始记忆」触发一次,
  /// 依据**角色卡 + 常驻(恒定)世界书**生成一份初始长期记忆并落库;之后用户可
  /// 手动编辑,或经 [regenerateMemory] 依据全量对话重生成。
  ///
  /// 与 [runAfterTurn] 不同,这里没有"无对话可维护"短路 —— 初始化是用户显式
  /// 触发、面向全新会话的操作(新会话本来就没有对话);也只看 memory 一个功能,
  /// 不牵动 变量/生图。
  Future<BackgroundTurnResult> initializeMemory({
    required int sessionId,
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
    final outcome = await engine.runMemoryInit(
      model: model,
      character: character,
      worldbook: worldbook,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      tier: tier,
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(outcome.reason, outcome.detail);
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    final mem = result.memoryUpdate;
    if (mem == null || mem.trim().isEmpty) {
      // 未产出有效记忆(缺字段/空串/字面 null)→ 不落库,良性跳过并给出原因。
      return BackgroundTurnResult.skipped('初始化未产出有效记忆,请重试');
    }
    // 与 runAfterTurn 一致:记忆写入自带事务(MemoryRepository.set),失败即回滚。
    await memories.set(sessionId, mem);
    return BackgroundTurnResult.applied(result);
  }

  /// 全量重生成记忆(用户主动发起,具有所有上下文的请求):把会话全部活跃
  /// 对话连同角色卡、常驻世界书与既有记忆送入 LLM,产出新记忆整段替换落库。
  /// [stripSkillNames]:转录里的 @技能名 记号剥离集合(同 runAfterTurn)。
  Future<BackgroundTurnResult> regenerateMemory({
    required int sessionId,
    required String model,
    required CharacterCard character,
    List<WorldbookEntry> worldbook = const [],
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double? temperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    BackgroundOutputTier tier = BackgroundOutputTier.standard,
    Set<String> stripSkillNames = const {},
  }) async {
    final (allMessages, currentMemories) = await (
      messages.bySession(sessionId),
      memories.bySession(sessionId),
    ).wait;
    final currentMemory = currentMemories.map((m) => m.content).join('\n');
    final outcome = await engine.runMemoryRegenerate(
      model: model,
      character: character,
      history: [
        for (final m in allMessages)
          if (m.isChat)
            m.copyWith(
              content: ContextAssembler.withoutSkillTokens(
                m.content,
                stripSkillNames,
              ),
            )
          else
            m,
      ],
      worldbook: worldbook,
      currentMemory: currentMemory.isEmpty ? null : currentMemory,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      tier: tier,
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(outcome.reason, outcome.detail);
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    final mem = result.memoryUpdate;
    if (mem == null || mem.trim().isEmpty) {
      return BackgroundTurnResult.skipped('重生成未产出有效记忆,请重试');
    }
    await memories.set(sessionId, mem);
    return BackgroundTurnResult.applied(result);
  }

  /// 主动初始化会话生图指导:空指导时,用户点击「生成初始指导」触发一次,
  /// 依据**角色卡 + 常驻世界书**产出定妆外貌/风格基调的英文 tag 指导并落库。
  Future<BackgroundTurnResult> initializeImageGuide({
    required int sessionId,
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
    final outcome = await engine.runImageGuideInit(
      model: model,
      character: character,
      worldbook: worldbook,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      tier: tier,
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(outcome.reason, outcome.detail);
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    final guide = result.imageGuide;
    if (guide == null || guide.trim().isEmpty) {
      return BackgroundTurnResult.skipped('初始化未产出有效生图指导,请重试');
    }
    await imageGuides.set(sessionId, guide);
    return BackgroundTurnResult.applied(result);
  }

  /// 多描述并行发起生图(服务端并行排队,墙钟≈单张),结果并行下载、逐条落库;
  /// 每张落库触发一次 [onImagePlaced] —— 多张时图片在聊天流中逐张浮现,
  /// 不必等全部生成完。单个描述生成失败或单张下载/落库失败只跳过该张
  /// (仍 best-effort);只有一张都没落成时才走 [onImageFailed]。
  ///
  /// [replaceTargets] 非空时(后台重跑 `/rerun`)按位置尝试原地替换既有图片消息:
  /// 条件更新(id + 原描述 + 仍有图)成功则改写该行图片与新描述,不追加新行;
  /// 目标已被删/清图/描述已改则回退追加。新描述多于目标时多出的追加、少于
  /// 目标时旧图保留 —— 不静默删除用户可见的消息行。
  Future<void> _generateImage(
    int sessionId,
    List<String> prompts,
    ImageBackend backend, {
    List<ImageReplaceTarget> replaceTargets = const [],
  }) async {
    final stopwatch = Stopwatch()..start();
    // 先并行收集所有描述的生图结果:单描述失败只丢该张,不拖垮其余。
    // 失败原因随结果带回,全部失败时进状态摘要(此前只知道「失败」)。
    final attempts = await Future.wait([
      for (final p in prompts) _generateOneSafe(p, backend),
    ]);
    final elapsedGen = stopwatch.elapsedMilliseconds;
    final results = [for (final a in attempts) a.result];
    var failureDetail = attempts
        .map((a) => a.error)
        .firstWhere((e) => e != null, orElse: () => null);
    // 每张(每条链接)要落的一条消息:base64 待下载填充,URL 恒保留(下载失败
    // 回退 URL 渲染)。同一条描述返回多张时逐张保留该描述(重新生成按它重绘)。
    // `source` 记录来源描述下标,重跑时据此对齐替换目标(见下方落库循环)。
    final entries = <({int source, String? base64, String? url, String prompt})>[
      for (var i = 0; i < results.length; i++)
        for (final image in results[i].images)
          (source: i, base64: image.base64, url: image.url, prompt: prompts[i]),
    ];
    // 并行下载所有字节:多张时墙钟 = 最慢的那一张,不再串行叠加 —— 每张下载
    // 10~20s 时,两张串行要多等一整张,并行只在最后一张等齐。
    var downloadMs = List<int>.filled(entries.length, 0);
    await Future.wait([
      for (var i = 0; i < entries.length; i++)
        () async {
          final sw = Stopwatch()..start();
          var localBase64 = entries[i].base64;
          if (localBase64 == null && entries[i].url != null) {
            localBase64 = await downloadImageBase64(entries[i].url!);
          }
          downloadMs[i] = sw.elapsedMilliseconds;
          entries[i] = (
            source: entries[i].source,
            base64: localBase64,
            url: entries[i].url,
            prompt: entries[i].prompt,
          );
        }(),
    ]);
    var anyPlaced = false;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final sw = Stopwatch()..start();
      try {
        // 重跑:原地替换上一轮为同一轮生成的图片(条件更新:id + 原描述 +
        // 仍有图)。替换目标与描述一一对应时按**来源描述**取目标 —— 某条描述
        // 本次生成失败不产出条目,按落库顺序取会让后面的图前移,覆盖到失败
        // 描述对应的旧图上。目标已被删/清图/描述已改时返回 false,回退追加。
        final targetIndex = replaceTargets.length == prompts.length
            ? entry.source
            : i;
        final target = targetIndex < replaceTargets.length
            ? replaceTargets[targetIndex]
            : null;
        if (target != null) {
          final replaced = await messages.replaceImage(
            target.messageId,
            imageBase64: entry.base64,
            imageUrl: entry.url,
            expectedPrompt: target.expectedPrompt,
            newImagePrompt: entry.prompt,
          );
          if (replaced) {
            _log(
              '#${i + 1}/${entries.length} 下载 ${downloadMs[i]}ms,原地替换消息 '
              '${target.messageId} 用时 ${sw.elapsedMilliseconds}ms,'
              'base64 ${entry.base64?.length ?? 0} 字符',
            );
            anyPlaced = true;
            onImagePlaced?.call((
              messageId: target.messageId,
              prompt: entry.prompt,
              replaced: true,
            ));
            continue;
          }
        }
        // 云端图只存 URL 时,重启/重建会反复重新拉取 —— 生成时立刻把字节
        // 下载成 base64 随消息落库,气泡渲染永远走本地;下载失败回退 URL 渲染。
        final appended = await messages.append(
          sessionId: sessionId,
          role: 'assistant',
          content: '',
          imageBase64: entry.base64,
          imageUrl: entry.url,
          imagePrompt: entry.prompt,
        );
        _log(
          '#${i + 1}/${entries.length} 下载 ${downloadMs[i]}ms,落库 ${sw.elapsedMilliseconds}ms,'
          'base64 ${entry.base64?.length ?? 0} 字符${entry.base64 == null ? '(下载失败,回退 URL 渲染)' : ''}',
        );
        anyPlaced = true;
        onImagePlaced?.call((
          messageId: appended.id!,
          prompt: entry.prompt,
          replaced: false,
        ));
      } catch (e) {
        // 单张落库失败静默跳过,不拖垮其余几张;原因留给全部失败时的状态摘要。
        failureDetail ??= _shortError(e);
      }
    }
    _log(
      '后台生图总耗时 ${stopwatch.elapsedMilliseconds}ms(含生成 ${elapsedGen}ms + 下载 + 落库,共 ${entries.length} 张)',
    );
    if (!anyPlaced) onImageFailed?.call(failureDetail);
  }

  /// 单个描述生图请求的失败安全版:排队/网络/解析失败返回空结果(调用方丢该张),
  /// 不向并发兄弟请求传播异常。失败原因随结果带回,全部失败时展示在状态摘要里。
  Future<({ImageResult result, String? error})> _generateOneSafe(
    String prompt,
    ImageBackend backend,
  ) async {
    try {
      return (result: await backend.generateImage(prompt), error: null);
    } catch (e) {
      // 失败原因也按 [img] 调试约定透出,release 下由状态面板的失败摘要兜底。
      _log('后台生图失败:$e');
      return (result: const ImageResult([]), error: _shortError(e));
    }
  }

  /// 失败诊断摘要:压成单行并截断(状态面板文案用,防止长错误刷屏)。
  static String _shortError(Object error) {
    final line = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= 120 ? line : '${line.substring(0, 120)}…';
  }

  /// 按历史上限裁剪转录(取末尾 [limit] 条);limit<=0 或不足时不裁剪。
  List<Message> _trim(List<Message> msgs, int limit) {
    if (limit <= 0 || msgs.length <= limit) return msgs;
    return msgs.sublist(msgs.length - limit);
  }

  /// 每批送给后台的变量增量消息条数上限;剩余部分由控制器下一轮继续处理,
  /// 避免单次请求被整段长对话撑爆。
  static const int maxVariableMessages = 12;

  /// 定位用计时日志:仅 debug 直跑(flutter run)可见,测试进程与 release 静默。
  static void _log(String message) {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (const bool.fromEnvironment('dart.vm.product')) return;
    // ignore: avoid_print
    print('[img] $message');
  }
}
