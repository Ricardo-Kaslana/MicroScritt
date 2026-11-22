/// 基于 RandomAccessFile 的流式 ZIP STORE reader。
///
/// 打开时解析 EOCD 与 central directory;entry 数据按块读取并校验 CRC,不拼接完整
/// entry。仅支持单磁盘、STORE、UTF-8/ASCII 文件名,不支持 Zip64、加密或压缩方法。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _zip32Sentinel = 0xffffffff;
const int _zip16Sentinel = 0xffff;
const int _maxEocdSearch = 22 + 0xffff;
const int _readChunkSize = 64 * 1024;

final RegExp _drivePrefix = RegExp(r'^[A-Za-z]:');

/// central directory 中的一个 STORE 文件元数据。
///
/// [size] 是未压缩大小;[hasDataDescriptor] 仅描述格式,读取大小始终以 central
/// directory 为准。[crc32] 在完整消费 entry 流后校验。
class ZipStoreEntry {
  final String name;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final bool hasDataDescriptor;
  final int _flags;
  final Uint8List _encodedName;
  final Object _owner;

  int get size => uncompressedSize;

  ZipStoreEntry._({
    required this.name,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.hasDataDescriptor,
    required int flags,
    required Uint8List encodedName,
    required Object owner,
  }) : _flags = flags,
       _encodedName = encodedName,
       _owner = owner;
}

/// 安全受限的 ZIP STORE reader;[open] 成功后拥有底层文件句柄。
///
/// 默认最多 10000 个 entry、1024 字节文件名和略小于 4GiB 的总未压缩数据,可在
/// [open] 调低。只支持 STORE method 0,其他方法、Zip64、多磁盘、加密及非法路径在
/// 打开时抛 [FormatException]。entry 必须逐个完整消费,最后调用 [close]。
class ZipStoreReader {
  final RandomAccessFile _file;
  final Object _owner = Object();

  /// 当前实例采用的归档安全限制。
  final int maxEntries;
  final int maxFileNameBytes;
  final int maxTotalUncompressedBytes;
  final int maxEntryUncompressedBytes;

  late List<ZipStoreEntry> _entries;
  late int _centralOffset;
  bool _closed = false;
  bool _entryActive = false;

  ZipStoreReader._(
    this._file, {
    required this.maxEntries,
    required this.maxFileNameBytes,
    required this.maxTotalUncompressedBytes,
    required this.maxEntryUncompressedBytes,
  });

  /// 已解析且通过路径、方法及大小限制的 entries;列表不可修改。
  List<ZipStoreEntry> get entries => _entries;

  /// 打开并解析 [file],成功后由 reader 拥有并关闭其 RandomAccessFile。
  ///
  /// 解析失败会关闭句柄。安全限制包含 entry 数、UTF-8 文件名长度、单 entry 与总
  /// 未压缩大小;负数大小或超过经典 ZIP 文件名上限的限制抛 [ArgumentError]。
  static Future<ZipStoreReader> open(
    File file, {
    int maxEntries = 10000,
    int maxFileNameBytes = 1024,
    int maxTotalUncompressedBytes = 0xfffffffe,
    int maxEntryUncompressedBytes = 0xfffffffe,
  }) async {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries', '必须为正数');
    }
    if (maxFileNameBytes <= 0 || maxFileNameBytes > _zip16Sentinel) {
      throw ArgumentError.value(
        maxFileNameBytes,
        'maxFileNameBytes',
        '必须在 1..65535',
      );
    }
    if (maxTotalUncompressedBytes < 0) {
      throw ArgumentError.value(
        maxTotalUncompressedBytes,
        'maxTotalUncompressedBytes',
        '不能为负数',
      );
    }
    if (maxEntryUncompressedBytes < 0) {
      throw ArgumentError.value(
        maxEntryUncompressedBytes,
        'maxEntryUncompressedBytes',
        '不能为负数',
      );
    }

