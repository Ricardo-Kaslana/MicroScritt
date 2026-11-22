// 图片资产测试夹具:生成真实 PNG、写入资产库并读取引用计数。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:microscritt/data/database.dart';

Future<Uint8List> solidTestPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff5577aa),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<String> putTestImageHash(
  AppDatabase db, {
  int width = 8,
  int height = 8,
}) async {
  final ref = await db.images.putBytes(await solidTestPng(width, height));
  return ref.hash;
}

Future<int> testImageRefCount(AppDatabase db, String hash) async {
  final rows = await db.db.query(
    'image_assets',
    columns: ['ref_count'],
    where: 'hash = ?',
    whereArgs: [hash],
  );
  return rows.single['ref_count'] as int;
}
