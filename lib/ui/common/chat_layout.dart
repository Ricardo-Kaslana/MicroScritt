/// 聊天页宽窗布局刻度:高宽度桌面窗口下把会话收敛成居中阅读列。
///
/// 列宽超过 [kChatColumnMaxWidth] 后不再增长,居中留白随窗口变宽;
/// 999 与 1000 断点两侧同为封顶宽度,拖动窗口时输入卡不会突然回缩。
library;

import 'layout_breakpoints.dart';

/// 进入居中列布局的窗口宽度阈值(逻辑像素)。
const double kChatWideBreakpoint = kDesktopBreakpoint;

/// 桌面宽窗会话侧栏宽度(全部会话按角色卡分组)。
const double kChatSidebarWidth = 300;

/// 进入「侧栏 + 聊天」主从布局的窗口宽度阈值:右侧仍能完整容纳居中会话列
/// (880)与两侧呼吸空间时才出侧栏;1000–1200 的宽窗保持纯居中列布局。
const double kChatSidebarBreakpoint = kSidebarBreakpoint;

/// 会话列最大宽度:输入卡 = 列宽 − 24(即 856)。
///
/// 超过这条线后列宽不再随窗口增长 —— 宽屏继续放大只会把单行输入卡拉成
/// 狭长条,而不是增加可用内容宽。
const double kChatColumnMaxWidth = 880;

/// 会话内容列宽(逻辑像素):超过 [kChatColumnMaxWidth] 即封顶并居中。
///
/// 消息区、输入区、灵动岛与滚动导航共用同一列宽,AppBar 内容也按它对齐。
double chatColumnMaxWidth(double availableWidth) =>
    availableWidth >= kChatColumnMaxWidth
    ? kChatColumnMaxWidth
    : availableWidth;

/// 桌面消息导航卡片的展开宽度。
const double kChatNavCardWidth = 280;

/// 导航卡/刻度条距窗口右缘的留白:避开桌面滚动条,不抢它的拖动热区。
const double kChatNavInset = 12;

/// 收起态刻度条的热区宽度。只有这一条窄带参与命中,展开后才是卡片全宽。
const double kChatNavRailWidth = 22;

/// 收起态刻度条每条消息占用的竖向间距(也是密集时的最小抽样间距)。
/// 消息很少时整条刻度按内容收缩(1 条 = 20 高、2 条 = 36 高),不再撑满
/// 整张卡片高度;消息多到超出卡片高度时按可用高度均分,再按此间距抽样。
const double kChatNavTickSpacing = 16;

/// 收起态刻度条轨道的上下留白(轨道两端留一点空,避免贴边被裁切)。
const double kChatNavRailPadding = 10;

/// 导航卡列表项的固定行高(单行摘要 + 序号徽标)。
const double kChatNavItemExtent = 40;
