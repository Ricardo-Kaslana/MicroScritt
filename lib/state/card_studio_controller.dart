/// AI 制卡控制器:读基线 → 跑 Agent(流式)→ 快照暂存 → diff → 自动生图 →
/// 审阅/多轮打磨 → 单事务应用。
///
/// 内核转录不跨轮:每次 run 以「已接受草稿」为种子新建 transcript,历轮
/// 指令/摘要经 `<card_session_log>` 注入提示词。Agent 写动作只改内存暂存,
/// 失败/取消/护栏则整轮丢弃;应用是唯一落库点。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/image_downloader.dart';
import '../data/card_studio_draft_file.dart';
import '../data/shrink_image.dart';
import '../engine/agent/agent_events.dart';
import '../engine/agent/agent_runner.dart';
import '../engine/card_studio/card_agent.dart';
import '../engine/card_studio/card_diff.dart';
import '../engine/card_studio/card_staging.dart';
import '../models/backend_config.dart';
import '../models/character_card.dart';
import '../models/llm_units.dart';
import '../models/token_usage.dart';
import '../models/usage_stats.dart';
import '../models/worldbook_entry.dart';
import 'card_studio_draft_codec.dart';
import 'card_studio_state.dart';
import 'interrupt_token.dart';
import 'providers.dart';

/// 制卡工作台控制器(应用级单实例;页面退出时 disposeStudio 复位)。
class CardStudioController extends Notifier<CardStudioState> {
  /// 流式正文节流间隔(约 25FPS,与聊天草稿同款)。
  static const int _flushIntervalMs = 40;

  static const int _maxSessionLogLines = 20;

  InterruptToken? _token;
  Timer? _throttleTimer;
  final StringBuffer _streamBuffer = StringBuffer();
  int _lastFlushMs = 0;

  /// 旧生图结果作废计数(新 run/重生成/应用都会自增)。
  int _avatarGeneration = 0;

  bool _started = false;
  bool _baseLoaded = false;
  int? _targetId;

  /// 数据库基线(diff 与应用合成以它为底)。
  CharacterCard _originCard = const CharacterCard();
  List<WorldbookEntry> _originEntries = const [];

  /// 下一轮 Agent 的种子(上一轮已接受的变更折叠后的卡/条目)。
  CharacterCard _seedCard = const CharacterCard();
  List<WorldbookEntry> _seedEntries = const [];
  String? _seedAvatarPrompt;

  /// 已生成当前种子头像的提示词(避免重复计费)。
  String? _generatedAvatarPrompt;

  /// 最近一轮的轮前快照;null = 没有可撤回的轮次(未运行/已应用/草稿恢复)。
  _TurnSnapshot? _turn;

  /// 最近一轮是否产出了会被编辑撤回的内容(成功 finish 的变更或新头像)。
  /// 失败/取消/空结果轮保持 false:这些轮次没有实际修改,编辑它没有后果。
  bool _turnHasResults = false;

  final List<String> _sessionLog = [];

  /// 草稿文件实例(启动时捕获;测试为 null 时完全不做文件 IO)。
  CardStudioDraftFile? _draftFile;
  Timer? _draftSaveTimer;
  bool _draftDirty = false;

  /// 单调代数:apply/discard/新 start 后让在排队的防抖写回调失效,
  /// 防止删除草稿后又被迟到写复活。
  int _draftEpoch = 0;

  @override
  CardStudioState build() {
    ref.onDispose(_cancelAll);
    return const CardStudioState();
  }

  /// 进入工作台时调用;characterId=null 表示新建。
  ///
  /// 可重复调用以开启新会话(页面退出时只 [detach] 取消在飞任务,不写状态;
  /// 下次 start 在这里统一重置)。
  Future<void> start(int? characterId) async {
    if (state.busy) return;
    _started = true;
    _baseLoaded = false;
    _targetId = characterId;
    _turn = null;
    _draftEpoch++;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    _draftDirty = false;
    _draftFile = ref.read(cardStudioDraftFileProvider);
    _originCard = const CharacterCard();
    _originEntries = const [];
    _seedCard = const CharacterCard();
    _seedEntries = const [];
    _seedAvatarPrompt = null;
    _generatedAvatarPrompt = null;
    _sessionLog.clear();
    _clearDraft();
    state = CardStudioState(
      phase: CardStudioPhase.preparing,
      targetCharacterId: characterId,
    );
    try {
      final card = characterId == null
          ? const CharacterCard()
          : await ref.read(characterRepositoryProvider).get(characterId);
      if (characterId != null && card == null) {
        await _draftFile?.clear(characterId);
        throw StateError('角色卡不存在或已被删除');
      }
      final entries = characterId == null
          ? const <WorldbookEntry>[]
          : await ref.read(worldbookRepositoryProvider).byCharacter(characterId);
      if (!_started || !ref.mounted) return;
      final currentCard = card ?? const CharacterCard();
      if (await _restoreDraftIfPresent(characterId, currentCard, entries)) {
        return;
      }
      if (!_started || !ref.mounted) return;
      _originCard = currentCard;
      _originEntries = entries;
      _seedCard = _originCard;
      _seedEntries = _originEntries;
      _baseLoaded = true;
      state = state.copyWith(
        phase: CardStudioPhase.idle,
        targetName: _originCard.name,
        loaded: true,
        baseCard: _originCard,
        baseEntries: _originEntries,
      );
    } catch (e) {
      if (!_started || !ref.mounted) return;
      state = state.copyWith(
        phase: CardStudioPhase.failed,
        error: '读取角色卡失败：$e',
      );
    }
  }

