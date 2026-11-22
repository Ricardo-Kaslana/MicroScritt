/// 角色卡头像预览:列表/网格/牌堆共用的文件资产缩略图。
///
/// 卡片记录只携带 SHA-256;这里按用途降采样解码,文件缺失时回退破图占位。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/character_card.dart';
import '../../state/providers.dart';
import '../common/hash_image.dart';

/// 角色卡头像预览:列表 384、大卡面 768 解码宽度,无头像回退名字首字。
class CharacterAvatarPreview extends ConsumerWidget {
  final int recordId;
  final CharacterCard card;

  /// 圆角/解码宽度按用途可调。
  final double borderRadius;
  final int cacheWidth;
  const CharacterAvatarPreview({
    super.key,
    required this.recordId,
    required this.card,
    this.borderRadius = 8,
    this.cacheWidth = 384,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hash = card.avatarHash;
    if (hash != null) {
      final provider = hashImageProvider(
        ref.read(databaseProvider).images,
        hash,
        cacheWidth: cacheWidth,
      );
      if (provider != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image(
            key: ValueKey('character-avatar-$recordId-$hash'),
            image: provider,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _failedPlaceholder(context, scheme),
          ),
        );
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: _failedPlaceholder(context, scheme),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: _placeholder(context, scheme, card),
    );
  }

  Widget _failedPlaceholder(BuildContext context, ColorScheme scheme) {
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 20,
        color: scheme.outline,
      ),
    );
  }

  Widget _placeholder(
    BuildContext context,
    ColorScheme scheme,
    CharacterCard card,
  ) {
    final initial = card.name.isEmpty ? '?' : card.name.characters.first;
    return Container(
      color: scheme.secondaryContainer.withValues(alpha: 0.55),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            initial,
            style: Theme.of(context).textTheme.displayLarge?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
