// 内容寻址图片解码:空值/坏哈希回退、合法哈希降采样 provider 与缺图头像占位。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_asset_store.dart';
import 'package:microscritt/ui/common/hash_image.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory dir;
  late AppDatabase db;
  late ImageAssetStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hash-image-test-');
    db = await openTestDb();
    store = ImageAssetStore(db.db, p.join(dir.path, 'images'));
  });

  tearDown(() async {
    await db.db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('hashImageProvider 对空值与坏哈希返回 null', () {
    expect(hashImageProvider(store, null, cacheWidth: 384), isNull);
    expect(hashImageProvider(store, '', cacheWidth: 384), isNull);
    expect(hashImageProvider(store, 'not-a-hash', cacheWidth: 384), isNull);
  });

  test('hashImageProvider 为合法哈希返回降采样 ResizeImage', () {
    final hash = 'a' * 64;
    final provider = hashImageProvider(
      store,
      hash,
      cacheWidth: kAvatarImageWidth,
    );
    expect(provider, isA<ResizeImage>());
    final resize = provider! as ResizeImage;
    expect(resize.width, kAvatarImageWidth);
    expect(resize.height, isNull);
    expect(resize.policy, ResizeImagePolicy.fit);
    expect(resize.imageProvider, isA<FileImage>());
    expect(
      (resize.imageProvider as FileImage).file.path,
      store.fileFor(hash).path,
    );
  });

  testWidgets('HashAvatar 无哈希时显示 fallback', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: HashAvatar(hash: null, radius: 16, child: Text('A')),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
  });
}
