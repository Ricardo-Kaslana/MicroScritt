/// 制卡差异与提交合成:纯模型,不依赖 Flutter/Riverpod/数据层。
///
/// - 行级 diff:公共前后缀裁剪 + LCS;超大文本降级为整块替换,保证 UI 与
///   内存安全(卡片文本通常百行内,LCS 足够且结果确定)。
/// - 审阅决策与提交合成放在同一文件:UI 只维护开关/编辑值,最终卡与完整
///   条目列表由 [buildCardSubmission] 一次算出,避免各处重复合并逻辑。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../models/character_card.dart';
import '../../models/worldbook_entry.dart';
import 'card_staging.dart';

/// 行级 diff 的行类型。
enum DiffLineKind { same, added, removed }

class DiffLine {
  final DiffLineKind kind;
  final String text;
  const DiffLine(this.kind, this.text);
}

/// 一段文本的逐行差异。
class TextDiff {
  final List<DiffLine> lines;
  const TextDiff(this.lines);

  int get addedCount => lines.where((l) => l.kind == DiffLineKind.added).length;

  int get removedCount =>
      lines.where((l) => l.kind == DiffLineKind.removed).length;

  bool get hasChanges => addedCount > 0 || removedCount > 0;
}

/// 折叠后的显示行:[collapsedCount] 非空表示「… N 行未变 …」占位。
class FoldedDiffLine {
  final DiffLineKind kind;
  final String text;
  final int? collapsedCount;
  const FoldedDiffLine(this.kind, this.text, {this.collapsedCount});
}

/// 字符/行级 diff 的规模上限:超过则整块删+整块增,避免 O(n*m) 拖垮 UI。
const int kLineDiffCellLimit = 40000;

/// 逐行 diff(行分隔按 `\n`,兼容 CRLF;空串视为零行)。
TextDiff diffText(String oldText, String newText) {
  if (oldText == newText) {
    return TextDiff([
      for (final line in _splitLines(oldText))
        DiffLine(DiffLineKind.same, line),
    ]);
  }
  final a = _splitLines(oldText);
  final b = _splitLines(newText);
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final middle = _diffMiddle(
    a.sublist(prefix, a.length - suffix),
    b.sublist(prefix, b.length - suffix),
  );
  return TextDiff([
    for (var i = 0; i < prefix; i++) DiffLine(DiffLineKind.same, a[i]),
    ...middle,
    for (var i = a.length - suffix; i < a.length; i++)
      DiffLine(DiffLineKind.same, a[i]),
  ]);
}

List<String> _splitLines(String s) {
  if (s.isEmpty) return const [];
  return s.replaceAll('\r\n', '\n').split('\n');
}

List<DiffLine> _diffMiddle(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0) {
    return [for (final line in b) DiffLine(DiffLineKind.added, line)];
  }
  if (m == 0) {
    return [for (final line in a) DiffLine(DiffLineKind.removed, line)];
  }
  if (n * m > kLineDiffCellLimit) {
    // 超大规模:整块替换,保持「先删后增」的 git 观感。
    return [
      for (final line in a) DiffLine(DiffLineKind.removed, line),
      for (final line in b) DiffLine(DiffLineKind.added, line),
    ];
  }
  final width = m + 1;
  final dp = Int32List((n + 1) * width);
  int at(int i, int j) => dp[i * width + j];
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (a[i - 1] == b[j - 1]) {
        dp[i * width + j] = at(i - 1, j - 1) + 1;
      } else {
        final up = at(i - 1, j);
        final left = at(i, j - 1);
        dp[i * width + j] = up >= left ? up : left;
      }
    }
  }
  final reversed = <DiffLine>[];
  var i = n;
  var j = m;
  while (i > 0 && j > 0) {
    if (a[i - 1] == b[j - 1]) {
      reversed.add(DiffLine(DiffLineKind.same, a[i - 1]));
      i--;
      j--;
    } else if (at(i - 1, j) > at(i, j - 1)) {
      reversed.add(DiffLine(DiffLineKind.removed, a[i - 1]));
      i--;
    } else {
      reversed.add(DiffLine(DiffLineKind.added, b[j - 1]));
      j--;
    }
  }
  while (i > 0) {
    reversed.add(DiffLine(DiffLineKind.removed, a[i - 1]));
    i--;
  }
  while (j > 0) {
    reversed.add(DiffLine(DiffLineKind.added, b[j - 1]));
    j--;
  }
  return reversed.reversed.toList();
}