    final handle = await file.open();
    final reader = ZipStoreReader._(
      handle,
      maxEntries: maxEntries,
      maxFileNameBytes: maxFileNameBytes,
      maxTotalUncompressedBytes: maxTotalUncompressedBytes,
      maxEntryUncompressedBytes: maxEntryUncompressedBytes,
    );
    try {
      await reader._readCentralDirectory();
      return reader;
    } catch (_) {
      try {
        await handle.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// 流式读取一个 entry,STORE 不解压,仅按 central directory 大小限长读取。
  ///
  /// 完整消费流时校验 CRC32;截断、local header 不一致或 CRC 错误抛
  /// [FormatException]。同一时刻只能读取一个 entry;提前取消订阅不会校验 CRC,
  /// 调用方需要 await 订阅取消完成后再打开下一个。
  Stream<List<int>> openEntry(ZipStoreEntry entry) {
    if (_closed) throw StateError('ZIP reader 已关闭');
    if (!identical(entry._owner, _owner)) {
      throw ArgumentError.value(entry, 'entry', 'entry 不属于此 reader');
    }
    return _readEntry(entry);
  }

  /// 关闭底层文件;重复调用安全。entry 流仍活跃时抛 [StateError],避免竞态关句柄。
  Future<void> close() async {
    if (_closed) return;
    if (_entryActive) throw StateError('请先完成或取消当前 entry 流');
    _closed = true;
    await _file.close();
  }

  Future<void> _readCentralDirectory() async {
    final end = await _readEndRecord();
    _centralOffset = end.centralOffset;
    if (end.entryCount > maxEntries) {
      throw FormatException('ZIP entry 数超过限制:$maxEntries');
    }

    await _file.setPosition(end.centralOffset);
    final entries = <ZipStoreEntry>[];
    var totalSize = 0;
    for (var index = 0; index < end.entryCount; index++) {
      final header = await _readExact(46);
      if (_u32(header, 0) != 0x02014b50) {
        throw const FormatException('ZIP central directory 被截断或结构无效');
      }
      final versionNeeded = _u16(header, 6);
      final flags = _u16(header, 8);
      final method = _u16(header, 10);
      final crc32 = _u32(header, 16);
      final compressedSize = _u32(header, 20);
      final uncompressedSize = _u32(header, 24);
      final nameLength = _u16(header, 28);
      final extraLength = _u16(header, 30);
      final commentLength = _u16(header, 32);
      final diskStart = _u16(header, 34);
      final localOffset = _u32(header, 42);

      if (versionNeeded > 20) {
        throw const FormatException('ZIP entry 需要不支持的版本或 Zip64');
      }
      if (diskStart != 0) throw const FormatException('不支持多磁盘 ZIP');
      if ((flags & 1) != 0) throw const FormatException('不支持加密 ZIP entry');
      if ((flags & ~0x0808) != 0) {
        throw const FormatException('ZIP entry 含不支持的 general-purpose flags');
      }
      if (method != 0) throw const FormatException('只支持 ZIP STORE method 0');
      if (compressedSize == _zip32Sentinel ||
          uncompressedSize == _zip32Sentinel ||
          localOffset == _zip32Sentinel) {
        throw const FormatException('不支持 Zip64 entry');
      }
      if (compressedSize != uncompressedSize) {
        throw const FormatException('STORE entry 的压缩与未压缩大小不一致');
      }
      if (uncompressedSize > maxEntryUncompressedBytes) {
        throw FormatException('ZIP entry 大小超过限制:$maxEntryUncompressedBytes');
      }
      totalSize += uncompressedSize;
      if (totalSize > maxTotalUncompressedBytes) {
        throw FormatException('ZIP 总未压缩大小超过限制:$maxTotalUncompressedBytes');
      }
      if (localOffset >= end.centralOffset) {
        throw const FormatException('ZIP local header 偏移无效');
      }
      if (nameLength > maxFileNameBytes) {
        throw FormatException('ZIP 文件名超过限制:$maxFileNameBytes 字节');
      }

      final encodedName = await _readExact(nameLength);
      final String name;
      try {
        name = utf8.decode(encodedName);
      } on FormatException {
        throw const FormatException('ZIP 文件名不是有效 UTF-8');
      }
      _validateName(name);
      await _file.setPosition(
        await _file.position() + extraLength + commentLength,
      );

      entries.add(
        ZipStoreEntry._(
          name: name,
          crc32: crc32,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localHeaderOffset: localOffset,
          hasDataDescriptor: (flags & 0x0008) != 0,
          flags: flags,
          encodedName: encodedName,
          owner: _owner,
        ),
      );
    }
    if (await _file.position() != end.centralOffset + end.centralSize) {
      throw const FormatException('ZIP central directory 大小不匹配');
    }
    _entries = List<ZipStoreEntry>.unmodifiable(entries);
  }

  Future<({int centralOffset, int centralSize, int entryCount, int eocdOffset})>
  _readEndRecord() async {
    final fileLength = await _file.length();
    if (fileLength < 22) throw const FormatException('ZIP 文件被截断');
    if (fileLength >= _zip32Sentinel) {
      throw const FormatException('不支持 Zip64 或超大 ZIP');
    }

    final tailLength = fileLength < _maxEocdSearch
        ? fileLength
        : _maxEocdSearch;
    await _file.setPosition(fileLength - tailLength);
    final tail = await _readExact(tailLength);
    for (var index = tail.length - 22; index >= 0; index--) {
      if (_u32(tail, index) != 0x06054b50) continue;
      final commentLength = _u16(tail, index + 20);
      if (index + 22 + commentLength != tail.length) continue;

      final disk = _u16(tail, index + 4);
      final centralDisk = _u16(tail, index + 6);
      final entriesOnDisk = _u16(tail, index + 8);
      final entryCount = _u16(tail, index + 10);
      final centralSize = _u32(tail, index + 12);
      final centralOffset = _u32(tail, index + 16);
      if (disk != 0 || centralDisk != 0 || entriesOnDisk != entryCount) {
        throw const FormatException('不支持多磁盘 ZIP');
      }
      if (entryCount == _zip16Sentinel ||
          centralSize == _zip32Sentinel ||
          centralOffset == _zip32Sentinel) {
        throw const FormatException('不支持 Zip64 end record');
      }
      final eocdOffset = fileLength - tailLength + index;
      if (centralOffset + centralSize != eocdOffset) {
        throw const FormatException('ZIP central directory 偏移或大小无效');
      }
      return (
        centralOffset: centralOffset,
        centralSize: centralSize,
        entryCount: entryCount,
        eocdOffset: eocdOffset,
      );
    }
    throw const FormatException('缺少有效的 ZIP end record');
  }

  Stream<List<int>> _readEntry(ZipStoreEntry entry) async* {
    if (_closed) throw StateError('ZIP reader 已关闭');
    if (_entryActive) throw StateError('ZIP entry 必须串行读取');
    _entryActive = true;
    try {
      await _file.setPosition(entry.localHeaderOffset);
      final header = await _readExact(30);
      if (_u32(header, 0) != 0x04034b50) {
        throw const FormatException('ZIP local header 无效');
      }
      final flags = _u16(header, 6);
      final method = _u16(header, 8);
      final localCrc = _u32(header, 14);
      final localCompressedSize = _u32(header, 18);
      final localUncompressedSize = _u32(header, 22);
      final nameLength = _u16(header, 26);
      final extraLength = _u16(header, 28);
      if (flags != entry._flags || method != 0) {
        throw const FormatException('ZIP local 与 central header 不一致');
      }
      if (nameLength != entry._encodedName.length) {
        throw const FormatException('ZIP local 文件名长度不一致');
      }
      final dataOffset =
          entry.localHeaderOffset + 30 + nameLength + extraLength;
      if (dataOffset + entry.compressedSize > _centralOffset) {
        throw const FormatException('ZIP entry 数据越界或被截断');
      }
      final localName = await _readExact(nameLength);
      for (var index = 0; index < localName.length; index++) {
        if (localName[index] != entry._encodedName[index]) {
          throw const FormatException('ZIP local 与 central 文件名不一致');
        }
      }

      if (entry.hasDataDescriptor) {
        if (!_matchesOrZero(localCrc, entry.crc32) ||
            !_matchesOrZero(localCompressedSize, entry.compressedSize) ||
            !_matchesOrZero(localUncompressedSize, entry.uncompressedSize)) {
          throw const FormatException(
            'ZIP data descriptor entry 的 local 元数据无效',
          );
        }
      } else if (localCrc != entry.crc32 ||
          localCompressedSize != entry.compressedSize ||
          localUncompressedSize != entry.uncompressedSize) {
        throw const FormatException('ZIP local 与 central 元数据不一致');
      }

      await _file.setPosition(dataOffset);
      final crc = _Crc32();
      var remaining = entry.compressedSize;
      while (remaining > 0) {
        final count = remaining < _readChunkSize ? remaining : _readChunkSize;
        final chunk = await _file.read(count);
        if (chunk.isEmpty) throw const FormatException('ZIP entry 数据被截断');
        remaining -= chunk.length;
        crc.add(chunk);
        yield chunk;
      }
      if (crc.value != entry.crc32) {
        throw FormatException('ZIP entry CRC32 不匹配:${entry.name}');
      }
    } finally {
      _entryActive = false;
    }
  }

  Future<Uint8List> _readExact(int length) async {
    final out = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final count = await _file.readInto(out, offset);
      if (count == 0) throw const FormatException('ZIP 文件被截断');
      offset += count;
    }
    return out;
  }
}

bool _matchesOrZero(int value, int expected) => value == 0 || value == expected;

int _u16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(List<int> bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

void _validateName(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains('\x00') ||
      _drivePrefix.hasMatch(name)) {
    throw FormatException('ZIP entry 路径不安全:$name');
  }
  for (final segment in name.split('/')) {
    if (segment.isEmpty || segment == '..') {
      throw FormatException('ZIP entry 路径含空段或 ..:$name');
    }
  }
}

final List<int> _crcTable = _makeCrcTable();

List<int> _makeCrcTable() {
  return List<int>.generate(256, (value) {
    var crc = value;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
    }
    return crc;
  });
}

class _Crc32 {
  int _state = 0xffffffff;

  int get value => _state ^ 0xffffffff;

  void add(List<int> bytes) {
    var crc = _state;
    for (final byte in bytes) {
      crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    _state = crc;
  }
}
