import 'package:flutter/material.dart';

/// 标题旁的小号「查看说明」入口:低饱和灰,不抢行内文案的视觉焦点,点击弹
/// 详情说明。
///
/// 放在 title/标题 Row 内使用 —— 内层按钮优先于 SwitchListTile 的开关热区,
/// 点图标不会误切开关。与各编辑页「外置灰色小标题」的 iOS 分组表单惯例同调。
class InfoButton extends StatelessWidget {
  final VoidCallback onTap;

  /// 桌面端悬停提示;默认「查看说明」。
  final String tooltip;

  const InfoButton({super.key, required this.onTap, this.tooltip = '查看说明'});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        icon: Icon(Icons.info_outline, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
        onPressed: onTap,
      ),
    );
  }
}
