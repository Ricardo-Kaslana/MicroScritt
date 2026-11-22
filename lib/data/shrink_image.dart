/// 图片缩小:只按长边缩到安全尺寸,不再按旧 base64 预算反复重编码。
///
/// 文件入库路径直接拿字节:尺寸已在上限内时逐字节返回,绝不因文件体积
/// 门槛重编码;GIF/动图保留原始字节(动画不能取首帧转 PNG)。缩图失败时
/// 保持既有回退:字节入口返回 null,base64 入口返回原始字符串。
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'image_codec.dart';
import 'image_compressor.dart';

/// 把一张 base64 图片缩到安全尺寸再 base64 返回。
///
/// 非 base64/解码失败:原样返回(不缩小,保住原值),由调用方决定占位或回退。
Future<String?> shrinkBase64Image(String? base64, {int maxDim = 1024}) async {
  if (base64 == null || base64.isEmpty) return null;
  final bytes = safeBase64Decode(base64);
  if (bytes == null) return base64;
  return await shrinkImageBytes(bytes, maxDim: maxDim) ?? base64;
}

/// 把原始图片字节缩到安全尺寸并 base64 返回;解码失败返回 null。
Future<String?> shrinkImageBytes(Uint8List? bytes, {int maxDim = 1024}) async {
  final shrunk = await shrinkImageBytesToBytes(bytes, maxDim: maxDim);
  return shrunk == null ? null : base64Encode(shrunk);
}

/// 把原始图片字节缩到长边不超过 [maxDim],直接返回可资产化的字节。
///
/// 只读文件头就能确定的边界先挡掉:尺寸 `<= maxDim` 的图原样返回(帧内
/// 不放大、不重编码),GIF/动图原样返回(保住动画),超出资产库硬上限的图
/// 返回 null 而不是冒险整图解码。真正需要缩小时,首次解码就按比例限制目标
/// 宽高,避免先解出全尺寸像素再缩放。
Future<Uint8List?> shrinkImageBytesToBytes(
  Uint8List? bytes, {
  int maxDim = 1024,
}) async {
  if (bytes == null || bytes.isEmpty || maxDim <= 0) return null;
  final header = readImageHeader(bytes);
  if (header != null) {
    if (header.mime == 'image/gif' || header.animated) return bytes;
    if (header.width > maxImageDimension || header.height > maxImageDimension) {
      return null;
    }
    if (header.width * header.height > maxImagePixelCount) return null;
    if (header.width <= maxDim && header.height <= maxDim) return bytes;
  }

  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? img;
  try {
    // 同时给 codec 两个裸 maxDim 会把非方图拉成方形;先只读图片头尺寸,
    // 再按原比例计算双向封顶的首次解码尺寸。
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } finally {
      buffer.dispose();
    }
    final originalWidth = descriptor.width;
    final originalHeight = descriptor.height;
    // 可识别的四种位图已在上面按文件头挡过;其余格式只在这里用平台
    // descriptor 的头部尺寸补同样的硬上限,再决定是否需要缩小。
    if (header == null) {
      if (originalWidth > maxImageDimension ||
          originalHeight > maxImageDimension) {
        return null;
      }
      if (originalWidth * originalHeight > maxImagePixelCount) return null;
      if (originalWidth <= maxDim && originalHeight <= maxDim) return bytes;
    }
    final longest = originalWidth > originalHeight
        ? originalWidth
        : originalHeight;
    if (longest <= 0) return null;
    final scale = longest > maxDim ? maxDim / longest : 1.0;
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: (originalWidth * scale).round().clamp(1, maxDim),
      targetHeight: (originalHeight * scale).round().clamp(1, maxDim),
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    img = frame.image;
    final w = img.width;
    final h = img.height;
    // 按长边重采样到精确目标框:平台 codec 的采样可能只压住一个轴。
    final tw = (originalWidth * maxDim / longest).round().clamp(1, maxDim);
    final th = (originalHeight * maxDim / longest).round().clamp(1, maxDim);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final resized = await picture.toImage(tw, th);
    picture.dispose();
    final ByteData? byteData;
    try {
      byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      resized.dispose();
    }
    if (byteData == null) return null;
    return byteData.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    img?.dispose();
    codec?.dispose();
    descriptor?.dispose();
  }
}
