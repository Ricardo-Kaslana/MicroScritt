/// AI 制卡的内存暂存:基线与覆盖分离,工具写动作只改本对象,finish 后由
/// 控制器快照并交给 diff/审阅;失败/取消/护栏触发时整体丢弃,不落库。
///
/// 世界书条目按 id 对账:既有条目保持 id/position/extra 稳定(附件去重
/// 账本依赖 `wb:<id>`);本轮新增条目用负临时 id 索引,落库时由仓库分配
/// 真实 id。
library;

import '../../models/character_card.dart';
import '../../models/worldbook_entry.dart';

/// AI 可编辑的角色卡字段 key(与工具 schema、diff、最终卡构建共用)。
const List<String> kEditableCardFieldKeys = [
  'name',
  'description',
  'personality',
  'scenario',
  'firstMessage',
  'alternateGreetings',
  'mesExample',
  'systemPrompt',
  'postHistoryInstructions',
  'creatorNotes',
  'depthPrompt',
  'tags',
];

const Set<String> kEditableCardFieldKeySet = {
  'name',
  'description',
  'personality',
  'scenario',
  'firstMessage',
  'alternateGreetings',
  'mesExample',
  'systemPrompt',
  'postHistoryInstructions',
  'creatorNotes',
  'depthPrompt',
  'tags',
};

/// 制卡暂存态。字段覆盖 last-action-wins;条目工作副本随 upsert/remove 变化。
class CardStaging {
  /// 基线卡;null = 新建。
  final CharacterCard? baseCard;

  /// 基线条目(只读;用于恢复被删除条目、diff 与 id 校验)。
  final List<WorldbookEntry> baseEntries;

  /// 目标角色 id;新建时为 0(新条目落库由仓库覆盖)。
  final int characterId;

  final Map<String, Object> _fields = {};
  final List<WorldbookEntry> _entries;
  final Set<int> _removedBaseIds = {};
  final Set<int> _everRemoved = {};
  final Set<int> _stagedNewIds = {};
  int _nextTempId = -1;

  /// 暂存的头像生图提示词;null/空 = 未产出。
  String? avatarPrompt;

  /// 已生成的头像(base64,已缩图);与 [generatedPrompt] 配对。
  String? avatarBase64;

  /// 产生 [avatarBase64] 的提示词,用于避免重复生图。
  String? generatedPrompt;

  CardStaging({
    this.baseCard,
    List<WorldbookEntry> baseEntries = const [],
    this.characterId = 0,
  })  : baseEntries = List.unmodifiable(baseEntries),
        _entries = List.of(baseEntries) {
    // 多轮种子可能已带上轮新增条目(负临时 id);新 id 必须继续往更小分配,
    // 否则 `new:-1` 会撞号,审阅决策互相覆盖。
    for (final entry in _entries) {
      final id = entry.id;
      if (id == null || id >= 0) continue;
      _stagedNewIds.add(id);
      if (id <= _nextTempId) _nextTempId = id - 1;
    }
  }

  Map<String, Object> get fieldOverrides => Map.unmodifiable(_fields);

  List<WorldbookEntry> get workingEntries => List.unmodifiable(_entries);

  Set<int> get removedBaseIds => Set.unmodifiable(_removedBaseIds);

  /// 曾暂存删除的不同基线条目 id(累计帽按它计,remove→upsert→remove 不重复计)。
  Set<int> get everRemoved => Set.unmodifiable(_everRemoved);

  int get stagedNewCount => _stagedNewIds.length;

  bool isStagedNew(int id) => id < 0;

  bool isRemoved(int id) => _removedBaseIds.contains(id);

  /// 已覆盖字段数(readDraft 摘要用)。
  int get overriddenFieldCount => _fields.length;

