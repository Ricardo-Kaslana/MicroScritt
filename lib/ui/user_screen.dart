/// 用户设置:用户名与头像,从设置页「用户」进入。
///
/// 表单本体在 `user_profile_form.dart`,桌面设置工作台复用同一份;本页只提供
/// 移动端的 Scaffold、返回前确认与保存后的回退。
library;

import 'package:flutter/material.dart';

import 'common/unsaved_changes_guard.dart';
import 'user_profile_form.dart';

class UserScreen extends StatelessWidget {
  const UserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesGuard(
      // 表单状态(用户名/头像)由 UserProfileForm 私有持有,本层无法读取
      // 脏值;简单表单按「返回前确认」兜底,避免误触返回静默丢弃输入。
      hasChanges: () => true,
      title: '离开用户设置?',
      message: '未点击「保存」时,本次输入的用户名与头像修改不会保留。',
      confirmLabel: '离开',
      child: Scaffold(
        appBar: AppBar(title: const Text('用户')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            UserProfileForm(onSaved: () => Navigator.pop(context)),
          ],
        ),
      ),
    );
  }
}
