// 图片瘦身:超尺寸按长边缩到 1024、小图逐字节保留、data URI 归一,
// 以及坏输入的 null/原值回退。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/shrink_image.dart';

/// 用 dart:ui 画一张纯色 PNG(文件很小,但解压后像素很多 —— 刚好覆盖
/// "文件不大也必须按尺寸缩"的情况)。
Future<Uint8List> _solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff5577aa),
  );
  final image = await recorder.endRecording().toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

void main() {
  testWidgets('downscales oversized dimensions even when the file is tiny', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final png = await _solidPng(1600, 1200);
      // 纯色 PNG 压缩后远小于 1.4MB,但像素尺寸超限 —— 必须仍缩到 1024。
      expect(png.length, lessThan(1400 * 1024));

      final shrunk = await shrinkImageBytes(png);
      expect(shrunk, isNotNull);
      final image = await _decode(base64Decode(shrunk!));
      try {
        expect(math.max(image.width, image.height), lessThanOrEqualTo(1024));
        expect(image.width, 1024);
        expect(image.height, 768);
      } finally {
        image.dispose();
      }
    });
  });

  testWidgets('keeps small images byte-for-byte', (tester) async {
    await tester.runAsync(() async {
      final png = await _solidPng(64, 84);
      final b64 = await shrinkImageBytes(png);
      expect(b64, base64Encode(png));
    });
  });

  testWidgets('limits very tall images by the long edge', (tester) async {
    await tester.runAsync(() async {
      final png = await _solidPng(800, 3000);
      final b64 = await shrinkImageBytes(png);
      expect(b64, isNotNull);
      final image = await _decode(base64Decode(b64!));
      try {
        expect(image.height, 1024);
        expect(image.width, lessThan(image.height));
      } finally {
        image.dispose();
      }
    });
  });

  testWidgets('data URI avatars are normalized and shrunk', (tester) async {
    await tester.runAsync(() async {
      final png = await _solidPng(1600, 1200);
      final withPrefix = 'data:image/png;base64,${base64Encode(png)}';
      final b64 = await shrinkBase64Image(withPrefix);
      expect(b64, isNotNull);
      expect(b64!.startsWith('data:'), isFalse);
      final image = await _decode(base64Decode(b64));
      try {
        expect(math.max(image.width, image.height), lessThanOrEqualTo(1024));
      } finally {
        image.dispose();
      }
    });
  });

  testWidgets('bad image bytes return null / original without throwing', (
    tester,
  ) async {
    await tester.runAsync(() async {
      expect(await shrinkImageBytes(Uint8List.fromList([1, 2, 3])), isNull);
      // 兼容旧语义:传入串不是可解码图片时原样返还,由调用方决定回退。
      final notImage = base64Encode([1, 2, 3]);
      expect(await shrinkBase64Image(notImage), notImage);
      expect(await shrinkBase64Image(null), isNull);
    });
  });
}
