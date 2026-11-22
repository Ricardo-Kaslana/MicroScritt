// 图片文件资产:内容去重与并发写入、格式/大小校验、事务引用计数、预览与宽限期回收。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:microscritt/data/card_studio_draft_file.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_asset_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Uint8List> _solidPng(int width, int height) async {
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

/// 噪声图:PNG 体积明显大于同尺寸 JPEG,用于验证压缩收益与落盘尺寸。
Uint8List _noisyPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  final random = math.Random(7);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        255,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// 带 EXIF 方向的噪声 JPEG;orientation 6 = 顺时针 90°,显示宽高与原始相反。
Uint8List _noisyJpeg(int width, int height, {int? orientation}) {
  final image = img.Image(width: width, height: height);
  final random = math.Random(11);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        255,
      );
    }
  }
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

/// 只用于在真实解码前触发尺寸护栏;这些字节不应被当成有效图片接受。
Uint8List _pngHeader(int width, int height) {
  final bytes = Uint8List(33);
  bytes.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  bytes[11] = 13;
  bytes.setRange(12, 16, [0x49, 0x48, 0x44, 0x52]);
  for (var i = 0; i < 4; i++) {
    bytes[16 + i] = (width >> (24 - i * 8)) & 0xff;
    bytes[20 + i] = (height >> (24 - i * 8)) & 0xff;
  }
  return bytes;
}

Future<int> _insertCharacter(
  AppDatabase db, {
  String? avatar,
  String? background,
}) => db.db.insert('characters', {
  'name': '测试角色',
  'avatar_hash': avatar,
  'background_hash': background,
  'data_json': '{}',
});

