import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/import/png_chunk_reader.dart';

Uint8List _chunk(String type, List<int> data) {
  final len = [(data.length >> 24) & 0xff, (data.length >> 16) & 0xff, (data.length >> 8) & 0xff, data.length & 0xff];
  return Uint8List.fromList([...len, ...type.codeUnits, ...data, 0, 0, 0, 0]); // dummy CRC (reader skips it)
}

Uint8List buildPngWithText(String keyword, String text) {
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  final data = [...utf8.encode(keyword), 0, ...utf8.encode(text)];
  return Uint8List.fromList([...sig, ..._chunk('tEXt', data), ..._chunk('IEND', [])]);
}

/// Builds a PNG from its signature plus raw chunk payloads.
Uint8List _buildPng(List<List<int>> chunks) {
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  return Uint8List.fromList([sig, ...chunks].expand((x) => x).toList());
}

void main() {
  test('extracts tEXt chunk keyword and text', () {
    final chunks = readPngTextChunks(buildPngWithText('chara', 'abc'));
    expect(chunks.length, 1);
    expect(chunks.first.keyword, 'chara');
    expect(chunks.first.text, 'abc');
  });

  test('throws on non-PNG input', () {
    expect(() => readPngTextChunks(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])), throwsFormatException);
  });

  test('inflates a zTXt chunk', () {
    // zTXt: keyword\0 | compressionMethod(0=zlib) | zlib(text)
    final data = [...utf8.encode('chara'), 0, 0, ...ZLibEncoder().convert(utf8.encode('{"name":"Aila"}'))];
    final png = _buildPng([_chunk('zTXt', data), _chunk('IEND', [])]);
    final chunks = readPngTextChunks(png);
    expect(chunks.single.keyword, 'chara');
    expect(chunks.single.text, '{"name":"Aila"}');
  });

  test('inflates a compression-flagged iTXt chunk', () {
    // iTXt: keyword\0 | flag(1=compressed) | method(0) | lang\0 | translated\0 | zlib(text)
    final data = [
      ...utf8.encode('ccv3'),
      0,
      1, // compression flag
      0, // method
      ...utf8.encode('en'),
      0, // language terminator
      0, // empty translated keyword
      ...ZLibEncoder().convert(utf8.encode('{"spec":"chara-card-v3"}')),
    ];
    final png = _buildPng([_chunk('iTXt', data), _chunk('IEND', [])]);
    final chunks = readPngTextChunks(png);
    expect(chunks.single.keyword, 'ccv3');
    expect(chunks.single.text, '{"spec":"chara-card-v3"}');
  });

  test('reads an uncompressed iTXt chunk', () {
    final data = [
      ...utf8.encode('ccv3'),
      0,
      0, // uncompressed
      0, // method ignored
      0, // empty lang
      0, // empty translated keyword
      ...utf8.encode('{"name":"Aila"}'),
    ];
    final png = _buildPng([_chunk('iTXt', data), _chunk('IEND', [])]);
    final chunks = readPngTextChunks(png);
    expect(chunks.single.keyword, 'ccv3');
    expect(chunks.single.text, '{"name":"Aila"}');
  });

  test('zTXt with Latin-1 (non-UTF-8) bytes falls back instead of crashing the import', () async {
    // 回归:zTXt 曾按严格 UTF-8 解码,含 Latin-1 重音字符(如 Description 块)的
    // 卡直接 FormatException 炸掉整卡导入,连后部完好的 chara 块都救不回。
    final latin1Bytes = latin1.encode('café < description >');
    final data = [...latin1.encode('Description'), 0, 0, ...ZLibEncoder().convert(latin1Bytes)];
    final png = _buildPng([_chunk('zTXt', data), _chunk('IEND', [])]);
    final chunks = readPngTextChunks(png);
    expect(chunks.single.keyword, 'Description');
    // UTF-8 解码失败 → Latin-1 兜底,字节按码点还原。
    expect(chunks.single.text, 'café < description >');
  });

  test('multiple same-keyword chara chunks are concatenated in file order', () {
    // V3 规范允许超大 base64 载荷拆进多个同名块;此前只取首个,分块卡必因
    // 截断的 base64 解不开而导入失败。
    const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final full = base64Encode(utf8.encode('{"name":"Split Card"}'));
    final mid = full.length ~/ 2;
    final part1 = [...utf8.encode('chara'), 0, ...utf8.encode(full.substring(0, mid))];
    final part2 = [...utf8.encode('chara'), 0, ...utf8.encode(full.substring(mid))];
    final png = Uint8List.fromList([
      ...sig,
      ..._chunk('tEXt', part1),
      ..._chunk('tEXt', part2),
      ..._chunk('IEND', []),
    ]);
    final chunks = readPngTextChunks(png);
    expect(chunks.length, 2);
    expect(chunks[0].text + chunks[1].text, full);
  });
}
