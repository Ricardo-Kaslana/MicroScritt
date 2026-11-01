// PNG 卡导出测试:图片原样复用、chara/ccv3 载荷剥离 avatar 与占位图回退。
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/export/character_card_png_exporter.dart';
import 'package:microscritt/import/character_card_importer.dart';
import 'package:microscritt/import/png_chunk_reader.dart';
import 'package:microscritt/models/character_card.dart';

/// 1×1 透明 PNG(标准最小卡图,含 IHDR/IDAT/IEND)。
const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

void main() {
  test('embeds the card json as a chara chunk and round-trips', () async {
    final avatar = 'data:image/png;base64,$_onePixelPng';
    final card = const CharacterCard(
      name: 'Alice',
      description: 'knight',
    ).withAvatar(avatar);

    final out = await CharacterCardPngExporter.export(card);

    // 图片本体沿用原头像 PNG(未重编码,仅追加文本块)。
    expect(out.sublist(0, 8), base64Decode(_onePixelPng).sublist(0, 8));
    final chunks = readPngTextChunks(out);
    final chara = chunks.where((c) => c.keyword == 'chara').single;
    final payload =
        jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
            as Map<String, dynamic>;
    expect(payload['name'], 'Alice');
    expect(payload['description'], 'knight');
    // PNG 自己就是头像,载荷里不再内嵌 base64。
    expect(payload.containsKey('avatar'), isFalse);

    // 全环往返:导出的 PNG 再导入,name/desc 还原,头像 = 整张 PNG。
    final imported = CharacterCardImporter.fromBytes(out);
    expect(imported.name, 'Alice');
    expect(imported.description, 'knight');
    expect(imported.avatarBase64, base64Encode(out));
  });

  test('V3 cards also carry a ccv3 chunk with the same payload', () async {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {'name': 'Aila', 'avatar': 'stale'},
    }).withAvatar(_onePixelPng);

    final out = await CharacterCardPngExporter.export(card);
    final chunks = readPngTextChunks(out);
    final chara = chunks.where((c) => c.keyword == 'chara').single;
    final ccv3 = chunks.where((c) => c.keyword == 'ccv3').single;
    expect(ccv3.text, chara.text);
    final payload =
        jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
            as Map<String, dynamic>;
    expect(payload['spec'], 'chara_card_v3');
    expect(payload.containsKey('avatar'), isFalse);
    expect(
      (payload['data'] as Map<String, dynamic>).containsKey('avatar'),
      isFalse,
    );
  });

  test('large payloads embed intact (no giant int-list expansion)', () async {
    final description = '长' * 600000; // ≈1.8MB UTF-8 JSON
    final card = CharacterCard(
      name: 'Big',
      description: description,
    ).withAvatar(_onePixelPng);

    final out = await CharacterCardPngExporter.export(card);
    final chunks = readPngTextChunks(out);
    final chara = chunks.where((c) => c.keyword == 'chara').single;
    final payload =
        jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
            as Map<String, dynamic>;
    expect(payload['description'], description);
    // 头像仍是原始 1×1 PNG 本体,导出未重编码。
    expect(out.length, greaterThan(description.length));
  });

  testWidgets('cards without a usable avatar export a placeholder PNG', (
    tester,
  ) async {
    // 占位图要经真实图片编解码(Picture.toImage / instantiateImageCodec),
    // 假时钟下这些 Future 不会完成,必须放进 runAsync。
    await tester.runAsync(() async {
      for (final avatar in [
        null,
        base64Encode([1, 2, 3]),
      ]) {
        final out = await CharacterCardPngExporter.export(
          CharacterCard(name: '无名', avatarBase64: avatar),
        );
        // 占位图是真实可解码的 512×512 PNG,且携带卡数据。
        final codec = await ui.instantiateImageCodec(out);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 512);
        expect(frame.image.height, 512);
        frame.image.dispose();
        codec.dispose();
        final chunks = readPngTextChunks(out);
        final chara = chunks.where((c) => c.keyword == 'chara').single;
        final payload =
            jsonDecode(CharacterCardImporter.decodeCharaPayload(chara.text))
                as Map<String, dynamic>;
        expect(payload['name'], '无名');
      }
    });
  });
}
