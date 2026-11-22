// ZIP STORE writer 测试:多 entry 流式往返、两类 sink、路径与大小失败语义。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/export/zip_store_writer.dart';
import 'package:microscritt/import/zip_store_reader.dart';

Iterable<List<int>> _chunks(List<int> bytes, int size) sync* {
  for (var offset = 0; offset < bytes.length; offset += size) {
    final end = offset + size > bytes.length ? bytes.length : offset + size;
    yield bytes.sublist(offset, end);
  }
}

Future<List<int>> _readEntry(ZipStoreReader reader, String name) async {
  final entry = reader.entries.singleWhere(
    (candidate) => candidate.name == name,
  );
  final output = BytesBuilder(copy: false);
  await for (final chunk in reader.openEntry(entry)) {
    output.add(chunk);
  }
  return output.takeBytes();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zip_store_writer');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('多 entry/二进制/空文件/unicode 与小 chunk 可往返', () async {
    final file = File('${tmp.path}/roundtrip.zip');
    final sink = file.openWrite();
    final writer = ZipStoreWriter(sink);
    final binary = List<int>.generate(200000, (index) => (index * 37) & 0xff);
    final meta = utf8.encode('{"version":5}');

    await writer.addBytes('meta.json', meta);
    await writer.addStream(
      'assets/图片-😀.bin',
      Stream<List<int>>.fromIterable(_chunks(binary, 313)),
      size: binary.length,
    );
    await writer.addBytes('empty.txt', const <int>[]);
    await writer.close();
    await sink.close();

    final reader = await ZipStoreReader.open(file);
    try {
      expect(reader.entries.map((entry) => entry.name), [
        'meta.json',
        'assets/图片-😀.bin',
        'empty.txt',
      ]);
      expect(reader.entries.every((entry) => entry.hasDataDescriptor), isTrue);
      expect(await _readEntry(reader, 'meta.json'), meta);
      expect(await _readEntry(reader, 'assets/图片-😀.bin'), binary);
      expect(await _readEntry(reader, 'empty.txt'), isEmpty);
    } finally {
      await reader.close();
    }
  });

  test('自定义字节 sink 接收合法归档并在完成时 flush', () async {
    final output = BytesBuilder(copy: false);
    var flushes = 0;
    final writer = ZipStoreWriter.custom(
      add: output.add,
      flush: () async => flushes++,
    );
    await writer.addBytes('a.txt', const [0, 1, 2, 255]);
    await writer.close();
    await writer.close();

    expect(flushes, 1);
    final bytes = output.takeBytes();
    expect(ByteData.sublistView(bytes).getUint32(0, Endian.little), 0x04034b50);
    final file = File('${tmp.path}/custom.zip');
    await file.writeAsBytes(bytes);
    final reader = await ZipStoreReader.open(file);
    try {
      expect(await _readEntry(reader, 'a.txt'), [0, 1, 2, 255]);
    } finally {
      await reader.close();
    }
  });

  test('危险或歧义路径在写任何 entry 前被拒绝', () async {
    final invalidNames = <String>[
      '',
      '/absolute.txt',
      r'folder\file.txt',
      '../escape.txt',
      'folder/../escape.txt',
      'folder//file.txt',
      'folder/',
      'C:/absolute.txt',
      'C:relative.txt',
      'bad\x00name',
    ];
    for (final name in invalidNames) {
      final writer = ZipStoreWriter.custom(add: (_) {});
      await expectLater(
        writer.addBytes(name, const [1]),
        throwsArgumentError,
        reason: name,
      );
      await writer.close();
    }
  });

  test('声明大小不匹配后禁止补写尾部伪装成合法包', () async {
    final writer = ZipStoreWriter.custom(add: (_) {});
    await expectLater(
      writer.addStream(
        'wrong.txt',
        Stream<List<int>>.value(const [1, 2]),
        size: 1,
      ),
      throwsFormatException,
    );
    await expectLater(writer.close(), throwsStateError);
  });

  test('Zip64 边界在读取源流前明确失败', () async {
    final writer = ZipStoreWriter.custom(add: (_) {});
    await expectLater(
      writer.addStream(
        'huge.bin',
        const Stream<List<int>>.empty(),
        size: 0xffffffff,
      ),
      throwsArgumentError,
    );
    await writer.close();
  });
}