/// 把未变化的行折叠成占位:只保留变化行前后 [context] 行。
/// 无变化的 diff 返回空列表(调用方直接不渲染该字段)。
List<FoldedDiffLine> foldDiffLines(TextDiff diff, {int context = 3}) {
  final lines = diff.lines;
  if (!diff.hasChanges) return const [];
  final keep = List<bool>.filled(lines.length, false);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].kind == DiffLineKind.same) continue;
    final from = i - context < 0 ? 0 : i - context;
    final to = i + context >= lines.length ? lines.length - 1 : i + context;
    for (var k = from; k <= to; k++) {
      keep[k] = true;
    }
  }
  final out = <FoldedDiffLine>[];
  var hidden = 0;
  for (var i = 0; i < lines.length; i++) {
    if (keep[i]) {
      if (hidden > 0) {
        out.add(FoldedDiffLine(DiffLineKind.same, '', collapsedCount: hidden));
        hidden = 0;
      }
      out.add(FoldedDiffLine(lines[i].kind, lines[i].text));
    } else {
      hidden++;
    }
  }
  if (hidden > 0) {
    out.add(FoldedDiffLine(DiffLineKind.same, '', collapsedCount: hidden));
  }
  return out;
}

/// 角色卡字段的显示名与展示顺序(与编辑页字段一致)。
const Map<String, String> kCardFieldLabels = {
  'name': '名字',
  'description': '描述',
  'personality': '性格',
  'scenario': '场景',
  'firstMessage': '开场白',
  'alternateGreetings': '备用开场白',
  'mesExample': '对话示例',
  'systemPrompt': '系统提示词',
  'postHistoryInstructions': '历史后指令',
  'creatorNotes': '作者备注',
  'depthPrompt': '深度提示',
  'tags': '标签',
};

/// 制卡字段护栏:AI 工具面([CardProfile])与提交前校验共用同一份上限。
/// 放在共享模型层,审阅页内联编辑也必须接受同样的检查,不能绕过 AI 侧护栏。
const int kCardMaxNameChars = 80;
const int kCardMaxDescriptionChars = 4000;
const int kCardMaxPersonalityChars = 2000;
const int kCardMaxScenarioChars = 2000;
const int kCardMaxSystemPromptChars = 2000;
const int kCardMaxPostHistoryChars = 2000;
const int kCardMaxCreatorNotesChars = 2000;
const int kCardMaxFirstMessageChars = 8000;
const int kCardMaxMesExampleChars = 8000;
const int kCardMaxDepthPromptChars = 1000;
const int kCardMaxGreetings = 10;
const int kCardMaxGreetingChars = 3000;
const int kCardMaxTags = 20;
const int kCardMaxTagChars = 40;
const int kCardMaxCardTextChars = 48000;

/// 世界书护栏(同为 AI 工具面与提交校验共用)。
const int kCardMaxEntriesTotal = 60;
const int kCardMaxEntryContentChars = 6000;
const int kCardMaxEntryKeys = 20;
const int kCardMaxEntryKeyChars = 40;
const int kCardMaxWorldbookTextChars = 80000;

/// 单值字符串字段的长度上限(与 AI 侧 `_stringFieldCaps` 同源)。
const Map<String, int> kCardStringFieldCaps = {
  'name': kCardMaxNameChars,
  'description': kCardMaxDescriptionChars,
  'personality': kCardMaxPersonalityChars,
  'scenario': kCardMaxScenarioChars,
  'firstMessage': kCardMaxFirstMessageChars,
  'mesExample': kCardMaxMesExampleChars,
  'systemPrompt': kCardMaxSystemPromptChars,
  'postHistoryInstructions': kCardMaxPostHistoryChars,
  'creatorNotes': kCardMaxCreatorNotesChars,
  'depthPrompt': kCardMaxDepthPromptChars,
};

