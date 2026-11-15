/// 输入框的行内样式构建器:在保持原文长度与字符不变的前提下,把本地语法
/// 渲染成带样式的 `TextSpan`。
///
/// TextField 的 `buildTextSpan` 不支持删字或内嵌 Widget,因此这里只做样式:
/// 标签标记淡化显示、标签内容真实加粗/斜体/下划线/高亮/上色,引号台词按开关
/// 强调,`<chip>` 标记淡化、内容加底色;`/命令`、`@技能名`、`{{user}}`/
/// `{{char}}` 由共享 [CompiledSyntax] 扫描。返回 null 表示没有可渲染语法,
/// 调用方回退基类渲染。
library;

import 'package:flutter/material.dart';

import 'text_syntax.dart';

TextSpan? buildComposerSpans({
  required String text,
  required TextStyle? baseStyle,
  required CompiledSyntax syntax,
  required SyntaxPalette palette,
  required bool highlightDialogue,
}) {
  if (text.isEmpty) return null;
  final spans = <TextSpan>[];
  final stack = <StyleTag>[];
  var inChip = false;
  var matched = false;

  TextStyle? activeStyle() {
    if (stack.isEmpty && !inChip) return null;
    return composeStyle(
      baseStyle ?? const TextStyle(),
      stack,
      palette,
      chip: inChip,
    );
  }

  /// 输出一段原文(可不连续);内部再按行内 token 切分。返回是否有 token 命中。
  bool emitRange(
    int start,
    int end,
    TextStyle? style, {
    bool includeCommands = true,
  }) {
    if (end <= start) return false;
    final chunk = text.substring(start, end);
    final tokens = syntax.scanInline(
      chunk,
      startsAtBoundary: isSyntaxBoundaryAt(text, start),
      includeCommands: includeCommands,
    );
    if (tokens.isEmpty) {
      spans.add(TextSpan(text: chunk, style: style));
      return false;
    }
    var from = 0;
    for (final t in tokens) {
      if (t.start > from) {
        spans.add(TextSpan(text: chunk.substring(from, t.start), style: style));
      }
      spans.add(
        TextSpan(
          text: chunk.substring(t.start, t.end),
          style: _tokenStyle(style, t.kind, palette),
        ),
      );
      from = t.end;
    }
    if (from < chunk.length) {
      spans.add(TextSpan(text: chunk.substring(from), style: style));
    }
    return true;
  }

  void emitMarkup(String marker, TextStyle? style) {
    spans.add(TextSpan(text: marker, style: markupStyle(style, palette)));
    matched = true;
  }

  /// 引号段:引号本身与内容共同取台词样式;内部标签/ chip 标记用局部栈解析,
  /// 不泄漏到引号外。命令在台词内不具备执行语义,不参与高亮。
  void emitQuote(int absoluteStart, String hit) {
    final outer = activeStyle();
    final quoteStyle = highlightDialogue
        ? (outer ?? baseStyle ?? const TextStyle()).copyWith(
            fontStyle: FontStyle.italic,
            color: palette.dialogueAccent,
          )
        : outer;
    spans.add(TextSpan(text: hit.substring(0, 1), style: quoteStyle));
    final localStack = <StyleTag>[];
    var localChip = false;
    TextStyle? localStyle() => localStack.isEmpty && !localChip
        ? quoteStyle
        : composeStyle(
            quoteStyle ?? baseStyle ?? const TextStyle(),
            localStack,
            palette,
            chip: localChip,
          );
    var cursor = 1;
    for (final m in syntax.innerComposerPattern.allMatches(hit)) {
      if (m.start > cursor) {
        if (emitRange(
          absoluteStart + cursor,
          absoluteStart + m.start,
          localStyle(),
          includeCommands: false,
        )) {
          matched = true;
        }
      }
      final marker = m[0]!;
      emitMarkup(marker, quoteStyle);
      if (marker == '<chip>') {
        localChip = true;
      } else if (marker == '</chip>') {
        localChip = false;
      } else {
        final tag = syntax.tagPattern.firstMatch(marker);
        if (tag != null) applyStyleTag(tag, localStack);
      }
      cursor = m.end;
    }
    if (emitRange(
      absoluteStart + cursor,
      absoluteStart + hit.length - 1,
      localStyle(),
      includeCommands: false,
    )) {
      matched = true;
    }
    spans.add(TextSpan(text: hit.substring(hit.length - 1), style: quoteStyle));
    matched = true;
  }

  var last = 0;
  for (final m in syntax.composerMasterPattern.allMatches(text)) {
    if (emitRange(last, m.start, activeStyle())) matched = true;
    final hit = m[0]!;
    final tag = syntax.tagPattern.firstMatch(hit);
    if (tag != null) {
      emitMarkup(hit, activeStyle());
      applyStyleTag(tag, stack);
    } else if (hit == '<chip>') {
      emitMarkup(hit, activeStyle());
      inChip = true;
    } else if (hit == '</chip>') {
      emitMarkup(hit, activeStyle());
      inChip = false;
    } else {
      emitQuote(m.start, hit);
    }
    last = m.end;
  }
  if (emitRange(last, text.length, activeStyle())) matched = true;

  if (!matched) return null;
  assert(
    spans.map((s) => s.text ?? '').join() == text,
    'composer spans must preserve the original text exactly',
  );
  return TextSpan(style: baseStyle, children: spans);
}

TextStyle _tokenStyle(TextStyle? base, InlineKind kind, SyntaxPalette palette) {
  final style = base ?? const TextStyle();
  switch (kind) {
    case InlineKind.command:
      final weight = style.fontWeight;
      return style.copyWith(
        color: palette.command,
        fontWeight: weight != null && weight.index > FontWeight.w600.index
            ? weight
            : FontWeight.w600,
      );
    case InlineKind.skill:
      return style.copyWith(color: palette.skill);
    case InlineKind.macro:
      return style.copyWith(color: palette.macro, fontStyle: FontStyle.italic);
  }
}
