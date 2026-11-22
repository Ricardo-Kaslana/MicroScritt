/// 聊天页浮层展示件:AppBar 头像、角色/用户状态卡、背景层与重命名弹窗。

part of '../chat_screen.dart';

/// AppBar 里的小头像:hash 文件图或名字首字,解码失败时首字自然露出。
class _ChatAvatar extends ConsumerWidget {
  final String name;
  final String? avatarHash;
  const _ChatAvatar({required this.name, required this.avatarHash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial = name.isEmpty ? '?' : name.characters.first;
    return HashAvatar(
      hash: avatarHash,
      radius: 16,
      child: Text(initial, style: const TextStyle(fontSize: 14)),
    );
  }
}

/// 角色 / 用户的头像状态卡(底部弹层):大头像 + 名称 + 简介,下接入口行
/// (角色卡编辑 / 个人设置)。头像缺失时退回图标占位。
class _AvatarStatusSheet extends StatelessWidget {
  final ImageProvider? avatar;
  final IconData fallbackIcon;
  final String title;
  final String subtitle;
  final String? body;
  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;

  const _AvatarStatusSheet({
    required this.avatar,
    required this.fallbackIcon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.body,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final icon = Icon(
      fallbackIcon,
      size: 36,
      color: scheme.onSecondaryContainer,
    );
    final avatarWidget = avatar == null
        ? CircleAvatar(
            radius: 40,
            backgroundColor: scheme.secondaryContainer,
            child: icon,
          )
        : CircleAvatar(
            radius: 40,
            backgroundColor: scheme.secondaryContainer,
            foregroundImage: avatar,
            onForegroundImageError: (_, __) {},
            child: icon,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: avatarWidget),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.titleMedium,
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (body != null && body!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              body!,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          GroupCard(
            margin: EdgeInsets.zero,
            children: [
              ListTile(
                leading: Icon(actionIcon, size: 20),
                title: Text(actionLabel),
                trailing: const Icon(Icons.chevron_right),
                onTap: onAction,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 聊天页背景层:优先角色背景 hash,未设置时回退角色头像 hash。
/// FileImage 以内容 hash 路径为缓存键,换图自然刷新,旧帧由 gaplessPlayback 保留。
class _ChatBackground extends ConsumerStatefulWidget {
  final String? backgroundHash;
  final String? avatarHash;
  final double blur;
  const _ChatBackground({
    super.key,
    required this.backgroundHash,
    required this.avatarHash,
    required this.blur,
  });

  @override
  ConsumerState<_ChatBackground> createState() => _ChatBackgroundState();
}

class _ChatBackgroundState extends ConsumerState<_ChatBackground> {
  @override
  Widget build(BuildContext context) {
    final hash = widget.backgroundHash ?? widget.avatarHash;
    if (hash == null || hash.isEmpty) return const SizedBox.shrink();
    final provider = hashImageProvider(
      ref.read(databaseProvider).images,
      hash,
      cacheWidth: kBackgroundImageExtent,
      cacheHeight: kBackgroundImageExtent,
    );
    if (provider == null) return const SizedBox.shrink();
    // 取主题背景色的一个不透明近似色做遮罩:亮色用白、暗色用黑,让背景若隐若现。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final veilColor =
        (isDark ? const Color(0xFF121212) : const Color(0xFFFAFAFA)).withValues(
          alpha: 0.60,
        );
    final image = Image(
      image: provider,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    // blur <= 0 时不包 ImageFiltered(零模糊本就是无操作),便于测试区分。
    final rendered = widget.blur <= 0
        ? image
        : ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: widget.blur,
              sigmaY: widget.blur,
            ),
            child: image,
          );
    return ClipRect(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            rendered,
            ColoredBox(color: veilColor),
          ],
        ),
      ),
    );
  }
}

/// 会话重命名弹窗:控制器归弹窗 State 所有 —— 在 showDialog 调用方释放会
/// 撞上退场动画期间 TextField 重建(controller used after dispose)。
class _RenameSessionDialog extends StatefulWidget {
  final String initialTitle;
  const _RenameSessionDialog({required this.initialTitle});

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '会话标题'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
