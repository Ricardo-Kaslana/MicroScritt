/// 消息正文的显示层富文本管线:宏替换、显示层正则与标记解析。
///
/// 所有改写只作用于气泡显示,落库正文与发给 LLM 的内容保持原文;最终输出
/// `TextSpan` 由 Flutter 原生渲染,不解析 HTML,没有注入面。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../engine/display_regex.dart';
import '../../engine/glossary.dart';

/// 剥离正文里 `<system-reminder>…</system-reminder>` 段所用的正则。
///
/// system-reminder 是给模型的旁路注入(附件/通知),不能在气泡中渲染。附件行
/// 已由消息列表整体过滤,这里是第二道防线:正文若混入该标签(hook 改写、
/// 旧数据导入等)也不露出内部注入文本;流式期间未闭合的尾段一并吞掉。
final RegExp _systemReminderPattern = RegExp(
  r'<system-reminder>[\s\S]*?(?:</system-reminder>|$)',
);

/// 剥掉正文里的 system-reminder 段(含流式中未闭合的尾段)。
///
/// 任何渲染路径都必须先过这一步 —— 超长流式草稿的纯文本降级路径同样如此,
/// 内部注入在任何情况下都不得露出。
String stripSystemReminders(String text) => text.replaceAll(_systemReminderPattern, '');

/// 显示层宏替换:把正文里的 `{{user}}` / `{{char}}` 替换为实际名字。
///
/// 仅改显示,不回写落库内容;名字为空或 null 时保留占位符原样。
String expandDisplayMacros(String text, {String? userName, String? charName}) {
  var out = text;
  if (userName != null && userName.isNotEmpty && out.contains('{{user}}')) {
    out = out.replaceAll('{{user}}', userName);
  }
  if (charName != null && charName.isNotEmpty && out.contains('{{char}}')) {
    out = out.replaceAll('{{char}}', charName);
  }
  return out;
}

/// 单遍扫描的主正则:样式标记(开/闭)与三种引号的台词。
///
/// 交替分支按序尝试,台词分支不允许跨引号(`“…”` 内无 `”`)。台词一旦命中
/// 就整段输出,内部的标记不再解析 —— 引号里的 `<b>` 按原文显示。
final RegExp _masterPattern = RegExp(
  r'</?(?:i|b|u|s|mark|c)(?:=#?[0-9a-fA-F]{6})?>|“[^”]*”|「[^」]*」|"[^"]*"',
);

/// 开/闭标记的独立正则(用于判断主正则命中的是标记还是台词)。
final RegExp _tagPattern = RegExp(r'^<(/?)(i|b|u|s|mark|c)(?:=(#?[0-9a-fA-F]{6}))?>$');

/// 块级胶囊标记:优先匹配闭合形态;无闭合时把 `<chip>` 到文末的尾段也视为
/// 胶囊内容(流式期间即时呈现,不闪裸标记)。
final RegExp _chipPattern = RegExp(r'<chip>(.*?)</chip>|<chip>(.*?)$', dotAll: true);

/// 拆分结果的一块:普通正文段(走行内富文本)或胶囊段(独占一行居中)。
sealed class _RichPart {}

/// 普通正文段,内容继续交给 [buildRichSpanTree] 解析行内标记。
class _RichTextPart extends _RichPart {
  final String text;
  _RichTextPart(this.text);
}

/// 胶囊段:内容已去掉标记并 trim,渲染为居中胶囊。
class _RichChipPart extends _RichPart {
  final String label;
  _RichChipPart(this.label);
}

/// 把(宏替换 + 正则脚本之后的)显示文本按 `<chip>` 标记拆成块序列。
///
/// 标签内容为空的胶囊直接丢弃;纯空白正文段由渲染侧跳过。
List<_RichPart> _splitChips(String text) {
  if (!text.contains('<chip>')) {
    return [_RichTextPart(text)];
  }
  final parts = <_RichPart>[];
  var last = 0;
  for (final m in _chipPattern.allMatches(text)) {
    if (m.start > last) parts.add(_RichTextPart(text.substring(last, m.start)));
    final label = (m.group(1) ?? m.group(2) ?? '').trim();
    if (label.isNotEmpty) parts.add(_RichChipPart(label));
    last = m.end;
  }
  if (last < text.length) parts.add(_RichTextPart(text.substring(last)));
  return parts;
}

