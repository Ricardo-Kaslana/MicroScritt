/// SHA-256 内容寻址的图片文件资产库。
///
/// 原图与预览位于调用方给定的 `images` 根目录,SQLite 只保存元数据与引用计数。
/// 文件写入不进数据库事务;引用调整可加入业务事务,物理回收只发生在事务外。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/image_ref.dart';
import 'image_compressor.dart';

/// 图片资产的原子写入、查找、引用计数与延迟回收。
class ImageAssetStore {
  static const int maxOriginalBytes = 16 * 1024 * 1024;
  static const int maxPixelCount = 40 * 1000 * 1000;
  static const int maxDimension = maxImageDimension;
  static const int _validationDecodeEdge = 256;

  /// 预览命中后刷新 mtime 的最小间隔(近似 LRU 只需要小时级精度)。
  static const Duration _previewTouchInterval = Duration(hours: 1);

  /// 预览总量上限;超出后按文件年龄淘汰最旧的可重建预览。
  static const int maxPreviewBytes = 256 * 1024 * 1024;

  /// 新入库图片的长边压缩上限;0 = 关闭。由 AppSettingsRepository 水合/保存
  /// 时同步,因此生图、导入与手工选图共用同一策略。
  int compressMaxEdge = 0;

  static final RegExp _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final Random _random = Random.secure();
  static final Map<String, Future<void>> _hashLocks = {};
  static final Map<String, Future<void>> _previewTrimTails = {};

  final DatabaseExecutor _db;
  final Directory _originalDir;
  final Directory _previewDir;
  final Directory _tmpDir;
  final String _lockNamespace;

  /// 测试用来停在「元数据已认领、原图尚未删除」的竞态窗口。
  @visibleForTesting
  Future<void> Function(String hash)? debugBeforeOriginalDelete;

  /// [rootPath] 是资产根目录 `images`,不是应用数据根目录。
  ImageAssetStore(DatabaseExecutor db, String rootPath)
    : _db = db,
      _originalDir = Directory(p.join(rootPath, 'original')),
      _previewDir = Directory(p.join(rootPath, 'preview')),
      _tmpDir = Directory(p.join(rootPath, 'tmp')),
      _lockNamespace = p.absolute(p.normalize(rootPath));

  /// 校验内容寻址哈希,拒绝路径片段与大写形式。
  static bool isValidHash(String hash) => _hashPattern.hasMatch(hash);

  /// 返回原图路径;只构造路径,不创建目录或检查文件是否存在。
  File fileFor(String hash) {
    _validateHash(hash);
    return File(
      p.join(
        _originalDir.path,
        hash.substring(0, 2),
        hash.substring(2, 4),
        hash,
      ),
    );
  }

  /// 原图文件是否存在;数据库有元数据但文件缺失时同样返回 false。
  Future<bool> exists(String hash) => fileFor(hash).exists();

  /// 查找 v1/1600 预览,优先返回 JPEG,没有可用预览时返回 null。
  ///
  /// 命中时按小时级节流刷新 mtime:LRU 淘汰以修改时间为「最近使用」信号,
  /// 只看创建时间会退化成 FIFO,把仍常用的大预览先删掉。
  Future<File?> previewFileFor(String hash) async {
    _validateHash(hash);
    for (final extension in ['jpg', 'png']) {
      final file = File(
        p.join(
          _previewDir.path,
          hash.substring(0, 2),
          '$hash-v1-1600.$extension',
        ),
      );
      if (await file.exists()) {
        unawaited(_touchIfStale(file));
        return file;
      }
    }
    return null;
  }

