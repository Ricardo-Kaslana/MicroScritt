/// AI 制卡工作台的不可变状态与流式正文 provider。
///
/// 高频流式正文单独放 [cardStudioDraftProvider](仿 chatDraftProvider),避免
/// 每个 delta 都重建整页;阶段/草稿/审阅决策走主 state,只在步结束与阶段
/// 切换时更新。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/card_studio/card_diff.dart';
import '../models/character_card.dart';
import '../models/worldbook_entry.dart';

/// 制卡阶段。生图进度独立为 [CardStudioAvatarStatus],审阅期可并行进行。
enum CardStudioPhase {
  /// 尚未开始(基线已加载)。
  idle,

  /// 正在读取既有卡/世界书。
  preparing,

  /// Agent 正在运行。
  running,

  /// 有提案可审阅。
  review,

  /// 正在写库。
  applying,

  /// 已应用。
  done,

  /// 最近一轮失败(可能仍有上一版提案)。
  failed,
}

enum CardStudioAvatarStatus { idle, generating, ready, failed }

enum CardStudioEntryKind { user, agent, toolStep, notice, error }

/// 对话记录中的一个条目。
class CardStudioEntry {
  final CardStudioEntryKind kind;
  final String text;
  final List<String> tools;
  final int step;

  const CardStudioEntry(
    this.kind,
    this.text, {
    this.tools = const [],
    this.step = 0,
  });

  const CardStudioEntry.user(String text)
      : this(CardStudioEntryKind.user, text);

  const CardStudioEntry.notice(String text)
      : this(CardStudioEntryKind.notice, text);

  const CardStudioEntry.error(String text)
      : this(CardStudioEntryKind.error, text);
}

/// 制卡工作台状态快照。
class CardStudioState {
  final CardStudioPhase phase;

  /// 目标角色 id;null = 新建。
  final int? targetCharacterId;

  /// 既有角色名(头部展示);新建为空。
  final String targetName;

  /// 基线是否加载成功(false 时禁用输入:失败的是读库而非某轮生成)。
  final bool loaded;

  /// 数据库基线(只读;diff 与应用合成以此为底)。
  final CharacterCard baseCard;
  final List<WorldbookEntry> baseEntries;

  /// 对话记录(旧→新)。
  final List<CardStudioEntry> entries;

  /// 最近一轮提案快照;null = 还没有可用草稿。
  final CharacterCard? draftCard;
  final List<WorldbookEntry>? draftEntries;

  /// 提案相对基线的差异。
  final CardDiff? diff;

  /// 审阅决策(默认全接受)。
  final ReviewDecisions decisions;

  /// 当前头像提示词(审阅页可编辑并重生成)。
  final String? draftAvatarPrompt;

  final CardStudioAvatarStatus avatarStatus;
  final String? avatarError;

  /// 本轮失败原因(Agent 运行失败/未配置后端)。
  final String? error;

  /// 应用前校验/写库错误。
  final List<String> applyErrors;

  /// 既有卡在应用前被其他页面修改的提示;置空后可再次应用。
  final String? conflictWarning;

  /// 应用成功后的角色 id。
  final int? appliedCharacterId;

  /// 最近一轮 finish 摘要。
  final String? lastSummary;

  /// 最近一个逻辑步的实际输入 token(系统提示 + 完整转录);null = 本次
  /// 会话还没有上报过用量。上下文圆环优先用它,与聊天页「最近一轮」同口径。
  final int? lastRequestInputTokens;

  /// 最近一个逻辑步命中提示缓存的输入 token;仅在 [lastRequestInputTokens]
  /// 非空时有意义,供圆环底单展示缓存命中率。
  final int lastRequestCachedInputTokens;

  /// 运行开始时的提示词字符估算(系统提示 + 首条指令),无真实用量时的
  /// 圆环兜底口径。
  final int contextEstimateTokens;

  const CardStudioState({
    this.phase = CardStudioPhase.idle,
    this.targetCharacterId,
    this.targetName = '',
    this.loaded = false,
    this.baseCard = const CharacterCard(),
    this.baseEntries = const [],
    this.entries = const [],
    this.draftCard,
    this.draftEntries,
    this.diff,
    this.decisions = ReviewDecisions.acceptAll,
    this.draftAvatarPrompt,
    this.avatarStatus = CardStudioAvatarStatus.idle,
    this.avatarError,
    this.error,
    this.applyErrors = const [],
    this.conflictWarning,
    this.appliedCharacterId,
    this.lastSummary,
    this.lastRequestInputTokens,
    this.lastRequestCachedInputTokens = 0,
    this.contextEstimateTokens = 0,
  });

  /// preparing/running/applying 期间所有公开动作都应被门控。
  bool get busy => switch (phase) {
        CardStudioPhase.preparing ||
        CardStudioPhase.running ||
        CardStudioPhase.applying =>
          true,
        _ => false,
      };

  bool get hasProposal => draftCard != null && diff != null;

