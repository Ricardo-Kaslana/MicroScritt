// 图片资产测试夹具:最小有效 PNG、资产化与引用计数查询。
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:microscritt/data/database.dart';

const testPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const testPngBase64Alt =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=';

Uint8List testPngBytes({bool alternate = false}) => Uint8List.fromList(
  base64Decode(alternate ? testPngBase64Alt : testPngBase64),
);

String testPngHash({bool alternate = false}) =>
    sha256.convert(testPngBytes(alternate: alternate)).toString();

Future<String> putTestImage(AppDatabase db, {bool alternate = false}) async {
  final ref = await db.images.putBytes(testPngBytes(alternate: alternate));
  return ref.hash;
}

Future<int> imageRefCount(AppDatabase db, String hash) async {
  final rows = await db.db.query(
    'image_assets',
    columns: ['ref_count'],
    where: 'hash = ?',
    whereArgs: [hash],
  );
  return rows.isEmpty ? 0 : rows.single['ref_count'] as int;
}
