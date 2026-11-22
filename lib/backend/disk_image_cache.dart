/// 远程图片字节的本地磁盘缓存与近似 LRU 淘汰。
///
/// 只缓存 URL-only 图片的字节(hash 图片走文件资产库);缓存失败
/// 一律静默降级为联网读取,不影响渲染主流程。写盘前与命中读取时都校验
/// 图片魔数,HTML/错误页不会被当成图片长期缓存;损坏缓存可经 [invalidate]
/// 删除后重新下载。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/data_root.dart';
import 'image_magic.dart';

/// 远程图片字节的本地磁盘缓存。
///
/// 目的:URL-only 的图片(旧消息 / 生成时下载失败)在对话滚动重建、Flutter 内存
/// 图片缓存逐出、重启后会被 `NetworkImage` 反复重新拉取 —— 这里把首次取到的字节
/// 写盘,之后任何一次渲染都优先读盘(本地解码,不依赖网络),彻底消除"已生成的
/// 图片反复重新加载"。已资产化的 hash 图片走 FileImage,不经过这里。
///
/// 文件名是 URL 的 **FNV-1a 64 位哈希**(16 个十六进制字符,定长)而非全长
/// base64Url 编码:带签名查询参数的长 CDN URL 经 base64Url 膨胀后轻松超过
/// Windows 260 字符路径上限,`writeAsBytes` 抛错且被静默吞掉 —— 该 URL 的
/// 磁盘缓存永远失效,每次渲染都重新联网下载(正是这个类要解决的问题)。
/// 64 位哈希对缓存场景的碰撞概率可忽略(非安全场景,仅作 key)。
///
/// 容量:单次生成 2~4MB,不设上限数月可达 GB 级 —— 写入后按
/// `LastAccessTime`(读取时刷新 mtime 模拟)做近似 LRU 淘汰,总量不超过
/// [maxTotalBytes]。目录是本应用专属缓存目录,淘汰扫描可安全覆盖其中全部文件
/// (含旧版 base64Url 长名的历史文件)。
class DiskImageCache {
  DiskImageCache._();

  /// 缓存总量上限(近似 LRU 淘汰到上限内)。static 可变以供测试调小触发淘汰。
  static int maxTotalBytes = 256 * 1024 * 1024;

  /// 读取命中后刷新 mtime 的最小间隔。LRU 只需要小时级精度 —— 旧实现每次
  /// 读都 `setLastModified`,长会话滚动回看会变成持续的磁盘元数据写。
  static const Duration _touchInterval = Duration(hours: 1);

  /// 过期临时文件的清理门槛;远大于一次下载写盘的耗时。
  static const Duration _tempMaxAge = Duration(hours: 24);

  /// 各缓存根目录的已知总字节数(缺失 = 尚未扫描)。按根目录隔离,
  /// 测试的临时目录互不影响;写入时累加,只有超限才做一次全目录扫描淘汰。
  static final Map<String, int> _totalByRoot = {};

  /// 串行化同一根目录的「记账 + 淘汰」,避免并发写入重复扫描/重复计数。
  static final Map<String, Future<void>> _accountQueue = {};

  /// 已做过一次进程内过期临时文件清扫的根目录。
  static final Set<String> _tempSweptRoots = {};

  static final Random _random = Random.secure();

  /// 测试注入缓存根目录;null 时按 [DataRoot] 解析:桌面端固定在
  /// `~/.microscritt/image_cache`,移动端用应用支持目录下的 `image_cache`。
  static Future<Directory> Function()? overrideRoot;

