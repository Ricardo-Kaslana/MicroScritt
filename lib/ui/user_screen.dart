/// 用户设置:用户名与头像,从设置页「用户」进入。
///
/// 表单本体在 `user_profile_form.dart`,桌面设置工作台复用同一份;本页只提供
/// 移动端的 Scaffold 与保存后的回退。
library;

import 'package:flutter/material.dart';

import 'user_profile_form.dart';

class UserScreen extends StatelessWidget {
  const UserScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('用户')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          UserProfileForm(onSaved: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}
