// 会话归档流式读取测试:各分块大小下与 jsonDecode 等价,截断/坏结构在
// 第一遍扫描即报 FormatException。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/import/json_stream_reader.dart';

Iterable<String> _chunks(String text, int size) sync* {
  for (var i = 0; i < text.length; i += size) {
    yield text.substring(i, i + size > text.length ? text.length : i + size);
  }
}

Future<Map<String, dynamic>> _scan(String text, int chunkSize) async {
  final scanner = JsonStreamScanner(Stream.fromIterable(_chunks(text, chunkSize)));
  await scanner.beginObject();
  final out = <String, dynamic>{};
  while (true) {
    final key = await scanner.nextKey();
    if (key == null) break;
    if (key == 'messages') {
      await scanner.beginArray();
      final list = <dynamic>[];
      while (true) {
        final raw = await scanner.nextArrayElement();
        if (raw == null) break;
        list.add(jsonDecode(raw));
      }
      out[key] = list;
    } else {
      out[key] = await scanner.readSmallValue();
    }
  }
  await scanner.endObjectAndVerifyEof();
  await scanner.close();
  return out;
}

void main() {
  test('scans tricky JSON identically to jsonDecode at every chunk size', () async {
    final text = jsonEncode({
      'title': 'a"b{c}[d]\\\\e\u0041',
      'emoji': '😀 }}]',
      'n': -1.5e3,
      'ok': true,
      'nil': null,
      'nested': {
        'x': [1, {'y': '}'}],
      },
      'messages': [
        {'content': 'line\n"q" \\ end', 'imageBase64': 'QUJDREVG'},
        {'content': 'braces }{][ and emoji 😀', 'kind': 'attachment'},
      ],
    });
    final expected = jsonDecode(text) as Map<String, dynamic>;
    // 块大小 1/2/3 会把 emoji 的代理对与反斜杠转义切在两块之间 —— 扫描器
    // 必须跨块续读;整串大小则覆盖"一次读满"的路径。
    for (final size in [1, 2, 3, 7, 64, text.length]) {
      final actual = await _scan(text, size);
      expect(actual, expected, reason: 'chunk size $size');
    }
  });

  test('header counts messages and ignores unknown/large values', () async {
    final dir = await Directory.systemTemp.createTemp('stream_header');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/archive.json');
    file.writeAsStringSync(jsonEncode({
      'version': 4,
      'session': {'title': '王都之旅', 'usage': {'inputTokens': 3}},
      'character': {'name': 'Alice'},
      // 未知顶层键:头部扫描必须整体跳过而不是读进内存,否则等于全文件解码。
      'unknownHuge': {
        'payload': List.filled(1000, 'x' * 100),
      },
      'messages': [
        {'content': 'one'},
        {'content': 'two', 'imageBase64': 'QUJD'},
      ],
      'variables': {'hp': '10'},
      'variableAccess': {'hp': 'full'},
      'memory': '简洁文风',
    }));

    final reader = SessionArchiveReader(file);
    final header = await reader.readHeader();
    expect(header.version, 4);
    expect(header.character, {'name': 'Alice'});
    expect(header.session!['title'], '王都之旅');
    expect(header.variables, {'hp': '10'});
    expect(header.variableAccess, {'hp': 'full'});
    expect(header.memory, '简洁文风');
    expect(header.messagesArrays, 1);
    expect(header.messageCount, 2);

    final raws = <String>[];
    await reader.forEachMessage(
      skipArrays: 0,
      messageCount: header.messageCount,
      onMessage: (raw, index) async => raws.add(raw),
    );
    expect(raws, hasLength(2));
    expect((jsonDecode(raws[0]) as Map)['content'], 'one');
    expect((jsonDecode(raws[1]) as Map)['imageBase64'], 'QUJD');
  });

  test('duplicate messages keys follow last-wins like jsonDecode', () async {
    final dir = await Directory.systemTemp.createTemp('stream_dup');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/archive.json');
    file.writeAsStringSync('{"version":4,"character":{"name":"A"},'
        '"messages":[{"content":"old"}],'
        '"messages":[{"content":"new1"},{"content":"new2"}]}');

    final reader = SessionArchiveReader(file);
    final header = await reader.readHeader();
    expect(header.messagesArrays, 2);
    expect(header.messageCount, 2);

    final raws = <String>[];
    // 重复 messages 键与整文件 jsonDecode 同语义(后者覆盖):前一个数组跳过。
    await reader.forEachMessage(
      skipArrays: header.messagesArrays - 1,
      messageCount: header.messageCount,
      onMessage: (raw, index) async => raws.add(raw),
    );
    expect(raws.map((raw) => (jsonDecode(raw) as Map)['content']), ['new1', 'new2']);
  });

  test('every truncation prefix fails with FormatException', () async {
    final dir = await Directory.systemTemp.createTemp('stream_trunc');
    addTearDown(() => dir.deleteSync(recursive: true));
    final text = jsonEncode({
      'version': 4,
      'character': {'name': 'Alice', 'description': 'knight'},
      'messages': [
        {'content': 'a"b', 'imageBase64': 'QUJD'},
        {'content': 'c'},
      ],
      'variables': {'hp': '10'},
      'memory': 'm',
    });
    final file = File('${dir.path}/archive.json');
    // 每个前缀长度都必须失败(含 0):截断可能落在任何位置,只测几个边界
    // 挡不住"读一半就放行"的回归。
    for (var length = 0; length < text.length; length++) {
      file.writeAsStringSync(text.substring(0, length));
      await expectLater(
        SessionArchiveReader(file).readHeader(),
        throwsA(isA<FormatException>()),
        reason: 'prefix length $length',
      );
    }
  });

  test('trailing content after the root object is rejected', () async {
    final dir = await Directory.systemTemp.createTemp('stream_tail');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/archive.json');
    file.writeAsStringSync('{"version":4,"character":{"name":"A"},"messages":[]} x');
    await expectLater(
      SessionArchiveReader(file).readHeader(),
      throwsA(isA<FormatException>()),
    );
  });

  test('messages must be an array', () async {
    final dir = await Directory.systemTemp.createTemp('stream_shape');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/archive.json');
    file.writeAsStringSync('{"version":4,"character":{"name":"A"},"messages":{}}');
    await expectLater(
      SessionArchiveReader(file).readHeader(),
      throwsA(isA<FormatException>()),
    );
  });
}
