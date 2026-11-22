/// 表单编辑页的统一骨架:返回防护、保存中状态与顶部/底部保存键。
///
/// 技能、Hooks、提示词、正则、生图风格等编辑页共用同一版式:AppBar 右侧
/// 保存(保存中转圈并禁用)、列表表单与底部保存键。传入 [hasChanges] 时
/// 自动挂上未保存修改的返回防护。
library;

import 'package:flutter/material.dart';

import 'inline_spinner.dart';
import 'unsaved_changes_guard.dart';

/// 编辑页骨架。
///
/// [children] 直接排进 `ListView`;底部保存键默认显示,可与页内其它操作
/// 通过 [bottomSave] 关闭。[saving] 为真时两处保存键一并禁用并显示转圈,
/// 防止重复提交。
class EditFormScaffold extends StatelessWidget {
  final String title;
  final bool saving;
  final VoidCallback onSave;
  final List<Widget> children;

  /// 未保存修改的判定与变更源;null 表示本页不挂返回防护。
  final bool Function()? hasChanges;
  final List<Listenable> changes;

  /// AppBar 上额外的动作(保存键之前)。
  final List<Widget> actions;

  final String saveLabel;
  final bool bottomSave;
  final EdgeInsets padding;

  const EditFormScaffold({
    super.key,
    required this.title,
    required this.saving,
    required this.onSave,
    required this.children,
    this.hasChanges,
    this.changes = const [],
    this.actions = const [],
    this.saveLabel = '保存',
    this.bottomSave = true,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaffold = Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          ...actions,
          TextButton(
            onPressed: saving ? null : onSave,
            child: saving
                ? InlineSpinner(color: scheme.primary)
                : Text(saveLabel),
          ),
        ],
      ),
      body: ListView(
        padding: padding,
        children: [
          ...children,
          if (bottomSave) ...[
            const SizedBox(height: 20),
            FilledButton(
              onPressed: saving ? null : onSave,
              child: saving
                  ? InlineSpinner(color: scheme.onPrimary, size: 18)
                  : Text(saveLabel),
            ),
          ],
        ],
      ),
    );
    final check = hasChanges;
    if (check == null) return scaffold;
    return UnsavedChangesGuard(
      hasChanges: check,
      changes: changes,
      child: scaffold,
    );
  }
}