/// 样式标记的种类。
enum _TagKind { italic, bold, underline, strikethrough, color, highlight }

_TagKind? _kindOf(String name) => switch (name) {
      'i' => _TagKind.italic,
      'b' => _TagKind.bold,
      'u' => _TagKind.underline,
      's' => _TagKind.strikethrough,
      'c' => _TagKind.color,
      'mark' => _TagKind.highlight,
      _ => null,
    };

/// 栈里一个未闭合的标记。
class _OpenTag {
  final _TagKind kind;

  /// `<c=RRGGBB>` 解析出的颜色(仅 color 种类有值)。
  final Color? color;
  const _OpenTag(this.kind, this.color);
}

/// 对话台词的强调色:随气泡底色取对比 —— 深色文字(白卡气泡)叠主题
/// 主色,浅色文字(用户实心主色气泡)叠一点深色压出对比,再配斜体。
Color _dialogueAccent(Color base, ColorScheme scheme) {
  if (base.computeLuminance() > 0.5) {
    return Color.alphaBlend(Colors.black.withValues(alpha: 0.18), base);
  }
  return Color.alphaBlend(scheme.primary.withValues(alpha: 0.55), base);
}

/// 把当前标记栈合成为样式。
///
/// 按入栈顺序叠加,后入栈的同类覆盖先入栈;`decoration` 只有一个槽位,
/// 删除线会顶掉下划线(两者嵌套时以更内层为准)。
TextStyle _composeStyle(TextStyle base, List<_OpenTag> stack, Color highlightColor) {
  var s = base;
  for (final t in stack) {
    switch (t.kind) {
      case _TagKind.italic:
        s = s.copyWith(fontStyle: FontStyle.italic);
      case _TagKind.bold:
        s = s.copyWith(fontWeight: FontWeight.bold);
      case _TagKind.underline:
        s = s.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: s.color?.withValues(alpha: 0.7),
        );
      case _TagKind.strikethrough:
        s = s.copyWith(decoration: TextDecoration.lineThrough);
      case _TagKind.color:
        if (t.color != null) s = s.copyWith(color: t.color);
      case _TagKind.highlight:
        s = s.copyWith(backgroundColor: highlightColor);
    }
  }
  return s;
}

/// 词条样式:保留当前样式,叠点状下划线(提示"这是个名词")。
TextStyle _termStyle(TextStyle style) => style.copyWith(
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: style.color?.withValues(alpha: 0.55),
    );

