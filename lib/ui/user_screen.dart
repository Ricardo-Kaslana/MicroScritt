/// 用户设置:用户名与头像,从设置页「用户」进入。
///
/// 用户名会注入 Hook 上下文(`__ctx.userName`),默认 USER 替换脚本把正文里
/// 的 `{{user}}` 替换成它;头像只在用户气泡旁展示,不进上下文。
library;

import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/image_codec.dart';
import '../models/user.dart';
import '../state/app_config_sync.dart';
import '../state/providers.dart';
import 'common/pick_file_bytes.dart';
import 'common/shrink_image.dart';

/// 用户管理屏:设置用户名与头像,保存后同步内存快照与文本配置文件。
///
/// 头像先缩到安全尺寸再落库,避免大图撑爆 Android CursorWindow;
/// `_saving` 期间禁用保存按钮,防止重复提交。
class UserScreen extends ConsumerStatefulWidget {
  const UserScreen({super.key});

  @override
  ConsumerState<UserScreen> createState() => _UserScreenState();
}

class _UserScreenState extends ConsumerState<UserScreen> {
  late final TextEditingController _name;
  String? _avatarBase64;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(userProfileProvider);
    _name = TextEditingController(text: user.name);
    _avatarBase64 = user.avatarBase64;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    // withData: false —— Android 大图整读原生 ByteArray 会 OOM 静默丢字节,
    // 改从选择结果 path 读(见 pickedFileBytes)。
    final result = await FilePicker.pickFiles(type: FileType.image);
    final bytes = await pickedFileBytes(result?.files.single);
    if (bytes == null) return;
    // 缩到安全尺寸再落库:用户可能选整张几 MB 的照片作头像,不缩会撑爆
    // Android CursorWindow(启动读 user_profile 整行即抛 Row too big),与
    // 角色卡编辑/导入同款防护,见 shrink_image.dart。
    final shrunk = await shrinkBase64Image(base64Encode(bytes));
    if (shrunk != null) setState(() => _avatarBase64 = shrunk);
  }

  /// 保存用户资料:先落库再刷新内存快照,并回写文本配置文件
  /// (`syncAppConfigFile` 写失败只打日志,不影响本次保存)。
  Future<void> _save() async {
    final user = UserProfile(name: _name.text.trim(), avatarBase64: _avatarBase64);
    setState(() => _saving = true);
    try {
      await ref.read(userRepositoryProvider).save(user);
      ref.read(userProfileProvider.notifier).state = user;
      await syncAppConfigFile(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('用户信息已保存')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const fallback = CircleAvatar(radius: 36, child: Icon(Icons.person, size: 36));
    Widget avatar = fallback;
    final avatarBytes = safeBase64Decode(_avatarBase64);
    if (avatarBytes != null) {
      avatar = CircleAvatar(radius: 36, backgroundImage: MemoryImage(avatarBytes));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('用户')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                avatar,
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _pickAvatar,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('选择头像'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '用户名',
              hintText: '例如:小明',
              helperText: '消息正文中的 {{user}} 在显示时会替换为该用户名(存储不变)',
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}
