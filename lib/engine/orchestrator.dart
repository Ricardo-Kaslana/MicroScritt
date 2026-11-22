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

import 'package:flutter/foundation.dart';

import '../backend/image_backend.dart';
import '../backend/image_downloader.dart';
import '../context/context_assembler.dart';
import '../data/image_codec.dart';
import '../data/image_guide_repository.dart';
import '../data/memory_repository.dart';
import '../data/message_repository.dart';
import '../data/variable_repository.dart';
import '../models/app_settings.dart';
import '../models/character_card.dart';
import '../models/image_guide.dart';
import '../models/image_result.dart';
import '../models/llm_provider.dart';
import '../models/memory.dart';
import '../models/message.dart';
import '../models/token_usage.dart';
import '../models/variable.dart';
import '../models/worldbook_entry.dart';
import 'agent/agent_events.dart';
import 'agent/agent_runner.dart';
import 'background_agent.dart';
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

  /// 变量条件写回失败(期间变量被人工修改),本轮结果整体丢弃。
  final bool variableConflict;

  /// 本轮已发生的 token 用量(含失败/取消前的请求)。失败轮同样可能已计费,
  /// 控制器据此写 `reported` 用量行而不是记零。
  final TokenUsage usage;

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
    this.usage = const TokenUsage(),
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
  factory BackgroundTurnResult.conflict({
    TokenUsage usage = const TokenUsage(),
  }) => BackgroundTurnResult._(
    skipped: true,
    variableConflict: true,
    skippedReason: '变量已被修改,已丢弃旧后台结果',
    usage: usage,
  );

  /// 失败轮:带细分原因与可选诊断摘要,调用方不得推进游标。
  factory BackgroundTurnResult.failed([
    BackgroundFailureReason reason = BackgroundFailureReason.backendError,
    String? detail,
    TokenUsage usage = const TokenUsage(),
  ]) => BackgroundTurnResult._(
    failureReason: reason,
    failureDetail: detail,
    usage: usage,
  );
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

/// 一轮维护的候选窗口(legacy 与 agentic 共用同一份构建):增量批/功能裁剪/
/// 快照/锚定输入/参考消息/技能剥离/权限集。maxSeq 供 agentic 的 readHistory
/// 在调用方未给 throughSeq 时兜底 clamp。
typedef _PreparedWindow = ({
  List<Message> batch,
  bool hasMore,
  BackgroundFeatures runFeatures,
  ({
    Map<String, String> values,
    Map<String, VariableAccess> access,
    int revision,
  })
  snapshot,
  List<ImageGuide> guideList,
  List<Memory> memoryRows,
  List<Message> reference,
  List<Message> Function(List<Message>) strip,
  Set<String> deletableVariables,
  Set<String> readonlyVariables,
  int maxSeq,
});

