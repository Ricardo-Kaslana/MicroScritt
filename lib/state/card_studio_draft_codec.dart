/// 制卡草稿的 JSON 编解码(纯 Dart,不依赖 Flutter 数据层)。
///
/// 卡片走紧凑 DTO:只存建模字段/头像/背景,不存 `raw`(大卡 raw 可达数十 MB,
/// 且 draft 的 raw 从不参与提交合成);恢复时由控制器把当前库 raw 附回。
/// 世界书条目复用 `WorldbookEntry.toMap/fromMap`,保留负临时 id、position、extra。
library;

import 'package:flutter/foundation.dart';

import '../engine/card_studio/card_diff.dart';
import '../models/bubble_style.dart';
import '../models/character_card.dart';
import '../models/worldbook_entry.dart';
import 'card_studio_state.dart';

/// 一次草稿快照(恢复所需的全部状态)。
class CardStudioDraftSnapshot {
  final int? targetCharacterId;
  final CharacterCard baseCard;
  final List<WorldbookEntry> baseEntries;
  final CharacterCard draftCard;
  final List<WorldbookEntry> draftEntries;
  final ReviewDecisions decisions;
  final List<CardStudioEntry> entries;
  final List<String> sessionLog;
  final String? draftAvatarPrompt;
  final String? generatedAvatarPrompt;
  final String? lastSummary;

  /// 已由此草稿持有的图片引用;null = 旧格式,恢复后需要补建持有清单。
  final List<String>? heldAssetHashes;

  /// 最近一个逻辑步的真实输入 token;null = 还没有上报过用量。
  final int? lastRequestInputTokens;

  /// 最近一个逻辑步的缓存命中输入 token。
  final int lastRequestCachedInputTokens;

  /// 首个逻辑步完成前的提示词字符估算兜底。
  final int contextEstimateTokens;

  const CardStudioDraftSnapshot({
    required this.targetCharacterId,
    required this.baseCard,
    required this.baseEntries,
    required this.draftCard,
    required this.draftEntries,
    required this.decisions,
    required this.entries,
    required this.sessionLog,
    this.draftAvatarPrompt,
    this.generatedAvatarPrompt,
    this.lastSummary,
    this.heldAssetHashes,
    this.lastRequestInputTokens,
    this.lastRequestCachedInputTokens = 0,
    this.contextEstimateTokens = 0,
  });

  /// 快照两侧卡面出现的全部图片;旧基线也持有,避免外部换图后草稿无法审阅。
  Set<String> get requiredAssetHashes => {
    if (baseCard.avatarHash?.isNotEmpty ?? false) baseCard.avatarHash!,
    if (baseCard.backgroundHash?.isNotEmpty ?? false) baseCard.backgroundHash!,
    if (draftCard.avatarHash?.isNotEmpty ?? false) draftCard.avatarHash!,
    if (draftCard.backgroundHash?.isNotEmpty ?? false)
      draftCard.backgroundHash!,
  };
}

/// 编码草稿;任何不可序列化的值都会抛异常,由调用方按写入失败处理。
Map<String, dynamic> encodeCardStudioDraft(CardStudioDraftSnapshot snapshot) =>
    {
      'target': snapshot.targetCharacterId,
      'base': _encodeSide(snapshot.baseCard, snapshot.baseEntries),
      'draft': _encodeSide(snapshot.draftCard, snapshot.draftEntries),
      'decisions': _encodeDecisions(snapshot.decisions),
      'entries': [for (final entry in snapshot.entries) _encodeEntry(entry)],
      'sessionLog': snapshot.sessionLog,
      'draftAvatarPrompt': snapshot.draftAvatarPrompt,
      'generatedAvatarPrompt': snapshot.generatedAvatarPrompt,
      'lastSummary': snapshot.lastSummary,
      'heldAssetHashes': snapshot.heldAssetHashes,
      'lastRequestInputTokens': snapshot.lastRequestInputTokens,
      'lastRequestCachedInputTokens': snapshot.lastRequestCachedInputTokens,
      'contextEstimateTokens': snapshot.contextEstimateTokens,
    };

