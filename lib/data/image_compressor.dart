/// 入库前的大图压缩、图片头解析与受控解码并发闸。
///
/// 调用方负责跳过 GIF(保留动画);解码失败、无需压缩或压缩后反而更大时
/// 返回 null,由调用方保留原图。解析与重编码在 isolate 中执行,不阻塞 UI,
/// 且全局并发解码数受 [runImageDecodeTask] 限制,避免多张巨图同时解码打爆内存。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 与资产库一致的尺寸/像素硬上限;文件头解析后先挡超限输入,避免整图解码。
const int maxImageDimension = 8192;
const int maxImagePixelCount = 40 * 1000 * 1000;

/// 单进程同时执行的重解码任务上限。压缩与校验解码都走同一个闸门。
const int maxConcurrentImageDecodes = 2;

/// 图片头里可廉价获得的格式与尺寸信息。
class ImageHeader {
  /// 归一化的 MIME(仅 PNG/JPEG/GIF/WebP)。
  final String mime;

  /// 文件头声明的宽度(JPEG 为 EXIF 旋转前的原始像素宽度)。
  final int width;

  /// 文件头声明的高度(JPEG 为 EXIF 旋转前的原始像素高度)。
  final int height;

  /// 是否可能含多帧(GIF 一律按动画处理;WebP 看 VP8X 动画标志)。
  final bool animated;

  const ImageHeader(
    this.mime,
    this.width,
    this.height, {
    this.animated = false,
  });
}

/// 只解析文件头,不申请整图像素缓冲区;无法识别返回 null。
///
/// 与入库校验共用同一份逻辑:压缩前、缩图前、落库前都先经过这里,
/// 任何超限/伪装格式都不会进入解码器。
ImageHeader? readImageHeader(Uint8List bytes) {
  try {
    if (_isPngBytes(bytes)) {
      final size = _pngSize(bytes);
      if (size == null) return null;
      return ImageHeader('image/png', size.$1, size.$2);
    }
    if (_isJpegBytes(bytes)) {
      final size = _jpegSize(bytes);
      if (size == null) return null;
      return ImageHeader('image/jpeg', size.$1, size.$2);
    }
    if (_isGifBytes(bytes)) {
      return ImageHeader(
        'image/gif',
        _le16(bytes, 6),
        _le16(bytes, 8),
        animated: true,
      );
    }
    if (_isWebpBytes(bytes)) {
      final size = _webpSize(bytes);
      if (size == null) return null;
      return ImageHeader(
        'image/webp',
        size.$1,
        size.$2,
        animated: _isAnimatedWebp(bytes),
      );
    }
    return null;
  } catch (_) {
    return null;
  }
}

bool _isPngBytes(Uint8List b) =>
    b.length >= 24 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    b[4] == 0x0D &&
    b[5] == 0x0A &&
    b[6] == 0x1A &&
    b[7] == 0x0A;

bool _isJpegBytes(Uint8List b) =>
    b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

bool _isGifBytes(Uint8List b) =>
    b.length >= 10 &&
    b[0] == 0x47 &&
    b[1] == 0x49 &&
    b[2] == 0x46 &&
    b[3] == 0x38 &&
    (b[4] == 0x37 || b[4] == 0x39) &&
    b[5] == 0x61;

bool _isWebpBytes(Uint8List b) =>
    b.length >= 16 &&
    b[0] == 0x52 &&
    b[1] == 0x49 &&
    b[2] == 0x46 &&
    b[3] == 0x46 &&
    b[8] == 0x57 &&
    b[9] == 0x45 &&
    b[10] == 0x42 &&
    b[11] == 0x50;

/// 把 [bytes] 的长边压到 [maxEdge];不需要或无法安全压缩时返回 null。
Future<Uint8List?> compressImageForStorage(
  Uint8List bytes, {
  int maxEdge = 2048,
}) => runImageDecodeTask(() => compute(_compress, (bytes, maxEdge)));

/// 全局重解码并发闸:超过 [maxConcurrentImageDecodes] 的任务排队等待。
///
/// 巨图解码的峰值内存与并发数直接相乘;这里只保证进程内所有走本入口的
/// 解码(存储压缩、入库前真实解码校验)不会相互叠满内存。
Future<T> runImageDecodeTask<T>(Future<T> Function() action) async {
  while (_activeDecodes >= maxConcurrentImageDecodes) {
    final waiter = Completer<void>();
    _decodeWaiters.add(waiter);
    await waiter.future;
  }
  _activeDecodes++;
  try {
    return await action();
  } finally {
    _activeDecodes--;
    if (_decodeWaiters.isNotEmpty) {
      _decodeWaiters.removeAt(0).complete();
    }
  }
}

