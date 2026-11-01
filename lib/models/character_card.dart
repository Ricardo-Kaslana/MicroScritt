/// 角色卡领域模型:ST V1/V2/V3 兼容字段、角色卡 extension 与落库序列化。
///
/// 序列化分三种口径,不可混用:
/// - [CharacterCard.toJson]:内存/导入后的完整卡(可能内嵌头像);
/// - [CharacterCard.toStorageJson]:落库用,剥掉内嵌头像,避免单行超过
///   Android SQLite 的 CursorWindow 上限;
/// - [CharacterCard.toExportJson]:导出用,把列里的头像补回卡 JSON。
///
/// 头像与背景图始终以 `avatar_base64` / `background_base64` 列为主存储,
/// 卡 JSON 内的同名字段只作为导入来源与导出还原。
library;

import 'bubble_style.dart';

/// 角色卡(不可变);未知字段保存在 [raw] 中,导出时原样透传。
class CharacterCard {
  /// 角色名。V2/V3 从 `data.name` 读取,V1 兼容 `char_name` 回退。
  final String name;

  /// 角色描述,进入主写 system 的角色段。
  final String description;

  /// 性格设定,进入主写 system 的角色段。
  final String personality;

  /// 场景设定,进入主写 system 的角色段。
  final String scenario;

  /// 首条开场白,新建会话时作为助手首条消息落库。
  final String firstMessage;

  /// 对话示例(`mes_example`),进入主写 system 的示例段。
  final String mesExample;

  /// 角色卡自带 system 提示词,与全局预设按组装规则合并。
  final String systemPrompt;

  /// 剧情后注,置于历史之后、生成之前。
  final String postHistoryInstructions;

  /// 作者备注;V1 兼容 `creatorcomment`。
  final String creatorNotes;

  /// 内嵌头像(base64);落库时剥离,读取时由 `avatar_base64` 列回填。
  final String? avatarBase64;

  /// 角色卡专属聊天背景图(base64)。未设置时为 null,开启背景后回退头像。
  /// 持久化在 characters.background_base64 列(不塞进角色卡 JSON)。
  final String? backgroundBase64;

  /// 备用开场白(ST V2 `alternate_greetings`)。导入时兼容数组与单字符串两种
  /// 形态(部分第三方导出工具把数组写成字符串);新建/编辑角色时逐行录入。
  final List<String> alternateGreetings;

  /// 标签(ST `tags`)。导入时兼容数组与中英文逗号分隔字符串(V1 时代形态)。
  final List<String> tags;

  /// 作者(ST `creator`)。
  final String creator;

  /// 角色卡版本(ST `character_version`,卡作者自定的迭代号)。
  final String characterVersion;

  /// 话痨度(ST V1 顶层或 V2/V3 `extensions.talkativeness`)。仅元数据,不进上下文。
  final String talkativeness;

  /// 收藏标记(ST V1 顶层或 V2/V3 `extensions.fav`)。仅元数据,不进上下文。
  final bool fav;

  /// 深度提示(ST `extensions.depth_prompt.prompt`)。仅保存,不参与上下文组装。
  final String depthPrompt;

  /// 角色级气泡样式(MicroScritt 私有,存 `extensions.microscritt_bubble_style`;
  /// 仅定制助手气泡外观,不进上下文)。null/默认 = 应用统一样式。
  final BubbleStyle? bubbleStyle;

  /// 导入时的原始 JSON(含第三方 extensions 与 `character_book` 等未知字段)。
  /// 导出/落库时以副本合并当前可编辑字段,保证不丢失外部数据。
  final Map<String, dynamic> raw;

  const CharacterCard({
    this.name = '',
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMessage = '',
    this.mesExample = '',
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    this.creatorNotes = '',
    this.avatarBase64,
    this.backgroundBase64,
    this.alternateGreetings = const [],
    this.tags = const [],
    this.creator = '',
    this.characterVersion = '',
    this.talkativeness = '',
    this.fav = false,
    this.depthPrompt = '',
    this.bubbleStyle,
    this.raw = const {},
  });