/// 支持的样式标记(可由正则脚本的替换串输出,也可直接写在正文里):
/// `<i>` / `<b>` / `<u>` / `<s>` / `<mark>` 与 `<c=RRGGBB>…</c>`;三种引号
/// (`“…”` / `「…」` / `"…"`)内的台词按斜体强调渲染(受 [highlightDialogue]
/// 开关控制)。未闭合的标记在段末自动容忍(流式期间常见),错配的闭合标记
/// 被忽略。
///
/// 解析为富文本 spans:普通文本随当前标记栈取样式;台词段叠斜体与强调色
/// (`<c>` 栈里有颜色时尊重之);标记本身不产生文本。词典命中段在 emit 时
/// 二次拆分为可点击词条 span;`@技能名` 记号([skillTokenPattern] 非空时)
/// 同样在 emit 时二次拆分,命中段染 [skillTokenColor]。
///
/// 文本既不含 `<`/引号字符、也没有启用词典或记号高亮时,直接输出纯文本
/// span,不对长文本做正则扫描。新建的 [TapGestureRecognizer] 追加到
/// [recognizerSink],所有权归调用方:
/// 重建或销毁时必须逐个 dispose,否则 recognizer 会随流式重建累积泄漏。
TextSpan buildRichSpanTree(
  String text,
  TextStyle base,
  ColorScheme scheme, {
  CompiledGlossary? glossary,
  void Function(GlossaryTerm term)? onTermTap,
  List<TapGestureRecognizer>? recognizerSink,
  bool highlightDialogue = true,
  RegExp? skillTokenPattern,
  Color? skillTokenColor,
}) {
  if (text.isEmpty) return TextSpan(style: base);

  final hasGlossary = glossary != null && !glossary.isEmpty;
  final hasSkillTokens = skillTokenPattern != null &&
      skillTokenColor != null &&
      skillTokenPattern.hasMatch(text);
  final mayHaveTagsOrQuotes = text.contains('<') ||
      text.contains('“') ||
      text.contains('「') ||
      text.contains('"');

  // 快路径:既无标签也无引号且无词典/记号命中目标时,直接以纯文本 span 呈现,避免对长文本进行正则扫描
  if (!mayHaveTagsOrQuotes && !hasGlossary && !hasSkillTokens) {
    return TextSpan(style: base, children: [TextSpan(text: text, style: base)]);
  }

  final highlight = scheme.secondaryContainer.withValues(alpha: 0.85);
  final accent = _dialogueAccent(base.color ?? scheme.onSurface, scheme);
  final stack = <_OpenTag>[];
  final spans = <TextSpan>[];
  var last = 0;

  /// 词典命中的二次拆分:命中段出点状下划线词条样式(可点击);其余原样。
  void emitGlossary(String chunk, TextStyle style) {
    if (chunk.isEmpty) return;
    final g = glossary;
    if (g == null || g.isEmpty) {
      spans.add(TextSpan(text: chunk, style: style));
      return;
    }
    final pat = g.pattern;
    if (pat == null || !pat.hasMatch(chunk)) {
      spans.add(TextSpan(text: chunk, style: style));
      return;
    }
    var from = 0;
    for (final m in pat.allMatches(chunk)) {
      if (m.start > from) spans.add(TextSpan(text: chunk.substring(from, m.start), style: style));
      final term = g.termFor(m[0]!);
      if (term == null) {
        spans.add(TextSpan(text: m[0], style: style));
      } else {
        TapGestureRecognizer? recognizer;
        if (onTermTap != null && recognizerSink != null) {
          recognizer = TapGestureRecognizer()..onTap = () => onTermTap(term);
          recognizerSink.add(recognizer);
        }
        spans.add(TextSpan(
          text: m[0],
          style: _termStyle(style),
          recognizer: recognizer,
        ));
      }
      from = m.end;
    }
    if (from < chunk.length) spans.add(TextSpan(text: chunk.substring(from), style: style));
  }

  /// @技能名 记号的二次拆分(仅用户气泡传入):命中段染记号色,其余继续走
  /// 词典拆分。
  void emitStyled(String chunk, TextStyle style) {
    if (chunk.isEmpty) return;
    final pattern = skillTokenPattern;
    if (!hasSkillTokens || pattern == null || !pattern.hasMatch(chunk)) {
      emitGlossary(chunk, style);
      return;
    }
    var from = 0;
    for (final m in pattern.allMatches(chunk)) {
      if (m.start > from) emitGlossary(chunk.substring(from, m.start), style);
      spans.add(TextSpan(text: m[0], style: style.copyWith(color: skillTokenColor)));
      from = m.end;
    }
    if (from < chunk.length) emitGlossary(chunk.substring(from), style);
  }

  for (final m in _masterPattern.allMatches(text)) {
    emitStyled(text.substring(last, m.start), _composeStyle(base, stack, highlight));
    final hit = m[0]!;
    final tag = _tagPattern.firstMatch(hit);
    if (tag == null) {
      // 台词:斜体 + 强调色(`<c>` 栈顶颜色优先);对话高亮总开关关闭时按
      // 当前栈样式原样输出(引号保留,只是不上色不斜体)。
      if (!highlightDialogue) {
        emitStyled(hit, _composeStyle(base, stack, highlight));
      } else {
        final topColor = stack.lastWhereOrNull((t) => t.kind == _TagKind.color)?.color;
        final dialogueStyle = _composeStyle(base, stack, highlight).copyWith(
          fontStyle: FontStyle.italic,
          color: topColor ?? accent,
        );
        emitStyled(hit, dialogueStyle);
      }
    } else {
      final kind = _kindOf(tag.group(2)!)!;
      if (tag.group(1) == '/') {
        // 闭合:从栈顶向下找最近的同种类标记;找不到则忽略(容忍错配)。
        for (var i = stack.length - 1; i >= 0; i--) {
          if (stack[i].kind == kind) {
            stack.removeAt(i);
            break;
          }
        }
      } else if (kind == _TagKind.color) {
        final hex = (tag.group(3) ?? '').replaceFirst('#', '');
        stack.add(_OpenTag(kind, Color(int.parse('ff$hex', radix: 16))));
      } else {
        stack.add(_OpenTag(kind, null));
      }
    }
    last = m.end;
  }
  emitStyled(text.substring(last), _composeStyle(base, stack, highlight));
  return TextSpan(style: base, children: spans);
}