/// 解码草稿;版本/结构/条目损坏一律返回 null,坏草稿绝不阻断工作台。
CardStudioDraftSnapshot? decodeCardStudioDraft(Map<String, dynamic> payload) {
  try {
    final target = payload['target'];
    if (target != null && target is! int) return null;
    final base = payload['base'];
    final draft = payload['draft'];
    if (base is! Map || draft is! Map) return null;
    final baseCard = _decodeCard(base['card']);
    final draftCard = _decodeCard(draft['card']);
    final baseEntries = _decodeEntries(base['entries']);
    final draftEntries = _decodeEntries(draft['entries']);
    if (baseCard == null ||
        draftCard == null ||
        baseEntries == null ||
        draftEntries == null) {
      return null;
    }
    final decisions = _decodeDecisions(payload['decisions']);
    final entries = _decodeEntriesLog(payload['entries']);
    final sessionLog = _decodeStringList(payload['sessionLog']);
    if (decisions == null || entries == null || sessionLog == null) {
      return null;
    }
    return CardStudioDraftSnapshot(
      targetCharacterId: target as int?,
      baseCard: baseCard,
      baseEntries: baseEntries,
      draftCard: draftCard,
      draftEntries: draftEntries,
      decisions: decisions,
      entries: entries,
      sessionLog: sessionLog,
      draftAvatarPrompt: _optionalString(payload['draftAvatarPrompt']),
      generatedAvatarPrompt: _optionalString(payload['generatedAvatarPrompt']),
      lastSummary: _optionalString(payload['lastSummary']),
      heldAssetHashes: _stringList(payload['heldAssetHashes']),
      // 用量是展示元数据,坏值只回落默认,不因此丢弃整份草稿。
      lastRequestInputTokens: _optionalTokenCount(
        payload['lastRequestInputTokens'],
      ),
      lastRequestCachedInputTokens: _tokenCount(
        payload['lastRequestCachedInputTokens'],
      ),
      contextEstimateTokens: _tokenCount(payload['contextEstimateTokens']),
    );
  } catch (e) {
    debugPrint('制卡草稿解码失败(已忽略):$e');
    return null;
  }
}

Map<String, dynamic> _encodeSide(
  CharacterCard card,
  List<WorldbookEntry> entries,
) => {
  'card': _encodeCard(card),
  'entries': [for (final entry in entries) entry.toMap()],
};

Map<String, dynamic> _encodeCard(CharacterCard card) => {
  'name': card.name,
  'description': card.description,
  'personality': card.personality,
  'scenario': card.scenario,
  'firstMessage': card.firstMessage,
  'mesExample': card.mesExample,
  'systemPrompt': card.systemPrompt,
  'postHistoryInstructions': card.postHistoryInstructions,
  'creatorNotes': card.creatorNotes,
  'depthPrompt': card.depthPrompt,
  'alternateGreetings': card.alternateGreetings,
  'tags': card.tags,
  'creator': card.creator,
  'characterVersion': card.characterVersion,
  'talkativeness': card.talkativeness,
  'fav': card.fav,
  'bubbleStyle': card.bubbleStyle?.toJson(),
  'avatarHash': card.avatarHash,
  'backgroundHash': card.backgroundHash,
};

CharacterCard? _decodeCard(Object? raw) {
  if (raw is! Map) return null;
  final map = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is! String) return null;
    map[entry.key as String] = entry.value;
  }
  final bubbleRaw = map['bubbleStyle'];
  BubbleStyle? bubble;
  if (bubbleRaw is Map) {
    final bubbleMap = <String, dynamic>{};
    for (final entry in bubbleRaw.entries) {
      if (entry.key is! String) return null;
      bubbleMap[entry.key as String] = entry.value;
    }
    bubble = BubbleStyle.fromJson(bubbleMap);
  }
  return CharacterCard(
    name: _string(map['name']),
    description: _string(map['description']),
    personality: _string(map['personality']),
    scenario: _string(map['scenario']),
    firstMessage: _string(map['firstMessage']),
    mesExample: _string(map['mesExample']),
    systemPrompt: _string(map['systemPrompt']),
    postHistoryInstructions: _string(map['postHistoryInstructions']),
    creatorNotes: _string(map['creatorNotes']),
    depthPrompt: _string(map['depthPrompt']),
    alternateGreetings: _stringList(map['alternateGreetings']) ?? const [],
    tags: _stringList(map['tags']) ?? const [],
    creator: _string(map['creator']),
    characterVersion: _string(map['characterVersion']),
    talkativeness: _string(map['talkativeness']),
    fav: map['fav'] == true,
    bubbleStyle: bubble,
    avatarHash: _optionalString(map['avatarHash']),
    backgroundHash: _optionalString(map['backgroundHash']),
  );
}

