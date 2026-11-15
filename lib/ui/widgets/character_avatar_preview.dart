/// 角色卡头像预览:列表/网格/牌堆共用的惰性加载缩略图。
///
/// 按 id 惰性读 base64(列表查询已排除大 BLOB,Android CursorWindow 上限),
/// 拿到后按用途降采样解码,大图不再全分辨率解码占内存。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/character_card.dart';
import '../../state/providers.dart';

/// 角色卡头像预览:按 id 惰性读 base64,拿到后按用途降采样解码
/// (列表 384、大卡面 768);读取失败/为空(超大历史行)回退名字首字占位,
/// 绝不再转圈。
///
/// 数据走 [characterAvatarProvider]:编辑保存后 invalidate 该 provider,
/// 复用中的列表项也会拿到新头像(此前只按 id 重载,换头像要重导入才生效)。
class CharacterAvatarPreview extends ConsumerWidget {
  final int recordId;
  final CharacterCard card;

  /// 圆角/解码宽度按用途可调:列表缩略图 96 宽(384 解码即 ~4x 密度),
  /// 网格/牌堆卡面更大,交给调用方放大解码宽度。
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
    final avatar = ref.watch(characterAvatarProvider(recordId));
    final bytes = avatar.value;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.memory(
          bytes,
          cacheWidth: cacheWidth,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          // 编辑保存换图后 provider 会换新字节:保留旧帧直到新图解码完成,
          // 不再出现一帧空灰块。
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _failedPlaceholder(context, scheme),
        ),
      );
    }
    if (avatar.isLoading) {
      // 加载中:灰底占位,避免还没读到就闪字。
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(color: scheme.surfaceContainerHighest),
      );
    }
    if (avatar.hasError) {
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

  /// 头像字节存在但解码失败(损坏/非图片):与「没有头像」区分开,用破图
  /// 图标而不是名字首字,避免把坏数据误读成用户没设置头像。
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
      // 首字在 56–96 宽的小卡里也按可用尺寸收缩,超大字号设置下不溢出。
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
