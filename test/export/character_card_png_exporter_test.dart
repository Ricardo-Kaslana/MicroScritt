// PNG 卡导出测试:显式头像字节、chara/ccv3 载荷剥离 avatar 与占位图回退。
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/export/character_card_png_exporter.dart';
import 'package:microscritt/import/character_card_importer.dart';
import 'package:microscritt/import/png_chunk_reader.dart';
import 'package:microscritt/models/character_card.dart';

import '../import/png_chunk_reader_test.dart' show buildPngWithText;

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

void main() {
  test('embeds the card json as a chara chunk and round-trips', () async {
    final avatar = 'data:image/png;base64,$_onePixelPng';
    final card = CharacterCard(
      name: 'Alice',
      description: 'knight',
    ).withAvatar('a' * 64);

    final out = await CharacterCardPngExporter.export(
      card,
      avatarBase64: avatar,
    );

    expect(out.sublist(0, 8), base64Decode(_onePixelPng).sublist(0, 8));
    final chunks = readPngTextChunks(out);
    final chara = chunks.where((c) => c.keyword == 'chara').single;
    final payload = jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
        as Map<String, dynamic>;
    expect(payload['name'], 'Alice');
    expect(payload['description'], 'knight');
    expect(payload.containsKey('avatar'), isFalse);

    final imported = CharacterCardImporter.fromBytes(out);
    expect(imported.name, 'Alice');
    expect(imported.description, 'knight');
    expect(imported.importedAvatarBase64, base64Encode(out));
  });

  test('V3 cards also carry a ccv3 chunk with the same payload', () async {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {'name': 'Aila', 'avatar': 'stale'},
    }).replacingAvatar('b' * 64);

    final out = await CharacterCardPngExporter.export(
      card,
      avatarBase64: _onePixelPng,
    );
    final chunks = readPngTextChunks(out);
    final chara = chunks.where((c) => c.keyword == 'chara').single;
    final ccv3 = chunks.where((c) => c.keyword == 'ccv3').single;
    expect(ccv3.text, chara.text);
    final payload = jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
        as Map<String, dynamic>;
    expect(payload['spec'], 'chara_card_v3');
    expect(payload.containsKey('avatar'), isFalse);
    expect((payload['data'] as Map<String, dynamic>).containsKey('avatar'), isFalse);
  });

  test('reuses an avatar PNG without carrying its old chara payload', () async {
    final oldPayload = jsonEncode({'name': '旧卡', 'description': 'old'});
    final avatarPng = buildPngWithText(
      'chara',
      base64Encode(utf8.encode(oldPayload)),
    );

    final out = await CharacterCardPngExporter.export(
      const CharacterCard(name: '新卡', description: 'new'),
      avatarBase64: base64Encode(avatarPng),
    );

    expect(CharacterCardImporter.fromBytes(out).name, '新卡');
    expect(
      readPngTextChunks(
        out,
      ).where((chunk) => chunk.keyword.toLowerCase() == 'chara'),
      hasLength(1),
    );
  });

  test('V2 export strips an old ccv3 that would win the import lookup', () async {
    final oldV3 = jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {'name': '旧V3'},
    });
    final avatarPng = buildPngWithText(
      'ccv3',
      base64Encode(utf8.encode(oldV3)),
    );

    final out = await CharacterCardPngExporter.export(
      const CharacterCard(name: '新V2'),
      avatarBase64: base64Encode(avatarPng),
    );

    expect(CharacterCardImporter.fromBytes(out).name, '新V2');
    expect(
      readPngTextChunks(
        out,
      ).where((chunk) => chunk.keyword.toLowerCase() == 'ccv3'),
      isEmpty,
    );
  });

  test('large payloads embed intact (no giant int-list expansion)', () async {
    final description = '长' * 600000;
    final card = CharacterCard(
      name: 'Big',
      description: description,
    ).withAvatar('c' * 64);

    final out = await CharacterCardPngExporter.export(
      card,
      avatarBase64: _onePixelPng,
    );
    final chunks = readPngTextChunks(out);
    final chara = chunks.where((c) => c.keyword == 'chara').single;
    final payload = jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
        as Map<String, dynamic>;
    expect(payload['description'], description);
    expect(out.length, greaterThan(description.length));
  });

  testWidgets('cards without a usable avatar export a placeholder PNG', (tester) async {
    await tester.runAsync(() async {
      for (final avatar in [null, base64Encode([1, 2, 3])]) {
        final out = await CharacterCardPngExporter.export(
          const CharacterCard(name: '无名'),
          avatarBase64: avatar,
        );
        final codec = await ui.instantiateImageCodec(out);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 512);
        expect(frame.image.height, 512);
        frame.image.dispose();
        codec.dispose();
        final chunks = readPngTextChunks(out);
        final chara = chunks.where((c) => c.keyword == 'chara').single;
        final payload = jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
            as Map<String, dynamic>;
        expect(payload['name'], '无名');
      }
    });
  });
}
