/// 后台提示词的共享数据段:legacy 单发引擎与 agentic 维护 profile 共用同一份
/// 段落字节(锚定三段/转录/delta/变量/权限),契约文本(JSON 宪法 vs 工具宪法)
/// 留在各消费方 —— 数据段单点维护,两种模式对模型呈现的上下文逐字同构。
library;

import 'dart:convert';
import '../models/character_card.dart';
import '../models/image_prompt_guide.dart';
import '../models/message.dart';
import '../models/worldbook_entry.dart';

/// 段落标签包裹:与主写引擎 ContextAssembler._wrap 同构 ——
/// `<标签>说明行\n正文</标签>`,让模型明确分辨设定锚定与对话内容的边界。
String backgroundTag(String tag, String description, String content) =>
    '<$tag>$description\n$content</$tag>';

/// 截断保开头并加省略标记(锚定段兜底,防超长文本塞满每轮请求)。
String backgroundTruncate(String text, int maxChars) {
  final t = text.trim();
  if (t.length <= maxChars) return t;
  return '${t.substring(0, maxChars)}…(超长已截断)';
}

/// 快状态轮的角色卡紧凑形态(只取 Name/Description/Personality/Scenario;
/// systemPrompt/示例对话/剧情后注不进锚定段)。
String compactCharacterText(CharacterCard? character, {required int maxChars}) {
  final c = character;
  if (c == null) return '';
  final text = [
    if (c.name.isNotEmpty) 'Name: ${c.name}',
    if (c.description.isNotEmpty) 'Description:\n${c.description}',
    if (c.personality.isNotEmpty) 'Personality:\n${c.personality}',
    if (c.scenario.isNotEmpty) 'Scenario:\n${c.scenario}',
  ].join('\n\n');
  return backgroundTruncate(text, maxChars);
}

/// 后台锚定世界书内容:取用户选定(`background`,状态面板后台agent 区
/// 多选)且启用的条目,按 position 排序,**逐条截断**后拼合再套总量兜底。
/// 逐条截断是显式语义:用户勾了几条,每条都要真进锚定段(哪怕被夹到
/// [maxEntryChars]),不能让 position 靠后的外貌条目被前面吃光预算整段清零。
/// 后台锚定按用户选定,不再按常驻判断;初始化路径(记忆/生图指导)仍按
/// 常驻取数,不走此函数。
String backgroundWorldbookText(
  List<WorldbookEntry> worldbook, {
  required int maxChars,
  required int maxEntryChars,
}) {
  final entries = worldbook.where((e) => e.background && e.enabled).toList()
    ..sort((a, b) => a.position.compareTo(b.position));
  if (entries.isEmpty) return '';
  final joined = entries
      .map((e) => backgroundTruncate(e.content, maxEntryChars))
      .join('\n\n');
  return backgroundTruncate(joined, maxChars);
}

/// image 轮的只读锚定段(顺序固定:guide → character → memory → worldbook):
/// 生图指导空则回退内置英文 tag 规范;角色卡/记忆/世界书缺省即整段不注入。
/// 各段截断上限由调用方传入(常量归属 BackgroundEngine,测试引用)。
List<String> imageAnchorSections({
  String? imageGuide,
  CharacterCard? character,
  String? memory,
  List<WorldbookEntry> worldbook = const [],
  required int memoryChars,
  required int characterChars,
  required int worldbookChars,
  required int worldbookEntryChars,
}) {
  final sections = <String>[];
  final guide = imageGuide != null && imageGuide.trim().isNotEmpty
      ? imageGuide.trim()
      : kImageTagGuideEn;
  sections.add(
    backgroundTag(
      'image_guide',
      'Authoritative image direction guide (user-maintained). Reproduce the fixed appearance and style it pins down exactly.',
      guide,
    ),
  );
  final charText = compactCharacterText(character, maxChars: characterChars);
  if (charText.isNotEmpty) {
    sections.add(
      backgroundTag(
        'character',
        'Active character card (read-only reference): name, description, personality, scenario.',
        charText,
      ),
    );
  }
  final mem = memory?.trim() ?? '';
  if (mem.isNotEmpty) {
    sections.add(
      backgroundTag(
        'memory',
        'Session long-term memory (read-only; established facts and continuity; never copy into output).',
        backgroundTruncate(mem, memoryChars),
      ),
    );
  }
  final wbText = backgroundWorldbookText(
    worldbook,
    maxChars: worldbookChars,
    maxEntryChars: worldbookEntryChars,
  );
  if (wbText.isNotEmpty) {
    sections.add(
      backgroundTag(
        'worldbook_background',
        'User-selected worldbook lore for this session (read-only reference).',
        wbText,
      ),
    );
  }
  return sections;
}

/// 最新真实对话段:变量维护的只读上下文、当前画面场景的唯一事实来源。
String transcriptSection(List<Message> history) => backgroundTag(
  'recent_conversation',
  'The most recent conversation turns — read-only context for variables; the source of truth for the current image scene.',
  history.map((m) => '${m.role}: ${m.content}').join('\n'),
);

/// 本轮未处理对话段:变量变化的**唯一**来源(不重放旧改动)。
String variableDeltaSection(List<Message> variableHistory) => backgroundTag(
  'variable_delta',
  'Unprocessed conversation turns for this run — the ONLY source of variable changes; not an image scene source.',
  variableHistory.map((m) => '${m.role}: ${m.content}').join('\n'),
);

/// 当前变量板 JSON 段。
String variablesSection(Map<String, String> variables) => backgroundTag(
  'variables',
  'Current session variables as JSON. Reuse existing keys with their exact spelling; a key you add that is not listed here creates a new variable.',
  jsonEncode(variables),
);

/// 既有键权限段:deletable/readonly 排序后 JSON 化,字节稳定。
String variableAccessSection(Set<String> deletable, Set<String> readonly) {
  final deletableSorted = deletable.toList()..sort();
  final readonlySorted = readonly.toList()..sort();
  return backgroundTag(
    'variable_access',
    'Variable permissions for EXISTING keys: "deletable" lists the exact keys you may remove; '
        '"readonly" keys must never be updated or removed; all other existing keys may be updated '
        'but never removed. New keys are always allowed and are not restricted here.',
    jsonEncode({'deletable': deletableSorted, 'readonly': readonlySorted}),
  );
}

/// 审计宽历史窗段:变量板审计的取证上下文。与维护的 recent_conversation 刻意
/// 不同 —— 审计可据这段宽窗合并近义键/修剪陈旧事实/修正矛盾,不是画面场景来源。
String auditHistorySection(List<Message> history) => backgroundTag(
  'audit_history',
  'Recent conversation turns — evidence for auditing the variable board: merge duplicate or '
      'near-duplicate keys, prune stale or ended facts, and fix contradictions. Read-only context, '
      'not an image scene source.',
  history.map((m) => '${m.role}: ${m.content}').join('\n'),
);