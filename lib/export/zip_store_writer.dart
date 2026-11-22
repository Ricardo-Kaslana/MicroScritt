/// 流式 ZIP STORE writer:逐 entry 写数据与 data descriptor,最后写 central directory。
///
/// 不实现 Zip64;单 entry、文件名与总包都受经典 ZIP 字段限制,数据块不拼成完整
/// entry。writer 只拥有输出字节的所有权,不关闭调用方提供的 sink。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _zip32Sentinel = 0xffffffff;
const int _zip16Sentinel = 0xffff;
const int _drainThreshold = 8 * 1024 * 1024;

final RegExp _drivePrefix = RegExp(r'^[A-Za-z]:');

/// 只写 STORE(method 0)的 ZIP writer,entry 必须串行添加。
///
/// [addStream] 始终使用 data descriptor,因此输入流不必可Seek。任何 entry 大小或
/// 总包达到 Zip64 边界都会失败;写出中途失败后实例不可继续完成归档。[close] 只
/// 完成 ZIP 并 flush,不关闭底层 sink。
class ZipStoreWriter {
  final void Function(List<int> bytes) _add;
  final Future<void> Function()? _flush;
  final List<_PendingEntry> _entries = <_PendingEntry>[];

  int _offset = 0;
  bool _busy = false;
  bool _closed = false;
  bool _broken = false;

  /// 写入 [IOSink];调用方在 [close] 后自行关闭 sink。
  ZipStoreWriter(IOSink sink) : this.custom(add: sink.add, flush: sink.flush);

  /// 写入自定义字节 sink。[add] 必须同步消费或复制字节,[flush] 用于背压与最终落盘。
  ZipStoreWriter.custom({
    required void Function(List<int> bytes) add,
    Future<void> Function()? flush,
  }) : _add = add,
       _flush = flush;

  /// 添加完整字节 entry;适合小文件,大文件应使用 [addStream]。
  Future<void> addBytes(String name, List<int> bytes) {
    return addStream(name, Stream<List<int>>.value(bytes), size: bytes.length);
  }

