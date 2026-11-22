/// 聊天图片的显示预览：优先复用 1600 长边文件，缺失时后台生成并刷新。
///
/// 原图资产与引用计数仍由 ImageAssetStore 管理；本模块只写可整体重建的
/// v1 预览，不改数据库。GIF 始终使用原图，避免动画被静态预览替换。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../data/image_asset_store.dart';
import '../../data/image_compressor.dart';
import '../../state/providers.dart';
import '../common/image_header.dart';

/// 气泡图片渲染输入：降采样 provider、全屏原图与首帧占位比例。
typedef ImageAssetPreviewBuilder =
    Widget Function(
      BuildContext context,
      ImageProvider provider,
      File originalFile,
      double? aspectRatio,
    );

/// 单个 hash 的聊天预览选择器。
///
/// 文件缺失时展示 [fallback]；生成失败保留原图，不把后台预览故障暴露为
/// 图片加载错误。[ImageCache] 以文件路径和解码尺寸管理帧，本组件不缓存字节。
class ImageAssetPreview extends ConsumerStatefulWidget {
  final String hash;
  final int cacheWidth;
  final int cacheHeight;
  final ImageAssetPreviewBuilder builder;
  final Widget loading;
  final Widget fallback;

  const ImageAssetPreview({
    super.key,
    required this.hash,
    required this.cacheWidth,
    required this.cacheHeight,
    required this.builder,
    this.loading = const SizedBox.shrink(),
    this.fallback = const SizedBox.shrink(),
  });

  @override
  ConsumerState<ImageAssetPreview> createState() => _ImageAssetPreviewState();
}

class _ImageAssetPreviewState extends ConsumerState<ImageAssetPreview> {
  int _request = 0;
  ImageProvider? _provider;
  File? _original;
  double? _aspectRatio;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ImageAssetPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hash != widget.hash) {
      _provider = null;
      _original = null;
      _aspectRatio = null;
      _missing = false;
      _load();
      return;
    }
    if (oldWidget.cacheWidth != widget.cacheWidth ||
        oldWidget.cacheHeight != widget.cacheHeight) {
      // 窗口/分屏宽度变化只改变解码上限:保留当前帧继续铺满新框,后台按新
      // 尺寸重建 provider。若在这里清空 provider,连续拖拽窗口会反复回到
      // 转圈占位(闪灰),直到各次 _load 陆续完成。
      _missing = false;
      _load();
    }
  }

  ImageProvider _providerFor(File file) => ResizeImage(
    FileImage(file),
    width: widget.cacheWidth,
    height: widget.cacheHeight,
    policy: ResizeImagePolicy.fit,
  );

  Future<void> _load() async {
    final request = ++_request;
    final images = ref.read(databaseProvider).images;
    File original;
    try {
      original = images.fileFor(widget.hash);
    } catch (_) {
      _showMissing(request);
      return;
    }
    try {
      if (!await original.exists()) {
        _showMissing(request);
        return;
      }
    } catch (_) {
      // 文件不可读与缺失采用同一回退策略，不让单张图阻断消息列表。
      _showMissing(request);
      return;
    }

    var display = original;
    var shouldGenerate = false;
    try {
      // GIF 连既有预览也跳过，保证气泡与全屏都保留动画。
      if (!await _isGif(original)) {
        final preview = await images.previewFileFor(widget.hash);
        if (preview != null) {
          display = preview;
        } else {
          shouldGenerate = true;
        }
      }
    } catch (_) {
      // 预览目录不可读时仍可直接显示原图。
      display = original;
      shouldGenerate = false;
    }
    final aspect = await imageAspectFromFile(display);
    if (!mounted || request != _request) return;
    setState(() {
      _original = original;
      _aspectRatio = aspect;
      _provider = _providerFor(display);
    });
    if (shouldGenerate) unawaited(_generate(images, request));
  }

  Future<void> _generate(ImageAssetStore images, int request) async {
    final preview = await ImagePreviewCache.ensure(images, widget.hash);
    if (preview == null || !mounted || request != _request) return;
    setState(() => _provider = _providerFor(preview));
  }

  void _showMissing(int request) {
    if (!mounted || request != _request) return;
    setState(() => _missing = true);
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    final original = _original;
    if (provider != null && original != null) {
      return widget.builder(context, provider, original, _aspectRatio);
    }
    return _missing ? widget.fallback : widget.loading;
  }
}

