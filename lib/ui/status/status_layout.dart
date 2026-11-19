/// 状态面板桌面工作台的布局刻度。
///
/// 宽窗断点与聊天页宽窗断点同值,但状态面板的分区侧栏与工作区限宽独立,
/// 不引用 chat_layout.dart,避免页面间耦合。
library;

/// 进入桌面分区工作台的窗口宽度阈值。
const double kStatusDesktopBreakpoint = 1000;

/// 桌面左侧分区导航宽度。
const double kStatusDesktopSidebarWidth = 280;

/// 桌面工作区内容最大宽度,超宽屏下居中留白。
const double kStatusDesktopContentMaxWidth = 1120;