  /// 流式添加一个文件 entry;[size] 若提供会同时用于预检与实际字节数校验。
  ///
  /// 文件名按 UTF-8 编码,拒绝绝对路径、反斜杠、`..`、空段与 NUL。单 entry 必须
  /// 小于 4GiB,且达到 `0xffffffff` 的 Zip64 标记值即拒绝。源流或声明大小不匹配
  /// 时抛 [FormatException],已写输出应由调用方丢弃。
  Future<void> addStream(
    String name,
    Stream<List<int>> bytes, {
    int? size,
  }) async {
    _checkCanAdd();
    final encodedName = _encodeAndValidateName(name);
    if (size != null && (size < 0 || size >= _zip32Sentinel)) {
      throw ArgumentError.value(size, 'size', '单 entry 超出经典 ZIP 大小范围');
    }
    if (_entries.length >= _zip16Sentinel - 1) {
      throw StateError('ZIP entry 数达到 Zip64 边界');
    }

    _busy = true;
    try {
      final localOffset = _offset;
      _write(_localHeader(encodedName));
      _write(encodedName);

      final crc = _Crc32();
      var written = 0;
      var sinceDrain = 0;
      await for (final chunk in bytes) {
        if (chunk.isEmpty) continue;
        final nextSize = written + chunk.length;
        if (nextSize >= _zip32Sentinel) {
          throw StateError('单 entry 超出经典 ZIP 大小范围');
        }
        if (size != null && nextSize > size) {
          throw FormatException('entry 实际大小超过声明值:$name');
        }
        crc.add(chunk);
        _write(chunk);
        written = nextSize;
        sinceDrain += chunk.length;
        final flush = _flush;
        if (flush != null && sinceDrain >= _drainThreshold) {
          await flush();
          sinceDrain = 0;
        }
      }
      if (size != null && written != size) {
        throw FormatException('entry 实际大小与声明值不符:$name');
      }

      _write(_dataDescriptor(crc.value, written));
      _entries.add(
        _PendingEntry(
          name: encodedName,
          crc32: crc.value,
          size: written,
          localOffset: localOffset,
        ),
      );
    } catch (_) {
      _broken = true;
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// 写完 central directory 与 end record 并 flush;重复调用不会重复写尾部。
  ///
  /// 此方法不关闭底层 sink。此前 entry 写出失败时抛 [StateError],不能靠补写尾部
  /// 把半成品变成合法归档。
  Future<void> close() async {
    if (_closed) return;
    if (_busy) throw StateError('entry 仍在写入');
    if (_broken) throw StateError('ZIP 已写出失败,不能完成归档');
    _closed = true;
    try {
      final centralOffset = _offset;
      for (final entry in _entries) {
        _write(_centralHeader(entry));
        _write(entry.name);
      }
      final centralSize = _offset - centralOffset;
      _write(_endRecord(_entries.length, centralSize, centralOffset));
      final flush = _flush;
      if (flush != null) await flush();
    } catch (_) {
      _broken = true;
      rethrow;
    }
  }

  void _checkCanAdd() {
    if (_closed) throw StateError('ZIP writer 已关闭');
    if (_busy) throw StateError('ZIP entry 必须串行写入');
    if (_broken) throw StateError('ZIP 已写出失败');
  }

  void _write(List<int> bytes) {
    if (bytes.isEmpty) return;
    final nextOffset = _offset + bytes.length;
    // 留开 0xffffffff 标记值,避免任何经典字段被其他工具解释为 Zip64。
    if (nextOffset >= _zip32Sentinel) {
      throw StateError('ZIP 总包超出经典 ZIP 大小范围');
    }
    _add(bytes);
    _offset = nextOffset;
  }
}

class _PendingEntry {
  final Uint8List name;
  final int crc32;
  final int size;
  final int localOffset;

  const _PendingEntry({
    required this.name,
    required this.crc32,
    required this.size,
    required this.localOffset,
  });
}

Uint8List _encodeAndValidateName(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains('\x00') ||
      _drivePrefix.hasMatch(name)) {
    throw ArgumentError.value(name, 'name', 'ZIP 路径必须是相对文件路径');
  }
  for (final segment in name.split('/')) {
    if (segment.isEmpty || segment == '..') {
      throw ArgumentError.value(name, 'name', 'ZIP 路径含空段或 ..');
    }
  }
  final encoded = Uint8List.fromList(utf8.encode(name));
  if (encoded.length > _zip16Sentinel) {
    throw ArgumentError.value(name, 'name', 'ZIP 文件名的 UTF-8 编码过长');
  }
  return encoded;
}

Uint8List _localHeader(Uint8List name) {
  final out = Uint8List(30);
  final data = ByteData.view(out.buffer);
  data.setUint32(0, 0x04034b50, Endian.little);
  data.setUint16(4, 20, Endian.little);
  data.setUint16(6, 0x0808, Endian.little);
  data.setUint16(8, 0, Endian.little);
  data.setUint16(10, 0, Endian.little);
  data.setUint16(12, 0x0021, Endian.little);
  data.setUint16(26, name.length, Endian.little);
  return out;
}

Uint8List _dataDescriptor(int crc32, int size) {
  final out = Uint8List(16);
  final data = ByteData.view(out.buffer);
  data.setUint32(0, 0x08074b50, Endian.little);
  data.setUint32(4, crc32, Endian.little);
  data.setUint32(8, size, Endian.little);
  data.setUint32(12, size, Endian.little);
  return out;
}

Uint8List _centralHeader(_PendingEntry entry) {
  final out = Uint8List(46);
  final data = ByteData.view(out.buffer);
  data.setUint32(0, 0x02014b50, Endian.little);
  data.setUint16(4, 20, Endian.little);
  data.setUint16(6, 20, Endian.little);
  data.setUint16(8, 0x0808, Endian.little);
  data.setUint16(10, 0, Endian.little);
  data.setUint16(12, 0, Endian.little);
  data.setUint16(14, 0x0021, Endian.little);
  data.setUint32(16, entry.crc32, Endian.little);
  data.setUint32(20, entry.size, Endian.little);
  data.setUint32(24, entry.size, Endian.little);
  data.setUint16(28, entry.name.length, Endian.little);
  data.setUint32(42, entry.localOffset, Endian.little);
  return out;
}

Uint8List _endRecord(int count, int centralSize, int centralOffset) {
  final out = Uint8List(22);
  final data = ByteData.view(out.buffer);
  data.setUint32(0, 0x06054b50, Endian.little);
  data.setUint16(8, count, Endian.little);
  data.setUint16(10, count, Endian.little);
  data.setUint32(12, centralSize, Endian.little);
  data.setUint32(16, centralOffset, Endian.little);
  return out;
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
      if (byte < 0 || byte > 255) {
        throw ArgumentError.value(byte, 'bytes', '字节必须在 0..255');
      }
      crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    _state = crc;
  }
}