/// 可编辑卡面文本总长(与 AI 暂存同一口径)。
int cardEditableTextLength(CharacterCard card) => cardTextLengthOf(card);

/// 单个字段的差异(old/new + 行级 diff)。
class FieldDiff {
  final String key;
  final String label;
  final String oldText;
  final String newText;
  final TextDiff diff;
  const FieldDiff({
    required this.key,
    required this.label,
    required this.oldText,
    required this.newText,
    required this.diff,
  });
}

enum WorldbookChangeKind { added, modified, removed }

/// 一条世界书条目的新增/修改/删除。
class WorldbookEntryDiff {
  final WorldbookChangeKind kind;
  final int? baseId;
  final WorldbookEntry? oldEntry;
  final WorldbookEntry? newEntry;
  final List<FieldDiff> fieldDiffs;

  const WorldbookEntryDiff({
    required this.kind,
    this.baseId,
    this.oldEntry,
    this.newEntry,
    this.fieldDiffs = const [],
  });

  /// 审阅决策的稳定 key:既有条目按 id,新条目按负临时 id。
  String get reviewKey {
    final id = baseId;
    if (id != null) return 'base:$id';
    return 'new:${newEntry?.id}';
  }

  String get displayName =>
      newEntry?.displayLabel ?? oldEntry?.displayLabel ?? '(未命名条目)';

  FieldDiff? get contentField {
    for (final f in fieldDiffs) {
      if (f.key == 'content') return f;
    }
    return null;
  }
}

/// 头像资产 hash 变更(before/after;新 hash 非空且不同才视为变更)。
class AvatarDiff {
  final String? oldHash;
  final String? newHash;
  const AvatarDiff({this.oldHash, this.newHash});

  bool get hasChange => newHash != null && newHash != oldHash;
}

/// 一轮提案相对基线的全部差异。
class CardDiff {
  final List<FieldDiff> fields;
  final List<WorldbookEntryDiff> entries;
  final AvatarDiff? avatar;

  const CardDiff({
    this.fields = const [],
    this.entries = const [],
    this.avatar,
  });

  bool get hasChanges =>
      fields.isNotEmpty || entries.isNotEmpty || (avatar?.hasChange ?? false);

  /// 审阅项计数(字段 + 条目 + 头像),用于 Tab 徽标与应用按钮。
  int get changeCount =>
      fields.length + entries.length + ((avatar?.hasChange ?? false) ? 1 : 0);
}

/// 计算 draft 相对 base 的差异。新建卡传 `const CharacterCard()` 作基线。
CardDiff computeCardDiff({
  required CharacterCard baseCard,
  required List<WorldbookEntry> baseEntries,
  required CharacterCard draftCard,
  required List<WorldbookEntry> draftEntries,
}) {
  final fields = <FieldDiff>[];
  for (final key in kEditableCardFieldKeys) {
    final oldText = cardFieldText(baseCard, key);
    final newText = cardFieldText(draftCard, key);
    if (oldText == newText) continue;
    fields.add(
      FieldDiff(
        key: key,
        label: kCardFieldLabels[key] ?? key,
        oldText: oldText,
        newText: newText,
        diff: diffText(oldText, newText),
      ),
    );
  }

  final baseById = <int, WorldbookEntry>{
    for (final e in baseEntries)
      if (e.id != null) e.id!: e,
  };
  final draftById = <int, WorldbookEntry>{
    for (final e in draftEntries)
      if (e.id != null) e.id!: e,
  };
  final added = <WorldbookEntryDiff>[];
  for (final e in draftEntries) {
    final id = e.id;
    if (id != null && id >= 0) continue;
    // 基线里已有同一负临时 id = 上一轮应用后延续下来的条目(旧草稿可能把
    // 这类 id 原样存进基线)。它既不新增也不删除,否则会和下面的删除分支
    // 凑成一对内容完全相同的假差异。
    if (id != null && baseById.containsKey(id)) continue;
    added.add(
      WorldbookEntryDiff(
        kind: WorldbookChangeKind.added,
        newEntry: e,
        fieldDiffs: entryFieldDiffs(null, e),
      ),
    );
  }
  final modified = <WorldbookEntryDiff>[];
  final removed = <WorldbookEntryDiff>[];
  for (final base in baseEntries) {
    final id = base.id;
    if (id == null) continue;
    final draft = draftById[id];
    if (draft == null) {
      removed.add(
        WorldbookEntryDiff(
          kind: WorldbookChangeKind.removed,
          baseId: id,
          oldEntry: base,
          fieldDiffs: entryFieldDiffs(base, null),
        ),
      );
      continue;
    }
    final diffs = entryFieldDiffs(base, draft);
    if (diffs.isEmpty) continue;
    modified.add(
      WorldbookEntryDiff(
        kind: WorldbookChangeKind.modified,
        baseId: id,
        oldEntry: base,
        newEntry: draft,
        fieldDiffs: diffs,
      ),
    );
  }

  final oldAvatar = baseCard.avatarHash;
  final newAvatar = draftCard.avatarHash;
  final avatar = newAvatar != oldAvatar
      ? AvatarDiff(oldHash: oldAvatar, newHash: newAvatar)
      : null;

  return CardDiff(
    fields: fields,
    entries: [...added, ...modified, ...removed],
    avatar: avatar,
  );
}

