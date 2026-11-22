// 外部图片资产化入口:先缩图再落盘、base64 边界、内容去重与坏输入。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_asset_input.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() async {
    db = await openTestDb();
  });

  tearDown(() => db.db.close());

  testWidgets('small bytes and base64 share one zero-ref asset', (tester) async {
    await tester.runAsync(() async {
      final png = await solidTestPng(48, 32);
      final fromBytes = await assetizeImageBytes(db, png);
      final fromBase64 = await assetizeBase64Image(db, base64Encode(png));

      expect(fromBytes, isNotNull);
      expect(fromBase64, fromBytes);
      expect(await db.db.query('image_assets'), hasLength(1));
      expect(await testImageRefCount(db, fromBytes!), 0);
      expect(await db.images.fileFor(fromBytes).readAsBytes(), png);
    });
  });

  testWidgets('large image is shrunk before storage and bad input returns null', (tester) async {
    await tester.runAsync(() async {
      final png = await solidTestPng(1600, 1200);
      final hash = await assetizeImageBytes(db, png);
      expect(hash, isNotNull);

      final stored = await db.images.fileFor(hash!).readAsBytes();
      expect(stored.length, lessThan(png.length));
      final codec = await ui.instantiateImageCodec(stored);
      final frame = await codec.getNextFrame();
      expect(math.max(frame.image.width, frame.image.height), lessThanOrEqualTo(1024));
      expect(frame.image.width, 1024);
      expect(frame.image.height, 768);
      frame.image.dispose();
      codec.dispose();

      expect(await assetizeImageBytes(db, null), isNull);
      expect(await assetizeBase64Image(db, 'not-base64'), isNull);
    });
  });
}
