/// 设置页桌面工作台的布局刻度与分区定义。
///
/// 宽窗断点与状态面板同值,但侧栏宽度与内容限宽独立定义,不跨页 import,
/// 避免两个页面互相牵制。
library;

import 'package:flutter/material.dart';

/// 进入桌面分区工作台的窗口宽度阈值。
const double kSettingsDesktopBreakpoint = 1000;

/// 桌面左侧分区导航宽度。
const double kSettingsDesktopSidebarWidth = 280;

/// 桌面工作区内容最大宽度,超宽屏下居中留白。
const double kSettingsDesktopContentMaxWidth = 1120;

/// 设置工作台的分区。
enum SettingsDesktopSection {
  user('用户', Icons.person_outline, '设置用户名与头像;正文中的 {{user}} 显示时替换。'),
  appearance('外观', Icons.palette_outlined, '主题与聊天页背景,修改即时生效。'),
  conversation('对话与后台', Icons.tune_outlined, '上下文自动压缩与单轮附件注入上限。'),
  llm('LLM 后端', Icons.dns_outlined, '对话使用的服务商与模型;密钥只保存在本地。'),
  image('生图', Icons.image_outlined, '生图服务、插件与自定义风格。'),
  extensions('内容与扩展', Icons.extension_outlined, '技能、全局提示词、Hooks 与正则脚本。'),
  stats('统计', Icons.bar_chart_outlined, '逐请求用量明细、热力图与趋势。'),
  config('配置', Icons.settings_outlined, '用户名与 LLM 后端的纯文本配置;文件含明文 API Key,请妥善保管。'),
  about('关于', Icons.info_outline, '本地优先的极简 AI 角色扮演应用。');

  const SettingsDesktopSection(this.label, this.icon, this.description);

  final String label;
  final IconData icon;
  final String description;
}