/// 标记栈查找用的小扩展(仅本文件可见),避免为一次查找引入依赖。
extension<T> on List<T> {
  /// lastWhere 的空安全版:找不到返回 null 而不是抛错。
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}

/// 消息气泡正文:接收**原始正文**(未做任何替换),内部跑完整显示管线 ——
/// 剥 system-reminder → 宏替换 → 显示层正则脚本 → 胶囊拆分 → 富文本解析。
/// 样式基准由气泡侧传入(用户白字/助手黑字各自随底),可见文本为空时返回
/// 零尺寸占位;`<chip>` 段独占一行渲染为居中胶囊。
///
/// StatefulWidget:词条的 TapGestureRecognizer 由 State 统一持有,
/// 重建/销毁时释放(挂在 TextSpan 上的 recognizer 不 dispose 会泄漏);
/// 入参不变时直接复用缓存的子树,流式重建不重跑管线。
class RichMessageText extends StatefulWidget {
  /// 原始正文(含 `{{user}}`/`{{char}}` 占位符与脚本目标文本)。
  final String text;

  /// 基准样式(颜色/字号/字重随气泡)。
  final TextStyle style;

  /// 宏替换用的用户名(替换 `{{user}}`);null 或空时保留占位符。
  final String? userName;

  /// 宏替换用的角色名(替换 `{{char}}`);null 或空时保留占位符。
  final String? charName;

  /// 显示层正则脚本(已编译;null/空 = 跳过该步)。
  final List<CompiledRegexScript>? scripts;

  /// 名词词典(世界书词条高亮;null = 不高亮)。
  final CompiledGlossary? glossary;

  /// 词条点击回调(弹释义卡);null = 只有点状下划线样式、不可点。
  final void Function(GlossaryTerm term)? onTermTap;

  /// 内置对话高亮(引号台词斜体+强调色)总开关;false = 引号内文字按普通正文渲染。
  final bool highlightDialogue;

  /// `@技能名` 记号高亮(仅用户气泡传入,与 [skillTokenColor] 成对):正文里
  /// 命中的记号段染 [skillTokenColor]。两者任一为 null 即不启用。
  final RegExp? skillTokenPattern;

  /// 记号高亮色;与 [skillTokenPattern] 成对,单独给出不生效。
  final Color? skillTokenColor;

  const RichMessageText({
    super.key,
    required this.text,
    required this.style,
    this.userName,
    this.charName,
    this.scripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
    this.skillTokenPattern,
    this.skillTokenColor,
  });

  @override
  State<RichMessageText> createState() => _RichMessageTextState();
}

class _RichMessageTextState extends State<RichMessageText> {
  final List<TapGestureRecognizer> _recognizers = [];

  // 记忆化缓存:流式期间整页高频重建时,历史消息的所有入参均未变,直接复用上次构建结果,
  // 避免屏幕上可见的 N 条历史消息在每个流式块上反复重跑宏替换/正则脚本/富文本树解析。
  String? _cachedText;
  TextStyle? _cachedStyle;
  String? _cachedUserName;
  String? _cachedCharName;
  List<CompiledRegexScript>? _cachedScripts;
  CompiledGlossary? _cachedGlossary;
  void Function(GlossaryTerm term)? _cachedOnTermTap;
  bool? _cachedHighlightDialogue;
  ColorScheme? _cachedScheme;

