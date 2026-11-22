/// 内容寻址图片的统一解码入口与哈希头像组件。
///
/// 业务表只保存 SHA-256;各页面此前各自拼 `ResizeImage(FileImage(fileFor))`
/// 并各自兜底坏哈希。这里固定降采样策略与失败回退,避免解码尺寸与异常
/// 处理在聊天、列表、制卡之间漂移。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/image_asset_store.dart';
import '../../state/providers.dart';

/// 头像在列表与气泡旁的解码宽度。
const int kAvatarImageWidth = 384;

/// 大卡面、头像审阅、背景预览等较大的展示位。
const int kLargeImageWidth = 768;

/// 制卡头像缩略图。
const int kCardImageWidth = 512;

/// 聊天背景层的解码边长上限(宽高同值,竖图也不会只按宽解出超高帧)。
const int kBackgroundImageExtent = 2048;

/// 由内容哈希构造降采样图片 provider;空哈希、坏哈希或路径异常返回 null。
///
/// 固定 `policy: fit`:保持比例且不放大小图。调用方拿到 null 时自行展示
/// 占位,不再各自 try/catch。
ImageProvider? hashImageProvider(
  ImageAssetStore store,
  String? hash, {
  int? cacheWidth,
  int? cacheHeight,
}) {
  if (hash == null || hash.isEmpty) return null;
  try {
    return ResizeImage(
      FileImage(store.fileFor(hash)),
      width: cacheWidth,
      height: cacheHeight,
      policy: ResizeImagePolicy.fit,
    );
  } catch (_) {
    return null;
  }
}

/// 圆形哈希头像:有图显示降采样头像,缺图/坏图露出 [child] 占位。
///
/// 与直接写 `CircleAvatar` 等价;底色保持调用方传入的 [backgroundColor],
/// 不在这里强行套 `secondaryContainer`,聊天 AppBar 的默认底色不变。
class HashAvatar extends ConsumerWidget {
  final String? hash;
  final double radius;
  final Widget? child;
  final Color? backgroundColor;
  final int cacheWidth;

  const HashAvatar({
    super.key,
    required this.hash,
    required this.radius,
    this.child,
    this.backgroundColor,
    this.cacheWidth = kAvatarImageWidth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = hash;
    final provider = value == null || value.isEmpty
        ? null
        : hashImageProvider(
            ref.read(databaseProvider).images,
            value,
            cacheWidth: cacheWidth,
          );
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      foregroundImage: provider,
      onForegroundImageError: provider == null ? null : (_, __) {},
      child: child,
    );
  }
}