/// 编排器:主写引擎产出后驱动后台引擎做一次**快状态**维护(变量/生图)。
///
/// 读取候选(当前变量 / 最近对话增量 + 会话生图指导)→ 后台引擎 → 落库。
/// 记忆与生图指导不逐轮改写,只经用户主动的 [initializeMemory] /
/// [regenerateMemory] / [initializeImageGuide] / [regenerateImageGuide]
/// 路径;快状态轮里它们只作为生图的只读锚定输入。
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
  /// [temperature] 为本次后台所用模型配置的采样温度(与主写同源:后台专用
  /// 模型取它自己的配置),编排器与引擎都不另设默认或夹取;[maxTokens] 即
  /// 模型配置的「最大输出 tokens」,后台不另设档位。
  Future<BackgroundTurnResult> runAfterTurn({
    required int sessionId,
    required String model,
    BackgroundFeatures features = const BackgroundFeatures(),
    bool confirmVariableDeletions = false,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,

    /// 后台请求的推理强度(独立于主对话的设置):openai 兼容端点映射
    /// reasoning_effort,anthropic 映射 thinking 预算;默认 off 不发送。
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
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

    /// Agentic 增强开关(legacy 忽略):变量注入主写附件 / 下一步建议。
    /// 生效还要求变量维护开启(注入)与 Agentic 模式(由调用方保证)。
    bool variableInjection = false,
    bool nextSuggestions = false,

    /// 运行模式:legacy 单发(默认,零行为变化)/ agentic 多步工具循环。
    /// hybrid 的每轮维护仍按 legacy 跑;周期审计是控制器另行发起的独立
    /// [runAudit] 入口(不经此 mode 分流)。设置项与控制器接线 P3,审计 P4。
    BackgroundMode mode = BackgroundMode.legacy,

    /// agentic 每逻辑步回调(用量明细 + 进度文案的数据源);legacy 不触发。
    void Function(AgentStepEvent)? onAgentStep,
  }) async {
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    // 会话启用生图(与本轮是否生图分开):agentic 稳定前缀的工具面/契约按
    // 它注册,变量积压的纯变量轮与后续生图轮共享同一缓存前缀。
    final imageCapable = features.image && imageBackend != null;
    if (!features.variables && !imageCapable) {
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
    final imageDue = imageCapable && !hasMore;
    final runFeatures = BackgroundFeatures(
      variables: features.variables && batch.isNotEmpty,
      image: imageDue && recent.isNotEmpty,
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
      // 记忆锚定开启时,agentic 变量-only 轮也取记忆(readMemory/proposeMemory
      // 按需取证);image 轮进锚定段;legacy/hybrid 的变量轮不读。
      memoryAnchor && (runFeatures.image || mode == BackgroundMode.agentic)
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
    if (mode == BackgroundMode.agentic) {
      return _runAgenticTurn(
        sessionId: sessionId,
        model: model,
        imageTools: imageCapable,
        window: (
          batch: batch,
          hasMore: hasMore,
          runFeatures: runFeatures,
          snapshot: snapshot,
          guideList: guideList,
          memoryRows: memoryRows,
          reference: reference,
          strip: strip,
          deletableVariables: deletableVariables,
          readonlyVariables: readonlyVariables,
          maxSeq: conversation.last.seq,
        ),
        throughSeq: throughSeq,
        confirmVariableDeletions: confirmVariableDeletions,
        shouldCancel: shouldCancel,
        cancelSignal: cancelSignal,
        temperature: temperature,
        maxTokens: maxTokens,
        reasoningLevel: reasoningLevel,
        imageCount: imageCount,
        stripSkillNames: stripSkillNames,
        character: characterAnchor ? character : null,
        worldbook: worldbook,
        imageReplaceTargets: imageReplaceTargets,
        rerunContext: rerunContext,
        variableInjection: variableInjection,
        nextSuggestions: nextSuggestions,
        memoryAnchor: memoryAnchor,
        onAgentStep: onAgentStep,
      );
    }
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
      return BackgroundTurnResult.failed(
        outcome.reason,
        outcome.detail,
        outcome.usage,
      );
    }
    var result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        result.usage,
      );
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
            ? BackgroundTurnResult.failed(
                BackgroundFailureReason.cancelled,
                null,
                result.usage,
              )
            : BackgroundTurnResult.conflict(usage: result.usage);
      }
      // 摘要与落库结果必须一致:被权限拒绝的更新、超过上限的删除、严格模式
      // 下只生成提案的删除,都不能在摘要里冒充"已应用"。
      result = BackgroundResult(
        variableUpdates: applied.updates,
        addedVariables: _countAdditions(snapshot.values, applied.updates),
        variableRemovals: applied.removals,
        variableRemovalProposals: applied.proposedRemovals,
        imagePrompt: result.imagePrompt,
        imagePrompts: result.imagePrompts,
        usage: result.usage,
        memoryUpdate: result.memoryUpdate,
        imageGuide: result.imageGuide,
      );
    }
    var prompts = _clampImagePrompts(_imagePrompts(result), imageCount);
    // 补调即使没产出描述(或失败)也可能已计费:用量必须并回本轮结果,
    // 不能只在成功产出描述时记账。
    TokenUsage? retryUsage;
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
        final retriedPrompts = _clampImagePrompts(
          _imagePrompts(retried),
          imageCount,
          source: '补调',
        );
        if (retriedPrompts.isNotEmpty) {
          prompts = retriedPrompts;
          result = BackgroundResult(
            variableUpdates: result.variableUpdates,
            addedVariables: result.addedVariables,
            variableRemovals: result.variableRemovals,
            variableRemovalProposals: result.variableRemovalProposals,
            imagePrompt: retried.imagePrompt,
            imagePrompts: retried.imagePrompts,
            usage: result.usage + retried.usage,
            memoryProposal: result.memoryProposal,
          );
        } else {
          retryUsage = retried.usage;
        }
      } else if (retry is BackgroundRunFailure) {
        retryUsage = retry.usage;
      }
    }
    if (retryUsage != null) result = result.withAddedUsage(retryUsage);
    final backend = imageBackend;
    final imageTask = backend != null && runFeatures.image && prompts.isNotEmpty
        ? _generateImage(
            sessionId,
            prompts,
            backend,
            replaceTargets: imageReplaceTargets,
            shouldCancel: shouldCancel,
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

  /// agentic 路径:与 legacy 同一份候选窗口 → 维护 profile 多步循环 →
  /// 原 compareAndApply 一次原子提交 → 复用生图拆分任务。暂存只在内存,
  /// 失败/取消/护栏全丢弃;返回形状与 legacy 同构,控制器游标/待处理合并/
  /// `/rerun` 窗口逻辑零改。不做 image-only 补调:agent 拥有 setImagePrompts
  /// 工具,finish 未给描述即本轮不生图(机会保留后续轮),也避免混模式的
  /// 轮级用量行与逐步入账冲突。
  Future<BackgroundTurnResult> _runAgenticTurn({
    required int sessionId,
    required String model,
    required _PreparedWindow window,
    required bool confirmVariableDeletions,
    required bool imageTools,
    int? throughSeq,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    int imageCount = 1,
    Set<String> stripSkillNames = const {},
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    List<ImageReplaceTarget> imageReplaceTargets = const [],
    RerunContext? rerunContext,
    bool variableInjection = false,
    bool nextSuggestions = false,
    bool memoryAnchor = true,
    void Function(AgentStepEvent)? onAgentStep,
  }) async {
    final batch = window.batch;
    final hasMore = window.hasMore;
    final runFeatures = window.runFeatures;
    final snapshot = window.snapshot;
    final guideList = window.guideList;
    final memoryRows = window.memoryRows;
    final reference = window.reference;
    final strip = window.strip;
    final maxSeq = window.maxSeq;

    // 读历史只读回调:绑定本会话 + clamp 到本轮窗口上界(throughSeq 缺省
    // 用全会话最大 seq),技能 token 与主上下文同样剥离。内核不 import data
    // 层 —— 读库经此注入闭包。afterSeq 走向下分页,供 aroundSeq 邻近窗口。
    Future<List<Message>> readHistory({
      int? beforeSeq,
      int? afterSeq,
      required int limit,
    }) {
      final cap = (throughSeq ?? maxSeq) + 1;
      if (afterSeq != null) {
        if (afterSeq >= cap) return Future.value(const []);
        return messages
            .bySessionPageAfter(
              sessionId,
              afterSeq: afterSeq,
              beforeSeq: cap,
              limit: limit,
            )
            .then(strip);
      }
      final before = beforeSeq == null || beforeSeq > cap ? cap : beforeSeq;
      return messages
          .bySessionPageBefore(sessionId, beforeSeq: before, limit: limit)
          .then(strip);
    }

    Future<List<HistorySearchHit>> searchHistory(
      String query, {
      int limit = 5,
    }) async {
      final cap = (throughSeq ?? maxSeq) + 1;
      final hits = await messages.searchInSession(
        sessionId,
        query,
        limit: limit,
        beforeSeq: cap,
      );
      return [
        for (final hit in hits)
          (
            seq: hit.seq,
            role: hit.role,
            content: ContextAssembler.withoutSkillTokens(
              hit.content,
              stripSkillNames,
            ),
          ),
      ];
    }

    // 严格模式下待确认删除键:validateStaged 用它在提交前提示重复占帽。
    Future<Set<String>> Function()? pendingDeletions;
    if (confirmVariableDeletions) {
      pendingDeletions = () async => (await variables.pendingDeletions(
        sessionId,
      )).map((proposal) => proposal.key).toSet();
    }

    final built = MaintenanceProfile.build(
      backend: engine.backend,
      model: model,
      variables: snapshot.values,
      access: snapshot.access,
      history: strip(reference),
      variableHistory: strip(batch),
      features: runFeatures,
      imageCount: imageCount,
      imageTools: imageTools,
      imageGuide: guideList.isEmpty ? null : guideList.first.content,
      memory: memoryRows.isEmpty
          ? null
          : memoryRows.map((m) => m.content).join('\n'),
      character: character,
      worldbook: worldbook,
      rerunContext: rerunContext,
      variableInjection: runFeatures.variables && variableInjection,
      nextSuggestions: nextSuggestions,
      memoryTools: memoryAnchor,
      readHistory: readHistory,
      searchHistory: searchHistory,
      pendingDeletions: pendingDeletions,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      onStep: onAgentStep,
    );
    final outcome = await AgentRunner.run(built.spec);
    if (outcome is AgentRunFailure) {
      final reason = switch (outcome.reason) {
        AgentFailureReason.cancelled => BackgroundFailureReason.cancelled,
        AgentFailureReason.backendError => BackgroundFailureReason.backendError,
        AgentFailureReason.guardrail => BackgroundFailureReason.parseFailure,
      };
      return BackgroundTurnResult.failed(
        reason,
        outcome.detail,
        outcome.totalUsage,
      );
    }
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        (outcome as AgentRunSuccess).totalUsage,
      );
    }
    final staging = built.staging;
    var result = BackgroundResult(
      variableUpdates: staging.updates,
      variableRemovals: staging.removals,
      imagePrompts: staging.imagePrompts,
      nextSuggestions: staging.nextSuggestions ?? const [],
      memoryProposal: staging.memoryProposal,
      usage: (outcome as AgentRunSuccess).totalUsage,
    );
    if (runFeatures.variables) {
      final applied = await variables.compareAndApply(
        sessionId,
        expectedRevision: snapshot.revision,
        updates: staging.updates,
        removals: staging.removals,
        confirmRemovals: confirmVariableDeletions,
        shouldCancel: shouldCancel,
      );
      if (!applied.applied) {
        return (shouldCancel?.call() ?? false)
            ? BackgroundTurnResult.failed(
                BackgroundFailureReason.cancelled,
                null,
                result.usage,
              )
            : BackgroundTurnResult.conflict(usage: result.usage);
      }
      // 注入值必须按提交后的最终板解析:权限拒绝的更新保留基线,执行的删除
      // 剔除对应键,严格模式下仅生成提案的删除仍留在板上。
      final finalBoard = {...snapshot.values, ...applied.updates};
      for (final key in applied.removals) {
        finalBoard.remove(key);
      }
      final injected = <String, String>{};
      for (final key in staging.injectionKeys ?? const <String>[]) {
        final value = finalBoard[key];
        if (value != null) injected[key] = value;
      }
      // 摘要与落库结果一致:权限拒绝/超限/严格提案不得冒充"已应用"。
      result = BackgroundResult(
        variableUpdates: applied.updates,
        addedVariables: _countAdditions(snapshot.values, applied.updates),
        variableRemovals: applied.removals,
        variableRemovalProposals: applied.proposedRemovals,
        imagePrompts: staging.imagePrompts,
        injectedVariables: injected,
        nextSuggestions: staging.nextSuggestions ?? const [],
        memoryProposal: staging.memoryProposal,
        usage: result.usage,
      );
    }
    final prompts = _clampImagePrompts(
      staging.imagePrompts ?? const <String>[],
      imageCount,
      source: 'agentic',
    );
    final backend = imageBackend;
    final imageTask = backend != null && runFeatures.image && prompts.isNotEmpty
        ? _generateImage(
            sessionId,
            prompts,
            backend,
            replaceTargets: imageReplaceTargets,
            shouldCancel: shouldCancel,
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

  /// 变量板审计(hybrid 周期):独立于 delta 维护的一次 agent 轮。读全量变量板
  /// + 权限 + 最近 [AuditProfile.maxAuditHistoryMessages] 条宽历史窗取证,经审计
  /// profile 多步合并近义键/修剪陈旧事实/修正矛盾,finish 后走原 compareAndApply
  /// 一次原子提交。**不推进 delta 游标、不生图、不消费增量** —— 返回的 cursorSeq
  /// 恒 null,调用方据此与正常维护轮区分。空板/空对话良性跳过(省一次 LLM 调用);
  /// 失败/冲突 best-effort,只进状态面板。宽窗含压缩行(陈旧事实证据常在已压缩段)。
  Future<BackgroundTurnResult> runAudit({
    required int sessionId,
    required String model,
    bool confirmVariableDeletions = false,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    int? throughSeq,
    Set<String> stripSkillNames = const {},
    void Function(AgentStepEvent)? onAgentStep,
  }) async {
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
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
      return BackgroundTurnResult.skipped('无对话可审计,审计已跳过');
    }
    final snapshot = await variables.snapshot(sessionId);
    if (snapshot.values.isEmpty) {
      return BackgroundTurnResult.skipped('变量板为空,审计已跳过');
    }
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    final history = _trim(conversation, AuditProfile.maxAuditHistoryMessages);
    List<Message> strip(List<Message> rows) => [
      for (final m in rows)
        m.copyWith(
          content: ContextAssembler.withoutSkillTokens(
            m.content,
            stripSkillNames,
          ),
        ),
    ];
    final maxSeq = conversation.last.seq;
    // 读历史只读回调:绑定本会话 + clamp 到审计窗上界(同 _runAgenticTurn)。
    Future<List<Message>> readHistory({
      int? beforeSeq,
      int? afterSeq,
      required int limit,
    }) {
      final cap = (throughSeq ?? maxSeq) + 1;
      if (afterSeq != null) {
        if (afterSeq >= cap) return Future.value(const []);
        return messages
            .bySessionPageAfter(
              sessionId,
              afterSeq: afterSeq,
              beforeSeq: cap,
              limit: limit,
            )
            .then(strip);
      }
      final before = beforeSeq == null || beforeSeq > cap ? cap : beforeSeq;
      return messages
          .bySessionPageBefore(sessionId, beforeSeq: before, limit: limit)
          .then(strip);
    }

    Future<List<HistorySearchHit>> searchHistory(
      String query, {
      int limit = 5,
    }) async {
      final cap = (throughSeq ?? maxSeq) + 1;
      final hits = await messages.searchInSession(
        sessionId,
        query,
        limit: limit,
        beforeSeq: cap,
      );
      return [
        for (final hit in hits)
          (
            seq: hit.seq,
            role: hit.role,
            content: ContextAssembler.withoutSkillTokens(
              hit.content,
              stripSkillNames,
            ),
          ),
      ];
    }

    Future<Set<String>> Function()? pendingDeletions;
    if (confirmVariableDeletions) {
      pendingDeletions = () async => (await variables.pendingDeletions(
        sessionId,
      )).map((proposal) => proposal.key).toSet();
    }

    final built = AuditProfile.build(
      backend: engine.backend,
      model: model,
      variables: snapshot.values,
      access: snapshot.access,
      history: strip(history),
      readHistory: readHistory,
      searchHistory: searchHistory,
      pendingDeletions: pendingDeletions,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      onStep: onAgentStep,
    );
    final outcome = await AgentRunner.run(built.spec);
    if (outcome is AgentRunFailure) {
      final reason = switch (outcome.reason) {
        AgentFailureReason.cancelled => BackgroundFailureReason.cancelled,
        AgentFailureReason.backendError => BackgroundFailureReason.backendError,
        AgentFailureReason.guardrail => BackgroundFailureReason.parseFailure,
      };
      return BackgroundTurnResult.failed(
        reason,
        outcome.detail,
        outcome.totalUsage,
      );
    }
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        (outcome as AgentRunSuccess).totalUsage,
      );
    }
    final staging = built.staging;
    final applied = await variables.compareAndApply(
      sessionId,
      expectedRevision: snapshot.revision,
      updates: staging.updates,
      removals: staging.removals,
      confirmRemovals: confirmVariableDeletions,
      shouldCancel: shouldCancel,
    );
    if (!applied.applied) {
      return (shouldCancel?.call() ?? false)
          ? BackgroundTurnResult.failed(
              BackgroundFailureReason.cancelled,
              null,
              (outcome as AgentRunSuccess).totalUsage,
            )
          : BackgroundTurnResult.conflict(
              usage: (outcome as AgentRunSuccess).totalUsage,
            );
    }
    // 摘要与落库结果一致:权限拒绝/超限/严格提案不得冒充"已应用"。
    final result = BackgroundResult(
      variableUpdates: applied.updates,
      addedVariables: _countAdditions(snapshot.values, applied.updates),
      variableRemovals: applied.removals,
      variableRemovalProposals: applied.proposedRemovals,
      usage: (outcome as AgentRunSuccess).totalUsage,
    );
    return BackgroundTurnResult.applied(result);
  }

  /// 单张图片的提示词修订:读取目标图片**生成时点之前**的对话窗口 + 生图指导/
  /// 角色/记忆锚定,交给后台引擎产出一段新的英文描述。只读 + 一次 LLM 调用,
  /// 不写库、不生图;是否重绘由用户确认后走控制器的单图替换路径。
  ///
  /// [messageId] 用于定位目标行并以其 [Message.seq] 截断转录 —— 老图不会被后来
  /// 的剧情改写成另一幕。目标不存在/描述为空/方向为空时返回良性跳过。
  Future<BackgroundTurnResult> reviseImagePrompt({
    required int sessionId,
    required int messageId,
    required String currentPrompt,
    required String direction,
    required String model,
    Set<String> stripSkillNames = const {},
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    bool characterAnchor = true,
    bool memoryAnchor = true,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
  }) async {
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    if (currentPrompt.trim().isEmpty) {
      return BackgroundTurnResult.skipped('这张图片没有可用的原始描述');
    }
    if (direction.trim().isEmpty) {
      return BackgroundTurnResult.skipped('缺少图片修改要求');
    }
    final allMessages = await messages.bySession(sessionId);
    Message? target;
    for (final m in allMessages) {
      if (m.id == messageId) {
        target = m;
        break;
      }
    }
    if (target == null) {
      return BackgroundTurnResult.skipped('目标图片已不存在');
    }
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    final conversation = allMessages
        .where(
          (m) =>
              m.isChat &&
              m.role != 'system' &&
              m.content.isNotEmpty &&
              !m.isCompacted &&
              m.id != messageId &&
              m.seq <= target!.seq,
        )
        .toList();
    final history = _trim(conversation, _imageRevisionHistoryLimit);
    final (guideList, memoryRows) = await (
      imageGuides.bySession(sessionId),
      memoryAnchor
          ? memories.bySession(sessionId)
          : Future.value(const <Never>[]),
    ).wait;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(BackgroundFailureReason.cancelled);
    }
    final outcome = await engine.runImagePromptRevision(
      model: model,
      currentPrompt: currentPrompt.trim(),
      direction: direction.trim(),
      history: [
        for (final m in history)
          m.copyWith(
            content: ContextAssembler.withoutSkillTokens(
              m.content,
              stripSkillNames,
            ),
          ),
      ],
      imageGuide: guideList.isEmpty ? null : guideList.first.content,
      memory: memoryRows.isEmpty
          ? null
          : memoryRows.map((m) => m.content).join('\n'),
      character: characterAnchor ? character : null,
      worldbook: worldbook,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(
        outcome.reason,
        outcome.detail,
        outcome.usage,
      );
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        result.usage,
      );
    }
    return BackgroundTurnResult.applied(result);
  }

  /// 落库更新中相对 CAS 基线新出现的键数:compareAndApply 成功即证明基线
  /// 未被并发改写,基线里没有的键就是本轮新建。供灵动岛区分「新增/修改」。
  static int _countAdditions(
    Map<String, String> baseline,
    Map<String, String> updates,
  ) => updates.keys.where((key) => !baseline.containsKey(key)).length;

  /// 结果里的图像描述:优先多描述数组,回退单描述;都没有时为空列表。
  static List<String> _imagePrompts(BackgroundResult result) =>
      result.imagePrompts ??
      (result.imagePrompt == null ? const <String>[] : [result.imagePrompt!]);

  /// 描述条数超过配置时截断并留诊断日志 —— legacy 对每条描述并发生图
  /// (付费),多给的描述一律不生成。补调与 agentic 共用同一口径。
  static List<String> _clampImagePrompts(
    List<String> prompts,
    int max, {
    String? source,
  }) {
    if (prompts.length <= max) return prompts;
    debugPrint(
      '[background] ${source == null ? '' : '$source '}imagePrompts '
      '${prompts.length} 条超过配置 $max,已截断',
    );
    return prompts.take(max).toList();
  }

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
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
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
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(
        outcome.reason,
        outcome.detail,
        outcome.usage,
      );
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        result.usage,
      );
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
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
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
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(
        outcome.reason,
        outcome.detail,
        outcome.usage,
      );
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        result.usage,
      );
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
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
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
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(
        outcome.reason,
        outcome.detail,
        outcome.usage,
      );
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        result.usage,
      );
    }
    final guide = result.imageGuide;
    if (guide == null || guide.trim().isEmpty) {
      return BackgroundTurnResult.skipped('初始化未产出有效生图指导,请重试');
    }
    await imageGuides.set(sessionId, guide);
    return BackgroundTurnResult.applied(result);
  }

  /// 全量重生成生图指导(用户主动发起,具有所有上下文的请求):把会话全部
  /// 活跃对话连同角色卡、常驻世界书与既有指导送入 LLM,产出新指导整段替换
  /// 落库。用于剧情新增角色、角色外貌或世界观大幅变化后同步定妆信息。
  /// [stripSkillNames]:转录里的 @技能名 记号剥离集合(同 [regenerateMemory])。
  Future<BackgroundTurnResult> regenerateImageGuide({
    required int sessionId,
    required String model,
    required CharacterCard character,
    List<WorldbookEntry> worldbook = const [],
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    Set<String> stripSkillNames = const {},
  }) async {
    final (allMessages, currentGuides) = await (
      messages.bySession(sessionId),
      imageGuides.bySession(sessionId),
    ).wait;
    final currentGuide = currentGuides.map((g) => g.content).join('\n');
    final outcome = await engine.runImageGuideRegenerate(
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
      currentGuide: currentGuide.isEmpty ? null : currentGuide,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
    );
    if (outcome is BackgroundRunFailure) {
      return BackgroundTurnResult.failed(
        outcome.reason,
        outcome.detail,
        outcome.usage,
      );
    }
    final result = (outcome as BackgroundRunSuccess).result;
    if (shouldCancel?.call() ?? false) {
      return BackgroundTurnResult.failed(
        BackgroundFailureReason.cancelled,
        null,
        result.usage,
      );
    }
    final guide = result.imageGuide;
    if (guide == null || guide.trim().isEmpty) {
      return BackgroundTurnResult.skipped('重生成未产出有效生图指导,请重试');
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
    bool Function()? shouldCancel,
  }) async {
    bool cancelled() => shouldCancel?.call() ?? false;
    final stopwatch = Stopwatch()..start();
    // 切会话/历史改写会取消令牌:已发出的生成请求无法召回,但可以在下载与
    // 落库前丢弃,避免旧剧情图片被追加到已重写的会话尾部。
    if (cancelled()) return;
    // 先并行收集所有描述的生图结果:单描述失败只丢该张,不拖垮其余。
    // 失败原因随结果带回,全部失败时进状态摘要(此前只知道「失败」)。
    final attempts = await Future.wait([
      for (final p in prompts) _generateOneSafe(p, backend),
    ]);
    if (cancelled()) return;
    final elapsedGen = stopwatch.elapsedMilliseconds;
    final results = [for (final a in attempts) a.result];
    var failureDetail = attempts
        .map((a) => a.error)
        .firstWhere((e) => e != null, orElse: () => null);
    // 每张(每条链接)要落的一条消息:先还原/下载字节并资产化,URL 恒保留
    // (仅下载失败时回退 URL 渲染)。`source` 记录来源描述下标,重跑时据此
    // 对齐替换目标;同一条描述返回多张时逐张保留该描述。
    final entries =
        <
          ({
            int source,
            String? base64,
            String? hash,
            String? url,
            String prompt,
            String? error,
          })
        >[
          for (var i = 0; i < results.length; i++)
            for (final image in results[i].images)
              (
                source: i,
                base64: image.base64,
                hash: null,
                url: image.url,
                prompt: prompts[i],
                error: null,
              ),
        ];
    // 并行下载与资产化:putBytes 先落零引用资产,随后业务事务才获取引用;
    // 后续 append/replace 失败时留下的零引用文件由延迟 GC 回收。
    var downloadMs = List<int>.filled(entries.length, 0);
    await Future.wait([
      for (var i = 0; i < entries.length; i++)
        () async {
          if (cancelled()) {
            entries[i] = (
              source: entries[i].source,
              base64: null,
              hash: null,
              url: entries[i].url,
              prompt: entries[i].prompt,
              error: '已取消',
            );
            return;
          }
          final sw = Stopwatch()..start();
          final entry = entries[i];
          try {
            final bytes = entry.base64 != null
                ? safeBase64Decode(entry.base64)
                : entry.url != null
                ? await downloadImageBytes(entry.url!)
                : null;
            if (entry.base64 != null && bytes == null) {
              throw const FormatException('插件返回了无效 base64 图片');
            }
            final ref = bytes == null
                ? null
                // URL 来源保留原字节:丢失后按哈希修复时重新下载的仍是原图;
                // 压缩会改变哈希,让修复永远失败。base64 无再取路径,可压缩。
                : await messages.db.images.putBytes(
                    bytes,
                    compress: entry.base64 != null,
                  );
            entries[i] = (
              source: entry.source,
              base64: null,
              hash: ref?.hash,
              url: entry.url,
              prompt: entry.prompt,
              error: null,
            );
          } catch (e) {
            entries[i] = (
              source: entry.source,
              base64: null,
              hash: null,
              url: entry.url,
              prompt: entry.prompt,
              error: _shortError(e),
            );
          }
          downloadMs[i] = sw.elapsedMilliseconds;
        }(),
    ]);
    var anyPlaced = false;
    for (var i = 0; i < entries.length; i++) {
      if (cancelled()) return;
      final entry = entries[i];
      final sw = Stopwatch()..start();
      try {
        if (entry.error != null) {
          failureDetail ??= entry.error;
          continue;
        }
        if (entry.hash == null && (entry.url == null || entry.url!.isEmpty)) {
          failureDetail ??= '图片下载或资产化失败';
          continue;
        }
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
            imageHash: entry.hash,
            imageUrl: entry.url,
            expectedPrompt: target.expectedPrompt,
            newImagePrompt: entry.prompt,
          );
          if (replaced) {
            _log(
              '#${i + 1}/${entries.length} 下载 ${downloadMs[i]}ms,原地替换消息 '
              '${target.messageId} 用时 ${sw.elapsedMilliseconds}ms,'
              'asset ${entry.hash ?? '-'}',
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
        final appended = await messages.append(
          sessionId: sessionId,
          role: 'assistant',
          content: '',
          imageHash: entry.hash,
          imageUrl: entry.url,
          imagePrompt: entry.prompt,
        );
        _log(
          '#${i + 1}/${entries.length} 下载 ${downloadMs[i]}ms,落库 ${sw.elapsedMilliseconds}ms,'
          'asset ${entry.hash ?? '-'}${entry.hash == null ? '(下载失败,回退 URL 渲染)' : ''}',
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

  /// 单图提示词修订的近期场景窗条数(与 image 轮 `_trim(recent, 6)` 一致):
  /// 只取目标图片 seq 之前的最新几轮,防止老图吃到后来剧情。
  static const int _imageRevisionHistoryLimit = 6;

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
