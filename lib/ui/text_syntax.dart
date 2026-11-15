/// 特殊输入语法的共享定义:标签/引号/chip 正则、行内 token 扫描、
/// 样式栈合成与按表面取色的调色板。
///
/// 输入框([buildComposerSpans])与气泡(`buildRichSpanTree`)必须共用这里的
/// 一份定义,避免「输入框能识别、气泡不认」或两处配色/边界漂移。本文件只做
/// 纯解析与样式计算,不持有正文、不写库、不改变发送内容。
library;

import 'package:flutter/material.dart';

import '../state/slash_commands.dart';

/// 行内样式标签的种类。
enum StyleTagKind { italic, bold, underline, strikethrough, color, highlight }

/// 栈里一个未闭合的样式标签;`<c=RRGGBB>` 携带解析后的颜色。
class StyleTag {
  final StyleTagKind kind;
  final Color? color;
  const StyleTag(this.kind, [this.color]);
}

/// 行内本地 token:斜杠命令、@技能名、未展开的显示宏。
enum InlineKind { command, skill, macro }

class InlineToken {
  final InlineKind kind;
  final int start;
  final int end;
  const InlineToken(this.kind, this.start, this.end);
}

/// 行内样式标签名:用户气泡的 `<tag>` 折叠规则必须避开这些名字,
/// 否则 `<b>…</b>` 会被当成 hook 便签折叠而不是加粗。
const Set<String> kStyleTagNames = {'i', 'b', 'u', 's', 'mark', 'c'};

const String _tagNames = 'i|b|u|s|mark|c';
const String _tagBody = '</?(?:$_tagNames)(?:=#?[0-9a-fA-F]{6})?>';
const String _quoteBody = '“[^”]*”|「[^」]*」|"[^"]*"';

final RegExp _whitespacePattern = RegExp(r'\s');

/// 某个绝对下标是否处于命令的合法边界(文本开头或空白之后)。
bool isSyntaxBoundaryAt(String text, int index) {
  if (index <= 0) return true;
  return _whitespacePattern.hasMatch(text.substring(index - 1, index));
}

/// 编译后的语法集合:按技能集合生成一次,输入框与气泡共用。
///
/// 命令交替来自 [allSlashCommands],大小写不敏感;技能名经 [RegExp.escape],
/// 并按长度降序排,保证长名先于短名命中。技能集合变化时 [compile] 会按
/// signature 失效单槽缓存,不会随技能编辑无限增长。
class CompiledSyntax {
  final String signature;
  final RegExp tagPattern;
  final RegExp tagOnlyPattern;
  final RegExp masterPattern;
  final RegExp quoteRangePattern;
  final RegExp chipPattern;
  final RegExp innerComposerPattern;
  final RegExp composerMasterPattern;
  final RegExp commandPattern;
  final RegExp? skillPattern;
  final RegExp macroPattern;

  CompiledSyntax._({
    required this.signature,
    required this.tagPattern,
    required this.tagOnlyPattern,
    required this.masterPattern,
    required this.quoteRangePattern,
    required this.chipPattern,
    required this.innerComposerPattern,
    required this.composerMasterPattern,
    required this.commandPattern,
    required this.skillPattern,
    required this.macroPattern,
  });

  static CompiledSyntax? _cached;

  /// 单槽 memo:聊天页每次 build 都按当前技能集合取同一实例。
  static CompiledSyntax compile({Set<String> skillNames = const {}}) {
    final names = [
      for (final n in skillNames)
        if (n.isNotEmpty) n,
    ]..sort();
    final signature = names.join('\u0000');
    final cached = _cached;
    if (cached != null && cached.signature == signature) return cached;
    final compiled = _build(signature, names);
    _cached = compiled;
    return compiled;
  }

