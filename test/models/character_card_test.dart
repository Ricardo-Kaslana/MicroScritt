import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/bubble_style.dart';
import 'package:microscritt/models/character_card.dart';

void main() {
  test('normalizes SillyTavern V2 flat card', () {
    final card = CharacterCard.fromJson({
      'name': 'Alice',
      'description': 'A knight',
      'personality': 'Brave',
      'scenario': 'In a tavern',
      'first_mes': 'Hello.',
      'mes_example': '<START>...',
      'system_prompt': 'You are Alice.',
    });
    expect(card.name, 'Alice');
    expect(card.description, 'A knight');
    expect(card.personality, 'Brave');
    expect(card.scenario, 'In a tavern');
    expect(card.firstMessage, 'Hello.');
    expect(card.systemPrompt, 'You are Alice.');
  });

  test('normalizes V3 card wrapped in data', () {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v3',
      'data': {'name': 'Bob', 'description': 'A mage', 'personality': 'Wise'},
    });
    expect(card.name, 'Bob');
    expect(card.description, 'A mage');
    expect(card.personality, 'Wise');
  });

  test('toJson keeps the avatar for hand-built cards (round-trip)', () {
    const card = CharacterCard(name: 'Pixel', avatarBase64: 'aGVsbG8=');
    final json = card.toJson();
    expect(json['avatar'], 'aGVsbG8=');

    final reloaded = CharacterCard.fromJson(json);
    expect(reloaded.avatarBase64, 'aGVsbG8=');
  });

  test('toStorageJson strips the embedded avatar but keeps everything else', () {
    // 大卡原始 JSON 内嵌整张 base64 头像 —— 落库(data_json)必须剥掉,只存列。
    const avatar = 'QUFBQSE=';
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {'name': 'Big', 'description': 'huge', 'avatar': avatar, 'personality': 'calm'},
      'extensions': {'fav': true},
    });
    final stored = card.toStorageJson();
    final data = stored['data'] as Map<String, dynamic>;
    expect(data['avatar'], isNull);
    expect(data['name'], 'Big');
    expect(data['personality'], 'calm');
    expect(stored['extensions'], isNotNull); // 其它字段原样保留
    // 信封外顶层 avatar 也剥。
    final flat = CharacterCard.fromJson({'name': 'F', 'avatar': avatar}).toStorageJson();
    expect(flat['avatar'], isNull);
    expect(flat['name'], 'F');
  });

  test('toStorageJson never mutates the raw json', () {
    final raw = {
      'spec': 'chara_card_v2',
      'data': {'name': 'Big', 'avatar': 'QUFBQSE='},
    };
    final card = CharacterCard.fromJson(raw);
    card.toStorageJson();
    expect((raw['data'] as Map<String, dynamic>)['avatar'], 'QUFBQSE=');
    expect(raw['data'], isNot(same(card.toStorageJson()['data'])));
  });

  test('toExportJson re-injects the column avatar when raw has none', () {
    // data_json 落库已剥头像;导出必须把列里的头像补回,否则换端丢图。
    const avatar = 'aGVsbG8=';
    final flat = CharacterCard.fromJson({'name': 'Alice'}).withAvatar(avatar);
    expect(flat.toExportJson()['avatar'], avatar);
    // 信封卡注入到 data.avatar。
    final v2 = CharacterCard.fromJson({'spec': 'chara_card_v2', 'data': {'name': 'Alice'}}).withAvatar(avatar);
    final data = v2.toExportJson()['data'] as Map<String, dynamic>;
    expect(data['avatar'], avatar);
    // raw 已带头像时原样保留(小卡导出仍带走原图,不被列值覆盖)。
    const embedded = 'RU1CRURERUQ=';
    final withRaw = CharacterCard.fromJson({'name': 'Alice', 'avatar': embedded});
    expect(withRaw.toExportJson()['avatar'], embedded);
    // 无头像时不注入任何东西。
    expect(CharacterCard.fromJson({'name': 'Alice'}).toExportJson().containsKey('avatar'), isFalse);
  });

  test('withBackground fills in background without touching the avatar', () {
    const card = CharacterCard(name: 'Pixel', avatarBase64: 'aGVsbG8=');
    final filled = card.withBackground('Ymc=');
    expect(filled.backgroundBase64, 'Ymc=');
    expect(filled.avatarBase64, 'aGVsbG8=');
    // 已有背景时不覆盖。
    expect(const CharacterCard(name: 'x', backgroundBase64: 'explicit').withBackground('Ymc=').backgroundBase64,
        'explicit');
    // null 列值不覆盖已有背景(与 withAvatar 语义一致)。
    expect(const CharacterCard(name: 'x', backgroundBase64: 'explicit').withBackground(null).backgroundBase64,
        'explicit');
  });

  test('replacingAvatar overrides the avatar even when one already exists (import shrink)', () {
    // 回归防护「大卡导入缩图被丢弃」:with* 只在无头像时回填,而 PNG 卡头像
    // 本就有值 —— 若导入用 with* 会把缩图丢掉、仍存回整张超大 base64,导致
    // Android 读取 "Row too big"。replacingAvatar 必须无条件覆盖。
    const card = CharacterCard(name: 'Pixel', avatarBase64: 'BIG_AVATAR');
    final shrunk = card.replacingAvatar('SMALL_AVATAR');
    expect(shrunk.avatarBase64, 'SMALL_AVATAR');
    expect(shrunk.name, 'Pixel');
    // 其他字段保留。
    expect(const CharacterCard(name: 'Pixel', description: 'd', backgroundBase64: 'bg')
        .replacingAvatar('s')
        .backgroundBase64, 'bg');
    // replacingBackground 同理无条件覆盖。
    expect(const CharacterCard(name: 'x', backgroundBase64: 'old').replacingBackground('new').backgroundBase64, 'new');
  });

  test('parses full V2 fields incl. extensions (talkativeness/fav/depth_prompt)', () {
    final card = CharacterCard.fromJson({
      'spec': 'chara_card_v2',
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
      },
    });
    expect(card.name, '艾拉');
    expect(card.systemPrompt, '你是图书管理员。');
    expect(card.creatorNotes, '作者注');
    expect(card.alternateGreetings, ['早上好。', '又见面了。']);
    expect(card.tags, ['奇幻', '图书馆']);
    expect(card.creator, 'anonymous');
    expect(card.characterVersion, '1.2');
    expect(card.talkativeness, '0.7'); // 数字标量转字符串
    expect(card.fav, isTrue);
    expect(card.depthPrompt, '[写环境描写]');
  });

  test('V1 fallbacks: creatorcomment, string tags/alternate_greetings, char_name', () {
    final card = CharacterCard.fromJson({
      'char_name': '老卡',
      'creatorcomment': 'V1 作者注',
      'talkativeness': 0.5,
      'fav': true,
      'tags': '奇幻, 图书馆，冒险',
      'alternate_greetings': '单独一句备用开场',
    });
    expect(card.name, '老卡');
    expect(card.creatorNotes, 'V1 作者注');
    expect(card.tags, ['奇幻', '图书馆', '冒险']);
    expect(card.alternateGreetings, ['单独一句备用开场']);
    expect(card.talkativeness, '0.5');
    expect(card.fav, isTrue);
    // creator_notes 优先于 creatorcomment。
    final both = CharacterCard.fromJson({'name': 'x', 'creator_notes': 'v2注', 'creatorcomment': 'v1注'});
    expect(both.creatorNotes, 'v2注');
    // 非字符串 avatar 不抛异常。
    expect(CharacterCard.fromJson({'name': 'x', 'avatar': 42}).avatarBase64, isNull);
  });

  test('hand-built card toJson round-trips the new fields', () {
    const card = CharacterCard(
      name: 'A',
      alternateGreetings: ['g1', 'g2'],
      tags: ['t1', 't2'],
      creator: 'c',
      characterVersion: '2.0',
      talkativeness: '0.3',
      fav: true,
      depthPrompt: 'dp',
    );
    final reloaded = CharacterCard.fromJson(card.toJson());
    expect(reloaded.alternateGreetings, ['g1', 'g2']);
    expect(reloaded.tags, ['t1', 't2']);
    expect(reloaded.creator, 'c');
    expect(reloaded.characterVersion, '2.0');
    expect(reloaded.talkativeness, '0.3');
    expect(reloaded.fav, isTrue);
    expect(reloaded.postHistoryInstructions, isEmpty);
  });

  group('bubbleStyle', () {
    const styleJson = {
      'bubble_color': 0xFF283593,
      'text_color': 0xFFFFFFFF,
      'radius': 22.0,
      'opacity': 0.85,
    };

    test('parses from V2 envelope extensions', () {
      final card = CharacterCard.fromJson({
        'spec': 'chara_card_v2',
        'data': {
          'name': 'A',
          'extensions': {'microscritt_bubble_style': styleJson},
        },
      });
      expect(card.bubbleStyle?.bubbleColor, 0xFF283593);
      expect(card.bubbleStyle?.radius, 22);
      expect(card.bubbleStyle?.opacity, 0.85);
    });

    test('parses from flat card extensions; corrupt/missing values to null', () {
      final card = CharacterCard.fromJson({
        'name': 'B',
        'extensions': {'microscritt_bubble_style': styleJson},
      });
      expect(card.bubbleStyle?.textColor, 0xFFFFFFFF);

      final none = CharacterCard.fromJson({'name': 'C'});
      expect(none.bubbleStyle, isNull);

      final corrupt = CharacterCard.fromJson({
        'name': 'D',
        'extensions': {'microscritt_bubble_style': 'not-a-map'},
      });
      expect(corrupt.bubbleStyle, isNull);
    });

    test('default style (all defaults) parses to null', () {
      final card = CharacterCard.fromJson({
        'name': 'E',
        'extensions': {
          'microscritt_bubble_style': {'radius': 18.0, 'opacity': 1.0},
        },
      });
      expect(card.bubbleStyle, isNull);
    });

    test('built card serializes style into extensions and roundtrips', () {
      const card = CharacterCard(
        name: 'F',
        bubbleStyle: BubbleStyle(bubbleColor: 0xFF7B1F2B, radius: 24),
      );
      final json = card.toJson();
      expect(json['extensions']['microscritt_bubble_style'], isNotNull);
      final reloaded = CharacterCard.fromJson(json);
      expect(reloaded.bubbleStyle?.bubbleColor, 0xFF7B1F2B);
      expect(reloaded.bubbleStyle?.radius, 24);
    });

    test('raw card writes style into envelope copy without mutating raw', () {
      final raw = <String, dynamic>{
        'spec': 'chara_card_v2',
        'data': {
          'name': 'G',
          'extensions': {'talkativeness': '0.5'},
        },
      };
      final card = CharacterCard.fromJson(raw).withTestBubbleStyle();
      final json = card.toJson();
      expect(json['data']['extensions']['microscritt_bubble_style'],
          {'bubble_color': 0xFF00695C});
      // 原 raw 不被改动,且既有 extensions 字段保留。
      expect(json['data']['extensions']['talkativeness'], '0.5');
      expect(raw['data']!['extensions']!.containsKey('microscritt_bubble_style'), isFalse);
      // 序列化结果再读回仍是该样式。
      expect(CharacterCard.fromJson(json).bubbleStyle?.bubbleColor, 0xFF00695C);
    });

    test('edited fields merge into raw without losing the V2 envelope or character_book', () {
      final raw = <String, dynamic>{
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {
          'name': 'Alice',
          'description': 'old description',
          'extensions': {
            'depth_prompt': {'depth': 4, 'prompt': '旧深度提示', 'role': 'system'},
            'third_party': {'keep': true},
          },
          'character_book': {
            'entries': [
              {'keys': ['王都'], 'content': '王都的描述。'},
            ],
          },
        },
      };
      final card = CharacterCard.fromJson(raw);
      // 模拟编辑页:_buildCard 保留 raw,改描述、设收藏与深度提示。
      final edited = CharacterCard(
        name: card.name,
        description: 'edited description',
        firstMessage: card.firstMessage,
        mesExample: card.mesExample,
        talkativeness: card.talkativeness,
        fav: true,
        depthPrompt: '新的深度提示',
        raw: card.raw,
      );
      final json = edited.toJson();
      // 信封与第三方内容原样保留。
      expect(json['spec'], 'chara_card_v2');
      final data = json['data'] as Map<String, dynamic>;
      expect(data['character_book'], isNotNull);
      final ext = data['extensions'] as Map<String, dynamic>;
      expect((ext['third_party'] as Map)['keep'], true);
      // 编辑过的字段反映进导出。
      expect(data['description'], 'edited description');
      // depth_prompt 只覆写 prompt,保留既有 depth/role。
      final dp = ext['depth_prompt'] as Map<String, dynamic>;
      expect(dp['prompt'], '新的深度提示');
      expect(dp['depth'], 4);
      expect(dp['role'], 'system');
      expect(ext['fav'], true);
      // 原 raw 不被污染。
      expect(((raw['data'] as Map)['extensions'] as Map)['fav'], isNull);
    });

    test('empty-raw card exports depth_prompt and fav inside extensions', () {
      const card = CharacterCard(name: 'Alice', depthPrompt: '保持克制', fav: true);
      final json = card.toJson();
      expect(json.containsKey('fav'), isFalse, reason: '顶层 fav 属 V1 形态,严格 V2 解析器不认');
      final ext = json['extensions'] as Map<String, dynamic>;
      expect((ext['depth_prompt'] as Map)['prompt'], '保持克制');
      expect(ext['fav'], true);
    });
  });
}

extension on CharacterCard {
  /// 测试辅助:raw 原样保留 + 指定气泡样式(触发 toJson 的 raw 分支合并)。
  CharacterCard withTestBubbleStyle() => CharacterCard(
        name: name,
        description: description,
        personality: personality,
        scenario: scenario,
        firstMessage: firstMessage,
        mesExample: mesExample,
        systemPrompt: systemPrompt,
        postHistoryInstructions: postHistoryInstructions,
        creatorNotes: creatorNotes,
        avatarBase64: avatarBase64,
        backgroundBase64: backgroundBase64,
        alternateGreetings: alternateGreetings,
        tags: tags,
        creator: creator,
        characterVersion: characterVersion,
        talkativeness: talkativeness,
        fav: fav,
        depthPrompt: depthPrompt,
        bubbleStyle: const BubbleStyle(bubbleColor: 0xFF00695C),
        raw: raw,
      );
}