int _activeDecodes = 0;
final List<Completer<void>> _decodeWaiters = [];

/// isolate 入口:先读文件头挡住超限/动画输入,再按长边重编码。
///
/// image 4.13 的 `copyResize` 会自动烘焙 EXIF 方向(内部按旋转后的宽高
/// 计算另一轴),但文件头尺寸仍是旋转前的像素。这里先按 orientation 5–8
/// 交换宽高,再选择长边轴,保证竖图与旋转图的结果长边都不超过 [maxEdge]。
Uint8List? _compress((Uint8List, int) input) {
  final (bytes, maxEdge) = input;
  if (maxEdge <= 0) return null;
  final header = readImageHeader(bytes);
  if (header == null) return null;
  if (header.mime == 'image/gif' || header.animated) return null;
  if (header.width > maxImageDimension || header.height > maxImageDimension) {
    return null;
  }
  if (header.width * header.height > maxImagePixelCount) return null;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  var width = decoded.width;
  var height = decoded.height;
  final orientation = decoded.exif.imageIfd.orientation ?? 1;
  if (orientation >= 5 && orientation <= 8) {
    final swapped = width;
    width = height;
    height = swapped;
  }
  if (width <= maxEdge && height <= maxEdge) return null;
  // copyResize 以 EXIF 旋转后的坐标系解释 width/height;只给长边所在轴。
  final resized = width >= height
      ? img.copyResize(
          decoded,
          width: maxEdge,
          interpolation: img.Interpolation.average,
        )
      : img.copyResize(
          decoded,
          height: maxEdge,
          interpolation: img.Interpolation.average,
        );
  return _encodeIfSmaller(resized, bytes);
}

Uint8List? _encodeIfSmaller(img.Image image, Uint8List original) {
  final hasAlpha = _hasTransparency(image);
  final encoded = hasAlpha
      ? Uint8List.fromList(img.encodePng(image))
      : Uint8List.fromList(img.encodeJpg(image, quality: 90));
  if (encoded.isEmpty || encoded.length >= original.length) return null;
  return encoded;
}

bool _hasTransparency(img.Image image) {
  for (final pixel in image) {
    if (pixel.a < 255) return true;
  }
  return false;
}

(int, int)? _pngSize(Uint8List b) {
  if (_be32(b, 8) != 13 ||
      b[12] != 0x49 ||
      b[13] != 0x48 ||
      b[14] != 0x44 ||
      b[15] != 0x52) {
    return null;
  }
  return (_be32(b, 16), _be32(b, 20));
}

(int, int)? _jpegSize(Uint8List b) {
  var offset = 2;
  while (offset + 1 < b.length) {
    if (b[offset] != 0xFF) {
      offset++;
      continue;
    }
    final marker = b[offset + 1];
    if (marker == 0xFF) {
      offset++;
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA || offset + 4 > b.length) return null;
    final length = (b[offset + 2] << 8) | b[offset + 3];
    if (length < 2 || offset + 2 + length > b.length) return null;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (length < 7) return null;
      return (
        (b[offset + 7] << 8) | b[offset + 8],
        (b[offset + 5] << 8) | b[offset + 6],
      );
    }
    offset += 2 + length;
  }
  return null;
}

(int, int)? _webpSize(Uint8List b) {
  if (b.length < 30 || b[12] != 0x56 || b[13] != 0x50 || b[14] != 0x38) {
    return null;
  }
  if (b[15] == 0x58) {
    return (
      1 + (b[24] | (b[25] << 8) | (b[26] << 16)),
      1 + (b[27] | (b[28] << 8) | (b[29] << 16)),
    );
  }
  if (b[15] == 0x20) {
    if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
    return (_le16(b, 26) & 0x3FFF, _le16(b, 28) & 0x3FFF);
  }
  if (b[15] == 0x4C) {
    if (b.length < 25 || b[20] != 0x2F) return null;
    final bits = _le32(b, 21);
    return (1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF));
  }
  return null;
}

/// VP8X 的动画标志(flags 字节 bit1);带 ANIM 块的多帧 WebP 保留原字节。
bool _isAnimatedWebp(Uint8List b) =>
    b.length >= 21 && b[15] == 0x58 && (b[20] & 0x02) != 0;

int _be32(Uint8List b, int offset) =>
    (b[offset] << 24) |
    (b[offset + 1] << 16) |
    (b[offset + 2] << 8) |
    b[offset + 3];

int _le16(Uint8List b, int offset) => b[offset] | (b[offset + 1] << 8);

int _le32(Uint8List b, int offset) =>
    b[offset] |
    (b[offset + 1] << 8) |
    (b[offset + 2] << 16) |
    (b[offset + 3] << 24);