  /// 尝试恢复同目标的草稿;返回 true 表示已经接管状态(或页面已卸载)。
  Future<bool> _restoreDraftIfPresent(
    int? characterId,
    CharacterCard currentCard,
    List<WorldbookEntry> currentEntries,
  ) async {
    final file = _draftFile;
    if (file == null) return false;
    final payload = await file.read(characterId);
    if (!_started || !ref.mounted) return true;
    if (payload == null) return false;
    final snapshot = decodeCardStudioDraft(payload);
    if (snapshot == null) {
      unawaited(file.clear(characterId));
      return false;
    }
    if (snapshot.targetCharacterId != characterId) return false;

    // 草稿不存 raw:恢复时附上当前库 raw,保证 apply 合并出的信封不丢;
    // 建模字段仍用快照基线,基线漂移由应用前冲突检测兜住。
    final raw = currentCard.raw;
    final base = snapshot.baseCard.withRaw(raw);
    final draft = snapshot.draftCard.withRaw(raw);
    // 旧版本可能把「应用后继续打磨」轮次的负临时 id 存进基线;不换成真实
    // id 的话 diff 会把同一条目同时判成删除与新增。
    final remapped = _remapTempEntryIds(
      snapshot.baseEntries,
      snapshot.draftEntries,
      currentEntries,
    );
    final baseEntries = remapped.base;
    final draftEntries = remapped.draft;
    final diff = computeCardDiff(
      baseCard: base,
      baseEntries: baseEntries,
      draftCard: draft,
      draftEntries: draftEntries,
    );
    final hasChanges = diff.hasChanges;
    if (!hasChanges && snapshot.entries.isEmpty && snapshot.sessionLog.isEmpty) {
      unawaited(file.clear(characterId));
      return false;
    }

    if (hasChanges) {
      final submission = buildCardSubmission(
        baseCard: base,
        baseEntries: baseEntries,
        draftCard: draft,
        draftEntries: draftEntries,
        decisions: snapshot.decisions,
      );
      _originCard = base;
      _originEntries = baseEntries;
      _seedCard = submission.card;
      _seedEntries = submission.entries;
      final avatarAccepted = snapshot.decisions.avatarAccepted &&
          draft.avatarBase64 != null &&
          draft.avatarBase64 != base.avatarBase64;
      _seedAvatarPrompt = avatarAccepted ? snapshot.draftAvatarPrompt : null;
      _generatedAvatarPrompt =
          avatarAccepted ? snapshot.generatedAvatarPrompt : null;
    } else {
      // 只有会话(应用后继续打磨 / 无变更轮):没有待审意图,基线一律取当前库,
      // 避免把快照里的过期基线带进下一轮;已生成头像的提示词仍作为复用凭据。
      _originCard = currentCard;
      _originEntries = currentEntries;
      _seedCard = currentCard;
      _seedEntries = currentEntries;
      final reusePrompt = snapshot.draftAvatarPrompt;
      final canReuse = reusePrompt != null &&
          snapshot.generatedAvatarPrompt == reusePrompt &&
          currentCard.avatarBase64 == snapshot.draftCard.avatarBase64;
      _seedAvatarPrompt = canReuse ? reusePrompt : null;
      _generatedAvatarPrompt = canReuse ? reusePrompt : null;
    }
    _sessionLog
      ..clear()
      ..addAll(snapshot.sessionLog);
    _baseLoaded = true;

    final restoredEntries = <CardStudioEntry>[
      ...snapshot.entries,
      CardStudioEntry.notice(
        hasChanges ? '已恢复上次未完成的草稿。' : '已恢复上次制卡对话，可继续调整。',
      ),
    ];
    if (hasChanges &&
        (!_sameCard(currentCard, base) ||
            !_sameEntries(currentEntries, baseEntries))) {
      restoredEntries.add(
        const CardStudioEntry.notice(
          '角色卡或世界书在离开期间已更新，应用时会提示冲突。',
        ),
      );
    }
    state = CardStudioState(
      phase: hasChanges ? CardStudioPhase.review : CardStudioPhase.idle,
      targetCharacterId: characterId,
      targetName: hasChanges ? base.name : currentCard.name,
      loaded: true,
      baseCard: _originCard,
      baseEntries: _originEntries,
      entries: restoredEntries,
      draftCard: hasChanges ? draft : null,
      draftEntries: hasChanges ? draftEntries : null,
      diff: hasChanges ? diff : null,
      decisions: hasChanges ? snapshot.decisions : ReviewDecisions.acceptAll,
      draftAvatarPrompt: hasChanges ? snapshot.draftAvatarPrompt : null,
      lastSummary: snapshot.lastSummary,
      lastRequestInputTokens: snapshot.lastRequestInputTokens,
      lastRequestCachedInputTokens: snapshot.lastRequestCachedInputTokens,
      contextEstimateTokens: snapshot.contextEstimateTokens,
    );
    return true;
  }