/// 卡片字段的文本投影(列表字段按行拼接),供 diff 与提示词共用。
String cardFieldText(CharacterCard card, String key) => switch (key) {
  'name' => card.name,
  'description' => card.description,
  'personality' => card.personality,
  'scenario' => card.scenario,
  'firstMessage' => card.firstMessage,
  'alternateGreetings' => card.alternateGreetings.join('\n'),
  'mesExample' => card.mesExample,
  'systemPrompt' => card.systemPrompt,
  'postHistoryInstructions' => card.postHistoryInstructions,
  'creatorNotes' => card.creatorNotes,
  'depthPrompt' => card.depthPrompt,
  'tags' => card.tags.join('\n'),
  _ => '',
};

/// 两条世界书条目之间的建模字段差异。
///
/// 审阅页在用户内联编辑后以同一口径重算展示,保证所见即所得。
List<FieldDiff> entryFieldDiffs(WorldbookEntry? old, WorldbookEntry? now) {
  final out = <FieldDiff>[];
  void add(String key, String label, String a, String b) {
    if (a == b) return;
    out.add(
      FieldDiff(
        key: key,
        label: label,
        oldText: a,
        newText: b,
        diff: diffText(a, b),
      ),
    );
  }

  add('name', '名称', old?.name ?? '', now?.name ?? '');
  add(
    'keys',
    '关键词',
    (old?.keys ?? const []).join(', '),
    (now?.keys ?? const []).join(', '),
  );
  add(
    'secondaryKeys',
    '次关键词',
    (old?.secondaryKeys ?? const []).join(', '),
    (now?.secondaryKeys ?? const []).join(', '),
  );
  add('content', '内容', old?.content ?? '', now?.content ?? '');
  add('constant', '常驻', _flag(old?.constant), _flag(now?.constant));
  add('selective', '选择性触发', _flag(old?.selective), _flag(now?.selective));
  add('useRegex', '正则', _flag(old?.useRegex), _flag(now?.useRegex));
  add(
    'caseSensitive',
    '区分大小写',
    _flag(old?.caseSensitive),
    _flag(now?.caseSensitive),
  );
  add(
    'matchWholeWords',
    '整词匹配',
    _flag(old?.matchWholeWords),
    _flag(now?.matchWholeWords),
  );
  add('enabled', '启用', _flag(old?.enabled), _flag(now?.enabled));
  add('background', '后台锚定', _flag(old?.background), _flag(now?.background));
  return out;
}

/// 决策后的字段展示文本(编辑值优先;列表字段按行拼接仅供展示)。
String effectiveFieldText(FieldDiff field, FieldDecision decision) =>
    decision.editedList?.join('\n') ?? decision.editedText ?? field.newText;

/// 决策后的字段展示 diff;编辑回原文视为无差异并返回 null。
TextDiff? effectiveFieldDiff(FieldDiff field, FieldDecision decision) {
  final text = effectiveFieldText(field, decision);
  if (text == field.oldText) return null;
  if (decision.editedText == null && decision.editedList == null) {
    return field.diff;
  }
  return diffText(field.oldText, text);
}

