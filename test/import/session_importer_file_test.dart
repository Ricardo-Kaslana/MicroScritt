// 会话文件导入:v5 预检/取消/资产安全与 v4 JSON 流式兼容。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_asset_store.dart';
import 'package:microscritt/data/memory_repository.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/export/zip_store_writer.dart';
import 'package:microscritt/import/json_stream_reader.dart';
import 'package:microscritt/import/session_importer.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/variable.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/image_fixture.dart';

Map<String, dynamic> _meta(String name) => {
  'version': 5,
  'session': {'title': '$name 会话'},
  'character': {'name': name},
  'variables': <String, dynamic>{},
  'variableAccess': <String, dynamic>{},
  'memory': null,
};

Future<File> _writeV5(
  File file, {
  required Map<String, dynamic> meta,
  String messages = '',
  Map<String, List<int>> assets = const {},
  String? extraEntry,
}) async {
  final sink = file.openWrite();
  final writer = ZipStoreWriter(sink);
  await writer.addBytes('meta.json', utf8.encode(jsonEncode(meta)));
  await writer.addBytes('messages.ndjson', utf8.encode(messages));
  for (final entry in assets.entries) {
    await writer.addBytes('assets/${entry.key}', entry.value);
  }
  if (extraEntry != null) await writer.addBytes(extraEntry, const [1]);
  await writer.close();
  await sink.close();
  return file;
}