  /// 发起一轮生成/修改。种子为 [_seedCard]/[_seedEntries](首轮=基线)。
  Future<void> run(String instruction) async {
    if (state.busy || !_baseLoaded) return;
    final text = instruction.trim();
    if (text.isEmpty) return;

    final backend = ref.read(backendProvider);
    final config = ref.read(backendConfigProvider);
    if (backend == null || config == null) {
      _fail('未配置 LLM 后端，请先到设置页配置模型。');
      return;
    }
    final imageBackend = ref.read(imageBackendProvider);

    // 状态变更前记下轮前种子/日志/展示提案,供编辑最近指令时忠实撤回。
    _captureTurnSnapshot();

    _token?.cancel();
    final token = InterruptToken();
    _token = token;
    _avatarGeneration++;
    _clearDraft();
    state = state.copyWith(
      phase: CardStudioPhase.running,
      error: null,
      applyErrors: const [],
      conflictWarning: null,
      avatarStatus: CardStudioAvatarStatus.idle,
      avatarError: null,
      entries: [
        ...state.entries,
        CardStudioEntry.user(text),
      ],
    );
    _appendLog('用户：$text');

    final staging = CardStaging(
      baseCard: _seedCard,
      baseEntries: _seedEntries,
      characterId: _targetId ?? 0,
    )
      ..avatarPrompt = _seedAvatarPrompt
      ..generatedPrompt = _generatedAvatarPrompt;

    final built = CardProfile.build(
      backend: backend,
      model: config.model,
      instruction: text,
      staging: staging,
      avatarEnabled: imageBackend != null,
      sessionLog: List.of(_sessionLog),
      temperature: config.temperature,
      maxTokens: config.maxTokens,
      reasoningLevel: ref.read(appSettingsProvider).reasoningLevel,
      shouldCancel: () => token.cancelled,
      cancelSignal: token.whenCancelled,
      onStep: (event) {
        // 新一轮已换发令牌时丢弃上一轮的迟到回调。
        if (!identical(_token, token)) return;
        unawaited(_recordStepUsage(config, event));
        _handleStep(event);
      },
      onTextDelta: (delta) {
        if (!identical(_token, token)) return;
        _onTextDelta(delta);
      },
    );
    // 首个逻辑步上报真实用量前,圆环先用提示词字符估算兜底。
    state = state.copyWith(
      contextEstimateTokens: estimateTokensFromChars(
        built.spec.systemPrompt.length + built.spec.initialUserMessage.length,
      ),
    );

    AgentRunResult result;
    try {
      result = await AgentRunner.run(built.spec);
    } catch (e) {
      result = AgentRunFailure(
        AgentFailureReason.backendError,
        detail: '$e',
        stepUsages: const [],
        totalUsage: const TokenUsage(),
      );
    }
    if (!identical(_token, token)) return;
    _token = null;
    _clearDraft();
    if (!ref.mounted) return;

    switch (result) {
      case AgentRunSuccess(:final finishArgs):
        final draftCard = staging.workingCard;
        final draftEntries = staging.workingEntries;
        final diff = computeCardDiff(
          baseCard: _originCard,
          baseEntries: _originEntries,
          draftCard: draftCard,
          draftEntries: draftEntries,
        );
        _turnHasResults = diff.hasChanges;
        final summary = (finishArgs['summary'] ?? '').toString().trim();
        _appendLog('完成：${summary.isEmpty ? '草稿已生成' : summary}');
        state = state.copyWith(
          phase: CardStudioPhase.review,
          draftCard: draftCard,
          draftEntries: draftEntries,
          diff: diff,
          decisions: ReviewDecisions.acceptAll,
          draftAvatarPrompt: staging.avatarPrompt,
          lastSummary: summary.isEmpty ? null : summary,
          avatarStatus: CardStudioAvatarStatus.idle,
          avatarError: null,
          error: null,
          entries: summary.isEmpty
              ? state.entries
              : [
                  ...state.entries,
                  CardStudioEntry.notice('完成：$summary'),
                ],
        );
        // 先落一次提案:头像生成可能耗时很久,期间退出也不丢草稿。
        _scheduleDraftSave();
        await _maybeGenerateAvatar(
          prompt: staging.avatarPrompt,
          priorPrompt: staging.generatedPrompt,
        );
        _scheduleDraftSave();
      case AgentRunFailure(:final reason, :final detail):
        if (token.cancelled || reason == AgentFailureReason.cancelled) {
          state = state.copyWith(
            phase: state.diff == null
                ? CardStudioPhase.idle
                : CardStudioPhase.review,
            error: null,
            entries: [
              ...state.entries,
              const CardStudioEntry.notice('已取消本轮生成。'),
            ],
          );
        } else {
          final message = switch (reason) {
            AgentFailureReason.backendError =>
              'Agent 运行失败：${detail ?? '后端错误'}',
            AgentFailureReason.guardrail =>
              'Agent 无法继续：${detail ?? '工具调用异常'}',
            AgentFailureReason.cancelled => '已取消本轮生成。',
          };
          state = state.copyWith(
            phase: CardStudioPhase.failed,
            error: message,
            entries: [
              ...state.entries,
              CardStudioEntry.error(message),
            ],
          );
        }
        _scheduleDraftSave();
    }
  }

  /// 在审阅阶段继续追加指令:先把已接受变更折叠为种子,再跑新一轮。
  Future<void> continueAdjust(String instruction) async {
    if (state.busy) return;
    final text = instruction.trim();
    if (text.isEmpty) return;
    final draftCard = state.draftCard;
    final draftEntries = state.draftEntries;
    if (draftCard == null || draftEntries == null) return;

    final submission = buildCardSubmission(
      baseCard: _originCard,
      baseEntries: _originEntries,
      draftCard: draftCard,
      draftEntries: draftEntries,
      decisions: state.decisions,
    );
    _seedCard = submission.card;
    _seedEntries = submission.entries;
    final avatarAccepted = state.decisions.avatarAccepted &&
        submission.card.avatarBase64 != _originCard.avatarBase64;
    _seedAvatarPrompt = avatarAccepted ? state.draftAvatarPrompt : null;
    if (avatarAccepted) {
      _generatedAvatarPrompt = state.draftAvatarPrompt;
    } else {
      _generatedAvatarPrompt = null;
    }
    await run(text);
  }

  void cancel() => _token?.cancel();

  /// 最近一轮是否产出了会被编辑撤回的修改。false = 该轮失败/取消/没有实际
  /// 变更,编辑它不会丢弃任何内容。
  bool get latestTurnProducedChanges => _turn != null && _turnHasResults;

  /// 最近一条用户指令在 entries 中的下标;没有用户指令时为 null。
  int? get latestUserInstructionIndex {
    for (var i = state.entries.length - 1; i >= 0; i--) {
      if (state.entries[i].kind == CardStudioEntryKind.user) return i;
    }
    return null;
  }

