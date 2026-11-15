/// 聊天页宽窗布局刻度:高宽度桌面窗口下把会话收敛成居中阅读列。
///
/// 低/中宽度(移动与中等桌面窗口)保持气泡左右贴边的满宽布局 —— 那两档
/// 本就舒适,不动;只有超过 [kChatWideBreakpoint] 才封顶居中,避免助手气泡
/// 贴屏幕左缘、用户气泡贴右缘、输入区悬在中央的「三点分散」观感。
library;

import 'package:flutter/widgets.dart';

/// 进入居中列布局的窗口宽度阈值(逻辑像素)。
const double kChatWideBreakpoint = 1000;

/// 居中会话列的最大宽度:内容宽 = 列宽 − 24(左右各 12 边距),助手气泡
/// 上限与输入卡宽度都取这条内容宽 —— 宽窗下气泡外缘与输入区左右严格对齐,
/// 列内仍留出呼吸空间。用户气泡单独封顶 520。
const double kChatColumnMaxWidth = 880;

/// 桌面宽窗会话侧栏宽度(全部会话按角色卡分组)。
const double kChatSidebarWidth = 300;

/// 进入「侧栏 + 聊天」主从布局的窗口宽度阈值:右侧仍能完整容纳居中会话列
/// (880)与两侧呼吸空间时才出侧栏;1000–1200 的宽窗保持纯居中列布局。
const double kChatSidebarBreakpoint = 1200;

/// 会话内容列宽:宽窗封顶 [kChatColumnMaxWidth],否则不限(吃满可用宽)。
/// 消息区、输入区、灵动岛与滚动导航共用同一列宽,AppBar 内容也按它对齐。
double chatColumnMaxWidth(double availableWidth) =>
    availableWidth >= kChatWideBreakpoint
    ? kChatColumnMaxWidth
    : double.infinity;

/// 宽窗下浮动 SnackBar 的封顶宽度:默认吃满整窗,高宽度桌面上一条提示
/// 会拉成整屏宽;窄窗返回 null,保持原满宽行为。
double? chatSnackBarWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kChatWideBreakpoint ? 480 : null;