/// 决策后的条目展示值;删除条目返回 null。
WorldbookEntry? effectiveEntryValue(
  WorldbookEntryDiff diff,
  EntryDecision decision,
) {
  if (diff.kind == WorldbookChangeKind.removed) return null;
  return decision.editedEntry ?? diff.newEntry;
}

/// 决策后的条目字段展示 diff(编辑值优先)。
List<FieldDiff> effectiveEntryFieldDiffs(
  WorldbookEntryDiff diff,
  EntryDecision decision,
) {
  if (diff.kind == WorldbookChangeKind.removed) return diff.fieldDiffs;
  return entryFieldDiffs(diff.oldEntry, effectiveEntryValue(diff, decision));
}

String _flag(bool? value) => value == null ? '' : (value ? '是' : '否');

/// 单个字段的审阅决策。编辑即视为接受(accepted 同时置 true)。
class FieldDecision {
  final bool accepted;

  /// 纯文本字段的编辑结果;列表字段不使用。
  final String? editedText;

  /// 列表字段(备用开场白/标签)的逐元素编辑结果。
  ///
  /// 与 [editedText] 互斥:列表字段必须按元素保存,不能经换行/逗号文本投影
  /// 往返,否则元素内部的换行或逗号会被拆成多条。
  final List<String>? editedList;

  const FieldDecision({this.accepted = true, this.editedText, this.editedList});
}

/// 单条世界书条目的审阅决策。
class EntryDecision {
  final bool accepted;
  final WorldbookEntry? editedEntry;
  const EntryDecision({this.accepted = true, this.editedEntry});
}

/// 审阅决策集合:默认全接受;key 见 [WorldbookEntryDiff.reviewKey]。
class ReviewDecisions {
  final Map<String, FieldDecision> fields;
  final Map<String, EntryDecision> entries;
  final bool avatarAccepted;

  const ReviewDecisions({
    this.fields = const {},
    this.entries = const {},
    this.avatarAccepted = true,
  });

  static const ReviewDecisions acceptAll = ReviewDecisions();

  FieldDecision field(String key) => fields[key] ?? const FieldDecision();

  EntryDecision entry(String key) => entries[key] ?? const EntryDecision();

  ReviewDecisions withField(String key, FieldDecision value) => ReviewDecisions(
    fields: {...fields, key: value},
    entries: entries,
    avatarAccepted: avatarAccepted,
  );

  ReviewDecisions withEntry(String key, EntryDecision value) => ReviewDecisions(
    fields: fields,
    entries: {...entries, key: value},
    avatarAccepted: avatarAccepted,
  );

  ReviewDecisions withAvatar(bool accepted) => ReviewDecisions(
    fields: fields,
    entries: entries,
    avatarAccepted: accepted,
  );
}

/// 提交值:最终卡(含头像)与完整世界书列表。
class CardSubmission {
  final CharacterCard card;
  final List<WorldbookEntry> entries;
  const CardSubmission({required this.card, required this.entries});
}