  /// 该用户条目能否撤回重跑;null = 可编辑,否则返回菜单置灰原因。
  String? instructionEditBlockedReasonFor(int index) {
    if (index < 0 || index >= state.entries.length) return '该条目已不存在。';
    if (state.entries[index].kind != CardStudioEntryKind.user) {
      return '仅用户指令可修改。';
    }
    if (index != latestUserInstructionIndex) return '仅最近一条指令可修改';
    if (state.busy) return '正在生成或应用中';
    if (state.phase == CardStudioPhase.done) return '已应用，仅可复制';
    if (!_baseLoaded) return '工作台尚未就绪';
    final turn = _turn;
    if (turn == null || turn.userEntryIndex != index) {
      return '该指令已应用或会话已恢复，仅可复制';
    }
    return null;
  }

  /// 撤回最近一轮并按 [text] 重跑。null = 已发起;否则为不可执行原因。
  ///
  /// 恢复该轮开始前的种子/日志/展示提案,截断该轮全部对话条目;更早轮次
  /// 已接纳的内容留在种子里,数据库(已应用结果)不受影响。
  Future<String?> editLastInstruction(String text) async {
    final trimmed = text.trim();
    final index = latestUserInstructionIndex;
    if (index == null) return '当前没有可修改的指令。';
    final blocked = instructionEditBlockedReasonFor(index);
    if (blocked != null) return blocked;
    if (trimmed.isEmpty) return '指令不能为空。';
    if (state.entries[index].text.trim() == trimmed) return null;
    if (ref.read(backendProvider) == null ||
        ref.read(backendConfigProvider) == null) {
      return '未配置 LLM 后端，无法重新生成。';
    }
    final turn = _turn!;
    _seedCard = turn.seedCard;
    _seedEntries = turn.seedEntries;
    _seedAvatarPrompt = turn.seedAvatarPrompt;
    _generatedAvatarPrompt = turn.generatedAvatarPrompt;
    _sessionLog
      ..clear()
      ..addAll(turn.sessionLog);
    // 作废该轮在飞头像与旧草稿文件:撤回窗口内退出不应让被丢弃的提案复活。
    _avatarGeneration++;
    _draftEpoch++;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    _draftDirty = false;
    unawaited(_draftFile?.clear(_targetId));
    _turn = null;
    state = state.copyWith(
      entries: state.entries.sublist(0, index),
      draftCard: turn.draftCard,
      draftEntries: turn.draftEntries,
      diff: turn.diff,
      decisions: turn.decisions,
      draftAvatarPrompt: turn.draftAvatarPrompt,
      lastSummary: turn.lastSummary,
      avatarStatus: CardStudioAvatarStatus.idle,
      avatarError: null,
      error: null,
      applyErrors: const [],
      conflictWarning: null,
    );
    await run(trimmed);
    return null;
  }

  void toggleField(String key, bool accepted) {
    if (state.phase != CardStudioPhase.review &&
        state.phase != CardStudioPhase.failed) {
      return;
    }
    final current = state.decisions.field(key);
    state = state.copyWith(
      decisions: state.decisions.withField(
        key,
        FieldDecision(accepted: accepted, editedText: current.editedText),
      ),
    );
    _scheduleDraftSave();
  }

  void editField(String key, String text) {
    if (state.phase != CardStudioPhase.review &&
        state.phase != CardStudioPhase.failed) {
      return;
    }
    state = state.copyWith(
      decisions: state.decisions.withField(
        key,
        FieldDecision(accepted: true, editedText: text),
      ),
    );
    _scheduleDraftSave();
  }

  void toggleEntry(String key, bool accepted) {
    if (state.phase != CardStudioPhase.review &&
        state.phase != CardStudioPhase.failed) {
      return;
    }
    final current = state.decisions.entry(key);
    state = state.copyWith(
      decisions: state.decisions.withEntry(
        key,
        EntryDecision(accepted: accepted, editedEntry: current.editedEntry),
      ),
    );
    _scheduleDraftSave();
  }

  void editEntry(String key, WorldbookEntry entry) {
    if (state.phase != CardStudioPhase.review &&
        state.phase != CardStudioPhase.failed) {
      return;
    }
    state = state.copyWith(
      decisions: state.decisions.withEntry(
        key,
        EntryDecision(accepted: true, editedEntry: entry),
      ),
    );
    _scheduleDraftSave();
  }

  void toggleAvatar(bool accepted) {
    if (state.phase != CardStudioPhase.review &&
        state.phase != CardStudioPhase.failed) {
      return;
    }
    state = state.copyWith(decisions: state.decisions.withAvatar(accepted));
    _scheduleDraftSave();
  }

