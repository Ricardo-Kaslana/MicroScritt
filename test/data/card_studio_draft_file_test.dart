// 制卡草稿文件测试:按目标分文件、读写顺序、清理、版本/坏文件与体积上限。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/card_studio_draft_file.dart';

void main() {
  late Directory dir;
  late CardStudioDraftFile store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('card-studio-draft-test-');
    store = CardStudioDraftFile(dir.path);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('writes and reads per-target payloads', () async {
    await store.write(null, {'value': 1});
    await store.write(7, {'value': 2});

    expect(await store.read(null), {'value': 1});
    expect(await store.read(7), {'value': 2});
    expect(await store.read(8), isNull);
    expect(
      store.pathFor(null),
      endsWith('card-studio-draft-new.json'),
    );
    expect(store.pathFor(7), endsWith('card-studio-draft-7.json'));
  });

  test('read waits for queued writes', () async {
    final pending = store.write(3, {'value': 'late'});
    expect(await store.read(3), {'value': 'late'});
    await pending;
  });

  test('clear is serialized after writes', () async {
    final pending = store.write(4, {'value': 1});
    final cleared = store.clear(4);
    await Future.wait([pending, cleared]);

    expect(await File(store.pathFor(4)).exists(), isFalse);
    expect(await store.read(4), isNull);
  });

  test('version mismatch and corrupt JSON are ignored', () async {
    final file = File(store.pathFor(5));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'version': 99, 'payload': {'a': 1}}));
    expect(await store.read(5), isNull);

    await file.writeAsString('{not json');
    expect(await store.read(5), isNull);
  });

  test('payload over the size cap is not written', () async {
    await store.write(6, {
      'blob': 'x' * (CardStudioDraftFile.maxPayloadChars + 10),
    });

    expect(await File(store.pathFor(6)).exists(), isFalse);
  });
}
