/// 用户设置:用户名与头像,从设置页「用户」进入。
///
/// 表单本体在 `user_profile_form.dart`,桌面设置工作台复用同一份;本页只提供
/// 移动端的 Scaffold、返回前确认与保存后的回退。
library;

import 'package:flutter/material.dart';

import 'common/unsaved_changes_guard.dart';
import 'user_profile_form.dart';

class UserScreen extends StatefulWidget {
  const UserScreen({super.key});

  @override
  State<UserScreen> createState() => _UserScreenState();
}

class _UserScreenState extends State<UserScreen> {
  /// 表单脏值由 UserProfileForm 经回调同步;没改过时返回不弹确认框。
  final _dirty = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _dirty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesGuard(
      hasChanges: () => _dirty.value,
      changes: [_dirty],
      title: '离开用户设置?',
      message: '未点击「保存」时,本次输入的用户名与头像修改不会保留。',
      confirmLabel: '离开',
      child: Scaffold(
        appBar: AppBar(title: const Text('用户')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            UserProfileForm(
              onSaved: () => Navigator.pop(context),
              onDirtyChanged: (dirty) => _dirty.value = dirty,
            ),
          ],
        ),
      ),
    );
  }
}