  /// 校验并写入一份原图,返回内容寻址引用。
  ///
  /// 同一内容的并发写入共用一个最终文件与一行元数据。压缩/校验解码都限制在
  /// 小目标内,且压缩前先按文件头核验原始尺寸、像素与格式;坏图、伪装格式与
  /// 超限输入抛出 [FormatException],不会留下临时文件或元数据。数据库写入
  /// 失败时会删除本次刚 rename 的原图,避免留下孤儿文件。
  ///
  /// [compress] 默认遵循入库压缩设置;按既有哈希修复或解包归档时必须传
  /// false,否则重编码会改变内容哈希,破坏文件名/引用的一致性。
  Future<ImageRef> putBytes(Uint8List bytes, {bool compress = true}) async {
    if (bytes.isEmpty) throw const FormatException('图片字节不能为空');
    if (bytes.length > maxOriginalBytes) {
      throw const FormatException('原始图片超过 16MiB 上限');
    }
    // 压缩会整图解码:必须先只读文件头挡住边长/像素/格式,否则高压缩比
    // 「解码炸弹」会在尺寸校验之前打穿内存。
    final header = _requireValidHeader(bytes);
    final prepared = compress ? await _compressIfEnabled(bytes, header) : bytes;
    await _tmpDir.create(recursive: true);
    final tmp = File(p.join(_tmpDir.path, _uniqueTempName()));
    try {
      await tmp.writeAsBytes(prepared, flush: true);
      return await _commitValidated(
        tmp,
        prepared,
        sha256.convert(prepared).toString(),
      );
    } finally {
      await _deleteTemp(tmp);
    }
  }

  /// 流式写入一份原图,同时计算 SHA-256 与字节数,单张硬上限为 16MiB。
  ///
  /// 格式、宽高与真实解码校验与 [putBytes] 共用。只有临时文件写完后才把
  /// 这一张(至多 16MiB)读回校验;调用方可以用它逐个导入归档资产,而不让
  /// 整包或整张超上限图片驻留内存。
  Future<ImageRef> putStream(
    Stream<List<int>> bytes, {
    bool compress = true,
  }) async {
    await _tmpDir.create(recursive: true);
    final tmp = File(p.join(_tmpDir.path, _uniqueTempName()));
    final digestSink = _DigestSink();
    final hashInput = sha256.startChunkedConversion(digestSink);
    try {
      final output = tmp.openWrite();
      var size = 0;
      var sinceFlush = 0;
      try {
        await for (final chunk in bytes) {
          if (chunk.isEmpty) continue;
          size += chunk.length;
          if (size > maxOriginalBytes) {
            throw const FormatException('原始图片超过 16MiB 上限');
          }
          hashInput.add(chunk);
          output.add(chunk);
          sinceFlush += chunk.length;
          if (sinceFlush >= 1024 * 1024) {
            await output.flush();
            sinceFlush = 0;
          }
        }
        hashInput.close();
      } finally {
        await output.close();
      }
      if (size == 0) throw const FormatException('图片字节不能为空');
      final digest = digestSink.value;
      if (digest == null) throw StateError('图片 SHA-256 计算未完成');
      final stored = await tmp.readAsBytes();
      final header = _requireValidHeader(stored);
      final prepared = compress
          ? await _compressIfEnabled(stored, header)
          : stored;
      var hash = digest.toString();
      if (!identical(prepared, stored)) {
        await tmp.writeAsBytes(prepared, flush: true);
        hash = sha256.convert(prepared).toString();
      }
      return await _commitValidated(tmp, prepared, hash);
    } finally {
      await _deleteTemp(tmp);
    }
  }

  /// 按当前设置压缩入库图片;关闭、GIF/动图或压缩失败时保留原始字节。
  /// [header] 是调用方已校验过的原始字节文件头,避免重复解析。
  Future<Uint8List> _compressIfEnabled(
    Uint8List bytes,
    ImageHeader header,
  ) async {
    final maxEdge = compressMaxEdge;
    if (maxEdge <= 0) return bytes;
    if (header.mime == 'image/gif' || header.animated) return bytes;
    try {
      return await compressImageForStorage(bytes, maxEdge: maxEdge) ?? bytes;
    } catch (_) {
      // 压缩是优化而非正确性前提:隔离区失败时继续用原图。
      return bytes;
    }
  }