  factory CharacterCard.fromJson(Map<String, dynamic> json) {
    final d = fieldData(json);
    final name = _str(d, 'name');
    final creatorNotes = _str(d, 'creator_notes');
    return CharacterCard(
      name: name.isEmpty ? _str(d, 'char_name') : name,
      description: _str(d, 'description'),
      personality: _str(d, 'personality'),
      scenario: _str(d, 'scenario'),
      firstMessage: _str(d, 'first_mes'),
      mesExample: _str(d, 'mes_example'),
      systemPrompt: _str(d, 'system_prompt'),
      postHistoryInstructions: _str(d, 'post_history_instructions'),
      // V1 用 creatorcomment 表示作者备注,V2/V3 是 creator_notes——空则回退。
      creatorNotes: creatorNotes.isEmpty ? _str(d, 'creatorcomment') : creatorNotes,
      avatarBase64: d['avatar'] is String ? d['avatar'] as String : null,
      alternateGreetings: _strArray(d, 'alternate_greetings'),
      tags: _strTags(d, 'tags'),
      creator: _str(d, 'creator'),
      characterVersion: _str(d, 'character_version'),
      // talkativeness:V1 在顶层,V2/V3 在 data.extensions;两处都读。
      talkativeness: _str(d, 'talkativeness').isEmpty ? _ext(d, 'talkativeness') : _str(d, 'talkativeness'),
      // fav:V1 顶层,V2/V3 在 extensions;两处都读。
      fav: _extBool(d, 'fav') || d['fav'] == true,
      // depth_prompt:extensions.depth_prompt = {depth, prompt, role};prompt 为空视为无。
      depthPrompt: _extMap(d, 'depth_prompt')?['prompt'].toString().trim() ?? '',
      // MicroScritt 私有:角色级气泡样式(extensions.microscritt_bubble_style)。
      bubbleStyle: _extBubbleStyle(d),
      raw: json,
    );
  }