/// 由基线 + draft + 决策合成最终提交值。
///
/// 世界书必须输出**完整列表**(replaceForCharacter 是整组语义);未提及的
/// 条目按"保持基线"处理,漏传会误删。头像只有在存在新生成图且被接受时
/// 才覆盖,避免无变更轮把既有头像清空。
CardSubmission buildCardSubmission({
  required CharacterCard baseCard,
  required List<WorldbookEntry> baseEntries,
  required CharacterCard draftCard,
  required List<WorldbookEntry> draftEntries,
  required ReviewDecisions decisions,
}) {
  String pickString(String key, String base, String draft) {
    final d = decisions.field(key);
    if (!d.accepted) return base;
    return d.editedText ?? draft;
  }

  List<String> pickList(
    String key,
    List<String> base,
    List<String> draft, {
    required bool commaSeparated,
  }) {
    final d = decisions.field(key);
    if (!d.accepted) return base;
    if (d.editedList != null) return List.of(d.editedList!);
    // 兼容旧草稿留下的文本投影编辑值;新审阅 UI 一律写 editedList。
    final text = d.editedText;
    if (text == null) return draft;
    final pattern = commaSeparated ? RegExp(r'[,，\n]') : RegExp(r'\n');
    return text
        .split(pattern)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  final card = CharacterCard(
    name: pickString('name', baseCard.name, draftCard.name).trim(),
    description: pickString(
      'description',
      baseCard.description,
      draftCard.description,
    ),
    personality: pickString(
      'personality',
      baseCard.personality,
      draftCard.personality,
    ),
    scenario: pickString('scenario', baseCard.scenario, draftCard.scenario),
    firstMessage: pickString(
      'firstMessage',
      baseCard.firstMessage,
      draftCard.firstMessage,
    ),
    mesExample: pickString(
      'mesExample',
      baseCard.mesExample,
      draftCard.mesExample,
    ),
    systemPrompt: pickString(
      'systemPrompt',
      baseCard.systemPrompt,
      draftCard.systemPrompt,
    ),
    postHistoryInstructions: pickString(
      'postHistoryInstructions',
      baseCard.postHistoryInstructions,
      draftCard.postHistoryInstructions,
    ),
    creatorNotes: pickString(
      'creatorNotes',
      baseCard.creatorNotes,
      draftCard.creatorNotes,
    ),
    depthPrompt: pickString(
      'depthPrompt',
      baseCard.depthPrompt,
      draftCard.depthPrompt,
    ),
    avatarHash: decisions.avatarAccepted && draftCard.avatarHash != null
        ? draftCard.avatarHash
        : baseCard.avatarHash,
    backgroundHash: baseCard.backgroundHash,
    alternateGreetings: pickList(
      'alternateGreetings',
      baseCard.alternateGreetings,
      draftCard.alternateGreetings,
      commaSeparated: false,
    ),
    tags: pickList('tags', baseCard.tags, draftCard.tags, commaSeparated: true),
    creator: baseCard.creator,
    characterVersion: baseCard.characterVersion,
    talkativeness: baseCard.talkativeness,
    fav: baseCard.fav,
    bubbleStyle: baseCard.bubbleStyle,
    raw: baseCard.raw,
  );

  final draftById = <int, WorldbookEntry>{
    for (final e in draftEntries)
      if (e.id != null) e.id!: e,
  };
  // 与 computeCardDiff 同口径:基线里的负临时 id 与草稿同 id 条目是同一
  // 暂存条目,配对后不再走「新增」分支,避免拒绝修改时旧新两份同时提交。
  final pairedTempIds = <int>{};
  final entries = <WorldbookEntry>[];
  for (final base in baseEntries) {
    final id = base.id;
    if (id == null) {
      entries.add(base);
      continue;
    }
    final draft = draftById[id];
    if (draft == null) {
      // 删除提案:默认接受;拒绝则保留基线。
      if (!decisions.entry('base:$id').accepted) entries.add(base);
      continue;
    }
    if (id < 0) pairedTempIds.add(id);
    if (entryEquals(base, draft)) {
      entries.add(base);
      continue;
    }
    final d = decisions.entry('base:$id');
    if (!d.accepted) {
      entries.add(base);
      continue;
    }
    entries.add(d.editedEntry ?? draft);
  }
  for (final draft in draftEntries) {
    final id = draft.id;
    if (id != null && id >= 0) continue;
    if (id != null && pairedTempIds.contains(id)) continue;
    final d = decisions.entry('new:$id');
    if (!d.accepted) continue;
    entries.add(d.editedEntry ?? draft);
  }

  return CardSubmission(card: card, entries: entries);
}

/// 两条世界书条目的完整等价判断(含 id;冲突检测与提交合成共用)。
bool entryEquals(WorldbookEntry a, WorldbookEntry b) =>
    a.id == b.id && entryContentEquals(a, b);

/// 忽略 id 与归属的内容等价:旧草稿把负临时 id 存进基线时,恢复按它
/// 与当前库条目对账(见 CardStudioController._remapTempEntryIds)。
bool entryContentEquals(WorldbookEntry a, WorldbookEntry b) =>
    a.name == b.name &&
    _listEquals(a.keys, b.keys) &&
    a.useRegex == b.useRegex &&
    a.caseSensitive == b.caseSensitive &&
    a.matchWholeWords == b.matchWholeWords &&
    a.selective == b.selective &&
    _listEquals(a.secondaryKeys, b.secondaryKeys) &&
    a.constant == b.constant &&
    a.content == b.content &&
    a.position == b.position &&
    a.enabled == b.enabled &&
    a.background == b.background &&
    jsonEncode(a.extra) == jsonEncode(b.extra);

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 应用前校验;返回空列表表示可提交。
///
/// 与 AI 工具面复用同一份上限:审阅页内联编辑可能把值改到超限,提交前必须
/// 以同一口径复查,否则 UI 编辑成为绕过护栏的通道。保留最小语义校验
/// (名字/正文/关键词)在前,便于用户先修硬伤。
List<String> validateCardSubmission(CardSubmission submission) {
  final errors = <String>[];
  final card = submission.card;
  final name = card.name.trim();
  if (name.isEmpty) {
    errors.add('角色名字不能为空');
  } else if (card.name.length > kCardMaxNameChars) {
    errors.add('角色名字不能超过 $kCardMaxNameChars 字符');
  }
  for (final field in kCardStringFieldCaps.entries) {
    if (field.key == 'name') continue;
    final length = cardFieldText(card, field.key).length;
    if (length > field.value) {
      errors.add(
        '${kCardFieldLabels[field.key] ?? field.key}不能超过 ${field.value} 字符'
        '(当前 $length)',
      );
    }
  }
  if (card.alternateGreetings.length > kCardMaxGreetings) {
    errors.add('备用开场白不能超过 $kCardMaxGreetings 条');
  }
  for (final greeting in card.alternateGreetings) {
    if (greeting.length > kCardMaxGreetingChars) {
      errors.add('备用开场白单条不能超过 $kCardMaxGreetingChars 字符');
      break;
    }
  }
  if (card.tags.length > kCardMaxTags) {
    errors.add('标签不能超过 $kCardMaxTags 个');
  }
  for (final tag in card.tags) {
    if (tag.length > kCardMaxTagChars) {
      errors.add('标签单条不能超过 $kCardMaxTagChars 字符');
      break;
    }
  }
  final cardTextLength = cardEditableTextLength(card);
  if (cardTextLength > kCardMaxCardTextChars) {
    errors.add('角色卡可编辑文本不能超过 $kCardMaxCardTextChars 字符(当前 $cardTextLength)');
  }
  if (submission.entries.length > kCardMaxEntriesTotal) {
    errors.add('世界书条目不能超过 $kCardMaxEntriesTotal 条');
  }
  var worldbookChars = 0;
  for (final e in submission.entries) {
    final label = e.displayLabel;
    worldbookChars += e.content.length;
    if (e.content.trim().isEmpty) {
      errors.add('世界书条目「$label」内容不能为空');
    } else if (e.content.length > kCardMaxEntryContentChars) {
      errors.add(
        '世界书条目「$label」内容不能超过 $kCardMaxEntryContentChars 字符'
        '(当前 ${e.content.length})',
      );
    }
    if (e.keys.isEmpty && !e.constant) {
      errors.add('世界书条目「$label」需要关键词或设为常驻');
    }
    if (e.keys.length > kCardMaxEntryKeys ||
        e.secondaryKeys.length > kCardMaxEntryKeys) {
      errors.add('世界书条目「$label」关键词不能超过 $kCardMaxEntryKeys 个');
    }
    for (final key in [...e.keys, ...e.secondaryKeys]) {
      if (key.length > kCardMaxEntryKeyChars) {
        errors.add('世界书条目「$label」关键词不能超过 $kCardMaxEntryKeyChars 字符');
        break;
      }
    }
  }
  if (worldbookChars > kCardMaxWorldbookTextChars) {
    errors.add(
      '世界书正文总量不能超过 $kCardMaxWorldbookTextChars 字符'
      '(当前 $worldbookChars)',
    );
  }
  return errors;
}