  Future<ImageRef> _commitValidated(
    File tmp,
    Uint8List bytes,
    String hash,
  ) async {
    final header = _requireValidHeader(bytes);
    final ref = ImageRef(
      hash: hash,
      byteSize: bytes.length,
      mime: header.mime,
      width: header.width,
      height: header.height,
    );
    await _validateDecodable(bytes, header.width, header.height);

    return _withHashLock(ref.hash, () async {
      final target = fileFor(ref.hash);
      await target.parent.create(recursive: true);
      var moved = false;
      if (!await target.exists()) {
        try {
          await tmp.rename(target.path);
          moved = true;
        } on FileSystemException {
          // Windows 不允许 rename 覆盖;并发同内容已落位时保留先到的一份。
          if (!await target.exists()) rethrow;
        }
      }
      try {
        await _db.insert('image_assets', {
          'hash': ref.hash,
          'byte_size': ref.byteSize,
          'mime': ref.mime,
          'width': ref.width,
          'height': ref.height,
          'ref_count': 0,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      } catch (_) {
        // 元数据插入失败时,本次 rename 落位的原图没有对应行,立即删除,
        // 避免留下只能靠孤儿清扫兜底的垃圾文件。
        if (moved) {
          try {
            await target.delete();
          } catch (_) {}
        }
        rethrow;
      }
      return ref;
    });
  }

  /// 只读文件头校验格式、边长与像素总量;非法输入抛 [FormatException]。
  static ImageHeader _requireValidHeader(Uint8List bytes) {
    final header = readImageHeader(bytes);
    if (header == null) {
      throw const FormatException('仅接受有效的 PNG/JPEG/WebP/GIF 图片头');
    }
    if (header.width <= 0 || header.height <= 0) {
      throw const FormatException('图片宽高必须为正数');
    }
    if (header.width > maxDimension || header.height > maxDimension) {
      throw const FormatException('图片边长超过 8192px 上限');
    }
    if (header.width * header.height > maxPixelCount) {
      throw const FormatException('图片像素总量超过 40MP 上限');
    }
    return header;
  }

  static Future<void> _deleteTemp(File tmp) async {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {
      // 保留原始写入/校验异常;遗留 .part 由启动清理负责。
    }
  }

  /// 在业务事务使用的 [executor] 上增加一个引用。
  ///
  /// 元数据不存在时抛出 [StateError],避免业务行提交后指向无资产哈希。
  Future<void> acquire(DatabaseExecutor executor, String hash) async {
    _validateHash(hash);
    final changed = await executor.rawUpdate(
      'UPDATE image_assets SET ref_count = ref_count + 1 WHERE hash = ?',
      [hash],
    );
    if (changed == 0) throw StateError('图片资产不存在: $hash');
  }

  /// 在业务事务使用的 [executor] 上释放一个引用,不物理删除文件。
  ///
  /// 重复释放与未知哈希均为无操作,引用计数不会降为负数。
  Future<void> release(DatabaseExecutor executor, String hash) async {
    _validateHash(hash);
    await executor.rawUpdate(
      'UPDATE image_assets SET ref_count = ref_count - 1 '
      'WHERE hash = ? AND ref_count > 0',
      [hash],
    );
  }

  /// 按真实业务引用重算 [image_assets] 的引用计数,并返回修正结果。
  ///
  /// 真实引用来自 `messages.image_hash`、`characters.avatar_hash`、
  /// `characters.background_hash`、`user_profile.avatar_hash`,每行各计一次;
  /// [externalReferences] 中每个集合代表一个外部持有方(如单份制卡草稿),
  /// 集合内每个哈希计一次,多份草稿各自累加。空值/非法哈希忽略。
  ///
  /// 计数直接写成期望值(包括把陈旧计数归零);有引用但缺元数据只记录
  /// warning,不凭空建行。所有写入在同一事务内完成。
  Future<ImageAssetReferenceReconcileResult> reconcileReferences({
    Iterable<Set<String>> externalReferences = const [],
    void Function(String message)? logger,
  }) {
    void log(String message) {
      if (logger != null) {
        logger(message);
      } else {
        debugPrint(message);
      }
    }

    final externalSets = externalReferences.toList(growable: false);
    Future<ImageAssetReferenceReconcileResult> reconcile(
      DatabaseExecutor executor,
    ) async {
      final expected = <String, int>{};
      void count(String? hash) {
        if (hash == null || hash.isEmpty || !isValidHash(hash)) return;
        expected[hash] = (expected[hash] ?? 0) + 1;
      }

      for (final row in await executor.rawQuery(
        'SELECT image_hash AS hash FROM messages '
        'WHERE image_hash IS NOT NULL',
      )) {
        count(row['hash'] as String?);
      }
      for (final row in await executor.rawQuery(
        'SELECT avatar_hash AS hash FROM characters '
        'WHERE avatar_hash IS NOT NULL '
        'UNION ALL '
        'SELECT background_hash AS hash FROM characters '
        'WHERE background_hash IS NOT NULL',
      )) {
        count(row['hash'] as String?);
      }
      for (final row in await executor.rawQuery(
        'SELECT avatar_hash AS hash FROM user_profile '
        'WHERE avatar_hash IS NOT NULL',
      )) {
        count(row['hash'] as String?);
      }
      for (final set in externalSets) {
        for (final hash in set) {
          count(hash);
        }
      }

      final rows = await executor.query(
        'image_assets',
        columns: ['hash', 'ref_count'],
      );
      final existing = <String, int>{
        for (final row in rows)
          row['hash'] as String: row['ref_count'] as int? ?? 0,
      };
      var missing = 0;
      for (final entry in expected.entries) {
        if (existing.containsKey(entry.key)) continue;
        missing++;
        log('图片引用缺少元数据(已跳过):${entry.key} 被引用 ${entry.value} 次');
      }
      var updated = 0;
      for (final entry in existing.entries) {
        final desired = expected[entry.key] ?? 0;
        if (entry.value == desired) continue;
        await executor.update(
          'image_assets',
          {'ref_count': desired},
          where: 'hash = ?',
          whereArgs: [entry.key],
        );
        updated++;
      }
      return ImageAssetReferenceReconcileResult(
        updatedAssets: updated,
        missingAssets: missing,
      );
    }

    final db = _db;
    return db is Database ? db.transaction(reconcile) : reconcile(db);
  }

  /// 回收已过宽限期的零引用资产,返回删除的元数据行数。
  ///
  /// 原图/预览删除与同哈希 put 共用进程内串行区,杜绝重新落库后旧回收任务
  /// 继续删文件。删除顺序是**先文件、后元数据**:文件删不掉(被占用)时保留
  /// 元数据,下一轮继续;单个 hash 失败不中断整轮。acquire 仍靠最终条件
  /// DELETE 与数据库事务串行化:先于认领提交则回收跳过,晚于认领则明确失败,
  /// 不会留下新引用。
  Future<int> deleteIfUnreferenced({
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? now,
  }) async {
    if (gracePeriod.isNegative) {
      throw ArgumentError.value(gracePeriod, 'gracePeriod', '不能为负数');
    }
    final cutoff = (now ?? DateTime.now())
        .subtract(gracePeriod)
        .millisecondsSinceEpoch;
    final rows = await _db.query(
      'image_assets',
      columns: ['hash'],
      where: 'ref_count = 0 AND created_at <= ?',
      whereArgs: [cutoff],
    );
    var reclaimed = 0;
    for (final row in rows) {
      final hash = row['hash'] as String;
      try {
        await _withHashLock(hash, () async {
          // 初始查询到拿锁之间可能被 acquire,删文件前再确认一次条件。
          final eligible = await _db.query(
            'image_assets',
            columns: ['hash'],
            where: 'hash = ? AND ref_count = 0 AND created_at <= ?',
            whereArgs: [hash, cutoff],
            limit: 1,
          );
          if (eligible.isEmpty) return;
          final beforeDelete = debugBeforeOriginalDelete;
          if (beforeDelete != null) await beforeDelete(hash);
          // 先删文件、后删元数据:文件删不掉(被占用)时保留元数据行,
          // 下一轮维护还会继续尝试,不会变成「数据库说没有、磁盘上还在」。
          final original = fileFor(hash);
          if (await original.exists()) {
            try {
              await original.delete();
            } on FileSystemException {
              if (await original.exists()) rethrow;
            }
          }
          // 预览是可重建缓存,删除失败不阻止原图回收(孤儿预览由裁剪/清理兜底)。
          await _deletePreviews(hash);
          final deleted = await _db.delete(
            'image_assets',
            where: 'hash = ? AND ref_count = 0 AND created_at <= ?',
            whereArgs: [hash, cutoff],
          );
          if (deleted > 0) reclaimed++;
        });
      } on FileSystemException {
        // 单个文件失败不中断整轮回收;元数据仍在,下一轮继续。
      }
    }
    return reclaimed;
  }

  /// 清扫无元数据行的原图文件(rename 后插库失败等历史遗留),返回删除数。
  ///
  /// 只处理目录内文件名正好是 64 位小写 SHA-256 的文件;[olderThan] 年龄
  /// 门槛保证正在 rename/写库中的新文件不会被误删。
  Future<int> cleanupOrphanOriginals({
    Duration olderThan = const Duration(hours: 24),
    DateTime? now,
  }) async {
    if (olderThan.isNegative) {
      throw ArgumentError.value(olderThan, 'olderThan', '不能为负数');
    }
    if (!await _originalDir.exists()) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(olderThan);
    final known = <String>{
      for (final row in await _db.query('image_assets', columns: ['hash']))
        if (row['hash'] is String) row['hash'] as String,
    };
    var removed = 0;
    await for (final entity in _originalDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!isValidHash(name) || known.contains(name)) continue;
      try {
        if ((await entity.lastModified()).isAfter(cutoff)) continue;
        await entity.delete();
        removed++;
      } on FileSystemException {
        // 并行写入/已删除的文件下一轮再看。
      }
    }
    return removed;
  }

  /// 清理资产临时目录中的 `.part` 文件,返回删除数量。
  ///
  /// 默认只清理 24 小时前的文件,避免误删仍在写入的临时文件;传
  /// `olderThan: Duration.zero` 可强制清理。单个文件失败不影响其余文件。
  Future<int> cleanupTempFiles({
    Duration olderThan = const Duration(hours: 24),
    DateTime? now,
  }) async {
    if (olderThan.isNegative) {
      throw ArgumentError.value(olderThan, 'olderThan', '不能为负数');
    }
    if (!await _tmpDir.exists()) return 0;
    final cutoff = (now ?? DateTime.now()).subtract(olderThan);
    var removed = 0;
    await for (final entity in _tmpDir.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path) != '.part') continue;
      try {
        if ((await entity.lastModified()).isAfter(cutoff)) continue;
        await entity.delete();
        removed++;
      } on FileSystemException {
        // 文件可能正被另一个写入方关闭或已清理,下一轮维护再处理。
      }
    }
    return removed;
  }

  /// 预览总量超过 [maxBytes] 时,按文件修改时间从旧到新淘汰可重建预览。
  ///
  /// 只扫描 `preview` 目录,跳过写入中的 `*.part`,绝不触碰原图与 tmp。
  /// 多次调用在进程内通过 future 链串行执行;单个文件删除失败跳过并继续,
  /// 前一次失败也不会让后续排队任务失效。返回删除的文件数。
  Future<int> trimPreviews({int maxBytes = maxPreviewBytes, DateTime? now}) {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', '不能为负数');
    }
    final previous = _previewTrimTails[_lockNamespace];
    final gate = Completer<void>();
    _previewTrimTails[_lockNamespace] = gate.future;
    final task = (previous ?? Future<void>.value()).then(
      (_) => _trimPreviewsNow(maxBytes: maxBytes),
    );
    unawaited(
      task.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        gate.complete();
        if (identical(_previewTrimTails[_lockNamespace], gate.future)) {
          _previewTrimTails.remove(_lockNamespace);
        }
      }),
    );
    return task;
  }

  Future<int> _trimPreviewsNow({required int maxBytes}) async {
    if (!await _previewDir.exists()) return 0;
    final entries = <({File file, DateTime modified, int size})>[];
    var total = 0;
    await for (final entity in _previewDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (p.extension(entity.path) == '.part') continue;
      try {
        final stat = await entity.stat();
        total += stat.size;
        entries.add((file: entity, modified: stat.modified, size: stat.size));
      } on FileSystemException {
        // 并发写入/清理中的文件不参与本轮计量。
      }
    }
    if (total <= maxBytes) return 0;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    var removed = 0;
    for (final entry in entries) {
      if (total <= maxBytes) break;
      try {
        await entry.file.delete();
        total -= entry.size;
        removed++;
      } on FileSystemException {
        // 文件正被读取或已被其他任务删除,下一轮维护再处理。
      }
    }
    return removed;
  }

  /// 统计数据库、原图、预览与到期零引用资产;不存在的目录/数据库按 0 字节计。
  ///
  /// 原图与预览取文件实测值(预览跳过写入中的 `.part`),待回收只累加仍然
  /// 实际存在的原图文件大小 —— 文件已缺失的行承诺不了任何可释放空间;
  /// [now] 与宽限期和回收 API 使用同一口径,内存数据库没有可统计的主文件。
  Future<ImageAssetStorageStats> storageStats({
    String? databasePath,
    Duration gracePeriod = const Duration(hours: 24),
    DateTime? now,
  }) async {
    if (gracePeriod.isNegative) {
      throw ArgumentError.value(gracePeriod, 'gracePeriod', '不能为负数');
    }
    final cutoff = (now ?? DateTime.now())
        .subtract(gracePeriod)
        .millisecondsSinceEpoch;
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS asset_count FROM image_assets',
    );
    final reclaimableRows = await _db.query(
      'image_assets',
      columns: ['hash'],
      where: 'ref_count = 0 AND created_at <= ?',
      whereArgs: [cutoff],
    );
    var reclaimableBytes = 0;
    for (final row in reclaimableRows) {
      final hash = row['hash'];
      if (hash is! String || !isValidHash(hash)) continue;
      try {
        final file = fileFor(hash);
        if (await file.exists()) reclaimableBytes += await file.length();
      } on FileSystemException {
        // 并发删除/统计失败的文件不计入可回收空间。
      }
    }
    var databaseBytes = 0;
    if (databasePath != null && databasePath != inMemoryDatabasePath) {
      try {
        final file = File(databasePath);
        if (await file.exists()) databaseBytes = await file.length();
      } on FileSystemException {
        // 单项统计失败不掩盖仍然可用的图片统计。
      }
    }
    return ImageAssetStorageStats(
      databaseBytes: databaseBytes,
      originalBytes: await _directoryBytes(_originalDir),
      assetCount: rows.single['asset_count'] as int? ?? 0,
      reclaimableBytes: reclaimableBytes,
      previewBytes: await _directoryBytes(_previewDir, skipPart: true),
    );
  }

  /// 按会话统计消息图片的去重资产数、图片消息数与原始字节合计。
  ///
  /// 同一图片在同一会话内被多条消息引用只计一次;跨会话重复引用会在每个
  /// 会话各计一次。只统计 `messages.image_hash`,不含角色头像/背景。结果按
  /// 占用字节从大到小排序,最多返回 [limit] 个会话;缺元数据的引用计 0 字节
  /// 但不会被丢弃。
  Future<List<SessionImageUsage>> sessionImageUsage({int limit = 50}) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', '必须为正数');
    }
    final rows = await _db.rawQuery(
      'SELECT u.session_id AS session_id, '
      "COALESCE(s.title, '') AS title, "
      'COUNT(*) AS asset_count, '
      'SUM(u.message_count) AS message_count, '
      'COALESCE(SUM(a.byte_size), 0) AS bytes '
      'FROM ('
      'SELECT session_id, image_hash, COUNT(*) AS message_count '
      'FROM messages WHERE image_hash IS NOT NULL '
      'GROUP BY session_id, image_hash'
      ') u '
      'JOIN sessions s ON s.id = u.session_id '
      'LEFT JOIN image_assets a ON a.hash = u.image_hash '
      'GROUP BY u.session_id '
      'ORDER BY bytes DESC, asset_count DESC, u.session_id ASC '
      'LIMIT ?',
      [limit],
    );
    return [
      for (final row in rows)
        SessionImageUsage(
          sessionId: row['session_id'] as int,
          title: row['title'] as String? ?? '',
          assetCount: row['asset_count'] as int? ?? 0,
          messageCount: row['message_count'] as int? ?? 0,
          bytes: row['bytes'] as int? ?? 0,
        ),
    ];
  }

  /// 回收到期零引用资产、清理 tmp 和全部预览,最后在事务外 VACUUM。
  Future<ImageAssetMaintenanceResult> organizeStorage({
    Duration gracePeriod = const Duration(hours: 24),
    Duration tempOlderThan = const Duration(hours: 24),
    DateTime? now,
  }) async {
    final reclaimed = await deleteIfUnreferenced(
      gracePeriod: gracePeriod,
      now: now,
    );
    final tempFiles = await cleanupTempFiles(
      olderThan: tempOlderThan,
      now: now,
    );
    final previews = await cleanupPreviews();
    // 兜底清扫历史遗留的无元数据原图;年龄门槛与临时文件清理一致。
    final orphans = await cleanupOrphanOriginals(
      olderThan: tempOlderThan,
      now: now,
    );
    await vacuumDatabase();
    return ImageAssetMaintenanceResult(
      reclaimedAssets: reclaimed,
      removedTempFiles: tempFiles,
      removedPreviews: previews,
      removedOrphanOriginals: orphans,
    );
  }

  /// 删除全部可重建预览,保留所有原图与业务引用,返回删除的文件数。
  ///
  /// 跳过仍在写入的 `.part`;单个文件删除失败只跳过,不影响其余文件。
  Future<int> cleanupPreviews() async {
    if (!await _previewDir.exists()) return 0;
    var removed = 0;
    await for (final entity in _previewDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (p.extension(entity.path) == '.part') continue;
      try {
        await entity.delete();
        removed++;
      } on FileSystemException {
        // 文件正被读取或已被其他任务删除,下一轮维护再处理。
      }
    }
    return removed;
  }

  /// 整理 SQLite 空闲页;调用方必须在没有活动数据库事务时执行。
  Future<void> vacuumDatabase() => _db.execute('VACUUM');

  static Future<int> _directoryBytes(
    Directory dir, {
    bool skipPart = false,
  }) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (skipPart && p.extension(entity.path) == '.part') continue;
      try {
        total += await entity.length();
      } on FileSystemException {
        // 并发清理的文件由下轮统计重新计量。
      }
    }
    return total;
  }

  Future<void> _deletePreviews(String hash) async {
    final dir = Directory(p.join(_previewDir.path, hash.substring(0, 2)));
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('$hash-v') ||
          !(name.endsWith('.jpg') || name.endsWith('.png'))) {
        continue;
      }
      try {
        await entity.delete();
      } on FileSystemException {
        // 预览可重建,删除失败交给总量裁剪/预览清理兜底。
      }
    }
  }

  /// 命中预览时按 [_previewTouchInterval] 节流刷新 mtime,近似 LRU 的最近使用信号。
  static Future<void> _touchIfStale(File file) async {
    try {
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) < _previewTouchInterval) {
        return;
      }
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // 只影响淘汰顺序,失败静默。
    }
  }

  Future<T> _withHashLock<T>(String hash, Future<T> Function() action) async {
    final key = '$_lockNamespace:$hash';
    final previous = _hashLocks[key];
    final gate = Completer<void>();
    _hashLocks[key] = gate.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      gate.complete();
      if (identical(_hashLocks[key], gate.future)) _hashLocks.remove(key);
    }
  }

  static String _uniqueTempName() {
    final suffix = List.generate(
      4,
      (_) => _random.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '${DateTime.now().microsecondsSinceEpoch}-$suffix.part';
  }

  static void _validateHash(String hash) {
    if (!isValidHash(hash)) {
      throw ArgumentError.value(hash, 'hash', '必须是 64 位小写 SHA-256');
    }
  }

  static Future<void> _validateDecodable(
    Uint8List bytes,
    int width,
    int height,
  ) => runImageDecodeTask(() async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      // 只解码到 256 目标内;目标尺寸由文件头算得,小图不放大。
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: width > _validationDecodeEdge
            ? _validationDecodeEdge
            : width,
        targetHeight: height > _validationDecodeEdge
            ? _validationDecodeEdge
            : height,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      if (image.width <= 0 || image.height <= 0) {
        throw const FormatException('图片解码后尺寸无效');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('图片损坏或当前平台无法解码');
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  });
}