/// 噪声图:PNG 体积明显大于同尺寸 JPEG,用于验证压缩与哈希稳定性。
Uint8List _noisyPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  final random = math.Random(7);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        255,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void _replaceAscii(Uint8List bytes, String from, String to) {
  expect(from.length, to.length);
  final source = ascii.encode(from);
  final replacement = ascii.encode(to);
  for (var offset = 0; offset <= bytes.length - source.length; offset++) {
    var matches = true;
    for (var index = 0; index < source.length; index++) {
      if (bytes[offset + index] != source[index]) {
        matches = false;
        break;
      }
    }
    if (matches) bytes.setRange(offset, offset + source.length, replacement);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tmp;
  late List<AppDatabase> dbs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('session_file_import');
    dbs = <AppDatabase>[];
  });

  tearDown(() async {
    for (final db in dbs.reversed) {
      try {
        await db.db.close();
      } catch (_) {}
    }
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<AppDatabase> openDb(String name) async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: p.join(tmp.path, '$name.db'),
      imageRootPath: p.join(tmp.path, '$name-images'),
    );
    dbs.add(db);
    return db;
  }

  Future<File> buildArchive(AppDatabase source, String name) async {
    final avatar = await putTestImage(source);
    final background = await putTestImage(source, alternate: true);
    final charId = await CharacterRepository(source).insert(
      CharacterCard(
        name: 'Alice',
        description: 'knight',
        avatarHash: avatar,
        backgroundHash: background,
      ),
    );
    final sessionId = await SessionRepository(source).create(charId, '王都之旅');
    final messages = MessageRepository(source);
    for (var i = 0; i < 12; i++) {
      await messages.append(
        sessionId: sessionId,
        role: 'user',
        content: 'm$i',
        imageHash: i == 0 ? avatar : null,
      );
    }
    final summary = await messages.insertSystem(
      sessionId: sessionId,
      content: 'summary',
    );
    final rows = await messages.bySession(sessionId);
    await messages.markCompacted([
      rows[0].id!,
      rows[1].id!,
    ], compactOf: summary);
    await messages.append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: avatar,
    );
    await VariableRepository(
      source,
    ).upsert(sessionId, 'hp', '10', access: VariableAccess.full);
    await MemoryRepository(source).set(sessionId, '简洁文风');
    await SessionRepository(source).updateTokenUsage(
      sessionId: sessionId,
      inputTokens: 100,
      outputTokens: 50,
      cachedInputTokens: 0,
      backgroundInputTokens: 0,
      backgroundOutputTokens: 0,
      backgroundCachedInputTokens: 0,
    );
    final file = File(p.join(tmp.path, '$name.msarc'));
    await SessionExporter(
      source,
    ).exportToFile(sessionId: sessionId, file: file);
    return file;
  }

  Future<void> expectNoBusinessData(AppDatabase db) async {
    expect(await CharacterRepository(db).all(), isEmpty);
    expect(await db.db.query('sessions'), isEmpty);
    expect(await db.db.query('messages'), isEmpty);
  }

  test(
    'v5 importFile restores originals, compact links, state and progress',
    () async {
      final source = await openDb('source');
      final target = await openDb('target');
      final archive = await buildArchive(source, 'roundtrip');
      final avatar = testPngHash();
      final background = testPngHash(alternate: true);
      final fillerChar = await CharacterRepository(
        target,
      ).insert(const CharacterCard(name: 'Filler'));
      final fillerSession = await SessionRepository(
        target,
      ).create(fillerChar, 'filler');
      await MessageRepository(
        target,
      ).append(sessionId: fillerSession, role: 'user', content: 'placeholder');

      final progress = <(int, int)>[];
      final result = await SessionImporter.importFile(
        target,
        archive,
        onProgress: (done, total) => progress.add((done, total)),
      );

      expect(result.reusedCharacter, isFalse);
      expect(progress.last, (14, 14));
      expect(
        (await SessionRepository(target).get(result.sessionId))!.title,
        '王都之旅',
      );
      final card = (await CharacterRepository(target).get(result.characterId))!;
      expect(card.avatarHash, avatar);
      expect(card.backgroundHash, background);
      final restored = await MessageRepository(
        target,
      ).bySession(result.sessionId);
      expect(restored, hasLength(14));
      expect(restored.take(12).map((m) => m.content), [
        for (var i = 0; i < 12; i++) 'm$i',
      ]);
      expect(restored[0].compactOf, restored[12].id);
      expect(restored[1].compactOf, restored[12].id);
      expect(restored[0].imageHash, avatar);
      expect(restored[13].imageHash, avatar);
      expect(await target.images.fileFor(avatar).readAsBytes(), testPngBytes());
      expect(
        await target.images.fileFor(background).readAsBytes(),
        testPngBytes(alternate: true),
      );
      expect(await imageRefCount(target, avatar), 3);
      expect(await imageRefCount(target, background), 1);
      final variables = await VariableRepository(
        target,
      ).snapshot(result.sessionId);
      expect(variables.values, {'hp': '10'});
      expect(variables.access, {'hp': VariableAccess.full});
      expect(
        (await MemoryRepository(
          target,
        ).bySession(result.sessionId)).last.content,
        '简洁文风',
      );
      final usage = (await SessionRepository(target).get(result.sessionId))!;
      expect(usage.inputTokens, 100);
      expect(usage.outputTokens, 50);
    },
  );

  test('truncated ZIP fails before any business write', () async {
    final source = await openDb('trunc_source');
    final target = await openDb('trunc_target');
    final archive = await buildArchive(source, 'truncated-source');
    final bytes = await archive.readAsBytes();
    final truncated = File(p.join(tmp.path, 'truncated.msarc'));
    await truncated.writeAsBytes(
      bytes.sublist(0, (bytes.length * 0.6).round()),
    );

    await expectLater(
      SessionImporter.importFile(target, truncated),
      throwsFormatException,
    );
    await expectNoBusinessData(target);
    expect(await target.db.query('image_assets'), isEmpty);
  });

  test(
    'malformed NDJSON fails during preflight before character creation',
    () async {
      final target = await openDb('ndjson_target');
      final file = await _writeV5(
        File(p.join(tmp.path, 'bad-messages.msarc')),
        meta: _meta('Broken'),
        messages: '{"role":"user","content":"hi"',
      );

      await expectLater(
        SessionImporter.importFile(target, file),
        throwsFormatException,
      );
      await expectNoBusinessData(target);
    },
  );

  test('oversized NDJSON line and message count are rejected in preflight', () async {
    final target = await openDb('ndjson_limits');
    final longLine = await _writeV5(
      File(p.join(tmp.path, 'long-line.msarc')),
      meta: _meta('LongLine'),
      messages: '${jsonEncode({'role': 'user', 'content': 'x' * 200})}\n',
    );
    await expectLater(
      SessionImporter.importFile(
        target,
        longLine,
        maxV5MessageLineBytes: 64,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('行超过'),
        ),
      ),
    );
    await expectNoBusinessData(target);

    final manyLines = await _writeV5(
      File(p.join(tmp.path, 'too-many-lines.msarc')),
      meta: _meta('TooMany'),
      messages: List.filled(3, '{"role":"user","content":"x"}\n').join(),
    );
    await expectLater(
      SessionImporter.importFile(target, manyLines, maxV5Messages: 2),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('消息条数超过'),
        ),
      ),
    );
    await expectNoBusinessData(target);
  });

  test('attachment ref ids are dropped on import but content is kept', () async {
    final target = await openDb('attachment_ref');
    final file = await _writeV5(
      File(p.join(tmp.path, 'attachment-ref.msarc')),
      meta: _meta('AttachmentRef'),
      messages:
          '${jsonEncode({'role': 'user', 'content': '<system-reminder>世界书正文</system-reminder>', 'kind': 'attachment', 'refId': 'wb:1'})}\n',
    );

    final result = await SessionImporter.importFile(target, file);
    final rows = await MessageRepository(target).bySession(result.sessionId);
    // refId 来自源库自增 id,跨库保留可能错误抑制同名条目注入;正文必须保留。
    expect(rows.single.kind.name, 'attachment');
    expect(rows.single.refId, isNull);
    expect(rows.single.content, '<system-reminder>世界书正文</system-reminder>');
  });

  test('text-only import never writes compact_of = -1 for a dropped target', () async {
    final target = await openDb('compact_dropped_target');
    final file = await _writeV5(
      File(p.join(tmp.path, 'compact-dropped.msarc')),
      meta: _meta('CompactDropped'),
      messages:
          '${jsonEncode({'role': 'assistant', 'content': 'summary', 'isCompacted': true, 'compactOf': 1})}\n'
          '${jsonEncode({'role': 'assistant', 'content': ''})}\n',
    );

    final result = await SessionImporter.importFile(
      target,
      file,
      includeImages: false,
    );
    final rows = await MessageRepository(target).bySession(result.sessionId);
    expect(rows, hasLength(1));
    expect(rows.single.content, 'summary');
    expect(rows.single.compactOf, isNull);
    final raw = await target.db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [rows.single.id],
    );
    expect(raw.single['compact_of'], isNull);
  });

  test(
    'cancel after business creation rolls back rows and acquired references',
    () async {
      final source = await openDb('cancel_source');
      final target = await openDb('cancel_target');
      final archive = await buildArchive(source, 'cancel-source');
      var cancelled = false;

      await expectLater(
        SessionImporter.importFile(
          target,
          archive,
          isCancelled: () => cancelled,
          onProgress: (done, total) {
            if (done == 9) cancelled = true;
          },
        ),
        throwsA(isA<ArchiveScanCancelled>()),
      );
      await expectNoBusinessData(target);
      final assets = await target.db.query('image_assets');
      expect(assets, isNotEmpty); // 预提交文件留待 GC,但不能残留业务引用。
      expect(assets.every((row) => row['ref_count'] == 0), isTrue);
    },
  );

  test(
    'missing assets and filename/content hash mismatch fail preflight',
    () async {
      final target = await openDb('asset_target');
      final hash = testPngHash();
      final message =
          '${jsonEncode({'role': 'assistant', 'imageHash': hash})}\n';
      final missing = await _writeV5(
        File(p.join(tmp.path, 'missing-asset.msarc')),
        meta: _meta('MissingAsset'),
        messages: message,
      );
      await expectLater(
        SessionImporter.importFile(target, missing),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('缺少被引用资产'),
          ),
        ),
      );
      await expectNoBusinessData(target);

      final mismatch = await _writeV5(
        File(p.join(tmp.path, 'wrong-hash.msarc')),
        meta: _meta('WrongHash'),
        messages: message,
        assets: {hash: testPngBytes(alternate: true)},
      );
      await expectLater(
        SessionImporter.importFile(target, mismatch),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      await expectNoBusinessData(target);
      expect(
        (await target.db.query(
          'image_assets',
        )).every((row) => row['ref_count'] == 0),
        isTrue,
      );
    },
  );

  test(
    'invalid image and oversized asset are rejected before business writes',
    () async {
      final target = await openDb('bad_image_target');
      final hash = 'a' * 64;
      final message =
          '${jsonEncode({'role': 'assistant', 'imageHash': hash})}\n';
      final invalid = await _writeV5(
        File(p.join(tmp.path, 'invalid-image.msarc')),
        meta: _meta('InvalidImage'),
        messages: message,
        assets: {
          hash: const [1, 2, 3],
        },
      );
      await expectLater(
        SessionImporter.importFile(target, invalid),
        throwsFormatException,
      );
      await expectNoBusinessData(target);

      final oversized = File(p.join(tmp.path, 'oversized.msarc'));
      final sink = oversized.openWrite();
      final writer = ZipStoreWriter(sink);
      await writer.addBytes(
        'meta.json',
        utf8.encode(jsonEncode(_meta('Oversized'))),
      );
      await writer.addBytes('messages.ndjson', utf8.encode(message));
      await writer.addStream(
        'assets/$hash',
        Stream<List<int>>.value(
          Uint8List(ImageAssetStore.maxOriginalBytes + 1),
        ),
      );
      await writer.close();
      await sink.close();
      await expectLater(
        SessionImporter.importFile(target, oversized),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('16MiB'),
          ),
        ),
      );
      await expectNoBusinessData(target);
    },
  );

  test('unknown and traversal entry paths are rejected safely', () async {
    final target = await openDb('path_target');
    final unknown = await _writeV5(
      File(p.join(tmp.path, 'unknown-entry.msarc')),
      meta: _meta('UnknownEntry'),
      extraEntry: 'outside.txt',
    );
    await expectLater(
      SessionImporter.importFile(target, unknown),
      throwsFormatException,
    );
    await expectNoBusinessData(target);

    final traversal = await _writeV5(
      File(p.join(tmp.path, 'traversal.msarc')),
      meta: _meta('Traversal'),
      extraEntry: 'safe.txt',
    );
    final bytes = await traversal.readAsBytes();
    _replaceAscii(bytes, 'safe.txt', '../x.txt');
    await traversal.writeAsBytes(bytes);
    await expectLater(
      SessionImporter.importFile(target, traversal),
      throwsFormatException,
    );
    await expectNoBusinessData(target);
  });

  test('v4 JSON file keeps streaming import and assetizes base64', () async {
    final target = await openDb('legacy_target');
    final file = File(p.join(tmp.path, 'legacy.json'));
    await file.writeAsString(
      jsonEncode({
        'version': 4,
        'character': {'name': 'LegacyFile', 'avatar': testPngBase64},
        'characterBackgroundBase64': testPngBase64Alt,
        'messages': [
          for (var index = 0; index < 11; index++)
            {'role': 'user', 'content': 'm$index'},
          {'role': 'assistant', 'content': '', 'imageBase64': testPngBase64},
        ],
        'variableAccess': {'hp': 'full'},
        'variables': {'hp': '10'},
      }),
    );

    final progress = <(int, int)>[];
    final result = await SessionImporter.importFile(
      target,
      file,
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(progress.last, (12, 12));
    final messages = await MessageRepository(
      target,
    ).bySession(result.sessionId);
    expect(messages.last.imageHash, testPngHash());
    expect(
      await target.images.fileFor(testPngHash()).readAsBytes(),
      testPngBytes(),
    );
    expect(await imageRefCount(target, testPngHash()), 2);
    expect(await imageRefCount(target, testPngHash(alternate: true)), 1);
  });

  test(
    'repeated v5 imports reuse asset files and only add business references',
    () async {
      final source = await openDb('repeat_source');
      final target = await openDb('repeat_target');
      final archive = await buildArchive(source, 'repeat-source');

      final first = await SessionImporter.importFile(target, archive);
      final second = await SessionImporter.importFile(target, archive);

      expect(first.reusedCharacter, isFalse);
      expect(second.reusedCharacter, isTrue);
      expect(second.characterId, first.characterId);
      expect(await target.db.query('image_assets'), hasLength(2));
      expect(await imageRefCount(target, testPngHash()), 5);
      expect(await imageRefCount(target, testPngHash(alternate: true)), 1);
      final originals = await Directory(
        p.join(target.imageRootPath, 'original'),
      ).list(recursive: true).where((entity) => entity is File).toList();
      expect(originals, hasLength(2));
    },
  );

  test(
    'v5 includeImages=false imports text only and drops asset references',
    () async {
      final source = await openDb('text_source');
      final target = await openDb('text_target');
      final archive = await buildArchive(source, 'text-source');

      final result = await SessionImporter.importFile(
        target,
        archive,
        includeImages: false,
      );

      expect(await target.db.query('image_assets'), isEmpty);
      final character = await CharacterRepository(
        target,
      ).get(result.characterId);
      expect(character!.avatarHash, isNull);
      expect(character.backgroundHash, isNull);
      final rows = await MessageRepository(target).bySession(result.sessionId);
      // 归档里末尾的纯图片消息(空正文)整条略过,其余 13 条照常导入。
      expect(rows, hasLength(13));
      expect(rows.every((message) => message.imageHash == null), isTrue);
      expect(rows.every((message) => message.imageUrl == null), isTrue);
      expect(rows.every((message) => message.content.isNotEmpty), isTrue);
      // 跳过一行后 compactOf 的归档索引仍必须指向正确的摘要行。
      expect(rows[0].isCompacted, isTrue);
      expect(rows[0].compactOf, rows[12].id);
      expect(rows[1].compactOf, rows[12].id);
      expect(
        (await VariableRepository(
          target,
        ).snapshot(result.sessionId)).values['hp'],
        '10',
      );
      expect(
        await MemoryRepository(target).bySession(result.sessionId),
        hasLength(1),
      );
    },
  );

  test(
    'v5 text-only import skips asset validation and drops image references',
    () async {
      final target = await openDb('text_url_target');
      final hash = 'a' * 64;
      final file = await _writeV5(
        File(p.join(tmp.path, 'text-url.msarc')),
        meta: _meta('TextUrl'),
        messages:
            '${jsonEncode({'role': 'assistant', 'content': '', 'imageHash': hash, 'imageUrl': 'https://example.com/a.png', 'imagePrompt': 'a prompt'})}\n'
            '${jsonEncode({'role': 'user', 'content': 'x', 'imageHash': hash, 'imageUrl': 'https://example.com/b.png', 'imagePrompt': 'b prompt'})}\n',
      );

      final result = await SessionImporter.importFile(
        target,
        file,
        includeImages: false,
      );

      // URL 引用同样必须清空:保留它会让气泡继续渲染远程图片,并在查看会话时
      // 经 URL 回填重新资产化,「仅文本」就失去意义。空正文的纯图片消息则
      // 整条略过,不能留下空气泡;seq 仍然连续。
      final rows = await MessageRepository(target).bySession(result.sessionId);
      final message = rows.single;
      expect(message.content, 'x');
      expect(message.seq, 0);
      expect(message.imageHash, isNull);
      expect(message.imageUrl, isNull);
      expect(message.imagePrompt, isNull);
      expect(await target.db.query('image_assets'), isEmpty);
    },
  );

  test(
    'v4 JSON text-only import drops base64, URLs and character images',
    () async {
      final target = await openDb('legacy_text_target');
      final file = File(p.join(tmp.path, 'legacy-text.json'));
      await file.writeAsString(
        jsonEncode({
          'version': 4,
          'character': {'name': 'LegacyText', 'avatar': testPngBase64},
          'characterBackgroundBase64': testPngBase64Alt,
          'messages': [
            {'role': 'user', 'content': 'hi'},
            {
              'role': 'assistant',
              'content': '',
              'imageBase64': testPngBase64,
              'imageUrl': 'https://example.com/a.png',
              'imagePrompt': 'a prompt',
            },
          ],
        }),
      );

      final result = await SessionImporter.importFile(
        target,
        file,
        includeImages: false,
      );

      expect(await target.db.query('image_assets'), isEmpty);
      final character = await CharacterRepository(
        target,
      ).get(result.characterId);
      expect(character!.avatarHash, isNull);
      expect(character.backgroundHash, isNull);
      final rows = await MessageRepository(target).bySession(result.sessionId);
      expect(rows.every((message) => message.imageHash == null), isTrue);
      expect(rows.every((message) => message.imageUrl == null), isTrue);
      expect(rows.every((message) => message.imagePrompt == null), isTrue);
      // 纯图片消息(空正文)整条略过,不留下空气泡。
      expect(rows.map((message) => message.content), ['hi']);
    },
  );

  test('v5 import keeps original assets when compression is enabled', () async {
    final source = await openDb('compress_source');
    final target = await openDb('compress_target');
    final charId = await CharacterRepository(
      source,
    ).insert(const CharacterCard(name: 'Big'));
    final sessionId = await SessionRepository(source).create(charId, 'big');
    final png = _noisyPng(2200, 100);
    final ref = await source.images.putBytes(png, compress: false);
    await MessageRepository(source).append(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
      imageHash: ref.hash,
    );
    final file = File(p.join(tmp.path, 'compressed-target.msarc'));
    await SessionExporter(
      source,
    ).exportToFile(sessionId: sessionId, file: file);

    // 目标开启入库压缩也必须逐字节接收归档资产:重编码会改变哈希,
    // 与 assets/<sha256> 文件名和消息引用不一致。
    target.images.compressMaxEdge = 2048;
    final result = await SessionImporter.importFile(target, file);

    final asset = (await target.db.query(
      'image_assets',
      where: 'hash = ?',
      whereArgs: [ref.hash],
    )).single;
    expect(asset['width'], 2200);
    expect(asset['height'], 100);
    expect(await target.images.exists(ref.hash), isTrue);
    final restored = (await MessageRepository(
      target,
    ).bySession(result.sessionId)).single;
    expect(restored.imageHash, ref.hash);
  });

  test('partial archive imports only the selected messages', () async {
    final source = await openDb('partial_source');
    final target = await openDb('partial_target');
    final charId = await CharacterRepository(
      source,
    ).insert(const CharacterCard(name: 'Partial'));
    final sessionId = await SessionRepository(source).create(charId, 'p');
    final repo = MessageRepository(source);
    final first = await repo.append(
      sessionId: sessionId,
      role: 'user',
      content: 'a',
    );
    await repo.append(sessionId: sessionId, role: 'assistant', content: 'b');
    await repo.append(sessionId: sessionId, role: 'user', content: 'c');
    final file = File(p.join(tmp.path, 'partial.msarc'));
    await SessionExporter(
      source,
    ).exportToFile(sessionId: sessionId, file: file, messageIds: {first.id!});

    final result = await SessionImporter.importFile(target, file);
    final rows = await MessageRepository(target).bySession(result.sessionId);
    expect(rows.map((message) => message.content).toList(), ['a']);
    expect(rows.single.isCompacted, isFalse);
  });

  test(
    'v5 reuses a same-name character and keeps its card untouched',
    () async {
      final source = await openDb('reuse_source');
      final target = await openDb('reuse_target');
      final archive = await buildArchive(source, 'reuse-source');
      final existingId = await CharacterRepository(
        target,
      ).insert(const CharacterCard(name: 'Alice', description: 'local edit'));

      final result = await SessionImporter.importFile(target, archive);
      expect(result.reusedCharacter, isTrue);
      expect(result.characterId, existingId);
      expect(
        (await CharacterRepository(target).get(existingId))!.description,
        'local edit',
      );
    },
  );
}