  /// `extensions.microscritt_bubble_style` 不存在或损坏时返回 null(默认样式)。
  static BubbleStyle? _extBubbleStyle(Map<String, dynamic> d) {
    final m = _extMap(d, 'microscritt_bubble_style');
    if (m == null) return null;
    try {
      final s = BubbleStyle.fromJson(m);
      return s.isDefault ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// 字段源对象:V2/V3 与部分第三方工具用 `data` 信封;扁平 V1 用顶层。
  /// 顶层有 `spec`(V2/V3),或顶层无 name 而 `data` 对象存在(未标记信封)
  /// → 用 `data`;否则用顶层(V1 扁平,含 V1 升级残留 `data` 的老卡)。
  static Map<String, dynamic> fieldData(Map<String, dynamic> json) {
    final hasSpec = json['spec'] != null;
    final topName = (json['name'] ?? '').toString();
    final hasData = json['data'] is Map<String, dynamic>;
    if (hasData && (hasSpec || topName.isEmpty)) {
      return json['data'] as Map<String, dynamic>;
    }
    return json;
  }

  /// 字符串值提取;数字/布尔转字符串(容忍第三方工具的非规范类型),null/缺失返回空串。
  static String _str(Map<String, dynamic> d, String key) {
    final v = d[key];
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return '';
  }

  /// `extensions.<key>` 字符串提取(V2/V3 把 talkativeness 等放 data.extensions)。
  static String _ext(Map<String, dynamic> d, String key) {
    final e = d['extensions'];
    if (e is Map<String, dynamic>) return _str(e, key);
    return '';
  }

  /// `extensions.<key>` 布尔提取(fav 等)。
  static bool _extBool(Map<String, dynamic> d, String key) {
    final e = d['extensions'];
    return e is Map<String, dynamic> && e[key] == true;
  }

  /// `extensions.<key>` 对象提取(depth_prompt 等)。
  static Map<String, dynamic>? _extMap(Map<String, dynamic> d, String key) {
    final e = d['extensions'];
    if (e is Map<String, dynamic> && e[key] is Map<String, dynamic>) {
      return e[key] as Map<String, dynamic>;
    }
    return null;
  }

  /// 数组字段提取;兼容单字符串形态(部分第三方导出工具把 alternate_greetings
  /// 写成字符串,而非数组)。
  static List<String> _strArray(Map<String, dynamic> d, String key) {
    final v = d[key];
    if (v is List) {
      return v.whereType<String>().toList();
    }
    if (v is String) return [v];
    return const [];
  }

  /// tags 提取:数组 / 逗号(中英文)分隔字符串,其余返回空。兼容 V1 时代的字符串 tags。
  static List<String> _strTags(Map<String, dynamic> d, String key) {
    final v = d[key];
    if (v is List) return v.whereType<String>().toList();
    if (v is String) {
      return v
          .split(RegExp(r'[，,]'))
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// 卡内没有头像时用 [avatar] 回填,已有头像则保持原样。
  /// 用于读取 `characters.avatar_base64` 列后把头像补回内存卡。
  CharacterCard withAvatar(String? avatar) => avatar == null || avatarBase64 != null
      ? this
      : CharacterCard(
          name: name,
          description: description,
          personality: personality,
          scenario: scenario,
          firstMessage: firstMessage,
          mesExample: mesExample,
          systemPrompt: systemPrompt,
          postHistoryInstructions: postHistoryInstructions,
          creatorNotes: creatorNotes,
          avatarBase64: avatar,
          backgroundBase64: backgroundBase64,
          alternateGreetings: alternateGreetings,
          tags: tags,
          creator: creator,
          characterVersion: characterVersion,
          talkativeness: talkativeness,
          fav: fav,
          depthPrompt: depthPrompt,
          bubbleStyle: bubbleStyle,
          raw: raw,
        );

  /// 卡内没有背景图时用 [background] 回填,已有背景图则保持原样。
  /// 用于读取 `characters.background_base64` 列后把背景补回内存卡。
  CharacterCard withBackground(String? background) => background == null || backgroundBase64 != null
      ? this
      : CharacterCard(
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
          backgroundBase64: background,
          alternateGreetings: alternateGreetings,
          tags: tags,
          creator: creator,
          characterVersion: characterVersion,
          talkativeness: talkativeness,
          fav: fav,
          depthPrompt: depthPrompt,
          bubbleStyle: bubbleStyle,
          raw: raw,
        );

  /// **强制**替换头像(导入缩图用):[withAvatar] 只在卡原本无头像时回填,这里
  /// 无条件覆盖 —— 大卡整张 PNG 作头像会撑爆 Android CursorWindow,导入时
  /// 必须把头像换成缩图,不换就会存回整张超大 base64。
  CharacterCard replacingAvatar(String? avatar) => CharacterCard(
        name: name,
        description: description,
        personality: personality,
        scenario: scenario,
        firstMessage: firstMessage,
        mesExample: mesExample,
        systemPrompt: systemPrompt,
        postHistoryInstructions: postHistoryInstructions,
        creatorNotes: creatorNotes,
        avatarBase64: avatar,
        backgroundBase64: backgroundBase64,
        alternateGreetings: alternateGreetings,
        tags: tags,
        creator: creator,
        characterVersion: characterVersion,
        talkativeness: talkativeness,
        fav: fav,
        depthPrompt: depthPrompt,
        bubbleStyle: bubbleStyle,
        raw: raw,
      );

  /// **强制**替换背景(导入缩图用),语义同 [replacingAvatar]。
  CharacterCard replacingBackground(String? background) => CharacterCard(
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
        backgroundBase64: background,
        alternateGreetings: alternateGreetings,
        tags: tags,
        creator: creator,
        characterVersion: characterVersion,
        talkativeness: talkativeness,
        fav: fav,
        depthPrompt: depthPrompt,
        bubbleStyle: bubbleStyle,
        raw: raw,
      );

  Map<String, dynamic> toJson() => raw.isEmpty
      ? {
          'name': name,
          'description': description,
          'personality': personality,
          'scenario': scenario,
          'first_mes': firstMessage,
          'mes_example': mesExample,
          'system_prompt': systemPrompt,
          'post_history_instructions': postHistoryInstructions,
          'creator_notes': creatorNotes,
          'alternate_greetings': alternateGreetings,
          'tags': tags,
          'creator': creator,
          'character_version': characterVersion,
          'talkativeness': talkativeness,
          // 手动构建/编辑的卡也要带 avatar,否则编辑保存或导出后头像丢失
          // (导入的卡 raw 非空,直接沿用原数据)。
          if (avatarBase64 != null) 'avatar': avatarBase64,
          // extensions:气泡样式(MicroScritt 私有)/深度提示/收藏标记 —— V2/V3
          // 规范把它们放 extensions,顶层 fav 属 V1 形态且严格的跨端解析器不认。
          if (_needsExtensions())
            'extensions': {
              if (bubbleStyle != null && !bubbleStyle!.isDefault)
                'microscritt_bubble_style': bubbleStyle!.toJson(),
              if (depthPrompt.isNotEmpty)
                'depth_prompt': {'prompt': depthPrompt},
              if (fav) 'fav': true,
            },
        }
      : _mergedRaw();

  bool _needsExtensions() =>
      (bubbleStyle != null && !bubbleStyle!.isDefault) || depthPrompt.isNotEmpty || fav;

  /// 把(可能已被编辑的)当前字段合并进 raw 副本再导出/落库 —— 此前 raw 原样
  /// 透传,编辑过的字段无法反映到 raw,编辑页为求字段生效只能丢弃 raw,导致
  /// V2/V3 信封降级成 V1 扁平、character_book 与未知 extensions 全丢。合并只
  /// 覆盖本应用可编辑的字段;信封结构(spec/data)、character_book、第三方
  /// extensions 键全部原样保留。始终在副本上操作,绝不改动原 raw。
  Map<String, dynamic> _mergedRaw() {
    final copy = <String, dynamic>{...raw};
    var target = copy;
    if (copy['data'] is Map<String, dynamic>) {
      target = <String, dynamic>{...(copy['data'] as Map<String, dynamic>)};
      copy['data'] = target;
    }
    void put(String key, Object? value) => target[key] = value;

    put('name', name);
    put('description', description);
    put('personality', personality);
    put('scenario', scenario);
    put('first_mes', firstMessage);
    put('mes_example', mesExample);
    put('system_prompt', systemPrompt);
    put('post_history_instructions', postHistoryInstructions);
    put('creator_notes', creatorNotes);
    put('alternate_greetings', alternateGreetings);
    put('tags', tags);
    put('creator', creator);
    put('character_version', characterVersion);
    put('talkativeness', talkativeness);

    final ext = target['extensions'] is Map<String, dynamic>
        ? <String, dynamic>{...(target['extensions'] as Map<String, dynamic>)}
        : <String, dynamic>{};
    if (talkativeness.isNotEmpty) ext['talkativeness'] = talkativeness;
    if (fav) ext['fav'] = true;
    if (depthPrompt.isNotEmpty) {
      // 保留既有 depth/role(若有),只覆写 prompt。
      final dp = ext['depth_prompt'] is Map<String, dynamic>
          ? <String, dynamic>{...(ext['depth_prompt'] as Map<String, dynamic>)}
          : <String, dynamic>{};
      dp['prompt'] = depthPrompt;
      ext['depth_prompt'] = dp;
    }
    if (bubbleStyle != null && !bubbleStyle!.isDefault) {
      ext['microscritt_bubble_style'] = bubbleStyle!.toJson();
    }
    if (ext.isNotEmpty) target['extensions'] = ext;
    return copy;
  }

  /// data_json 落库用序列化:与 [toJson] 相同,但**剥掉内嵌头像**(顶层 `avatar`
  /// 与信封 `data.avatar` 都剥)。头像只存 `avatar_base64` 列,读取时按 id 惰性
  /// 回填 —— 大卡原始 JSON 里内嵌整张 base64 头像(20MB 卡 ≈ 14MB base64)会
  /// 让 data_json 单行超过 Android SQLite 2MB CursorWindow,任何投影 data_json
  /// 的查询都抛 "Row too big to fit into CursorWindow",这就是"小卡正常、大卡
  /// 列表转圈/无法加载"的根因(桌面 FFI 直连 SQLite 无此上限)。背景图本就不进
  /// JSON(background_base64 列独立)。始终在副本上操作,绝不改动原 raw。
  Map<String, dynamic> toStorageJson() {
    final json = toJson();
    if (json['data'] is Map<String, dynamic>) {
      final data = json['data'] as Map<String, dynamic>;
      return <String, dynamic>{...json, 'data': <String, dynamic>{...data}..remove('avatar')}..remove('avatar');
    }
    return <String, dynamic>{...json}..remove('avatar');
  }

  /// 导出用序列化:与 [toJson] 相同,但 raw 缺头像时把列里的头像补回
  /// (data_json 落库已剥掉头像;导出到其它酒馆端必须还原,否则头像丢失)。
  /// raw 已带头像时原样保留(小卡导出仍带走原图)。只在副本上操作。
  Map<String, dynamic> toExportJson() {
    final json = toJson();
    final data = json['data'];
    final hasAvatar = json['avatar'] != null || (data is Map<String, dynamic> && data['avatar'] != null);
    if (hasAvatar || avatarBase64 == null) return json;
    if (data is Map<String, dynamic>) {
      return <String, dynamic>{...json, 'data': <String, dynamic>{...data, 'avatar': avatarBase64}};
    }
    return <String, dynamic>{...json, 'avatar': avatarBase64};
  }
}