  /// 当前工作卡:基线 + 字段覆盖,未覆盖字段原样保留。
  CharacterCard get workingCard {
    final b = baseCard;
    String str(String key, String fallback) =>
        _fields.containsKey(key) ? _fields[key] as String : fallback;
    List<String> list(String key, List<String> fallback) => _fields.containsKey(key)
        ? List<String>.unmodifiable(_fields[key] as List<String>)
        : fallback;
    return CharacterCard(
      name: str('name', b?.name ?? ''),
      description: str('description', b?.description ?? ''),
      personality: str('personality', b?.personality ?? ''),
      scenario: str('scenario', b?.scenario ?? ''),
      firstMessage: str('firstMessage', b?.firstMessage ?? ''),
      mesExample: str('mesExample', b?.mesExample ?? ''),
      systemPrompt: str('systemPrompt', b?.systemPrompt ?? ''),
      postHistoryInstructions:
          str('postHistoryInstructions', b?.postHistoryInstructions ?? ''),
      creatorNotes: str('creatorNotes', b?.creatorNotes ?? ''),
      depthPrompt: str('depthPrompt', b?.depthPrompt ?? ''),
      avatarBase64: avatarBase64 ?? b?.avatarBase64,
      backgroundBase64: b?.backgroundBase64,
      alternateGreetings:
          list('alternateGreetings', b?.alternateGreetings ?? const []),
      tags: list('tags', b?.tags ?? const []),
      creator: b?.creator ?? '',
      characterVersion: b?.characterVersion ?? '',
      talkativeness: b?.talkativeness ?? '',
      fav: b?.fav ?? false,
      bubbleStyle: b?.bubbleStyle,
      // 保留原 raw:落库序列化会把编辑过的字段合并进 raw,信封结构/
      // character_book/未知 extensions 不因 AI 编辑而降级丢失。
      raw: b?.raw ?? const {},
    );
  }

  /// 工具层已做类型校验,这里只做 last-action-wins 覆盖。
  void setFields(Map<String, Object> fields) => _fields.addAll(fields);

  WorldbookEntry? workingEntryById(int id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  WorldbookEntry? baseEntryById(int id) {
    for (final e in baseEntries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 按名称定位(trim + 大小写不敏感);多个同名时返回全部供调用方判歧义。
  List<WorldbookEntry> workingEntriesByName(String name) {
    final target = name.trim().toLowerCase();
    if (target.isEmpty) return const [];
    return [
      for (final e in _entries)
        if (e.name.trim().toLowerCase() == target) e,
    ];
  }

  /// 追加新条目:分配负临时 id 与末尾 position。
  int addEntry(WorldbookEntry prototype) {
    final id = _nextTempId--;
    final maxPos = _entries.fold<int>(-1, (m, e) => e.position > m ? e.position : m);
    final entry = WorldbookEntry(
      id: id,
      characterId: characterId,
      name: prototype.name,
      keys: prototype.keys,
      useRegex: prototype.useRegex,
      caseSensitive: prototype.caseSensitive,
      matchWholeWords: prototype.matchWholeWords,
      selective: prototype.selective,
      secondaryKeys: prototype.secondaryKeys,
      constant: prototype.constant,
      content: prototype.content,
      position: maxPos + 1,
      enabled: prototype.enabled,
      background: prototype.background,
      extra: prototype.extra,
    );
    _entries.add(entry);
    _stagedNewIds.add(id);
    return id;
  }

  /// 写回条目:工作副本中存在则替换;基线条目曾被删除则恢复并替换。
  /// 调用方负责校验 id 属于基线或暂存新条目。
  void upsertEntry(WorldbookEntry updated) {
    final id = updated.id;
    if (id == null) return;
    final index = _entries.indexWhere((e) => e.id == id);
    if (index >= 0) {
      _entries[index] = updated;
      return;
    }
    _removedBaseIds.remove(id);
    _entries.add(updated);
    _sortEntries();
  }

  /// 删除条目;暂存新条目直接抹除且不计删除帽。返回是否命中。
  bool removeEntry(int id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return false;
    _entries.removeAt(index);
    if (_stagedNewIds.remove(id)) return true;
    _removedBaseIds.add(id);
    _everRemoved.add(id);
    return true;
  }

  /// 可编辑卡面文本总长(护栏用;列表字段按条目计)。
  int get cardTextLength {
    final c = workingCard;
    return c.name.length +
        c.description.length +
        c.personality.length +
        c.scenario.length +
        c.firstMessage.length +
        c.mesExample.length +
        c.systemPrompt.length +
        c.postHistoryInstructions.length +
        c.creatorNotes.length +
        c.depthPrompt.length +
        c.alternateGreetings.fold<int>(0, (s, v) => s + v.length) +
        c.tags.fold<int>(0, (s, v) => s + v.length);
  }

  int get worldbookTextLength =>
      _entries.fold<int>(0, (s, e) => s + e.content.length);

  void _sortEntries() {
    _entries.sort((a, b) {
      final byPos = a.position.compareTo(b.position);
      if (byPos != 0) return byPos;
      return (a.id ?? 0).compareTo(b.id ?? 0);
    });
  }
}