  /// 用新提示词重生成头像(审阅页手动动作)。
  Future<void> regenerateAvatar(String prompt) async {
    if (state.phase != CardStudioPhase.review &&
        state.phase != CardStudioPhase.failed) {
      return;
    }
    if (state.busy || state.avatarStatus == CardStudioAvatarStatus.generating) {
      return;
    }
    if (state.draftCard == null || state.draftEntries == null) return;
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        avatarStatus: CardStudioAvatarStatus.failed,
        avatarError: '头像提示词不能为空。',
      );
      return;
    }
    if (ref.read(imageBackendProvider) == null) {
      state = state.copyWith(
        avatarStatus: CardStudioAvatarStatus.failed,
        avatarError: '未配置生图后端，无法生成头像。',
      );
      return;
    }
    state = state.copyWith(
      draftAvatarPrompt: trimmed,
      decisions: state.decisions.withAvatar(true),
    );
    // 先保存提示词/接受态:生图中途退出时草稿仍带最新提示词。
    _scheduleDraftSave();
    await _generateAvatar(trimmed);
    _scheduleDraftSave();
  }

  /// 应用变更:新卡 insertWithWorldbook,既有卡 updateWithWorldbook(单事务)。
  /// 返回 false 表示校验/冲突/写库失败,原因在 state.applyErrors/conflictWarning。
  Future<bool> apply({bool force = false}) async {
    if (!state.canApply) return false;
    // detach 会置空 `_targetId`/`_draftFile`,但写库仍会完成;入口处全部
    // 捕获,避免 await 之后把更新误判成新建或清理不掉的草稿。
    final targetId = _targetId;
    final savedTarget = targetId;
    final draftFile = _draftFile;
    final draftCard = state.draftCard!;
    final draftEntries = state.draftEntries!;
    final submission = buildCardSubmission(
      baseCard: _originCard,
      baseEntries: _originEntries,
      draftCard: draftCard,
      draftEntries: draftEntries,
      decisions: state.decisions,
    );
    final errors = validateCardSubmission(submission);
    if (errors.isNotEmpty) {
      state = state.copyWith(applyErrors: errors);
      return false;
    }
    if (targetId != null) {
      final current = await ref.read(characterRepositoryProvider).get(targetId);
      if (!ref.mounted) return false;
      if (current == null) {
        state = state.copyWith(applyErrors: ['角色卡已被删除，无法保存。']);
        return false;
      }
      final currentEntries = await ref
          .read(worldbookRepositoryProvider)
          .byCharacter(targetId);
      if (!ref.mounted) return false;
      if (!force) {
        final cardChanged = !_sameCard(current, _originCard);
        final entriesChanged = !_sameEntries(currentEntries, _originEntries);
        if (cardChanged || entriesChanged) {
          final parts = [
            if (cardChanged) '角色卡',
            if (entriesChanged) '世界书',
          ];
          state = state.copyWith(
            conflictWarning:
                '${parts.join('与')}已在其他页面被修改。继续应用将覆盖这些修改。',
          );
          return false;
        }
      }
    }

    _avatarGeneration++;
    state = state.copyWith(
      phase: CardStudioPhase.applying,
      applyErrors: const [],
      conflictWarning: null,
      error: null,
    );
    try {
      final repo = ref.read(characterRepositoryProvider);
      late final int id;
      if (targetId == null) {
        id = await repo.insertWithWorldbook(submission.card, submission.entries);
      } else {
        await repo.updateWithWorldbook(
          targetId,
          submission.card,
          submission.entries,
        );
        id = targetId;
      }
      // 写库即提交点:此后该轮指令只能复制,不允许再撤回重跑。
      _turn = null;
      if (!ref.mounted) return true;
      // 以库为准刷新基线:提交值里的新条目还是负临时 id,直接当基线会让
      // 下一轮 diff 把它们同时判成删除与新增,重复应用还会让世界书 id 漂移。
      var appliedCard = submission.card;
      var appliedEntries = submission.entries;
      try {
        final stored = await repo.get(id);
        if (stored != null) {
          appliedCard = stored;
          appliedEntries =
              await ref.read(worldbookRepositoryProvider).byCharacter(id);
        }
      } catch (e) {
        appliedCard = submission.card;
        appliedEntries = submission.entries;
        debugPrint('制卡应用后回读基线失败(沿用提交值):$e');
      }
      if (!ref.mounted) return true;
      // 已应用的头像与提示词继续作为后续打磨的复用凭据,避免同一提示词
      // 再生成一次图。
      final keepAvatarPrompt = state.decisions.avatarAccepted &&
          state.draftAvatarPrompt != null &&
          _generatedAvatarPrompt == state.draftAvatarPrompt &&
          submission.card.avatarBase64 == draftCard.avatarBase64;
      _targetId = id;
      _originCard = appliedCard;
      _originEntries = appliedEntries;
      _seedCard = appliedCard;
      _seedEntries = appliedEntries;
      _seedAvatarPrompt =
          keepAvatarPrompt ? state.draftAvatarPrompt : null;
      _generatedAvatarPrompt =
          keepAvatarPrompt ? state.draftAvatarPrompt : null;
      ref.invalidate(charactersProvider);
      ref.invalidate(sessionGroupsProvider);
      ref.invalidate(characterAvatarProvider(id));
      ref.invalidate(worldbookProvider(id));
      state = state.copyWith(
        phase: CardStudioPhase.done,
        appliedCharacterId: id,
        baseCard: appliedCard,
        baseEntries: appliedEntries,
        draftCard: appliedCard,
        draftEntries: appliedEntries,
        diff: null,
        draftAvatarPrompt: null,
        decisions: ReviewDecisions.acceptAll,
        applyErrors: const [],
        conflictWarning: null,
      );
      // 提案已落库:作废防抖回调并删除草稿(删除排在已入队写之后)。
      _draftEpoch++;
      _draftSaveTimer?.cancel();
      _draftSaveTimer = null;
      _draftDirty = false;
      unawaited(draftFile?.clear(savedTarget));
      return true;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(
          phase: CardStudioPhase.review,
          applyErrors: ['保存失败：$e'],
        );
      }
      return false;
    }
  }

  /// 应用成功后继续在同一工作台打磨:保留对话记录与已应用基线,清空提案。
  void continueAfterApply() {
    if (state.phase != CardStudioPhase.done) return;
    _clearDraft();
    _appendLog('已应用上一轮变更，后续修改以已应用版本为基线。');
    state = state.copyWith(
      phase: CardStudioPhase.idle,
      targetName: _originCard.name,
      baseCard: _originCard,
      baseEntries: _originEntries,
      draftCard: null,
      draftEntries: null,
      diff: null,
      decisions: ReviewDecisions.acceptAll,
      draftAvatarPrompt: null,
      avatarStatus: CardStudioAvatarStatus.idle,
      avatarError: null,
      error: null,
      applyErrors: const [],
      conflictWarning: null,
      appliedCharacterId: null,
      lastSummary: null,
      entries: [
        ...state.entries,
        const CardStudioEntry.notice('已应用，可继续描述要调整的内容。'),
      ],
    );
    // 应用后没有待审提案,但打磨会话本身也要落盘:退出后重进能接着聊。
    _saveDraftNow();
  }

  void clearConflict() {
    if (state.conflictWarning != null) {
      state = state.copyWith(conflictWarning: null);
    }
  }

  /// 丢弃当前草稿:清提案/对话/日志回到基线,并删除草稿文件。
  void discardDraft() {
    if (state.busy) return;
    _draftEpoch++;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    _draftDirty = false;
    _avatarGeneration++;
    _turn = null;
    final target = _targetId;
    unawaited(_draftFile?.clear(target));
    _seedCard = _originCard;
    _seedEntries = _originEntries;
    _seedAvatarPrompt = null;
    _generatedAvatarPrompt = null;
    _sessionLog.clear();
    _clearDraft();
    state = CardStudioState(
      phase: CardStudioPhase.idle,
      targetCharacterId: target,
      targetName: _originCard.name,
      loaded: true,
      baseCard: _originCard,
      baseEntries: _originEntries,
      entries: const [CardStudioEntry.notice('已丢弃当前草稿。')],
    );
  }

  /// 页面退出(在 State.dispose 里调用):先把待写草稿入队,再取消在飞运行/
  /// 生图并复位内部标志。**不写 provider 状态** —— 同步写会通知正在卸载的
  /// 订阅者,触发 `markNeedsBuild on defunct element`;下次 [start] 统一重置。
  /// 保留 `_targetId`:应用写库无法取消,退出后若写库失败,重试必须仍按
  /// 原目标更新而不是插入一张新卡。
  void detach() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    if (_draftDirty) _saveDraftNow(force: true);
    _draftDirty = false;
    _cancelAll();
    _started = false;
    _baseLoaded = false;
    _turn = null;
    _seedAvatarPrompt = null;
    _generatedAvatarPrompt = null;
    _sessionLog.clear();
    _draftFile = null;
  }

  /// 完全复位(不含页面卸载路径;测试/显式重置用)。
  void disposeStudio() {
    _draftEpoch++;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    _draftDirty = false;
    unawaited(_draftFile?.clear(_targetId));
    _draftFile = null;
    _cancelAll();
    if (ref.mounted) ref.read(cardStudioDraftProvider.notifier).clear();
    _started = false;
    _baseLoaded = false;
    _turn = null;
    _targetId = null;
    _originCard = const CharacterCard();
    _originEntries = const [];
    _seedCard = const CharacterCard();
    _seedEntries = const [];
    _seedAvatarPrompt = null;
    _generatedAvatarPrompt = null;
    _sessionLog.clear();
    state = const CardStudioState();
  }

  // ---- 内部

  /// 有需要落盘的内容:待审提案,或已经发生的制卡对话(应用后继续打磨的
  /// 会话没有提案,也要能跨页面/重进恢复)。
  bool get _hasRestorableContent => state.hasProposal || _sessionLog.isNotEmpty;

  /// 记下轮前种子/日志与轮前展示的提案,供 [editLastInstruction] 撤回本轮。
  void _captureTurnSnapshot() {
    _turnHasResults = false;
    _turn = _TurnSnapshot(
      userEntryIndex: state.entries.length,
      seedCard: _seedCard,
      seedEntries: List.of(_seedEntries),
      seedAvatarPrompt: _seedAvatarPrompt,
      generatedAvatarPrompt: _generatedAvatarPrompt,
      sessionLog: List.of(_sessionLog),
      draftCard: state.draftCard,
      draftEntries:
          state.draftEntries == null ? null : List.of(state.draftEntries!),
      diff: state.diff,
      decisions: state.decisions,
      draftAvatarPrompt: state.draftAvatarPrompt,
      lastSummary: state.lastSummary,
    );
  }

  /// 提案/决策/会话变化后的防抖落盘;忙碌态先跳过,run 结束会再调度。
  void _scheduleDraftSave() {
    if (_draftFile == null || state.busy || !_hasRestorableContent) return;
    _draftDirty = true;
    _draftSaveTimer?.cancel();
    final epoch = _draftEpoch;
    _draftSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _draftSaveTimer = null;
      if (epoch != _draftEpoch) return;
      _saveDraftNow();
    });
  }

  void _saveDraftNow({bool force = false}) {
    final file = _draftFile;
    if (file == null) return;
    if (!force && state.busy) return;
    if (!_hasRestorableContent) {
      _draftDirty = false;
      return;
    }
    // 无提案时将当前基线当作草稿侧写一份会话快照(diff 为空),用于退出后
    // 恢复对话与多轮上下文;恢复时基线仍以当前库为准。
    final sessionOnly = !state.hasProposal;
    final draftCard = sessionOnly ? state.baseCard : state.draftCard;
    final draftEntries = sessionOnly ? state.baseEntries : state.draftEntries;
    if (draftCard == null || draftEntries == null) {
      _draftDirty = false;
      return;
    }
    final snapshot = CardStudioDraftSnapshot(
      targetCharacterId: _targetId,
      baseCard: _originCard,
      baseEntries: _originEntries,
      draftCard: draftCard,
      draftEntries: draftEntries,
      decisions: state.decisions,
      entries: state.entries,
      sessionLog: List.of(_sessionLog),
      draftAvatarPrompt:
          state.draftAvatarPrompt ?? (sessionOnly ? _seedAvatarPrompt : null),
      generatedAvatarPrompt: _generatedAvatarPrompt,
      lastSummary: state.lastSummary,
      lastRequestInputTokens: state.lastRequestInputTokens,
      lastRequestCachedInputTokens: state.lastRequestCachedInputTokens,
      contextEstimateTokens: state.contextEstimateTokens,
    );
    _draftDirty = false;
    try {
      unawaited(
        file.write(_targetId, encodeCardStudioDraft(snapshot)),
      );
    } catch (e) {
      debugPrint('制卡草稿编码失败(已忽略):$e');
    }
  }

  /// 逐步用量入账(agentic 约定):失败/取消步 reported=false 仍计次,
  /// 不写轮级行。制卡不属于任何会话,session_id 留空。
  Future<void> _recordStepUsage(
    BackendConfig config,
    AgentStepEvent event,
  ) async {
    if (!ref.mounted) return;
    try {
      await ref.read(usageRepositoryProvider).record(
            sessionId: null,
            kind: UsageKind.card,
            providerId: config.providerId,
            providerName:
                config.providerName.isEmpty ? config.providerWire : config.providerName,
            model: config.model,
            modelName: config.modelName.isEmpty ? config.model : config.modelName,
            usage: event.usage,
            reported: event.reported,
          );
    } catch (_) {}
  }

  void _handleStep(AgentStepEvent event) {
    _flushStream();
    if (!ref.mounted) return;
    final text = event.text.trim();
    final additions = <CardStudioEntry>[];
    if (event.success && text.isNotEmpty) {
      additions.add(CardStudioEntry(
        CardStudioEntryKind.agent,
        text,
        step: event.step,
      ));
    }
    if (event.toolNames.isNotEmpty) {
      additions.add(CardStudioEntry(
        CardStudioEntryKind.toolStep,
        _toolLabel(event.toolNames),
        tools: List.unmodifiable(event.toolNames),
        step: event.step,
      ));
    }
    if (additions.isNotEmpty) {
      state = state.copyWith(entries: [...state.entries, ...additions]);
    }
    // 每步重发完整系统提示 + 转录,最后一步的实际输入即本轮占用上限;
    // 取单次请求口径(重试求和不代表上下文大小),unreported 时保留上一锚点。
    if (event.requestUsage.inputTokens > 0) {
      state = state.copyWith(
        lastRequestInputTokens: event.requestUsage.inputTokens,
        lastRequestCachedInputTokens: event.requestUsage.cachedInputTokens,
      );
    }
    _clearDraft();
  }

  void _onTextDelta(String delta) {
    if (!ref.mounted) return;
    _streamBuffer.write(delta);
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastFlushMs;
    if (elapsed >= _flushIntervalMs) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _flushStream();
    } else {
      _throttleTimer ??= Timer(
        Duration(milliseconds: _flushIntervalMs - elapsed),
        () {
          _throttleTimer = null;
          _flushStream();
        },
      );
    }
  }

  void _flushStream() {
    _lastFlushMs = DateTime.now().millisecondsSinceEpoch;
    if (!ref.mounted) return;
    ref.read(cardStudioDraftProvider.notifier).set(_streamBuffer.toString());
  }

  void _clearDraft() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _streamBuffer.clear();
    _lastFlushMs = 0;
    if (ref.mounted) ref.read(cardStudioDraftProvider.notifier).clear();
  }

  Future<void> _maybeGenerateAvatar({
    required String? prompt,
    required String? priorPrompt,
  }) async {
    final trimmed = prompt?.trim() ?? '';
    if (trimmed.isEmpty) {
      state = state.copyWith(
        avatarStatus: CardStudioAvatarStatus.idle,
        avatarError: null,
      );
      return;
    }
    final draftAvatar = state.draftCard?.avatarBase64;
    if (trimmed == priorPrompt && draftAvatar != null) {
      // 提示词未变且已有生成图(含已应用的基线头像):复用,不重复计费。
      state = state.copyWith(
        avatarStatus: CardStudioAvatarStatus.ready,
        avatarError: null,
        decisions: state.decisions.withAvatar(true),
      );
      return;
    }
    if (ref.read(imageBackendProvider) == null) {
      state = state.copyWith(
        avatarStatus: CardStudioAvatarStatus.failed,
        avatarError: '未配置生图后端，头像未生成。',
      );
      return;
    }
    await _generateAvatar(trimmed);
  }

  Future<void> _generateAvatar(String prompt) async {
    final generation = ++_avatarGeneration;
    state = state.copyWith(
      avatarStatus: CardStudioAvatarStatus.generating,
      avatarError: null,
    );
    String? base64;
    String? error;
    try {
      final backend = ref.read(imageBackendProvider);
      if (backend == null) {
        error = '未配置生图后端。';
      } else {
        final result = await backend.generateImage(prompt);
        final first = result.images.isNotEmpty ? result.images.first : null;
        if (first == null) {
          error = '生图后端未返回图片。';
        } else {
          var data = first.base64;
          if (data == null && first.url != null) {
            data = await downloadImageBase64(first.url!);
          }
          if (data == null) {
            error = '图片下载失败。';
          } else {
            base64 = await shrinkBase64Image(data);
          }
        }
      }
    } catch (e) {
      error = '头像生成失败：$e';
    }
    if (!ref.mounted || generation != _avatarGeneration) return;
    if (base64 == null) {
      state = state.copyWith(
        avatarStatus: CardStudioAvatarStatus.failed,
        avatarError: error ?? '头像生成失败。',
      );
      return;
    }
    _generatedAvatarPrompt = prompt;
    final draft = state.draftCard;
    final draftEntries = state.draftEntries;
    if (draft == null || draftEntries == null) return;
    // 新图已进入当前提案:编辑撤回会丢弃它,按「有产出」提示。
    _turnHasResults = true;
    final updatedCard = draft.replacingAvatar(base64);
    final diff = computeCardDiff(
      baseCard: _originCard,
      baseEntries: _originEntries,
      draftCard: updatedCard,
      draftEntries: draftEntries,
    );
    state = state.copyWith(
      draftCard: updatedCard,
      diff: diff,
      avatarStatus: CardStudioAvatarStatus.ready,
      avatarError: null,
      decisions: state.decisions.withAvatar(true),
    );
  }

  void _fail(String message) {
    state = state.copyWith(
      phase: CardStudioPhase.failed,
      error: message,
      entries: [...state.entries, CardStudioEntry.error(message)],
    );
  }

  void _appendLog(String line) {
    _sessionLog.add(line);
    while (_sessionLog.length > _maxSessionLogLines) {
      _sessionLog.removeAt(0);
    }
  }

  void _cancelAll() {
    _token?.cancel();
    _token = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    _avatarGeneration++;
    _streamBuffer.clear();
  }

  static String _toolLabel(List<String> names) {
    const labels = {
      'readDraft': '查看草稿',
      'setCardFields': '更新角色卡',
      'upsertWorldbookEntries': '撰写世界书',
      'removeWorldbookEntries': '删除世界书条目',
      'setAvatarPrompt': '设定头像提示词',
    };
    return names.map((n) => labels[n] ?? n).join(' · ');
  }

  /// 把基线里的负临时 id 按内容对账成当前库真实 id(基线/草稿同步改写)。
  /// 仅在旧草稿把「应用后延续」的暂存条目原样存盘时命中;对不上的条目
  /// (例如已被外部删除)保持原值,交给 diff/提交按暂存新增处理。
  static ({List<WorldbookEntry> base, List<WorldbookEntry> draft})
      _remapTempEntryIds(
    List<WorldbookEntry> baseEntries,
    List<WorldbookEntry> draftEntries,
    List<WorldbookEntry> currentEntries,
  ) {
    final remap = <int, int>{};
    // 已在基线里以真实 id 出现的条目不能被另一个临时 id 认领。
    final claimed = <int>{
      for (final e in baseEntries)
        if (e.id != null && e.id! >= 0) e.id!,
    };
    for (final base in baseEntries) {
      final tempId = base.id;
      if (tempId == null || tempId >= 0) continue;
      for (final current in currentEntries) {
        final id = current.id;
        if (id == null || claimed.contains(id)) continue;
        if (!entryContentEquals(base, current)) continue;
        remap[tempId] = id;
        claimed.add(id);
        break;
      }
    }
    if (remap.isEmpty) {
      return (base: baseEntries, draft: draftEntries);
    }
    WorldbookEntry mapped(WorldbookEntry entry) {
      final id = entry.id;
      final realId = id == null ? null : remap[id];
      return realId == null ? entry : entry.copyWith(id: realId);
    }

    return (
      base: [for (final e in baseEntries) mapped(e)],
      draft: [for (final e in draftEntries) mapped(e)],
    );
  }

  /// 卡面冲突比较:全部可编辑字段 + 头像/背景 + 提交时会保留的展示元数据。
  /// `raw` 不参与(避免对超大 JSON 做编码),直接改库 raw 的极端场景漏检。
  static bool _sameCard(CharacterCard a, CharacterCard b) {
    for (final key in kEditableCardFieldKeys) {
      if (cardFieldText(a, key) != cardFieldText(b, key)) return false;
    }
    return a.avatarBase64 == b.avatarBase64 &&
        a.backgroundBase64 == b.backgroundBase64 &&
        a.creator == b.creator &&
        a.characterVersion == b.characterVersion &&
        a.talkativeness == b.talkativeness &&
        a.fav == b.fav &&
        a.bubbleStyle == b.bubbleStyle;
  }

  /// 世界书冲突比较:按 id 对账,建模字段与 position/extra 全量比较。
  static bool _sameEntries(
    List<WorldbookEntry> a,
    List<WorldbookEntry> b,
  ) {
    if (a.length != b.length) return false;
    final byId = <int, WorldbookEntry>{};
    for (final entry in b) {
      final id = entry.id;
      if (id == null) return false;
      byId[id] = entry;
    }
    for (final entry in a) {
      final id = entry.id;
      if (id == null) return false;
      final other = byId[id];
      if (other == null || !entryEquals(entry, other)) return false;
    }
    return true;
  }
}

