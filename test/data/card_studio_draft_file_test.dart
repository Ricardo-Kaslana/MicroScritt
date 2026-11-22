// 制卡草稿文件测试:按目标分文件、读写顺序、清理、版本/坏文件与体积上限。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/card_studio_draft_file.dart';
import 'package:path/path.dart' as p;

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
    expect(store.pathFor(null), endsWith('card-studio-draft-new.json'));
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

  test('read waits for the post-write reconciliation callback', () async {
    var reconciled = false;
    final written = await store.write(
      9,
      {'value': 1},
      afterWrite: () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        reconciled = true;
      },
    );

    expect(written, isTrue);
    expect(await store.read(9), {'value': 1});
    expect(reconciled, isTrue);
  });

  test('version mismatch and corrupt JSON are ignored', () async {
    final file = File(store.pathFor(5));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'version': 99,
        'payload': {'a': 1},
      }),
    );
    expect(await store.read(5), isNull);

    await file.writeAsString('{not json');
    expect(await store.read(5), isNull);
  });

  test('payload over the size cap is not written', () async {
    final written = await store.write(6, {
      'blob': 'x' * (CardStudioDraftFile.maxPayloadChars + 10),
    });

    expect(written, isFalse);
    expect(await File(store.pathFor(6)).exists(), isFalse);
  });

  test('scan reports corrupt drafts and salvages their held hashes', () async {
    final held = 'f' * 64;
    final corrupt = File(store.pathFor(42));
    await corrupt.parent.create(recursive: true);
    // 截断的 JSON 无法整体解析,但里面声明过的哈希仍要保护起来。
    await corrupt.writeAsString(
      '{"version":1,"payload":{"heldAssetHashes":["$held",',
    );
    final badVersion = File(store.pathFor(41));
    await badVersion.writeAsString(
      jsonEncode({
        'version': 99,
        'payload': {
          'heldAssetHashes': ['e' * 64],
        },
      }),
    );
    await store.write(null, {
      'heldAssetHashes': ['a' * 64],
    });

    final scan = await store.scanHeldAssetHashSets();

    expect(scan.hadFailures, isTrue);
    expect(scan.failedFiles, contains('card-studio-draft-42.json'));
    expect(
      scan.sets.any((set) => set.contains(held)),
      isTrue,
      reason: '坏文件的哈希要宽松提取,避免对账后误回收',
    );
    expect(scan.sets.any((set) => set.contains('a' * 64)), isTrue);
    // 版本不符不是损坏,不阻塞回收。
    expect(scan.sets.any((set) => set.contains('e' * 64)), isFalse);
    expect(scan.failedFiles, isNot(contains('card-studio-draft-41.json')));
  });

  test(
    'scanHeldAssetHashSets waits for writes and scans valid drafts only',
    () async {
      final first = 'a' * 64;
      final second = 'b' * 64;
      final pending = store.write(1, {
        'heldAssetHashes': [first, '  $second  ', '   ', 42],
      });
      final snapshots = (await store.scanHeldAssetHashSets()).sets;
      await pending;
      await store.write(null, {
        'heldAssetHashes': ['c' * 64],
      });

      final corrupt = File(p.join(dir.path, 'card-studio-draft-99.json'));
      await corrupt.writeAsString('{not json');
      final badVersion = File(p.join(dir.path, 'card-studio-draft-98.json'));
      await badVersion.writeAsString(
        jsonEncode({
          'version': 99,
          'payload': {
            'heldAssetHashes': ['d' * 64],
          },
        }),
      );
      final tmp = File(p.join(dir.path, 'card-studio-draft-97.json.tmp'));
      await tmp.writeAsString(
        jsonEncode({
          'version': 1,
          'payload': {
            'heldAssetHashes': ['e' * 64],
          },
        }),
      );

      final scan = await store.scanHeldAssetHashSets();
      final sets = scan.sets;
      expect(scan.hadFailures, isTrue, reason: '坏文件要报告,不能静默');

      expect(snapshots, hasLength(1));
      expect(snapshots.single, {first, second});
      expect(sets, hasLength(2));
      expect(
        sets.any(
          (set) =>
              set.length == 2 && set.contains(first) && set.contains(second),
        ),
        isTrue,
      );
      expect(
        sets.any((set) => set.length == 1 && set.contains('c' * 64)),
        isTrue,
      );
    },
  );
}
