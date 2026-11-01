// 角色卡导入测试:PNG chara/ccv3 文本块与 JSON 文本两路解析,V1/V2 信封
// 与兼容形态的字段归一。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/image_codec.dart';
import 'package:microscritt/import/character_card_importer.dart';
import 'package:microscritt/import/worldbook_importer.dart';
import 'png_chunk_reader_test.dart' show buildPngWithText;

void main() {
  test('imports V2 card from PNG tEXt chara (base64 JSON)', () {
    final json = jsonEncode({'name': 'Alice', 'description': 'knight'});
    final b64 = base64.encode(utf8.encode(json));
    final png = buildPngWithText('chara', b64);
    final card = CharacterCardImporter.fromBytes(png);
    expect(card.name, 'Alice');
    expect(card.description, 'knight');
  });

  test('PNG voice/card becomes the avatar when JSON has none', () {
    final json = jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {'name': 'Pixel'},
    });
    final b64 = base64.encode(utf8.encode(json));
    final png = buildPngWithText('ccv3', b64);
    final card = CharacterCardImporter.fromBytes(png);
    // 头像来自 PNG 图片本身(而非 JSON),满足 V2/V3 标准里图片不进 JSON。
    final avatarBytes = safeBase64Decode(card.avatarBase64);
    expect(avatarBytes, isNotNull);
    expect(avatarBytes, hasLength(greaterThan(8)));
    expect(avatarBytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('can skip base64-encoding the whole PNG for the import UI', () {
    final json = jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {'name': 'Pixel'},
    });
    final png = buildPngWithText('ccv3', base64.encode(utf8.encode(json)));

    // 导入 UI 直接拿原始字节缩图,不再让 importer 把整张 20MB PNG 编码成
    // base64(随后又解码)—— 省两遍大拷贝与峰值内存。
    final card = CharacterCardImporter.fromBytes(
      png,
      includePngImageAsAvatar: false,
    );
    expect(card.name, 'Pixel');
    expect(card.avatarBase64, isNull);

    // 默认行为保持不变(测试/其它调用方仍拿"PNG 即头像")。
    expect(CharacterCardImporter.fromBytes(png).avatarBase64, isNotNull);
    expect(CharacterCardImporter.isPng(png), isTrue);
    expect(CharacterCardImporter.isPng(utf8.encode('{"name":"x"}')), isFalse);
  });

  test('keeps a JSON data.avatar over the PNG image', () {
    const tinyB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC';
    final json = jsonEncode({
      'spec': 'chara_card_v2',
      'data': {'name': 'J', 'avatar': tinyB64},
    });
    final png = buildPngWithText('chara', base64.encode(utf8.encode(json)));
    final card = CharacterCardImporter.fromBytes(png);
    expect(card.avatarBase64, tinyB64);
  });

  test('imports from plain JSON string', () {
    final card = CharacterCardImporter.fromJsonString('{"name":"Bob","personality":"calm"}');
    expect(card.name, 'Bob');
    expect(card.personality, 'calm');
  });

  test('decodeCharaPayload tolerates whitespace, url-safe base64, and direct JSON', () {
    final json = '{"name":"艾拉"}';
    final spaced = '  ${base64.encode(utf8.encode(json))}\n';
    expect(CharacterCardImporter.decodeCharaPayload(spaced), json);

    final urlSafe = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    expect(CharacterCardImporter.decodeCharaPayload(urlSafe), json);

    expect(CharacterCardImporter.decodeCharaPayload('{\n"name": "艾拉"\n}'), '{\n"name": "艾拉"\n}');
  });

  test('V2 envelope uses data, V1 flat with residual data uses the flat top level', () {
    final v2 = CharacterCardImporter.fromJsonString(
      '{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"艾拉","personality":"冷静"}}',
    );
    expect(v2.name, '艾拉');
    expect(v2.personality, '冷静');

    // V1 升级残留 data:按 ST 校验顺序仍读扁平顶层。
    final v1 = CharacterCardImporter.fromJsonString('{"name":"旧版","personality":"顶层","data":{"name":"嵌套版"}}');
    expect(v1.name, '旧版');
    expect(v1.personality, '顶层');
  });

  test('imports the full V2 field set incl. extensions and character_book', () {
    final card = CharacterCardImporter.fromJsonString(jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '艾拉',
        'description': '图书管理员',
        'personality': '冷静',
        'scenario': '星辉港',
        'first_mes': '你好。',
        'mes_example': '<START>',
        'system_prompt': '你是图书管理员。',
        'post_history_instructions': '不提密室。',
        'creator_notes': '作者注',
        'alternate_greetings': ['早上好。', '又见面了。'],
        'tags': ['奇幻', '图书馆'],
        'creator': 'anonymous',
        'character_version': '1.2',
        'extensions': {
          'talkativeness': 0.7,
          'fav': true,
          'depth_prompt': {'depth': 4, 'prompt': '[写环境描写]', 'role': 'system'},
        },
        'character_book': {
          'entries': [
            {'keys': ['图书馆'], 'content': '图书馆地下有密室。', 'constant': false},
          ],
        },
      },
    }));
    expect(card.name, '艾拉');
    expect(card.alternateGreetings, ['早上好。', '又见面了。']);
    expect(card.tags, ['奇幻', '图书馆']);
    expect(card.creator, 'anonymous');
    expect(card.characterVersion, '1.2');
    expect(card.talkativeness, '0.7');
    expect(card.fav, isTrue);
    expect(card.depthPrompt, '[写环境描写]');
    // 世界书独立提取(WorldbookImporter),不占卡片字段。
    final entries = WorldbookImporter.extract(card);
    expect(entries.single.keys, ['图书馆']);
    expect(entries.single.content, '图书馆地下有密室。');
  });

  test('imports V1 flat card with creatorcomment and string tags', () {
    final card = CharacterCardImporter.fromJsonString(
      jsonEncode({
        'name': '老卡',
        'description': 'd',
        'personality': 'p',
        'scenario': 's',
        'first_mes': 'f',
        'mes_example': 'm',
        'creatorcomment': 'V1 作者注',
        'tags': '奇幻, 冒险',
        'talkativeness': 0.6,
        'fav': true,
      }),
    );
    expect(card.creatorNotes, 'V1 作者注');
    expect(card.tags, ['奇幻', '冒险']);
    expect(card.talkativeness, '0.6');
    // V1 fav 顶层布尔,直接解析。
    expect(card.fav, isTrue);
  });

  test('imports RP-Hub style data envelope without spec', () {
    final card = CharacterCardImporter.fromJsonString(
      jsonEncode({
        'data': {
          'name': 'RP 角色',
          'personality': '开朗',
          'extensions': {'rp_hub_watermark': 'rp-hub'},
        },
      }),
    );
    expect(card.name, 'RP 角色');
    expect(card.personality, '开朗');
  });
}
