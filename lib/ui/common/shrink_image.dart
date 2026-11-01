import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../data/image_codec.dart';

/// 把一张 base64 图片缩到安全尺寸再 base64 返回。
///
/// 目的:Android SQLite 的 CursorWindow 固定 ~2MB,单行任一字段(如角色卡的
/// 头像,可能是整张几 MB 的 PNG)超过它就会抛 "Row too big to fit into
/// CursorWindow",`SELECT * FROM characters` 直接失败 —— 这就是"大角色卡只有
/// 移动端导入失败、且列表一直转圈"的根因(桌面 FFI 直连 SQLite 无此上限)。
/// 头像在应用里只用于小预览/气泡/背景,缩到 ~1024px 肉眼看不出差别,却能
/// 让行永远安全地待在小窗口里。超过安全上限会进一步缩到 768/512 逐档降级,
/// 保证 base64 远小于窗口(不是靠运气)。
///
/// 非 base64/解码失败:原样返回(不缩小,保住原图)。
Future<String?> shrinkBase64Image(String? base64, {int maxDim = 1024}) async {
  if (base64 == null || base64.isEmpty) return null;
  final bytes = safeBase64Decode(base64);
  if (bytes == null) return base64; // 非 base64(纯文本/坏值),原样返回
  return await shrinkImageBytes(bytes, maxDim: maxDim) ?? base64;
}

/// 把原始图片字节缩到安全尺寸并 base64 返回;解码失败返回 null。
///
/// 与 [shrinkBase64Image] 分开是为了 PNG 角色卡:导入时整张 20MB 卡图本来
/// 就在内存里,先 base64Encode 再 base64Decode 会白白做两遍 O(n) 大拷贝。
///
/// 解码时按 [maxDim] 限宽采样(`allowUpscaling: false` 保证小图不被放大):
/// 6000×6000 的整图解码要 ~144MB RGBA,移动端会直接 OOM/卡死;限宽后只有
/// 几 MB。竖长图高度仍可能超过 [maxDim],再走一遍画布缩放。
Future<String?> shrinkImageBytes(Uint8List? bytes, {int maxDim = 1024}) async {
  if (bytes == null || bytes.isEmpty) return null;
  ui.Codec? codec;
  ui.Image? img;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: maxDim,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    img = frame.image;
    final w = img.width;
    final h = img.height;
    // dimension 本来就小的图:不解码重编,原样返回(保住原图质量)。
    // `w < maxDim` 是"解码器没缩过"的判据:原宽 > maxDim 时 targetWidth
    // 会把它压到正好 maxDim,此时即使文件很小(纯色大图)也必须重编码到
    // 安全尺寸,不能因为文件字节小就返回原图。
    if (w < maxDim && h <= maxDim && _b64Safe(bytes)) {
      return base64Encode(bytes);
    }
    var target = maxDim;
    while (true) {
      final longest = w > h ? w : h;
      if (longest <= 0) return null;
      final tw = (w * target / longest).round().clamp(1, target);
      final th = (h * target / longest).round().clamp(1, target);
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
      final out = byteData.buffer.asUint8List();
      if (_b64Safe(out) || target <= 256) {
        return base64Encode(out);
      }
      target = (target * 0.75).round(); // 还不够小,下一档再缩
    }
  } catch (_) {
    return null; // 坏图:调用方回退占位/原值,不让导入整体失败
  } finally {
    img?.dispose();
    codec?.dispose();
  }
}

/// base64(≈ 4/3 原字节)是否明显小于 Android CursorWindow(~2MB 是整行预算,
/// 头像列还要与 data_json/name/background 共享)。保守压到 1.4MB,给同行其他
/// 字段留足余量,避免正好卡在窗口边上。
bool _b64Safe(Uint8List bytes) => bytes.length * 4 ~/ 3 < 1400 * 1024;