  static CompiledSyntax _build(String signature, List<String> skillNames) {
    final commandNames = [
      for (final c in allSlashCommands) slashCommandText[c]!,
    ]..sort((a, b) => b.length.compareTo(a.length));
    final commandAlternation = commandNames.map(RegExp.escape).join('|');
    final skillAlternation = [...skillNames]
      ..sort((a, b) {
        final byLength = b.length.compareTo(a.length);
        return byLength != 0 ? byLength : a.compareTo(b);
      });
    final skillPattern = skillNames.isEmpty
        ? null
        : RegExp('@(?:${skillAlternation.map(RegExp.escape).join('|')})');
    return CompiledSyntax._(
      signature: signature,
      tagPattern: RegExp(r'^<(/?)(i|b|u|s|mark|c)(?:=(#?[0-9a-fA-F]{6}))?>$'),
      tagOnlyPattern: RegExp(_tagBody),
      masterPattern: RegExp('$_tagBody|$_quoteBody'),
      quoteRangePattern: RegExp(_quoteBody),
      chipPattern: RegExp(r'<chip>(.*?)</chip>|<chip>(.*?)$', dotAll: true),
      innerComposerPattern: RegExp('$_tagBody|<chip>|</chip>'),
      composerMasterPattern: RegExp('$_tagBody|<chip>|</chip>|$_quoteBody'),
      commandPattern: RegExp(
        '(^|\\s)(/(?:$commandAlternation))(?=\\s|\$)',
        caseSensitive: false,
      ),
      skillPattern: skillPattern,
      macroPattern: RegExp(r'\{\{user\}\}|\{\{char\}\}'),
    );
  }

  /// 粗判文本是否可能含特殊语法,供输入框与气泡走快路径。
  bool mayContainSpecial(String text) {
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x3C || // <
          c == 0x40 || // @
          c == 0x7B || // {
          c == 0x22 || // "
          c == 0x201C || // “
          c == 0x300C || // 「
          c == 0x2F) {
        // /
        return true;
      }
    }
    return false;
  }

  /// 扫描行内 token;命令只取斜杠名本身(不含 args),并遵守原文边界。
  /// [startsAtBoundary] 为假时,chunk 开头即使像命令也不算(前文紧邻非空白)。
  List<InlineToken> scanInline(
    String chunk, {
    bool startsAtBoundary = true,
    bool includeCommands = true,
  }) {
    if (chunk.isEmpty) return const [];
    final found = <InlineToken>[];
    if (includeCommands) {
      for (final m in commandPattern.allMatches(chunk)) {
        final start = m.start + (m.group(1)?.length ?? 0);
        if (!startsAtBoundary && start == 0) continue;
        found.add(InlineToken(InlineKind.command, start, m.end));
      }
    }
    final skills = skillPattern;
    if (skills != null) {
      for (final m in skills.allMatches(chunk)) {
        found.add(InlineToken(InlineKind.skill, m.start, m.end));
      }
    }
    for (final m in macroPattern.allMatches(chunk)) {
      found.add(InlineToken(InlineKind.macro, m.start, m.end));
    }
    if (found.isEmpty) return const [];
    found.sort((a, b) {
      if (a.start != b.start) return a.start.compareTo(b.start);
      final priority = _priority(b.kind).compareTo(_priority(a.kind));
      if (priority != 0) return priority;
      return b.end.compareTo(a.end);
    });
    final merged = <InlineToken>[];
    var lastEnd = 0;
    for (final t in found) {
      if (t.start < lastEnd) continue;
      merged.add(t);
      lastEnd = t.end;
    }
    return merged;
  }

  static int _priority(InlineKind kind) => switch (kind) {
    InlineKind.command => 3,
    InlineKind.skill => 2,
    InlineKind.macro => 1,
  };
}

/// 渲染表面:输入框、用户气泡、助手气泡。配色按底色分别取。
enum SyntaxSurface { composer, userBubble, assistantBubble }

/// 共享调色板;每种表面只决定颜色,不决定语法是否生效。
class SyntaxPalette {
  final Color skill;
  final Color command;
  final Color macro;
  final Color markup;
  final Color markBackground;
  final Color chipBackground;
  final Color dialogueAccent;
  final Color baseTextColor;

  const SyntaxPalette({
    required this.skill,
    required this.command,
    required this.macro,
    required this.markup,
    required this.markBackground,
    required this.chipBackground,
    required this.dialogueAccent,
    required this.baseTextColor,
  });