/// 图片资产与数据库主文件的磁盘占用快照。
class ImageAssetStorageStats {
  final int databaseBytes;
  final int originalBytes;
  final int assetCount;
  final int reclaimableBytes;
  final int previewBytes;

  const ImageAssetStorageStats({
    required this.databaseBytes,
    required this.originalBytes,
    required this.assetCount,
    required this.reclaimableBytes,
    required this.previewBytes,
  });
}

/// 单个会话的消息图片构成。
///
/// [bytes] 是该会话引用到的去重资产原始字节合计;同一图片跨会话重复引用会在
/// 每个会话分别计入。
class SessionImageUsage {
  final int sessionId;
  final String title;
  final int assetCount;
  final int messageCount;
  final int bytes;

  const SessionImageUsage({
    required this.sessionId,
    required this.title,
    required this.assetCount,
    required this.messageCount,
    required this.bytes,
  });
}

/// 一次引用对账的结果。
class ImageAssetReferenceReconcileResult {
  /// 引用计数被改写的元数据行数。
  final int updatedAssets;

  /// 存在真实引用但缺少 `image_assets` 行的哈希数量(只警告,不建行)。
  final int missingAssets;

  const ImageAssetReferenceReconcileResult({
    required this.updatedAssets,
    required this.missingAssets,
  });
}

