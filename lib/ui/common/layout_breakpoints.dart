/// 全应用共享的宽窗断点与弹层限宽。
///
/// 聊天、设置、状态面板与制卡工作台此前各写一份 1000/1200;数值相同但来源
/// 分散,调整时容易漏改。这里只收敛公共刻度,各页自己的侧栏宽度与内容限宽
/// 仍留在各自 layout 文件里。
library;

import 'package:flutter/material.dart';

/// 进入桌面分区/宽窗布局的窗口宽度阈值(逻辑像素)。
const double kDesktopBreakpoint = 1000;

/// 聊天页出现左侧会话侧栏的窗口宽度阈值。
const double kSidebarBreakpoint = 1200;

/// 底部弹层在宽窗下的最大宽度;窄于该值的窗口不受限。
const double kSheetMaxWidth = 640;

/// 浮动提示在宽窗下的封顶宽度;窄窗保持满宽。
const double kSnackBarMaxWidth = 480;

/// 当前上下文是否运行在桌面平台(windows/macOS/linux)。
///
/// 与聊天页 `_desktopPlatform`、composer 的输入框加高判断同源:取
/// `Theme.of(context).platform` 而非 `defaultTargetPlatform`,测试里可以通过
/// `MaterialApp(theme: ThemeData(platform: ...))` 钉平台,分别覆盖移动端
/// (底部抽屉)与桌面端(锚定弹卡)两条弹层路径。
bool isDesktopPlatformOf(BuildContext context) {
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.windows ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.linux;
}
