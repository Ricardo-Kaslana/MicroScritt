/// 从图片头部直接解析像素宽高与宽高比,不解码整张图。
///
/// 识别失败一律返回 null,由调用方回退方形占位 —— 坏图/截断文件不允许
/// 阻断消息渲染,也不允许为了量尺寸把几十 MB 图片读进 Dart 堆。
library;

import 'dart:io';
import 'dart:typed_data';

/// 从图片头部解析像素宽高(不解码像素)。无法识别/头信息不完整返回 null。
///
/// 支持 Flutter 可解码的常见格式(PNG / JPEG / GIF / WebP / BMP)。任何越界
/// 或异常都按"识别不出"处理,调用方回退方形占位,绝不让一张坏图阻断渲染。
(int, int)? imageSizeFromBytes(Uint8List bytes) {
  try {
    if (_isPng(bytes)) return _pngSize(bytes);
    if (_isJpeg(bytes)) return _jpegSize(bytes);
    if (_isGif(bytes)) return _gifSize(bytes);
    if (_isWebp(bytes)) return _webpSize(bytes);
    if (_isBmp(bytes)) return _bmpSize(bytes);
  } catch (_) {}
  return null;
}

/// 图片宽高比包装。识别不出/宽高非法返回 null。
double? imageAspectFromBytes(Uint8List bytes) {
  final size = imageSizeFromBytes(bytes);
  if (size == null) return null;
  final (width, height) = size;
  if (width <= 0 || height <= 0) return null;
  return width / height;
}

/// 只读取文件头部(默认 64KB)解析宽高比:磁盘缓存命中时无需把整张图读进
/// Dart 堆。JPEG 的 SOF 段可能位于较大的 EXIF 之后,超出预读范围时返回
/// null,由解码完成后的真实比例补齐。
Future<double?> imageAspectFromFile(
  File file, {
  int headerBytes = 64 * 1024,
}) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final bytes = await raf.read(headerBytes);
    return imageAspectFromBytes(bytes);
  } catch (_) {
    return null;
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

bool _isPng(Uint8List b) =>
    b.length >= 24 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    b[4] == 0x0D &&
    b[5] == 0x0A &&
    b[6] == 0x1A &&
    b[7] == 0x0A;

/// PNG:IHDR 必须是第一个 chunk(长度 + 'IHDR' + 宽 + 高,大端)。
(int, int)? _pngSize(Uint8List b) {
  if (!(b[12] == 0x49 && b[13] == 0x48 && b[14] == 0x44 && b[15] == 0x52)) {
    return null;
  }
  return (_be32(b, 16), _be32(b, 20));
}

bool _isJpeg(Uint8List b) =>
    b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

/// JPEG:从 SOI 起逐段扫描,遇到 SOF0–SOF15(除 DHT/JPG/DAC)取段内宽高。
(int, int)? _jpegSize(Uint8List b) {
  var offset = 2;
  while (offset + 1 < b.length) {
    if (b[offset] != 0xFF) {
      offset++; // 标记间的填充字节
      continue;
    }
    final marker = b[offset + 1];
    if (marker == 0xFF) {
      offset++; // 标记前的 0xFF 填充
      continue;
    }
    // 无长度字段的独立标记:SOI / TEM / RSTn。
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      offset += 2;
      continue;
    }
    // 到 EOI / SOS 仍未遇到 SOF:头里没有可用的尺寸信息。
    if (marker == 0xD9 || marker == 0xDA) return null;
    if (offset + 4 > b.length) return null;
    final length = (b[offset + 2] << 8) | b[offset + 3];
    if (length < 2 || offset + 2 + length > b.length) return null;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 && // DHT
        marker != 0xC8 && // JPG
        marker != 0xCC; // DAC
    if (isSof) {
      // 段内:长度(2) + 精度(1) + 高(2) + 宽(2)。
      final height = (b[offset + 5] << 8) | b[offset + 6];
      final width = (b[offset + 7] << 8) | b[offset + 8];
      return (width, height);
    }
    offset += 2 + length;
  }
  return null;
}

bool _isGif(Uint8List b) =>
    b.length >= 10 &&
    b[0] == 0x47 &&
    b[1] == 0x49 &&
    b[2] == 0x46 &&
    b[3] == 0x38 &&
    (b[4] == 0x37 || b[4] == 0x39) &&
    b[5] == 0x61;

/// GIF:逻辑屏幕宽高在 6..9(小端)。
(int, int)? _gifSize(Uint8List b) => (_le16(b, 6), _le16(b, 8));

bool _isWebp(Uint8List b) =>
    b.length >= 16 &&
    b[0] == 0x52 &&
    b[1] == 0x49 &&
    b[2] == 0x46 &&
    b[3] == 0x46 &&
    b[8] == 0x57 &&
    b[9] == 0x45 &&
    b[10] == 0x42 &&
    b[11] == 0x50;

/// WebP:按首个 chunk 区分 VP8X(扩展,宽高 24 位)/ VP8(有损 14 位)/
/// VP8L(无损 14 位),偏移均相对 RIFF 头之后的 chunk data。
(int, int)? _webpSize(Uint8List b) {
  if (b.length >= 30 && b[12] == 0x56 && b[13] == 0x50 && b[14] == 0x38) {
    if (b[15] == 0x58) {
      // 'VP8X':flags(1) + reserved(3) + canvas width-1(3) + height-1(3)。
      final width = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
      final height = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
      return (width, height);
    }
    if (b[15] == 0x20) {
      // 'VP8 '(有损):帧起始码 9D 01 2A 后是 14 位宽高。
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      return (_le16(b, 26) & 0x3FFF, _le16(b, 28) & 0x3FFF);
    }
    if (b[15] == 0x4C) {
      // 'VP8L'(无损):0x2F 后 4 字节打包 14 位宽-1 + 14 位高-1。
      if (b.length < 25 || b[20] != 0x2F) return null;
      final bits = _le32(b, 21);
      return (1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF));
    }
  }
  return null;
}

bool _isBmp(Uint8List b) =>
    b.length >= 26 && b[0] == 0x42 && b[1] == 0x4D;

/// BMP:DIB 头宽高在 18/22(有符号 32 位小端;负高度表示自上而下)。
(int, int)? _bmpSize(Uint8List b) {
  final width = _le32s(b, 18);
  final height = _le32s(b, 22);
  return (width, height < 0 ? -height : height);
}

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _le32s(Uint8List b, int o) {
  final v = _le32(b, o);
  return (v & 0x80000000) != 0 ? v - 0x100000000 : v;
}