  factory SyntaxPalette.of(
    ColorScheme scheme,
    SyntaxSurface surface, {
    Color? baseTextColor,
  }) {
    switch (surface) {
      case SyntaxSurface.composer:
        final base = baseTextColor ?? scheme.onSurface;
        return SyntaxPalette(
          skill: scheme.primary,
          command: scheme.tertiary,
          macro: scheme.onSurfaceVariant,
          markup: scheme.outline.withValues(alpha: 0.75),
          markBackground: scheme.secondaryContainer.withValues(alpha: 0.85),
          chipBackground: scheme.secondaryContainer.withValues(alpha: 0.7),
          dialogueAccent: dialogueAccentFor(base, scheme),
          baseTextColor: base,
        );
      case SyntaxSurface.userBubble:
        final base = baseTextColor ?? scheme.onPrimary;
        final lightBubble = scheme.primary.computeLuminance() > 0.5;
        return SyntaxPalette(
          skill: skillColorFor(scheme, onPrimaryBubble: true),
          command: lightBubble
              ? const Color(0xFF7A3E00)
              : const Color(0xFFFFD180),
          macro: base.withValues(alpha: 0.72),
          markup: base.withValues(alpha: 0.6),
          markBackground: scheme.secondaryContainer.withValues(alpha: 0.85),
          chipBackground: base.withValues(alpha: 0.14),
          dialogueAccent: dialogueAccentFor(base, scheme),
          baseTextColor: base,
        );
      case SyntaxSurface.assistantBubble:
        final base = baseTextColor ?? scheme.onSurface;
        return SyntaxPalette(
          skill: scheme.primary,
          command: scheme.tertiary,
          macro: scheme.onSurfaceVariant,
          markup: scheme.outline.withValues(alpha: 0.75),
          markBackground: scheme.secondaryContainer.withValues(alpha: 0.85),
          chipBackground: scheme.secondaryContainer.withValues(alpha: 0.7),
          dialogueAccent: dialogueAccentFor(base, scheme),
          baseTextColor: base,
        );
    }
  }
}

/// @技能名 的共享选色;保留旧签名给 `skill_highlight.dart` 与测试复用。
Color skillColorFor(ColorScheme scheme, {required bool onPrimaryBubble}) {
  if (!onPrimaryBubble) return scheme.primary;
  return scheme.primary.computeLuminance() > 0.5
      ? const Color(0xFF6A1B9A)
      : const Color(0xFFD8B4FE);
}

/// 台词强调色:随气泡正文色取对比,深字叠主题色、浅字压深。
Color dialogueAccentFor(Color base, ColorScheme scheme) {
  if (base.computeLuminance() > 0.5) {
    return Color.alphaBlend(Colors.black.withValues(alpha: 0.18), base);
  }
  return Color.alphaBlend(scheme.primary.withValues(alpha: 0.55), base);
}

StyleTagKind? styleTagKindOf(String name) => switch (name) {
  'i' => StyleTagKind.italic,
  'b' => StyleTagKind.bold,
  'u' => StyleTagKind.underline,
  's' => StyleTagKind.strikethrough,
  'c' => StyleTagKind.color,
  'mark' => StyleTagKind.highlight,
  _ => null,
};

/// 把一条开/闭标签命中应用到栈上;闭合从栈顶向下找最近的同种标签,
/// 找不到则忽略,容忍错配。
void applyStyleTag(Match tag, List<StyleTag> stack) {
  final kind = styleTagKindOf(tag.group(2)!)!;
  if (tag.group(1) == '/') {
    for (var i = stack.length - 1; i >= 0; i--) {
      if (stack[i].kind == kind) {
        stack.removeAt(i);
        break;
      }
    }
  } else if (kind == StyleTagKind.color) {
    final hex = (tag.group(3) ?? '').replaceFirst('#', '');
    stack.add(StyleTag(kind, Color(int.parse('ff$hex', radix: 16))));
  } else {
    stack.add(StyleTag(kind));
  }
}

/// 按入栈顺序合成样式;后入栈覆盖先入栈,decoration 只有一个槽位
/// (删除线会顶掉下划线,与现有气泡语义一致)。[chip] 为真时最后叠胶囊底色。
TextStyle composeStyle(
  TextStyle base,
  List<StyleTag> stack,
  SyntaxPalette palette, {
  bool chip = false,
}) {
  var s = base;
  for (final tag in stack) {
    switch (tag.kind) {
      case StyleTagKind.italic:
        s = s.copyWith(fontStyle: FontStyle.italic);
      case StyleTagKind.bold:
        s = s.copyWith(fontWeight: FontWeight.bold);
      case StyleTagKind.underline:
        s = s.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: s.color?.withValues(alpha: 0.7),
        );
      case StyleTagKind.strikethrough:
        s = s.copyWith(decoration: TextDecoration.lineThrough);
      case StyleTagKind.color:
        if (tag.color != null) s = s.copyWith(color: tag.color);
      case StyleTagKind.highlight:
        s = s.copyWith(backgroundColor: palette.markBackground);
    }
  }
  if (chip) s = s.copyWith(backgroundColor: palette.chipBackground);
  return s;
}

/// 标签标记本身的显示样式:淡化,避免裸标记抢正文的视觉。
TextStyle markupStyle(TextStyle? base, SyntaxPalette palette) =>
    (base ?? const TextStyle()).copyWith(color: palette.markup);