  static Future<Directory> _root() async {
    final o = overrideRoot;
    if (o != null) return o();
    final fixed = DataRoot.desktopDir();
    if (fixed != null) return Directory(p.join(fixed, 'image_cache'));
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}image_cache');
  }

  /// FNV-1a 64 位哈希 → 16 位十六进制定长文件名。
  /// 乘法在 Dart 有符号 64 位下自然回绕;哈希可能是负数,而 VM 上
  /// `toUnsigned(64)` 无法表示 ≥2^63 的值 —— 拆成高低 32 位各自转十六进制,
  /// 恒为 16 个字符且不带负号。
  static String _hashName(String url) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(url)) {
      h ^= b;
      h *= 0x100000001b3;
    }
    final hi = (h >>> 32) & 0xffffffff;
    final lo = h & 0xffffffff;
    return '${hi.toRadixString(16).padLeft(8, '0')}${lo.toRadixString(16).padLeft(8, '0')}.img';
  }

  static Future<File> _file(String url) async {
    final root = await _root();
    return File('${root.path}${Platform.pathSeparator}${_hashName(url)}');
  }

  /// 旧版文件名(全长 base64Url):仅为存量缓存的一次性兼容读取保留。
  static Future<File?> _legacyFile(String url) async {
    final legacy = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    // 超长文件名在 Windows 上查存在性也会抛错;直接判定不可用。
    if (legacy.length > 120) return null;
    final root = await _root();
    return File('${root.path}${Platform.pathSeparator}$legacy.img');
  }

  /// 读取某 URL 的缓存文件;未命中/出错/内容不是图片返回 null。
  ///
  /// 命中时按 [_touchInterval] 节流刷新 mtime(LRU 的"最近使用"信号);旧版
  /// 长名命中后**复制**到新名(不再把字节读进 Dart 堆,调用方可直接用
  /// `FileImage` 解码),复制成功即删除旧文件。历史版本可能缓存过 HTML 错误页,
  /// 这类文件在命中时删除,让调用方重新下载。
  static Future<File?> existingFile(String url) async {
    try {
      final f = await _file(url);
      if (await f.exists()) {
        if (!await _hasImageMagic(f)) {
          await _safeDelete(f);
          return null;
        }
        unawaited(_touchIfStale(f));
        return f;
      }
      // 存量迁移:旧版 base64Url 长名还能命中就返回,并复制到新名下。
      final legacy = await _legacyFile(url);
      if (legacy != null && await legacy.exists()) {
        if (!await _hasImageMagic(legacy)) {
          await _safeDelete(legacy);
          return null;
        }
        final root = await _root();
        if (!await root.exists()) await root.create(recursive: true);
        final target = await _file(url);
        try {
          final copied = await legacy.copy(target.path);
          unawaited(_touchIfStale(copied));
          unawaited(_safeDelete(legacy));
          return copied;
        } catch (_) {
          return legacy; // 复制失败仍返回旧文件,下次读取再试迁移。
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 读取某 URL 的缓存字节;未命中/出错返回 null。
  ///
  /// 气泡 URL 图已改用 [existingFile](FileImage 不占 Dart 堆);这里保留给
  /// 全屏查看/导出/测试等确需字节的调用方。
  static Future<Uint8List?> read(String url) async {
    try {
      final f = await existingFile(url);
      return f == null ? null : await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 删除某 URL 的缓存(含旧版长名),使解码失败的文件可以重新下载。
  static Future<void> invalidate(String url) async {
    try {
      final f = await _file(url);
      await _safeDelete(f);
      final legacy = await _legacyFile(url);
      if (legacy != null) await _safeDelete(legacy);
      final root = await _root();
      _totalByRoot.remove(root.path);
    } catch (_) {}
  }

  /// 写某 URL 的字节到盘(幂等;失败静默,不影响渲染)。
  ///
  /// 只接受可识别魔数的图片:错误页/半截 HTML 绝不被缓存成"图片"。先写
  /// 唯一临时文件再 rename(原子替换),进程被杀时不留半截文件;失败分支
  /// 删除临时文件,首次写入时顺带清扫过期 `.tmp`。
  static Future<void> write(String url, Uint8List bytes) async {
    if (bytes.isEmpty || !looksLikeImageBytes(bytes)) return;
    try {
      final root = await _root();
      if (!await root.exists()) await root.create(recursive: true);
      _sweepTempOnce(root);
      final target = await _file(url);
      final suffix = _random.nextInt(0x7fffffff).toRadixString(16);
      final tmp = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}-$suffix.tmp',
      );
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(target.path);
      } finally {
        await _safeDelete(tmp);
      }
      _accountWrite(root, bytes.length);
    } catch (_) {}
  }

  /// 清理缓存根目录里过期的写入临时文件,返回删除数量。
  static Future<int> cleanupTempFiles({
    Duration olderThan = _tempMaxAge,
    DateTime? now,
  }) async {
    if (olderThan.isNegative) {
      throw ArgumentError.value(olderThan, 'olderThan', '不能为负数');
    }
    try {
      final root = await _root();
      if (!await root.exists()) return 0;
      final cutoff = (now ?? DateTime.now()).subtract(olderThan);
      var removed = 0;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.tmp')) continue;
        try {
          if ((await entity.lastModified()).isAfter(cutoff)) continue;
          await entity.delete();
          removed++;
        } on FileSystemException {
          // 正在写的临时文件下一轮再处理。
        }
      }
      return removed;
    } catch (_) {
      return 0;
    }
  }

  static void _sweepTempOnce(Directory root) {
    if (!_tempSweptRoots.add(root.path)) return;
    unawaited(cleanupTempFiles().then<void>((_) {}, onError: (_) {}));
  }

  /// 刷新文件 mtime,作为近似 LRU 的最近使用信号。只有距上次刷新超过
  /// [_touchInterval] 才写,避免每次读取都产生一次元数据更新。
  static Future<void> _touchIfStale(File f) async {
    try {
      final stat = await f.stat();
      if (DateTime.now().difference(stat.modified) < _touchInterval) return;
      await f.setLastModified(DateTime.now());
    } catch (_) {}
  }

  static Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 读取文件头校验图片魔数;打不开/不是图片返回 false。
  static Future<bool> _hasImageMagic(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      final header = await raf.read(16);
      return looksLikeImageBytes(header);
    } catch (_) {
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// 记账本次写入;同一根目录串行执行。首次记账时扫描一次现有文件总量
  /// (扫描发生在写入之后,已包含本次文件,不再重复累加 [addedBytes])。
  /// 并发写入下首次扫描可能把稍后写入的文件也计入基数、随后再累加会轻微
  /// 高估;这只影响淘汰时机,超限时的整目录重扫会把总量校正回实测值。
  static void _accountWrite(Directory root, int addedBytes) {
    final key = root.path;
    final prev = _accountQueue[key] ?? Future<void>.value();
    final task = prev.then((_) async {
      try {
        var total = _totalByRoot[key];
        if (total == null) {
          total = await _scanTotal(root);
        } else {
          total += addedBytes;
        }
        _totalByRoot[key] = total;
        if (total > maxTotalBytes) await _pruneOverLimit(root);
      } catch (_) {
        // 记账失败不影响缓存可用性;下次写入重新扫描。
        _totalByRoot.remove(key);
      }
    });
    _accountQueue[key] = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_accountQueue[key], task)) _accountQueue.remove(key);
      }),
    );
  }

  /// 扫描目录当前总字节数(忽略写盘中的临时文件)。
  static Future<int> _scanTotal(Directory root) async {
    var total = 0;
    await for (final e in root.list()) {
      if (e is! File || e.path.endsWith('.tmp')) continue;
      try {
        total += await e.length();
      } catch (_) {}
    }
    return total;
  }

  /// 总量超限时按最久未用优先删除,直到回到 [maxTotalBytes] 内。
  /// 静默 best-effort:目录不可列出/删除失败都不影响主流程。
  static Future<void> _pruneOverLimit(Directory root) async {
    try {
      final entries = await root.list().toList();
      final files = <File>[];
      var total = 0;
      for (final e in entries) {
        if (e is! File || e.path.endsWith('.tmp')) continue;
        final len = await e.length();
        files.add(e);
        total += len;
      }
      if (total <= maxTotalBytes) {
        _totalByRoot[root.path] = total;
        return;
      }
      final stats = <File, DateTime>{};
      for (final f in files) {
        stats[f] = await f.lastModified();
      }
      final byOldest = stats.keys.toList()
        ..sort((a, b) => stats[a]!.compareTo(stats[b]!));
      for (final f in byOldest) {
        if (total <= maxTotalBytes) break;
        try {
          final len = await f.length();
          await f.delete();
          total -= len;
        } catch (_) {}
      }
      // 记账口径同步为淘汰后的实测总量,后续写入只做增量累加。
      _totalByRoot[root.path] = total;
    } catch (_) {
      // 扫描/淘汰失败:丢弃记账,下次写入重新扫描,避免沿用错误基数。
      _totalByRoot.remove(root.path);
    }
  }
}