  /// 记号高亮缓存按正则源串比(调用方每次 build 新建 RegExp,identity 必失配)。
  String? _cachedSkillPatternSource;
  Color? _cachedSkillTokenColor;
  Widget? _cachedChild;

  @override
  void dispose() {
    _releaseRecognizers();
    super.dispose();
  }

  /// 释放上一轮 recognizer:每次 build 都会生成新的词条手势,旧的不释放
  /// 会随流式重建累积泄漏(先释放再构建,旧 span 在本次 build 后即被替换)。
  void _releaseRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final canReuse = _cachedChild != null &&
        _cachedText == widget.text &&
        _cachedStyle == widget.style &&
        _cachedUserName == widget.userName &&
        _cachedCharName == widget.charName &&
        identical(_cachedScripts, widget.scripts) &&
        identical(_cachedGlossary, widget.glossary) &&
        _cachedOnTermTap == widget.onTermTap &&
        _cachedHighlightDialogue == widget.highlightDialogue &&
        _cachedScheme == scheme &&
        _cachedSkillPatternSource == widget.skillTokenPattern?.pattern &&
        _cachedSkillTokenColor == widget.skillTokenColor;

    if (canReuse) {
      return _cachedChild!;
    }

    _releaseRecognizers();
    _cachedText = widget.text;
    _cachedStyle = widget.style;
    _cachedUserName = widget.userName;
    _cachedCharName = widget.charName;
    _cachedScripts = widget.scripts;
    _cachedGlossary = widget.glossary;
    _cachedOnTermTap = widget.onTermTap;
    _cachedHighlightDialogue = widget.highlightDialogue;
    _cachedScheme = scheme;
    _cachedSkillPatternSource = widget.skillTokenPattern?.pattern;
    _cachedSkillTokenColor = widget.skillTokenColor;

    // 先剥离 system-reminder 段(模型注入,不进渲染),再走宏替换与正则脚本。
    var displayed = stripSystemReminders(widget.text);
    displayed = expandDisplayMacros(
      displayed,
      userName: widget.userName,
      charName: widget.charName,
    );
    final s = widget.scripts;
    if (s != null && s.isNotEmpty) {
      displayed = applyDisplayScripts(displayed, s);
    }
    if (displayed.isEmpty) {
      _cachedChild = const SizedBox.shrink();
      return _cachedChild!;
    }
    final parts = _splitChips(displayed);
    final hasChip = parts.any((p) => p is _RichChipPart);
    // 无 chip:维持单 Text.rich 的旧路径(布局/既有测试零变化)。
    if (!hasChip) {
      _cachedChild = Text.rich(
        buildRichSpanTree(
          displayed,
          widget.style,
          scheme,
          glossary: widget.glossary,
          onTermTap: widget.onTermTap,
          recognizerSink: _recognizers,
          highlightDialogue: widget.highlightDialogue,
          skillTokenPattern: widget.skillTokenPattern,
          skillTokenColor: widget.skillTokenColor,
        ),
      );
      return _cachedChild!;
    }
    // 有 chip:正文块 + 居中胶囊块按出现顺序纵向排列(胶囊自带下间距,
    // chip 之间的纯空白段直接丢弃)。
    final children = <Widget>[];
    for (final p in parts) {
      switch (p) {
        case _RichTextPart(:final text):
          if (text.trim().isNotEmpty) {
            children.add(
              Text.rich(
                buildRichSpanTree(
                  text,
                  widget.style,
                  scheme,
                  glossary: widget.glossary,
                  onTermTap: widget.onTermTap,
                  recognizerSink: _recognizers,
                  highlightDialogue: widget.highlightDialogue,
                  skillTokenPattern: widget.skillTokenPattern,
                  skillTokenColor: widget.skillTokenColor,
                ),
              ),
            );
          }
        case _RichChipPart(:final label):
          children.add(_chipCapsule(context, label));
      }
    }
    _cachedChild = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
    return _cachedChild!;
  }

  /// 居中胶囊:小号字 + 圆角浅底,叠在气泡底色上作时间戳/场景横幅。
  Widget _chipCapsule(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: widget.style.copyWith(
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w500,
              color: scheme.onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}