/// 可重建预览的编码与原子写入。
///
/// 同一原图路径的在飞生成共享一个 Future，避免多个气泡重复编码和写盘。
/// 临时文件与目标同目录，rename 失败且目标已存在时复用先到的一份。
class ImagePreviewCache {
  ImagePreviewCache._();

  static const int longEdge = 1600;
  static final Map<String, Future<File?>> _inFlight = {};
  static final Random _random = Random.secure();

  static Future<File?> ensure(ImageAssetStore images, String hash) {
    final File original;
    try {
      original = images.fileFor(hash);
    } catch (_) {
      return Future<File?>.value();
    }
    final key = original.path;
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final task = _ensure(images, original, hash);
    _inFlight[key] = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_inFlight[key], task)) _inFlight.remove(key);
      }),
    );
    return task;
  }

  static Future<File?> _ensure(
    ImageAssetStore images,
    File original,
    String hash,
  ) async {
    try {
      if (!await original.exists() || await _isGif(original)) return null;
      final existing = await images.previewFileFor(hash);
      if (existing != null) return existing;
      // 预览解码与入库压缩共用全局并发闸:滚动长会话时多张巨图不会同时
      // 在各自 isolate 里全尺寸解码。
      final encoded = await runImageDecodeTask(
        () => compute(_encodePreview, original.path),
      );
      if (encoded == null) return null;
      final bytes = encoded[0] as Uint8List;
      final extension = encoded[1] as String;
      final target = _previewTarget(original, hash, extension);
      if (await target.exists()) return target;
      await target.parent.create(recursive: true);
      final suffix = _random.nextInt(0xffffffff).toRadixString(16);
      final tmp = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}-$suffix.part',
      );
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        try {
          await tmp.rename(target.path);
        } on FileSystemException {
          // Windows 不允许 rename 覆盖；另一写入方已落位时直接复用。
          if (!await target.exists()) rethrow;
        }
        // 新建预览后后台裁剪预览总量;复用既有预览的路径不扫描目录。
        unawaited(images.trimPreviews().then<void>((_) {}, onError: (_) {}));
        return target;
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    } catch (_) {
      // 坏原图、 isolate 解码失败与写盘失败都静默回退原图。
      return null;
    }
  }

  static File _previewTarget(File original, String hash, String extension) {
    final imagesRoot = original.parent.parent.parent.parent;
    return File(
      p.join(
        imagesRoot.path,
        'preview',
        hash.substring(0, 2),
        '$hash-v1-$longEdge.$extension',
      ),
    );
  }
}

Future<List<Object>?> _encodePreview(String path) async {
  final bytes = await File(path).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final source = decoded.width >= decoded.height
      ? (decoded.width > ImagePreviewCache.longEdge
            ? img.copyResize(
                decoded,
                width: ImagePreviewCache.longEdge,
                interpolation: img.Interpolation.average,
              )
            : decoded)
      : (decoded.height > ImagePreviewCache.longEdge
            ? img.copyResize(
                decoded,
                height: ImagePreviewCache.longEdge,
                interpolation: img.Interpolation.average,
              )
            : decoded);
  var transparent = false;
  for (final pixel in source) {
    if (pixel.a < 255) {
      transparent = true;
      break;
    }
  }
  if (transparent) {
    return [Uint8List.fromList(img.encodePng(source)), 'png'];
  }
  return [Uint8List.fromList(img.encodeJpg(source, quality: 88)), 'jpg'];
}

Future<bool> _isGif(File file) async {
  RandomAccessFile? input;
  try {
    input = await file.open();
    final header = await input.read(6);
    return header.length >= 6 &&
        header[0] == 0x47 &&
        header[1] == 0x49 &&
        header[2] == 0x46 &&
        header[3] == 0x38 &&
        (header[4] == 0x37 || header[4] == 0x39) &&
        header[5] == 0x61;
  } finally {
    await input?.close();
  }
}
