/// 用户资料表单:用户名与头像,移动端用户页与桌面设置工作台共用。
///
/// 用户名会注入 Hook 上下文(`__ctx.userName`),默认 USER 替换脚本把正文里
/// 的 `{{user}}` 替换成它;头像只在用户气泡旁展示,不进上下文。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/image_codec.dart';
import '../models/user.dart';
import '../state/app_config_sync.dart';
import '../state/providers.dart';
import 'common/form_row.dart';
import 'common/pick_file_bytes.dart';
import '../data/shrink_image.dart';

/// 用户名与头像表单。
///
/// [wide] 为真时渲染为设置工作台的单卡设置行(头像行 / 用户名行 / 保存底栏),
/// 外层负责包卡片;否则保持移动端纵向堆叠。[onSaved] 在落库、刷新内存快照并
/// 提示成功之后调用;移动端用它回退页面,桌面端不传。
class UserProfileForm extends ConsumerStatefulWidget {
  final bool wide;
  final VoidCallback? onSaved;

  const UserProfileForm({super.key, this.wide = false, this.onSaved});

  @override
  ConsumerState<UserProfileForm> createState() => _UserProfileFormState();
}

class _UserProfileFormState extends ConsumerState<UserProfileForm> {
  late final TextEditingController _name;
  String? _avatarBase64;

  /// 上次落库/初始水合的值,用于判断是否有未保存修改。
  late String _initialName;
  String? _initialAvatar;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(userProfileProvider);
    _name = TextEditingController(text: user.name);
    _avatarBase64 = user.avatarBase64;
    _initialName = user.name;
    _initialAvatar = user.avatarBase64;
    _name.addListener(_onNameChanged);
  }

  @override
  void dispose() {
    _name.removeListener(_onNameChanged);
    _name.dispose();
    super.dispose();
  }

  void _onNameChanged() {
    if (mounted) setState(() {});
  }

  /// 是否有未保存修改;首尾空白不计入用户名差异。
  bool get _dirty =>
      _name.text.trim() != _initialName.trim() ||
      _avatarBase64 != _initialAvatar;

  bool get _canSave => !_saving && _dirty;

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

  void _removeAvatar() => setState(() => _avatarBase64 = null);

  /// 保存用户资料:先落库再刷新内存快照,并回写文本配置文件
  /// (`syncAppConfigFile` 写失败只打日志,不影响本次保存)。
  Future<void> _save() async {
    final user = UserProfile(
      name: _name.text.trim(),
      avatarBase64: _avatarBase64,
    );
    setState(() => _saving = true);
    try {
      await ref.read(userRepositoryProvider).save(user);
      ref.read(userProfileProvider.notifier).state = user;
      await syncAppConfigFile(ref);
      if (!mounted) return;
      setState(() {
        _initialName = user.name;
        _initialAvatar = user.avatarBase64;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('用户信息已保存')));
      widget.onSaved?.call();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 带描边头像框的头像;已设置图片时可点击查看放大预览。
  Widget _avatarWidget(double radius) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = safeBase64Decode(_avatarBase64);
    final framed = KeyedSubtree(
      key: const ValueKey('settings_user_avatar'),
      child: _framedAvatar(scheme, radius, bytes),
    );
    if (bytes == null) return framed;
    return Tooltip(
      message: '查看头像',
      child: Semantics(
        button: true,
        label: '查看头像',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _showAvatarPreview(bytes),
            child: framed,
          ),
        ),
      ),
    );
  }

  Widget _framedAvatar(
    ColorScheme scheme,
    double radius,
    Uint8List? bytes,
  ) {
    final avatar = bytes == null
        ? CircleAvatar(
            radius: radius,
            child: Icon(Icons.person, size: radius),
          )
        : CircleAvatar(
            radius: radius,
            backgroundImage: MemoryImage(bytes),
          );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surface,
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.35),
          width: 2,
        ),
      ),
      child: avatar,
    );
  }

  /// 放大头像弹框:大图沿用同一头像框,附当前用户名与关闭按钮。
  Future<void> _showAvatarPreview(Uint8List bytes) {
    final name = _name.text.trim();
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final scheme = theme.colorScheme;
        final shortest = MediaQuery.sizeOf(dialogContext).shortestSide;
        final radius = (shortest * 0.26).clamp(96.0, 140.0).toDouble();
        return Dialog(
          key: const ValueKey('settings_user_avatar_dialog'),
          backgroundColor: scheme.surface,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '头像',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _framedAvatar(scheme, radius, bytes),
                  const SizedBox(height: 16),
                  Text(
                    name.isEmpty ? '未命名用户' : name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '头像只显示在用户气泡旁,不进入上下文。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _avatarBlock() {
    return Column(
      children: [
        _avatarWidget(36),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _pickAvatar,
          icon: const Icon(Icons.image_outlined),
          label: const Text('选择头像'),
        ),
        if (_avatarBase64 != null)
          TextButton(onPressed: _removeAvatar, child: const Text('移除头像')),
      ],
    );
  }

  Widget _nameField({bool showHelper = true}) => TextField(
    controller: _name,
    decoration: InputDecoration(
      labelText: '用户名',
      hintText: '例如:小明',
      helperText: showHelper
          ? '消息正文中的 {{user}} 在显示时会替换为该用户名(存储不变)'
          : null,
    ),
  );

  Widget _saveButton() => FilledButton(
    key: const ValueKey('settings_user_save'),
    onPressed: _canSave ? _save : null,
    child: _saving
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Text('保存'),
  );

  /// 桌面工作台:单卡设置行 + 保存底栏。外层 SurfaceCard 已去内边距,
  /// 分隔线与行内边距在这里对齐。
  Widget _wideBody(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsFormRow(
          icon: Icons.account_circle_outlined,
          title: '头像',
          description: '显示在用户气泡旁;只保存在本地,不进入上下文。',
          stackBreakpoint: 0,
          control: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _avatarWidget(26),
              const SizedBox(width: 14),
              OutlinedButton.icon(
                onPressed: _pickAvatar,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('选择头像'),
              ),
              if (_avatarBase64 != null) ...[
                const SizedBox(width: 4),
                TextButton(
                  onPressed: _removeAvatar,
                  child: const Text('移除头像'),
                ),
              ],
            ],
          ),
        ),
        const SettingsFormDivider(),
        SettingsFormRow(
          icon: Icons.badge_outlined,
          title: '用户名',
          description: '消息正文中的 {{user}} 在显示时会替换为该用户名(存储不变)。',
          control: SizedBox(
            width: 360,
            child: _nameField(showHelper: false),
          ),
        ),
        const SettingsFormDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _dirty ? '有未保存的修改' : '用户名与头像保存在本机',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _dirty ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: _dirty ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _saveButton(),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.wide) return _wideBody(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _avatarBlock()),
        const SizedBox(height: 16),
        _nameField(),
        const SizedBox(height: 24),
        _saveButton(),
      ],
    );
  }
}
