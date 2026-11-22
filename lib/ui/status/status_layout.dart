/// 状态面板桌面工作台的布局刻度。
///
/// 宽窗断点取全局共享刻度;分区侧栏与工作区限宽仍由本页独立定义。
library;

import '../common/layout_breakpoints.dart';

/// 进入桌面分区工作台的窗口宽度阈值。
const double kStatusDesktopBreakpoint = kDesktopBreakpoint;

/// 桌面左侧分区导航宽度。
const double kStatusDesktopSidebarWidth = 280;

/// 桌面工作区内容最大宽度,超宽屏下居中留白。
const double kStatusDesktopContentMaxWidth = 1120;
