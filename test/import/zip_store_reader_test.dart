// ZIP STORE reader 测试:标准夹具、data descriptor、CRC/路径/方法/截断与安全限制。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/export/zip_store_writer.dart';
import 'package:microscritt/import/zip_store_reader.dart';

// Python zipfile 生成的固定 STORE 包:a.txt -> hello,不依赖测试机外部工具。
const String _standardFixture =
    'UEsDBBQAAAAAAGxZc12GphA2BQAAAAUAAAAFAAAAYS50eHRoZWxsb1BLAQIUABQAAAAAAGxZc12GphA2BQAAAAUAAAAFAAAAAAAAAAAAAACAAQAAAABhLnR4dFBLBQYAAAAAAQABADMAAAAoAAAAAAA=';

int _u16(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(List<int> bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

int _signature(List<int> bytes, int signature) {
  for (var index = 0; index <= bytes.length - 4; index++) {
    if (_u32(bytes, index) == signature) return index;
  }
  throw StateError('测试夹具缺少 ZIP signature');
}

Iterable<List<int>> _chunks(List<int> bytes) sync* {
  for (var offset = 0; offset < bytes.length; offset += 3) {
    final end = offset + 3 > bytes.length ? bytes.length : offset + 3;
    yield bytes.sublist(offset, end);
  }
}

Future<Uint8List> _writeSample(
  File file, {
  String name = 'safe.txt',
  List<int>? data,
  bool secondEntry = false,
}) async {
  final payload = data ?? utf8.encode('hello data descriptor');
  final sink = file.openWrite();
  final writer = ZipStoreWriter(sink);
  await writer.addStream(
    name,
    Stream<List<int>>.fromIterable(_chunks(payload)),
    size: payload.length,
  );
  if (secondEntry) await writer.addBytes('second.txt', const [2]);
  await writer.close();
  await sink.close();
  return file.readAsBytes();
}

Future<List<int>> _readEntry(ZipStoreReader reader, ZipStoreEntry entry) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in reader.openEntry(entry)) {
    output.add(chunk);
  }
  return output.takeBytes();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zip_store_reader');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('读取外部标准工具生成的最小固定 ZIP 夹具', () async {
    final file = File('${tmp.path}/fixture.zip');
    await file.writeAsBytes(base64Decode(_standardFixture));
    final reader = await ZipStoreReader.open(file);
    try {
      final entry = reader.entries.single;
      expect(entry.name, 'a.txt');
      expect(entry.size, 5);
      expect(entry.hasDataDescriptor, isFalse);
      expect(await _readEntry(reader, entry), ascii.encode('hello'));
    } finally {
      await reader.close();
    }
  });

  test('data descriptor 场景从 central directory 取得大小并流式校验', () async {
    final file = File('${tmp.path}/descriptor.zip');
    final expected = List<int>.generate(70000, (index) => (index * 11) & 0xff);
    await _writeSample(file, name: 'assets/二进制.bin', data: expected);

    final reader = await ZipStoreReader.open(file);
    try {
      final entry = reader.entries.single;
      expect(entry.hasDataDescriptor, isTrue);
      expect(entry.size, expected.length);
      expect(await _readEntry(reader, entry), expected);
    } finally {
      await reader.close();
    }
  });

  test('entry 数据损坏在完整读取末尾报告 CRC32 错误', () async {
    final file = File('${tmp.path}/bad-crc.zip');
    final bytes = await _writeSample(file);
    final local = _signature(bytes, 0x04034b50);
    final dataOffset =
        local + 30 + _u16(bytes, local + 26) + _u16(bytes, local + 28);
    bytes[dataOffset + 2] ^= 0xff;
    await file.writeAsBytes(bytes);

    final reader = await ZipStoreReader.open(file);
    try {
      await expectLater(
        reader.openEntry(reader.entries.single).drain<void>(),
        throwsFormatException,
      );
    } finally {
      await reader.close();
    }
  });

  test('central directory 中的路径穿越在列出 entries 前被拒绝', () async {
    final file = File('${tmp.path}/traversal.zip');
    final bytes = await _writeSample(file);
    final central = _signature(bytes, 0x02014b50);
    bytes.setRange(central + 46, central + 54, ascii.encode('../x.txt'));
    await file.writeAsBytes(bytes);

    await expectLater(ZipStoreReader.open(file), throwsFormatException);
  });

  test('非 STORE method 明确不支持', () async {
    final file = File('${tmp.path}/deflate.zip');
    final bytes = await _writeSample(file);
    final central = _signature(bytes, 0x02014b50);
    bytes[central + 10] = 8;
    bytes[central + 11] = 0;
    await file.writeAsBytes(bytes);

    await expectLater(
      ZipStoreReader.open(file),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('STORE'),
        ),
      ),
    );
  });

  test('EOCD/central directory 截断均在打开时失败', () async {
    final source = File('${tmp.path}/complete.zip');
    final bytes = await _writeSample(source);
    for (final length in <int>[0, 10, bytes.length - 23, bytes.length - 1]) {
      final file = File('${tmp.path}/truncated-$length.zip');
      await file.writeAsBytes(bytes.sublist(0, length));
      await expectLater(
        ZipStoreReader.open(file),
        throwsFormatException,
        reason: 'prefix length $length',
      );
    }
  });

  test('entry 数/文件名/总大小限制可收紧', () async {
    final file = File('${tmp.path}/limits.zip');
    await _writeSample(file, secondEntry: true);

    await expectLater(
      ZipStoreReader.open(file, maxEntries: 1),
      throwsFormatException,
    );
    await expectLater(
      ZipStoreReader.open(file, maxFileNameBytes: 4),
      throwsFormatException,
    );
    await expectLater(
      ZipStoreReader.open(file, maxTotalUncompressedBytes: 2),
      throwsFormatException,
    );
  });
}
