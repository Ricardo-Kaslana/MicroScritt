/// `@技能名` 记号的共享高亮:正则拼接与配色,输入框与用户气泡共用。
///
/// 记号是本地调用语法(触发技能附件注入),发送管线在各 LLM 出口统一剥离,
/// 但气泡与输入框都保留原样显示 —— 记号需要被一眼认出,因此两处都必须
/// 高亮。本模块统一「匹配什么」(正则)与「染什么色」,避免两处各写一份、
/// 日后漂移。
library;

import 'package:flutter/material.dart';

/// 匹配 `@技能名` 记号:按已启用技能名拼 alternation。名字经 [RegExp.escape]
/// 转义,集合为空时不应调用(调用方先判空)。与发送端触发判据
/// (`contains('@$name')`)同构。
RegExp skillTokenPattern(Set<String> skillNames) =>
    RegExp('@(?:${skillNames.map(RegExp.escape).join('|')})');

/// `@技能名` 记号的高亮色。
///
/// - [onPrimaryBubble] = false(输入框,浅底):主题主色 —— 白底蓝字,对比清晰;
/// - [onPrimaryBubble] = true(用户气泡,实心主色底):气泡底是蓝色,记号不再
///   用同族色,改用**紫色**(与蓝底互为对比色,一眼可辨),并按底色亮度选深浅:
///   底色深(亮色模式的实心蓝)配亮紫,底色浅(暗色模式的淡蓝主色)配深紫 ——
///   两种主题下都与底色、白字正文可区分。
Color skillTokenColor(ColorScheme scheme, {required bool onPrimaryBubble}) {
  if (!onPrimaryBubble) return scheme.primary;
  return scheme.primary.computeLuminance() > 0.5
      ? const Color(0xFF6A1B9A)
      : const Color(0xFFD8B4FE);
}