Future<int> _insertSession(AppDatabase db, int characterId) =>
    db.db.insert('sessions', {
      'character_id': characterId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory dir;
  late AppDatabase db;
  late ImageAssetStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('image-asset-store-test-');
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    store = ImageAssetStore(db.db, p.join(dir.path, 'images'));
  });

  tearDown(() async {
    await db.db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('相同内容并发写入仍只有一个文件与一行元数据', (tester) async {
    await tester.runAsync(() async {
      final png = await _solidPng(12, 8);
      final refs = await Future.wait([
        store.putBytes(png),
        store.putBytes(png),
      ]);

      expect(refs[0], refs[1]);
      expect(refs[0].byteSize, png.length);
      expect(refs[0].mime, 'image/png');
      expect((refs[0].width, refs[0].height), (12, 8));
      expect(refs[0].hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        store.fileFor(refs[0].hash).path,
        p.join(
          dir.path,
          'images',
          'original',
          refs[0].hash.substring(0, 2),
          refs[0].hash.substring(2, 4),
          refs[0].hash,
        ),
      );
      expect(await store.exists(refs[0].hash), isTrue);
      expect(await store.fileFor(refs[0].hash).readAsBytes(), png);
      expect(await db.db.query('image_assets'), hasLength(1));
      final originals = await Directory(
        p.join(dir.path, 'images', 'original'),
      ).list(recursive: true).where((entity) => entity is File).toList();
      expect(originals, hasLength(1));
      expect(
        await Directory(
          p.join(dir.path, 'images', 'tmp'),
        ).list().where((entity) => entity is File).toList(),
        isEmpty,
      );
      expect(() => store.fileFor('../${refs[0].hash}'), throwsArgumentError);
      expect(ImageAssetStore.isValidHash(refs[0].hash.toUpperCase()), isFalse);
    });
  });

  testWidgets('putStream 分块计算哈希并沿用单图大小限制', (tester) async {
    await tester.runAsync(() async {
      final png = await _solidPng(9, 7);
      final ref = await store.putStream(
        Stream<List<int>>.fromIterable([
          png.sublist(0, 3),
          png.sublist(3, 41),
          png.sublist(41),
        ]),
      );

      expect(ref.byteSize, png.length);
      expect((ref.width, ref.height), (9, 7));
      expect(await store.fileFor(ref.hash).readAsBytes(), png);
      await expectLater(
        store.putStream(
          Stream<List<int>>.value(
            Uint8List(ImageAssetStore.maxOriginalBytes + 1),
          ),
        ),
        throwsFormatException,
      );
      expect(
        await Directory(
          p.join(dir.path, 'images', 'tmp'),
        ).list().where((entity) => entity is File).toList(),
        isEmpty,
      );
    });
  });

  testWidgets('坏图与伪装图片被拒绝且不留下资产', (tester) async {
    await tester.runAsync(() async {
      for (final bytes in [
        Uint8List.fromList([1, 2, 3]),
        _pngHeader(10, 10),
      ]) {
        await expectLater(store.putBytes(bytes), throwsFormatException);
      }

      expect(await db.db.query('image_assets'), isEmpty);
      expect(
        await Directory(
          p.join(dir.path, 'images', 'tmp'),
        ).list().where((entity) => entity is File).toList(),
        isEmpty,
      );
    });
  });

  testWidgets('原始字节、像素总量与单边尺寸均执行上限', (tester) async {
    await tester.runAsync(() async {
      await expectLater(
        store.putBytes(Uint8List(ImageAssetStore.maxOriginalBytes + 1)),
        throwsFormatException,
      );
      await expectLater(
        store.putBytes(_pngHeader(7000, 6000)),
        throwsFormatException,
      );
      await expectLater(
        store.putBytes(_pngHeader(8193, 1)),
        throwsFormatException,
      );
      expect(await db.db.query('image_assets'), isEmpty);
    });
  });

  testWidgets('acquire 与 release 可加入业务事务且 release 不删文件', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(4, 6));
      await db.transaction((txn) async {
        await store.acquire(txn, ref.hash);
        await store.acquire(txn, ref.hash);
      });
      expect((await db.db.query('image_assets')).single['ref_count'], 2);

      await db.transaction((txn) => store.release(txn, ref.hash));
      await db.transaction((txn) => store.release(txn, ref.hash));
      await db.transaction((txn) => store.release(txn, ref.hash));
      expect((await db.db.query('image_assets')).single['ref_count'], 0);
      expect(await store.exists(ref.hash), isTrue);
    });
  });

  testWidgets('零引用资产仅在宽限期后回收原图与预览', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(5, 5));
      final preview = File(
        p.join(
          dir.path,
          'images',
          'preview',
          ref.hash.substring(0, 2),
          '${ref.hash}-v1-1600.jpg',
        ),
      );
      await preview.parent.create(recursive: true);
      await preview.writeAsBytes([1, 2, 3]);
      expect((await store.previewFileFor(ref.hash))?.path, preview.path);

      expect(await store.deleteIfUnreferenced(), 0);
      expect(await store.exists(ref.hash), isTrue);
      expect(
        await store.deleteIfUnreferenced(
          now: DateTime.now().add(const Duration(hours: 25)),
        ),
        1,
      );
      expect(await store.exists(ref.hash), isFalse);
      expect(await store.previewFileFor(ref.hash), isNull);
      expect(await db.db.query('image_assets'), isEmpty);
    });
  });

  testWidgets('存储统计与整理保留有引用原图并清理预览', (tester) async {
    await tester.runAsync(() async {
      final png = await _solidPng(6, 4);
      final ref = await store.putBytes(png);
      final preview = File(
        p.join(
          dir.path,
          'images',
          'preview',
          ref.hash.substring(0, 2),
          '${ref.hash}-v1-1600.jpg',
        ),
      );
      await preview.parent.create(recursive: true);
      await preview.writeAsBytes([1, 2, 3]);
      final tmp = File(p.join(dir.path, 'images', 'tmp', 'stale.part'));
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes([4, 5]);
      final future = DateTime.now().add(const Duration(hours: 25));

      var stats = await store.storageStats(now: future);
      expect(stats.databaseBytes, 0);
      expect(stats.originalBytes, png.length);
      expect(stats.assetCount, 1);
      expect(stats.reclaimableBytes, png.length);
      expect(stats.previewBytes, 3);

      await db.transaction((txn) => store.acquire(txn, ref.hash));
      stats = await store.storageStats(now: future);
      expect(stats.reclaimableBytes, 0);
      final result = await store.organizeStorage(
        now: future,
        tempOlderThan: Duration.zero,
      );
      expect(result.reclaimedAssets, 0);
      expect(result.removedTempFiles, 1);
      expect(result.removedPreviews, 1);
      expect(await store.exists(ref.hash), isTrue);
      expect(await preview.exists(), isFalse);
      expect(await tmp.exists(), isFalse);
      expect((await db.db.query('image_assets')).single['ref_count'], 1);
    });
  });

  testWidgets('文件数据库字节可由统计 API 读取', (tester) async {
    await tester.runAsync(() async {
      final path = p.join(dir.path, 'storage.db');
      final fileDb = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
        imageRootPath: p.join(dir.path, 'file-images'),
      );
      try {
        final stats = await fileDb.images.storageStats(databasePath: path);
        expect(stats.databaseBytes, greaterThan(0));
        expect(stats.databaseBytes, await File(path).length());
      } finally {
        await fileDb.db.close();
      }
    });
  });

  testWidgets('启动维护清理过期临时文件与到期零引用资产', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(4, 4));
      final tmp = File(p.join(dir.path, 'images', 'tmp', 'old.part'));
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes([1]);
      final old = DateTime.now().subtract(const Duration(hours: 25));
      await tmp.setLastModified(old);
      await db.db.update(
        'image_assets',
        {'created_at': old.millisecondsSinceEpoch},
        where: 'hash = ?',
        whereArgs: [ref.hash],
      );
      final logs = <String>[];

      await runImageAssetStartupMaintenance(store, logger: logs.add);

      expect(logs, isEmpty);
      expect(await tmp.exists(), isFalse);
      expect(await store.exists(ref.hash), isFalse);
      expect(await db.db.query('image_assets'), isEmpty);
    });
  });

  testWidgets('外部引用扫描失败时跳过本轮回收', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(4, 4));
      await db.db.update(
        'image_assets',
        {
          'created_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
        where: 'hash = ?',
        whereArgs: [ref.hash],
      );
      final logs = <String>[];

      await runImageAssetStartupMaintenance(
        store,
        logger: logs.add,
        externalReferences: () async => throw StateError('draft scan failed'),
      );

      // 无法确认草稿持有时绝不能按零引用删除原图。
      expect(await store.exists(ref.hash), isTrue);
      expect(logs.single, contains('跳过回收'));
    });
  });

  testWidgets('回收暂停期间重新写入并 acquire 不会删除新引用原图', (tester) async {
    await tester.runAsync(() async {
      final png = await _solidPng(7, 6);
      final original = await store.putBytes(png);
      var deletePaused = false;
      var allowDelete = false;
      store.debugBeforeOriginalDelete = (_) async {
        deletePaused = true;
        while (!allowDelete) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      };

      final reclaiming = store.deleteIfUnreferenced(
        now: DateTime.now().add(const Duration(hours: 25)),
      );
      while (!deletePaused) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final reacquired = () async {
        final ref = await store.putBytes(png);
        await db.transaction((txn) => store.acquire(txn, ref.hash));
        return ref;
      }();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      allowDelete = true;

      expect(await reclaiming, 1);
      final restored = await reacquired;
      expect(restored.hash, original.hash);
      expect(await store.fileFor(restored.hash).readAsBytes(), png);
      final row = (await db.db.query('image_assets')).single;
      expect(row['hash'], restored.hash);
      expect(row['ref_count'], 1);
    });
  });

  testWidgets('临时文件按年龄清理且不碰其他文件', (tester) async {
    await tester.runAsync(() async {
      final tmp = Directory(p.join(dir.path, 'images', 'tmp'));
      await tmp.create(recursive: true);
      final stale = File(p.join(tmp.path, 'stale.part'));
      final fresh = File(p.join(tmp.path, 'fresh.part'));
      final unrelated = File(p.join(tmp.path, 'keep.txt'));
      await stale.writeAsBytes([1]);
      await fresh.writeAsBytes([2]);
      await unrelated.writeAsBytes([3]);
      final now = DateTime.now();
      await stale.setLastModified(now.subtract(const Duration(hours: 25)));

      expect(await store.cleanupTempFiles(now: now), 1);
      expect(await stale.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
      expect(
        await store.cleanupTempFiles(olderThan: Duration.zero, now: now),
        1,
      );
      expect(await fresh.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
    });
  });

  testWidgets('引用对账按业务表重算并修正错误计数', (tester) async {
    await tester.runAsync(() async {
      final avatar = await store.putBytes(await _solidPng(5, 5));
      final background = await store.putBytes(await _solidPng(6, 6));
      final messageImage = await store.putBytes(await _solidPng(7, 7));
      final userAvatar = await store.putBytes(await _solidPng(8, 8));
      final characterId = await _insertCharacter(
        db,
        avatar: avatar.hash,
        background: background.hash,
      );
      final sessionId = await _insertSession(db, characterId);
      for (var seq = 1; seq <= 2; seq++) {
        await db.db.insert('messages', {
          'session_id': sessionId,
          'role': 'user',
          'content': 'hi',
          'seq': seq,
          'image_hash': messageImage.hash,
        });
      }
      await db.db.insert('user_profile', {
        'id': 1,
        'avatar_hash': userAvatar.hash,
      });
      await db.db.update('image_assets', {'ref_count': 9});

      final result = await store.reconcileReferences();

      expect(result.updatedAssets, 4);
      expect(result.missingAssets, 0);
      final counts = {
        for (final row in await db.db.query('image_assets'))
          row['hash'] as String: row['ref_count'] as int,
      };
      expect(counts[avatar.hash], 1);
      expect(counts[background.hash], 1);
      expect(counts[messageImage.hash], 2);
      expect(counts[userAvatar.hash], 1);

      expect((await store.reconcileReferences()).updatedAssets, 0);
    });
  });

  testWidgets('零引用旧计数归零后可在宽限期外回收', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(4, 4));
      await db.db.update('image_assets', {'ref_count': 3});

      final result = await store.reconcileReferences();

      expect(result.updatedAssets, 1);
      expect((await db.db.query('image_assets')).single['ref_count'], 0);
      await db.db.update(
        'image_assets',
        {
          'created_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
        where: 'hash = ?',
        whereArgs: [ref.hash],
      );
      expect(
        await store.deleteIfUnreferenced(
          now: DateTime.now().add(const Duration(hours: 25)),
        ),
        1,
      );
      expect(await store.exists(ref.hash), isFalse);
    });
  });

  testWidgets('外部草稿引用在宽限期外仍保留且多份草稿各计一次', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(9, 9));
      await db.db.update(
        'image_assets',
        {
          'created_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
        where: 'hash = ?',
        whereArgs: [ref.hash],
      );

      final result = await store.reconcileReferences(
        externalReferences: [
          {ref.hash},
          {ref.hash},
        ],
      );

      expect(result.updatedAssets, 1);
      expect(result.missingAssets, 0);
      expect((await db.db.query('image_assets')).single['ref_count'], 2);
      expect(
        await store.deleteIfUnreferenced(
          now: DateTime.now().add(const Duration(hours: 25)),
        ),
        0,
      );
      expect(await store.exists(ref.hash), isTrue);
    });
  });

  testWidgets('引用存在但缺元数据只计数并记录 warning', (tester) async {
    await tester.runAsync(() async {
      final orphan = List.filled(64, 'c').join();
      final logs = <String>[];

      final result = await store.reconcileReferences(
        externalReferences: [
          {orphan, 'not-a-hash', ' ', orphan.toUpperCase()},
        ],
        logger: logs.add,
      );

      expect(result.missingAssets, 1);
      expect(result.updatedAssets, 0);
      expect(logs.single, contains(orphan));
      expect(await db.db.query('image_assets'), isEmpty);
    });
  });

  testWidgets('预览总量超限时删除最旧文件并跳过 part 与原图', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(5, 5));
      final previewDir = Directory(
        p.join(dir.path, 'images', 'preview', ref.hash.substring(0, 2)),
      );
      await previewDir.create(recursive: true);
      final oldest = File(p.join(previewDir.path, '${ref.hash}-old.jpg'));
      final newest = File(p.join(previewDir.path, '${ref.hash}-new.jpg'));
      final part = File(p.join(previewDir.path, '${ref.hash}-new.jpg.part'));
      final now = DateTime.now();
      await oldest.writeAsBytes(List.filled(60, 1));
      await newest.writeAsBytes(List.filled(60, 2));
      await part.writeAsBytes(List.filled(10, 3));
      await oldest.setLastModified(now.subtract(const Duration(hours: 2)));
      await newest.setLastModified(now.subtract(const Duration(hours: 1)));

      expect(await store.trimPreviews(maxBytes: 100), 1);
      expect(await oldest.exists(), isFalse);
      expect(await newest.exists(), isTrue);
      expect(await part.exists(), isTrue);
      expect(await store.exists(ref.hash), isTrue);
    });
  });

  testWidgets('预览总量未超限时不删除任何文件', (tester) async {
    await tester.runAsync(() async {
      final dirPreview = Directory(p.join(dir.path, 'images', 'preview', 'aa'));
      await dirPreview.create(recursive: true);
      final first = File(p.join(dirPreview.path, 'aa-first.jpg'));
      final second = File(p.join(dirPreview.path, 'aa-second.jpg'));
      await first.writeAsBytes(List.filled(20, 1));
      await second.writeAsBytes(List.filled(20, 2));

      expect(await store.trimPreviews(maxBytes: 100), 0);
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);
    });
  });

  testWidgets('并发多次 trimPreviews 串行执行且不抛错', (tester) async {
    await tester.runAsync(() async {
      final dirPreview = Directory(p.join(dir.path, 'images', 'preview', 'bb'));
      await dirPreview.create(recursive: true);
      final now = DateTime.now();
      for (var i = 0; i < 3; i++) {
        final file = File(p.join(dirPreview.path, 'bb-$i.jpg'));
        await file.writeAsBytes(List.filled(30, i));
        await file.setLastModified(now.subtract(Duration(hours: 3 - i)));
      }

      final removed = await Future.wait([
        store.trimPreviews(maxBytes: 50),
        store.trimPreviews(maxBytes: 50),
        store.trimPreviews(maxBytes: 50),
      ]);

      expect(removed.reduce((a, b) => a + b), 2);
      expect(
        await dirPreview.list().where((entity) => entity is File).length,
        1,
      );
    });
  });

  testWidgets('启动维护先对账外部引用再裁剪预览', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(6, 5));
      await db.db.update(
        'image_assets',
        {
          'ref_count': 0,
          'created_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
        where: 'hash = ?',
        whereArgs: [ref.hash],
      );
      final preview = File(
        p.join(
          dir.path,
          'images',
          'preview',
          ref.hash.substring(0, 2),
          '${ref.hash}-v1-1600.jpg',
        ),
      );
      await preview.parent.create(recursive: true);
      await preview.writeAsBytes(List.filled(50, 7));
      final logs = <String>[];

      await runImageAssetStartupMaintenance(
        store,
        logger: logs.add,
        externalReferences: () async => ImageAssetExternalReferences([
          {ref.hash},
        ]),
        previewMaxBytes: 10,
      );

      expect(logs, isEmpty);
      expect(await preview.exists(), isFalse);
      expect(await store.exists(ref.hash), isTrue);
      expect((await db.db.query('image_assets')).single['ref_count'], 1);
    });
  });

  testWidgets('开启入库压缩后长边压到 2048 且内容可去重', (tester) async {
    await tester.runAsync(() async {
      store.compressMaxEdge = 2048;
      final png = _noisyPng(2200, 100);
      final ref = await store.putBytes(png);

      expect(ref.width, 2048);
      expect(ref.height, lessThanOrEqualTo(2048));
      expect(ref.mime, 'image/jpeg');
      expect(ref.byteSize, lessThan(png.length));
      expect(await store.fileFor(ref.hash).length(), ref.byteSize);

      final again = await store.putBytes(_noisyPng(2200, 100));
      expect(again.hash, ref.hash);
      expect(await db.db.query('image_assets'), hasLength(1));

      final streamed = await store.putStream(
        Stream.value(_noisyPng(2200, 100)),
      );
      expect(streamed.width, 2048);
      expect(streamed.hash, ref.hash);
    });
  });

  testWidgets('关闭入库压缩时逐字节保留原图', (tester) async {
    await tester.runAsync(() async {
      final png = _noisyPng(2200, 100);
      final ref = await store.putBytes(png);

      expect((ref.width, ref.height), (2200, 100));
      expect(ref.mime, 'image/png');
      expect(ref.byteSize, png.length);
      expect(await store.fileFor(ref.hash).readAsBytes(), png);
    });
  });

  testWidgets('compress=false 时即使开关开启也逐字节保留', (tester) async {
    await tester.runAsync(() async {
      store.compressMaxEdge = 2048;
      final png = _noisyPng(2200, 100);
      final ref = await store.putBytes(png, compress: false);

      expect((ref.width, ref.height), (2200, 100));
      expect(ref.mime, 'image/png');
      expect(ref.byteSize, png.length);
      expect(await store.fileFor(ref.hash).readAsBytes(), png);
    });
  });

  testWidgets('压缩前先按文件头挡掉超限尺寸,不进入整图解码', (tester) async {
    await tester.runAsync(() async {
      store.compressMaxEdge = 2048;
      await expectLater(
        store.putBytes(_pngHeader(7000, 6000)),
        throwsFormatException,
      );
      await expectLater(
        store.putBytes(_pngHeader(8193, 1)),
        throwsFormatException,
      );
      expect(await db.db.query('image_assets'), isEmpty);
      final tmpDir = Directory(p.join(dir.path, 'images', 'tmp'));
      if (await tmpDir.exists()) {
        expect(
          await tmpDir.list().where((entity) => entity is File).toList(),
          isEmpty,
        );
      }
    });
  });

  testWidgets('竖图按长边缩放,结果长边不超过上限', (tester) async {
    await tester.runAsync(() async {
      store.compressMaxEdge = 2048;
      final ref = await store.putBytes(_noisyPng(100, 2200));

      expect(ref.height, 2048);
      expect(ref.width, lessThanOrEqualTo(2048));
      expect(ref.mime, 'image/jpeg');
      expect(await store.fileFor(ref.hash).length(), ref.byteSize);
    });
  });

  testWidgets('EXIF orientation 5–8 的宽高交换后仍按长边缩放', (tester) async {
    await tester.runAsync(() async {
      store.compressMaxEdge = 500;
      // 原始 1200×600,orientation 6 顺时针旋转后显示为 600×1200。
      final jpeg = _noisyJpeg(1200, 600, orientation: 6);
      final ref = await store.putBytes(jpeg);

      expect(ref.mime, 'image/jpeg');
      expect(ref.height, 500, reason: '旋转后的长边应被压到 500');
      expect(ref.width, lessThanOrEqualTo(500));
      final decoded = img.decodeImage(
        await store.fileFor(ref.hash).readAsBytes(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.height, 500);
      expect(decoded.width, lessThanOrEqualTo(500));
    });
  });

  testWidgets('回收时单个文件失败保留元数据并继续其它资产', (tester) async {
    await tester.runAsync(() async {
      final first = await store.putBytes(await _solidPng(3, 4));
      final second = await store.putBytes(await _solidPng(4, 5));
      final old = DateTime.now().subtract(const Duration(hours: 25));
      await db.db.update('image_assets', {
        'created_at': old.millisecondsSinceEpoch,
      });
      store.debugBeforeOriginalDelete = (hash) async {
        if (hash == first.hash) {
          throw const FileSystemException('locked by another process');
        }
      };

      expect(
        await store.deleteIfUnreferenced(
          now: DateTime.now().add(const Duration(hours: 25)),
        ),
        1,
      );
      final remaining = await db.db.query('image_assets', columns: ['hash']);
      expect(remaining.single['hash'], first.hash);
      expect(await store.exists(first.hash), isTrue);
      expect(await store.exists(second.hash), isFalse);
    });
  });

  testWidgets('元数据插入失败时删除已 rename 的原图', (tester) async {
    await tester.runAsync(() async {
      final brokenDb = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final brokenStore = ImageAssetStore(
        brokenDb.db,
        p.join(dir.path, 'broken-images'),
      );
      await brokenDb.db.close();

      final png = await _solidPng(6, 6);
      await expectLater(brokenStore.putBytes(png), throwsA(anything));
      expect(
        await Directory(
          p.join(dir.path, 'broken-images', 'original'),
        ).list(recursive: true).where((entity) => entity is File).toList(),
        isEmpty,
      );
    });
  });

  testWidgets('孤儿原图清扫按元数据差集与年龄门槛执行', (tester) async {
    await tester.runAsync(() async {
      final known = await store.putBytes(await _solidPng(4, 4));
      final originalDir = Directory(p.join(dir.path, 'images', 'original'));
      await originalDir.create(recursive: true);
      final orphanHash = List.filled(64, 'a').join();
      final oldOrphan = File(p.join(originalDir.path, orphanHash));
      final freshHash = List.filled(64, 'b').join();
      final freshOrphan = File(p.join(originalDir.path, freshHash));
      await oldOrphan.writeAsBytes([1, 2, 3]);
      await freshOrphan.writeAsBytes([4, 5, 6]);
      await oldOrphan.setLastModified(
        DateTime.now().subtract(const Duration(hours: 25)),
      );

      expect(await store.cleanupOrphanOriginals(), 1);
      expect(await oldOrphan.exists(), isFalse);
      expect(await freshOrphan.exists(), isTrue);
      expect(await store.exists(known.hash), isTrue);
    });
  });

  testWidgets('预览命中刷新 mtime,清理跳过 .part 且逐文件容错', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(5, 5));
      final previewDir = Directory(
        p.join(dir.path, 'images', 'preview', ref.hash.substring(0, 2)),
      );
      await previewDir.create(recursive: true);
      final preview = File(p.join(previewDir.path, '${ref.hash}-v1-1600.jpg'));
      final part = File(
        p.join(previewDir.path, '${ref.hash}-v1-1600.jpg.part'),
      );
      await preview.writeAsBytes([1, 2, 3]);
      await part.writeAsBytes([4, 5]);
      await preview.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );

      expect(await store.previewFileFor(ref.hash), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final touched = await preview.stat();
      expect(
        DateTime.now().difference(touched.modified),
        lessThan(const Duration(minutes: 1)),
      );

      expect(await store.cleanupPreviews(), 1);
      expect(await preview.exists(), isFalse);
      expect(await part.exists(), isTrue, reason: '清理不能删在写 .part');
    });
  });

  testWidgets('统计的预览口径跳过 .part,待回收按现存文件计算', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(6, 7));
      final old = DateTime.now().subtract(const Duration(hours: 25));
      await db.db.update(
        'image_assets',
        {'created_at': old.millisecondsSinceEpoch},
        where: 'hash = ?',
        whereArgs: [ref.hash],
      );
      final previewDir = Directory(
        p.join(dir.path, 'images', 'preview', ref.hash.substring(0, 2)),
      );
      await previewDir.create(recursive: true);
      await File(
        p.join(previewDir.path, '${ref.hash}-v1-1600.jpg'),
      ).writeAsBytes(List.filled(10, 1));
      await File(
        p.join(previewDir.path, '${ref.hash}-v1-1600.jpg.part'),
      ).writeAsBytes(List.filled(30, 2));

      final now = DateTime.now().add(const Duration(hours: 25));
      var stats = await store.storageStats(now: now);
      expect(stats.previewBytes, 10, reason: '.part 是写入中的临时文件,不计入');
      expect(stats.reclaimableBytes, ref.byteSize);

      // 原图已缺失时不再承诺可释放空间。
      await store.fileFor(ref.hash).delete();
      stats = await store.storageStats(now: now);
      expect(stats.reclaimableBytes, 0);
    });
  });

  testWidgets('制卡草稿扫描失败时跳过回收并降级保护哈希', (tester) async {
    await tester.runAsync(() async {
      final ref = await store.putBytes(await _solidPng(8, 8));
      await db.db.update(
        'image_assets',
        {
          'created_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
        where: 'hash = ?',
        whereArgs: [ref.hash],
      );
      final drafts = CardStudioDraftFile(p.join(dir.path, 'drafts'));
      await Directory(drafts.dir).create(recursive: true);
      // 坏 JSON 仍能从文本里捞出哈希:本轮不回收,恢复草稿后仍有图。
      await File(p.join(drafts.dir, 'card-studio-draft-1.json')).writeAsString(
        '{"version":1,"payload":{"heldAssetHashes":["${ref.hash}"]',
      );

      final scan = await drafts.scanHeldAssetHashSets();
      expect(scan.hadFailures, isTrue);
      expect(scan.sets.single, contains(ref.hash));

      final logs = <String>[];
      await runImageAssetStartupMaintenance(
        store,
        logger: logs.add,
        externalReferences: drafts.scanHeldAssetHashSets,
      );

      expect(logs.any((message) => message.contains('跳过零引用回收')), isTrue);
      expect(await store.exists(ref.hash), isTrue);
    });
  });
}
