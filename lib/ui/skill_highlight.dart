/// `@技能名` 记号的兼容门面。
///
/// 正则与选色已统一到 `text_syntax.dart`;这里保留旧 API,避免气泡/输入框
/// 的历史调用点与测试各自漂移。新代码应直接用 [CompiledSyntax] 与
/// [SyntaxPalette]。
library;

import 'package:flutter/material.dart';

import 'text_syntax.dart';

/// 匹配 `@技能名` 记号(按已启用技能名拼 alternation)。
RegExp skillTokenPattern(Set<String> skillNames) => skillNames.isEmpty
    ? RegExp('@(?:)')
    : CompiledSyntax.compile(skillNames: skillNames).skillPattern!;

/// `@技能名` 记号的高亮色。
Color skillTokenColor(ColorScheme scheme, {required bool onPrimaryBubble}) =>
    skillColorFor(scheme, onPrimaryBubble: onPrimaryBubble);