  /// 有待审提案或已发生的制卡对话(应用后继续打磨的会话可整体丢弃)。
  bool get hasSession =>
      hasProposal ||
      entries.any(
        (e) =>
            e.kind == CardStudioEntryKind.user ||
            e.kind == CardStudioEntryKind.agent ||
            e.kind == CardStudioEntryKind.toolStep,
      );

  int get changeCount => diff?.changeCount ?? 0;

  /// 决策后真正会写入的变更数(编辑回原文或全部拒绝时可为 0)。
  int get acceptedChangeCount {
    final d = diff;
    if (d == null) return 0;
    var count = 0;
    for (final field in d.fields) {
      final decision = decisions.field(field.key);
      if (!decision.accepted) continue;
      if (effectiveFieldText(field, decision) != field.oldText) count++;
    }
    for (final entry in d.entries) {
      final decision = decisions.entry(entry.reviewKey);
      if (!decision.accepted) continue;
      switch (entry.kind) {
        case WorldbookChangeKind.added:
          count++;
        case WorldbookChangeKind.removed:
          count++;
        case WorldbookChangeKind.modified:
          final now = effectiveEntryValue(entry, decision);
          if (now != null &&
              entry.oldEntry != null &&
              !entryEquals(entry.oldEntry!, now)) {
            count++;
          }
      }
    }
    if ((d.avatar?.hasChange ?? false) && decisions.avatarAccepted) count++;
    return count;
  }

  /// 可应用:有接受项且不在忙态;头像生成中暂缓(避免应用后再落一张图)。
  bool get canApply =>
      (phase == CardStudioPhase.review || phase == CardStudioPhase.failed) &&
      acceptedChangeCount > 0 &&
      !busy &&
      avatarStatus != CardStudioAvatarStatus.generating;

  static const Object _keep = Object();

  CardStudioState copyWith({
    CardStudioPhase? phase,
    int? targetCharacterId,
    String? targetName,
    bool? loaded,
    CharacterCard? baseCard,
    List<WorldbookEntry>? baseEntries,
    List<CardStudioEntry>? entries,
    Object? draftCard = _keep,
    Object? draftEntries = _keep,
    Object? diff = _keep,
    ReviewDecisions? decisions,
    Object? draftAvatarPrompt = _keep,
    CardStudioAvatarStatus? avatarStatus,
    Object? avatarError = _keep,
    Object? error = _keep,
    List<String>? applyErrors,
    Object? conflictWarning = _keep,
    Object? appliedCharacterId = _keep,
    Object? lastSummary = _keep,
    Object? lastRequestInputTokens = _keep,
    int? lastRequestCachedInputTokens,
    int? contextEstimateTokens,
  }) =>
      CardStudioState(
        phase: phase ?? this.phase,
        targetCharacterId: targetCharacterId ?? this.targetCharacterId,
        targetName: targetName ?? this.targetName,
        loaded: loaded ?? this.loaded,
        baseCard: baseCard ?? this.baseCard,
        baseEntries: baseEntries ?? this.baseEntries,
        entries: entries ?? this.entries,
        draftCard:
            identical(draftCard, _keep) ? this.draftCard : draftCard as CharacterCard?,
        draftEntries: identical(draftEntries, _keep)
            ? this.draftEntries
            : draftEntries as List<WorldbookEntry>?,
        diff: identical(diff, _keep) ? this.diff : diff as CardDiff?,
        decisions: decisions ?? this.decisions,
        draftAvatarPrompt: identical(draftAvatarPrompt, _keep)
            ? this.draftAvatarPrompt
            : draftAvatarPrompt as String?,
        avatarStatus: avatarStatus ?? this.avatarStatus,
        avatarError:
            identical(avatarError, _keep) ? this.avatarError : avatarError as String?,
        error: identical(error, _keep) ? this.error : error as String?,
        applyErrors: applyErrors ?? this.applyErrors,
        conflictWarning: identical(conflictWarning, _keep)
            ? this.conflictWarning
            : conflictWarning as String?,
        appliedCharacterId: identical(appliedCharacterId, _keep)
            ? this.appliedCharacterId
            : appliedCharacterId as int?,
        lastSummary: identical(lastSummary, _keep)
            ? this.lastSummary
            : lastSummary as String?,
        lastRequestInputTokens: identical(lastRequestInputTokens, _keep)
            ? this.lastRequestInputTokens
            : lastRequestInputTokens as int?,
        lastRequestCachedInputTokens:
            lastRequestCachedInputTokens ?? this.lastRequestCachedInputTokens,
        contextEstimateTokens:
            contextEstimateTokens ?? this.contextEstimateTokens,
      );
}

/// 流式正文(当前步尚未落定的 Agent 文本)。
class CardStudioDraftNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;

  void clear() => state = '';
}

final cardStudioDraftProvider =
    NotifierProvider<CardStudioDraftNotifier, String>(CardStudioDraftNotifier.new);