List<WorldbookEntry>? _decodeEntries(Object? raw) {
  if (raw is! List) return null;
  final out = <WorldbookEntry>[];
  for (final item in raw) {
    if (item is! Map) return null;
    final map = <String, Object?>{};
    for (final entry in item.entries) {
      if (entry.key is! String) return null;
      map[entry.key as String] = entry.value;
    }
    out.add(WorldbookEntry.fromMap(map));
  }
  return out;
}

Map<String, dynamic> _encodeDecisions(ReviewDecisions decisions) => {
  'fields': {
    for (final entry in decisions.fields.entries)
      entry.key: {
        'accepted': entry.value.accepted,
        if (entry.value.editedText != null) 'edited': entry.value.editedText,
        if (entry.value.editedList != null)
          'editedList': entry.value.editedList,
      },
  },
  'entries': {
    for (final entry in decisions.entries.entries)
      entry.key: {
        'accepted': entry.value.accepted,
        if (entry.value.editedEntry != null)
          'edited': entry.value.editedEntry!.toMap(),
      },
  },
  'avatarAccepted': decisions.avatarAccepted,
};

ReviewDecisions? _decodeDecisions(Object? raw) {
  if (raw is! Map) return null;
  final fieldRaw = raw['fields'];
  final entryRaw = raw['entries'];
  if (fieldRaw is! Map || entryRaw is! Map) return null;
  final fields = <String, FieldDecision>{};
  for (final item in fieldRaw.entries) {
    if (item.key is! String || item.value is! Map) return null;
    final value = item.value as Map;
    fields[item.key as String] = FieldDecision(
      accepted: value['accepted'] != false,
      editedText: _optionalString(value['edited']),
      editedList: _stringList(value['editedList']),
    );
  }
  final entries = <String, EntryDecision>{};
  for (final item in entryRaw.entries) {
    if (item.key is! String || item.value is! Map) return null;
    final value = item.value as Map;
    final editedRaw = value['edited'];
    WorldbookEntry? edited;
    if (editedRaw is Map) {
      final map = <String, Object?>{};
      for (final entry in editedRaw.entries) {
        if (entry.key is! String) return null;
        map[entry.key as String] = entry.value;
      }
      edited = WorldbookEntry.fromMap(map);
    } else if (editedRaw != null) {
      return null;
    }
    entries[item.key as String] = EntryDecision(
      accepted: value['accepted'] != false,
      editedEntry: edited,
    );
  }
  return ReviewDecisions(
    fields: fields,
    entries: entries,
    avatarAccepted: raw['avatarAccepted'] != false,
  );
}

Map<String, dynamic> _encodeEntry(CardStudioEntry entry) => {
  'kind': entry.kind.name,
  'text': entry.text,
  'tools': entry.tools,
  'step': entry.step,
};

List<CardStudioEntry>? _decodeEntriesLog(Object? raw) {
  if (raw is! List) return null;
  final out = <CardStudioEntry>[];
  for (final item in raw) {
    if (item is! Map) return null;
    final kindName = item['kind'];
    final text = item['text'];
    if (kindName is! String || text is! String) return null;
    final kind = _entryKind(kindName);
    if (kind == null) return null;
    out.add(
      CardStudioEntry(
        kind,
        text,
        tools: _stringList(item['tools']) ?? const [],
        step: item['step'] is int ? item['step'] as int : 0,
      ),
    );
  }
  return out;
}

CardStudioEntryKind? _entryKind(String name) {
  for (final kind in CardStudioEntryKind.values) {
    if (kind.name == name) return kind;
  }
  return null;
}

List<String>? _decodeStringList(Object? raw) {
  if (raw is! List) return null;
  return _stringList(raw);
}

List<String>? _stringList(Object? raw) {
  if (raw == null) return null;
  if (raw is! List) return null;
  final out = <String>[];
  for (final item in raw) {
    if (item is! String) return null;
    out.add(item);
  }
  return out;
}

String _string(Object? raw) => raw is String ? raw : '';

String? _optionalString(Object? raw) {
  if (raw == null) return null;
  return raw is String ? raw : null;
}

int? _optionalTokenCount(Object? raw) => raw is int && raw >= 0 ? raw : null;

int _tokenCount(Object? raw) => raw is int && raw >= 0 ? raw : 0;
