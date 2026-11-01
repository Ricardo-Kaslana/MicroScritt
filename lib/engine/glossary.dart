import '../models/worldbook_entry.dart';

/// 词典词条:一个触发词对应的世界书条目(点击气泡内高亮词弹出释义)。
class GlossaryTerm {
  /// 触发词(原文形态,匹配不区分大小写)。
  final String term;

  /// 释义卡标题(条目显示名;空时回退 [term])。
  final String title;

  /// 释义正文(条目 content)。
  final String content;

  /// 是否整词匹配(仅纯 ASCII 词生效,CJK 无词边界、恒为子串)。
  final bool wholeWord;

  const GlossaryTerm({
    required this.term,
    required this.title,
    required this.content,
    this.wholeWord = false,
  });
}

/// 已编译的名词词典:启用中的世界书条目 → 气泡内高亮 + 点击释义。
class CompiledGlossary {
  /// 全部词条,按触发词长度降序(长词优先,防止短词吞掉长词前缀)。
  final List<GlossaryTerm> terms;

  /// 全词条交替正则(大小写不敏感);无词条时为 null(渲染层直接跳过)。
  final RegExp? pattern;

  final Map<String, GlossaryTerm> _byLowerTerm;

  const CompiledGlossary._(this.terms, this.pattern, this._byLowerTerm);

  static const empty = CompiledGlossary._([], null, {});

  bool get isEmpty => terms.isEmpty;

  /// 命中文本(正则匹配到的原文)→ 词条;大小写不敏感。
  GlossaryTerm? termFor(String matched) => _byLowerTerm[matched.toLowerCase()];
}

/// 从世界书条目编译词典:
/// - 只取**启用中**的条目(世界书自 v37 起不再有类型之分;禁用条目不参与);
/// - 跳过 `use_regex` 条目(键是模式不是词,按字面高亮会错);
/// - 跳过空键与空释义;
/// - 同一触发词多个条目时**首个**条目胜出(与世界书触发语义无冲突,纯显示层)。
/// 按输入列表**实例**记忆化(流式期间聊天页每帧重取 Provider 值,实例不变
/// 直接复用,不重编交替正则)。
List<WorldbookEntry>? _lastInput;
CompiledGlossary? _lastCompiled;

CompiledGlossary compileGlossary(List<WorldbookEntry> entries) {
  if (identical(entries, _lastInput)) return _lastCompiled!;
  final byLowerTerm = <String, GlossaryTerm>{};
  for (final e in entries) {
    if (!e.enabled) continue;
    if (e.content.trim().isEmpty) continue;
    for (final k in e.keys) {
      final term = k.trim();
      if (term.isEmpty) continue;
      if (e.useRegex) continue;
      byLowerTerm.putIfAbsent(
        term.toLowerCase(),
        () => GlossaryTerm(
          term: term,
          title: e.name.trim().isEmpty ? term : e.name.trim(),
          content: e.content,
          wholeWord: e.matchWholeWords && _isAsciiWord(term),
        ),
      );
    }
  }
  final CompiledGlossary result;
  if (byLowerTerm.isEmpty) {
    result = CompiledGlossary.empty;
  } else {
    final terms = byLowerTerm.values.toList()
      ..sort((a, b) => b.term.length.compareTo(a.term.length));
    final alternation = terms.map((t) {
      final escaped = RegExp.escape(t.term);
      return t.wholeWord ? r'\b' + escaped + r'\b' : escaped;
    }).join('|');
    result = CompiledGlossary._(
      terms,
      RegExp(alternation, caseSensitive: false),
      byLowerTerm,
    );
  }
  _lastInput = entries;
  _lastCompiled = result;
  return result;
}

/// 纯 ASCII 词(可加 \b 词边界):全部字符都在可打印 ASCII 范围内。
bool _isAsciiWord(String s) =>
    s.isNotEmpty && s.codeUnits.every((c) => c >= 0x20 && c <= 0x7E);