/// 一次手动存储整理完成的各项删除数量。
class ImageAssetMaintenanceResult {
  final int reclaimedAssets;
  final int removedTempFiles;
  final int removedPreviews;

  /// 清扫掉的无元数据孤儿原图数量。
  final int removedOrphanOriginals;

  const ImageAssetMaintenanceResult({
    required this.reclaimedAssets,
    required this.removedTempFiles,
    required this.removedPreviews,
    this.removedOrphanOriginals = 0,
  });
}

/// 外部持有方(制卡草稿等)的资产扫描结果。
///
/// [complete] 为 false 表示扫描中有文件读取/解析失败,无法确认哪些哈希仍被
/// 草稿持有;启动维护据此跳过零引用回收,宁可少清一轮,也不能删掉恢复后
/// 还要用的图片。
class ImageAssetExternalReferences {
  final List<Set<String>> sets;
  final bool complete;

  const ImageAssetExternalReferences(this.sets, {this.complete = true});
}

/// 启动后异步对账引用、清理 tmp 与预览、回收到期零引用资产;失败只记录日志。
///
/// [externalReferences] 返回进程外持有方(制卡草稿等)的扫描结果,每份草稿
/// 一个哈希集合;`complete=false` 表示扫描部分失败、结果不可信。传入时先按
/// 真实业务表 + 外部集合重算引用计数,再执行文件侧维护。未传入时保留旧行为,
/// 不重算计数(避免把未知外部持有方归零)。各步骤分别捕获异常,前一项失败
/// 不会阻断后一项,调用方无需 await。
/// 外部持有方扫描/引用对账失败或扫描报告文件失败时本轮**跳过零引用回收**
/// —— 在无法确认草稿持有时删除原图,恢复后的草稿会永久缺图。孤儿清扫只删
/// 没有元数据行的文件,不受此限制(有元数据的草稿资产不会被它碰到)。
Future<void> runImageAssetStartupMaintenance(
  ImageAssetStore store, {
  void Function(String message)? logger,
  Future<ImageAssetExternalReferences> Function()? externalReferences,
  int previewMaxBytes = ImageAssetStore.maxPreviewBytes,
}) async {
  void log(String message) {
    if (logger != null) {
      logger(message);
    } else {
      debugPrint(message);
    }
  }

  var reclaimSafe = true;
  if (externalReferences != null) {
    try {
      final result = await externalReferences();
      if (!result.complete) {
        reclaimSafe = false;
        log('制卡草稿扫描存在失败文件,本轮跳过零引用回收(已忽略)');
      }
      await store.reconcileReferences(
        externalReferences: result.sets,
        logger: logger,
      );
    } catch (e) {
      reclaimSafe = false;
      log('启动图片引用对账失败,本轮跳过回收(已忽略):$e');
    }
  }
  try {
    await store.cleanupTempFiles();
  } catch (e) {
    log('启动图片临时文件清理失败(已忽略):$e');
  }
  try {
    await store.trimPreviews(maxBytes: previewMaxBytes);
  } catch (e) {
    log('启动图片预览裁剪失败(已忽略):$e');
  }
  if (reclaimSafe) {
    try {
      await store.deleteIfUnreferenced();
    } catch (e) {
      log('启动零引用图片回收失败(已忽略):$e');
    }
  }
  try {
    await store.cleanupOrphanOriginals();
  } catch (e) {
    log('启动孤儿原图清扫失败(已忽略):$e');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
