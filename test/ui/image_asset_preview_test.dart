// 聊天文件预览:后台生成、格式与长边、并发/再次复用、GIF 与坏原图回退。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:microscritt/data/database.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/widgets/image_asset_preview.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opaque image generates one 1600 JPEG preview and reuses it', () async {
    final db = await openTestDb();
    addTearDown(() => db.db.close());
    final source = img.Image(width: 2000, height: 1000);
    img.fill(source, color: img.ColorRgb8(30, 80, 140));
    final ref = await db.images.putBytes(
      Uint8List.fromList(img.encodePng(source)),
    );

    final results = await Future.wait([
      ImagePreviewCache.ensure(db.images, ref.hash),
      ImagePreviewCache.ensure(db.images, ref.hash),
    ]);
    final preview = results[0];
    expect(preview, isNotNull);
    expect(results[1]?.path, preview?.path);
    expect(preview?.path, endsWith('-v1-1600.jpg'));
    final decoded = img.decodeJpg(await preview!.readAsBytes());
    expect((decoded?.width, decoded?.height), (1600, 800));

    final modified = await preview.lastModified();
    final reused = await ImagePreviewCache.ensure(db.images, ref.hash);
    expect(reused?.path, preview.path);
    expect(await reused!.lastModified(), modified);
  });

  test('transparent image generates a transparent PNG preview', () async {
    final db = await openTestDb();
    addTearDown(() => db.db.close());
    final source = img.Image(width: 80, height: 40, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(20, 40, 60, 120));
    final ref = await db.images.putBytes(
      Uint8List.fromList(img.encodePng(source)),
    );

    final preview = await ImagePreviewCache.ensure(db.images, ref.hash);
    expect(preview?.path, endsWith('-v1-1600.png'));
    final decoded = img.decodePng(await preview!.readAsBytes());
    expect(decoded?.getPixel(0, 0).a, lessThan(255));
  });

  test('GIF never gets a static preview', () async {
    final db = await openTestDb();
    addTearDown(() => db.db.close());
    final source = img.Image(width: 32, height: 16);
    img.fill(source, color: img.ColorRgb8(120, 30, 40));
    final ref = await db.images.putBytes(
      Uint8List.fromList(img.encodeGif(source)),
    );

    expect(await ImagePreviewCache.ensure(db.images, ref.hash), isNull);
    expect(await db.images.previewFileFor(ref.hash), isNull);
  });

  test('corrupt original falls back without creating a preview', () async {
    final db = await openTestDb();
    addTearDown(() => db.db.close());
    final hash = List.filled(64, 'a').join();
    final original = db.images.fileFor(hash);
    await original.parent.create(recursive: true);
    await original.writeAsBytes(const [1, 2, 3, 4]);

    expect(await ImagePreviewCache.ensure(db.images, hash), isNull);
    expect(await original.exists(), isTrue);
    expect(await db.images.previewFileFor(hash), isNull);
  });

  testWidgets('preview generation failure keeps the original file provider', (
    tester,
  ) async {
    late final AppDatabase db;
    late final File original;
    final hash = List.filled(64, 'b').join();
    await tester.runAsync(() async {
      db = await openTestDb();
      original = db.images.fileFor(hash);
      await original.parent.create(recursive: true);
      await original.writeAsBytes(const [5, 6, 7]);
    });
    addTearDown(() => db.db.close());
    File? displayedOriginal;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ImageAssetPreview(
            hash: hash,
            cacheWidth: 320,
            cacheHeight: 520,
            fallback: const Text('missing'),
            builder: (context, provider, file, aspect) {
              displayedOriginal = file;
              return const SizedBox(width: 20, height: 20);
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 20 && displayedOriginal == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(displayedOriginal?.path, original.path);
    expect(find.text('missing'), findsNothing);
  });
}
