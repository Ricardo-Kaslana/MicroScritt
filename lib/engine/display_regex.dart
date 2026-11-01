import '../models/regex_script.dart';

/// 已编译的显示层正则脚本:编译失败的脚本被静默跳过(编辑页有实时校验,
/// 这里不让一条坏脚本拖垮整个气泡渲染)。
class CompiledRegexScript {
  final RegexScript source;
  final RegExp regex;

  const CompiledRegexScript(this.source, this.regex);
}

/// 编译显示层脚本:只取启用项,按 position/id 应用序;非法正则丢弃。
/// 按输入列表**实例**记忆化 —— 聊天页流式期间每帧重取 Provider 值时列表
/// 实例不变,直接复用上次编译结果(每次重建都重编 N 个 RegExp 会掉帧);
/// 列表 reload 后实例变化,自然重编。
List<RegexScript>? _lastInput;
List<CompiledRegexScript>? _lastCompiled;

List<CompiledRegexScript> compileDisplayScripts(List<RegexScript> scripts) {
  if (identical(scripts, _lastInput)) return _lastCompiled!;
  final sorted = [...scripts]..sort((a, b) {
      final byPos = a.position.compareTo(b.position);
      return byPos != 0 ? byPos : (a.id ?? 0).compareTo(b.id ?? 0);
    });
  final compiled = <CompiledRegexScript>[];
  for (final s in sorted) {
    if (!s.enabled) continue;
    try {
      compiled.add(CompiledRegexScript(s, RegExp(s.findRegex)));
    } on FormatException {
      continue;
    }
  }
  _lastInput = scripts;
  _lastCompiled = compiled;
  return compiled;
}

/// 依序应用全部脚本。替换串支持 `$1`–`$9`、`$&`(整体匹配)与 `$$`(字面 `$`)。
String applyDisplayScripts(String text, List<CompiledRegexScript> scripts) {
  var out = text;
  for (final s in scripts) {
    out = out.replaceAllMapped(s.regex, (m) => _expandReplacement(s.source.replace, m));
  }
  return out;
}

/// 校验正则可编译;返回错误信息或 null(合法)。编辑页实时校验用。
String? validateRegexPattern(String pattern) {
  try {
    RegExp(pattern);
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}

/// 展开替换串里的引用:`$$` → `$`,`$&` → 整体匹配,`$n` → 捕获组 n
/// (越界/未参与匹配的组替换为空串)。其余字符原样。
String _expandReplacement(String replace, Match m) {
  final buf = StringBuffer();
  for (var i = 0; i < replace.length; i++) {
    final ch = replace[i];
    if (ch != r'$' || i + 1 >= replace.length) {
      buf.write(ch);
      continue;
    }
    final next = replace[i + 1];
    if (next == r'$') {
      buf.write(r'$');
      i++;
    } else if (next == '&') {
      buf.write(m[0] ?? '');
      i++;
    } else if (RegExp(r'[0-9]').hasMatch(next)) {
      // 越界组号替换为空串(RegExpMatch[] 对非法下标会抛 RangeError)。
      final idx = int.parse(next);
      if (idx <= m.groupCount) buf.write(m.group(idx) ?? '');
      i++;
    } else {
      // 非引用形态(如 `$x`):原样保留 `$`,继续处理下一个字符。
      buf.write(ch);
    }
  }
  return buf.toString();
}
