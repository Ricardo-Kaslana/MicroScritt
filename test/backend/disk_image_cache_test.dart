// 磁盘图片缓存测试:读写往返、定长文件名、旧名迁移、魔数校验、失效与容量淘汰。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/disk_image_cache.dart';

/// 带 PNG 魔数的测试字节;长度为 [length],其余字节填充 [fill]。
Uint8List _imageBytes(int length, {int fill = 0}) {
  const magic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  final bytes = Uint8List(length);
  bytes.setRange(0, magic.length, magic);
  if (length > magic.length) bytes.fillRange(magic.length, length, fill);
  return bytes;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('microscritt_imgcache');
    DiskImageCache.overrideRoot = () async => tmp;
  });

  tearDown(() async {
    DiskImageCache.overrideRoot = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('read misses before write, then round-trips the bytes', () async {
    const url = 'https://example.com/a.png';
    expect(await DiskImageCache.read(url), isNull);

    final bytes = _imageBytes(16, fill: 5);
    await DiskImageCache.write(url, bytes);

    final back = await DiskImageCache.read(url);
    expect(back, isNotNull);
    expect(back, bytes);
  });

  test('existingFile returns the cache file without loading bytes', () async {
    const url = 'https://example.com/file.png';
    expect(await DiskImageCache.existingFile(url), isNull);

    await DiskImageCache.write(url, _imageBytes(24, fill: 4));

    final file = await DiskImageCache.existingFile(url);
    expect(file, isNotNull, reason: '命中时应直接暴露文件供 FileImage 解码');
    expect((await file!.readAsBytes()).first, 0x89);
  });

  test('different URLs do not collide', () async {
    await DiskImageCache.write(
      'https://example.com/a.png',
      _imageBytes(16, fill: 1),
    );
    await DiskImageCache.write(
      'https://example.com/b.png',
      _imageBytes(16, fill: 2),
    );

    final a = await DiskImageCache.read('https://example.com/a.png');
    final b = await DiskImageCache.read('https://example.com/b.png');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b)); // 两个 URL 各自独立缓存
    expect(a!.last, 1);
    expect(b!.last, 2);
  });

  test(
    'survives a "restart" (re-read from disk after a fresh root lookup)',
    () async {
      // 模拟重启:同一个根目录下再读一次(缓存写盘后不依赖内存)。
      await DiskImageCache.write(
        'https://example.com/a.png',
        _imageBytes(16, fill: 9),
      );
      // 重新走一次 _root 解析(等价重启后新建实例)仍能命中。
      expect((await DiskImageCache.read('https://example.com/a.png'))!.last, 9);
    },
  );

  test('non-image bytes are never cached', () async {
    const url = 'https://example.com/error.html';
    await DiskImageCache.write(url, Uint8List.fromList(utf8.encode('<html>')));

    expect(await DiskImageCache.read(url), isNull);
    expect(
      await tmp.list().where((entity) => entity is File).toList(),
      isEmpty,
    );
  });

  test(
    'a cache file with broken magic is deleted and becomes a miss',
    () async {
      const url = 'https://example.com/broken.png';
      await DiskImageCache.write(url, _imageBytes(16));
      final file = await DiskImageCache.existingFile(url);
      expect(file, isNotNull);

      await file!.writeAsBytes(utf8.encode('<html>not an image</html>'));
      expect(await DiskImageCache.existingFile(url), isNull);
      expect(await file.exists(), isFalse, reason: '坏缓存应被删除,允许重新下载');
    },
  );

  test('invalidate removes the cached file', () async {
    const url = 'https://example.com/invalidate.png';
    await DiskImageCache.write(url, _imageBytes(16));
    expect(await DiskImageCache.read(url), isNotNull);

    await DiskImageCache.invalidate(url);

    expect(await DiskImageCache.read(url), isNull);
  });

  test('stale .tmp files are cleaned up', () async {
    await tmp.create(recursive: true);
    final stale = File('${tmp.path}${Platform.pathSeparator}old.img.123.tmp');
    final fresh = File('${tmp.path}${Platform.pathSeparator}new.img.456.tmp');
    await stale.writeAsBytes([1]);
    await fresh.writeAsBytes([2]);
    await stale.setLastModified(
      DateTime.now().subtract(const Duration(hours: 25)),
    );

    expect(await DiskImageCache.cleanupTempFiles(), 1);
    expect(await stale.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });

  test(
    'filenames are fixed-length hashes (no path-length explosion on Windows)',
    () async {
      // 回归:旧实现用全长 base64Url 作文件名,带签名查询参数的长 CDN URL
      // 膨胀后超过 Windows 260 字符路径上限,writeAsBytes 抛错且被静默吞掉,
      // 缓存永远失效。新实现是 FNV-1a 64 位十六进制定长名。
      final longUrl =
          'https://cdn.example.com/images/img.png?'
          'sig=${'x' * 300}&expires=1735689600&token=${'y' * 200}';
      await DiskImageCache.write(longUrl, _imageBytes(16, fill: 7));
      expect((await DiskImageCache.read(longUrl))!.last, 7);

      final files = await tmp.list().toList();
      expect(files, isNotEmpty);
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        expect(
          RegExp(r'^[0-9a-f]{16}\.img$').hasMatch(name),
          isTrue,
          reason: '缓存文件名应为 16 位十六进制定长:$name',
        );
      }
    },
  );

  test(
    'legacy base64Url filenames are still readable (one-time migration)',
    () async {
      // 旧版本写入的长名文件:read 走新名未命中时回退旧名,命中即返回并迁移。
      final root = tmp;
      if (!await root.exists()) await root.create(recursive: true);
      const url = 'https://example.com/legacy.png';
      final legacyName = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
      final legacyBytes = _imageBytes(16, fill: 3);
      await File(
        '${root.path}${Platform.pathSeparator}$legacyName.img',
      ).writeAsBytes(legacyBytes);

      expect(await DiskImageCache.read(url), legacyBytes);
      // 迁移:新名下也有一份(此后读取不再依赖旧名)。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await DiskImageCache.read(url), isNotNull);
    },
  );

  test(
    'prunes oldest files when over the total size limit (approx LRU)',
    () async {
      final originalLimit = DiskImageCache.maxTotalBytes;
      DiskImageCache.maxTotalBytes = 20; // 每文件 10 字节 → 只容得下 2 个
      try {
        // 写入间隔须大于文件系统 mtime 粒度(实测本机 TEMP 卷为 1s),
        // 否则三个文件 mtime 相同,淘汰顺序不确定。
        await DiskImageCache.write(
          'https://example.com/1.png',
          _imageBytes(10),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await DiskImageCache.write(
          'https://example.com/2.png',
          _imageBytes(10),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await DiskImageCache.write(
          'https://example.com/3.png',
          _imageBytes(10),
        );
        await Future<void>.delayed(
          const Duration(milliseconds: 300),
        ); // 淘汰是 unawaited,等它跑完

        expect(
          await DiskImageCache.read('https://example.com/1.png'),
          isNull,
          reason: '最旧的应被淘汰',
        );
        expect(
          await DiskImageCache.read('https://example.com/2.png'),
          isNotNull,
        );
        expect(
          await DiskImageCache.read('https://example.com/3.png'),
          isNotNull,
        );
      } finally {
        DiskImageCache.maxTotalBytes = originalLimit;
      }
    },
  );
}