/// 一轮运行的轮前快照:编辑最近一条指令时据此忠实撤回该轮。
class _TurnSnapshot {
  /// 该轮用户条目在 entries 中的下标。
  final int userEntryIndex;
  final CharacterCard seedCard;
  final List<WorldbookEntry> seedEntries;
  final String? seedAvatarPrompt;
  final String? generatedAvatarPrompt;

  /// 轮前滚动日志(不含本轮用户行与完成摘要)。
  final List<String> sessionLog;

  /// 轮前展示的提案;该轮失败/被撤回后恢复,避免审阅面板突然空白。
  final CharacterCard? draftCard;
  final List<WorldbookEntry>? draftEntries;
  final CardDiff? diff;
  final ReviewDecisions decisions;
  final String? draftAvatarPrompt;
  final String? lastSummary;

  const _TurnSnapshot({
    required this.userEntryIndex,
    required this.seedCard,
    required this.seedEntries,
    required this.seedAvatarPrompt,
    required this.generatedAvatarPrompt,
    required this.sessionLog,
    required this.draftCard,
    required this.draftEntries,
    required this.diff,
    required this.decisions,
    required this.draftAvatarPrompt,
    required this.lastSummary,
  });
}

final cardStudioControllerProvider =
    NotifierProvider<CardStudioController, CardStudioState>(
  CardStudioController.new,
);
