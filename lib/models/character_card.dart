/// 角色卡领域模型:ST V1/V2/V3 兼容字段、角色卡 extension 与落库序列化。
///
/// 序列化分三种口径,不可混用:
/// - [CharacterCard.toJson]:内存/导入后的完整卡(可含短暂导入头像);
/// - [CharacterCard.toStorageJson]:落库用,剥掉内嵌头像与 V3 data-image URI;
/// - [CharacterCard.toExportJson]:导出用,仅由调用方显式传入头像 base64。
///
/// 运行态头像与背景只保存文件资产 SHA-256;base64 不允许进入仓储与制卡主链路。
library;

import 'bubble_style.dart';

const Object _unchangedImage = Object();

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

  /// 首条开场白。新会话只在该角色没有其它可选开场白时自动把它作为助手
  /// 首条消息落库;有多条时留空会话,由用户在空态选择。
  final String firstMessage;

  /// 对话示例(`mes_example`),进入主写 system 的示例段。
  final String mesExample;

  /// 角色卡自带 system 提示词,与全局预设按组装规则合并。
  final String systemPrompt;

  /// 剧情后注,置于历史之后、生成之前。
  final String postHistoryInstructions;

  /// 作者备注;V1 兼容 `creatorcomment`。
  final String creatorNotes;

  /// 头像文件资产 SHA-256;字节由 ImageAssetStore 管理。
  final String? avatarHash;

  /// 角色卡专属聊天背景文件资产 SHA-256;未设置时开启背景回退头像。
  final String? backgroundHash;

  /// 第三方卡 JSON/PNG 导入边界上的短暂头像 base64。
  ///
  /// 仓储加载的卡与 AI 制卡链路始终为 null;保存前必须缩图并资产化为
  /// [avatarHash]。该字段只用于兼容外部角色卡协议,不是运行态图片存储。
  final String? importedAvatarBase64;

  /// 备用开场白(ST V2 `alternate_greetings`)。导入时兼容数组与单字符串两种
  /// 形态(部分第三方导出工具把数组写成字符串);新建/编辑角色时逐行录入。
  final List<String> alternateGreetings;

  /// 是否有多条不同的非空开场白(主开场白 + 备用,去空去重)。
  ///
  /// 新建会话据此决定是否自动落入 `firstMessage`:只有一条时保持自动起笔;
  /// 有多条时留空会话,由用户在空态选择。选择只体现在该会话的消息里,
  /// 不写任何跨会话状态。
  bool get hasMultipleGreetings {
    final seen = <String>{};
    for (final raw in [firstMessage, ...alternateGreetings]) {
      final text = raw.trim();
      if (text.isNotEmpty) seen.add(text);
    }
    return seen.length > 1;
  }

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
    this.avatarHash,
    this.backgroundHash,
    this.importedAvatarBase64,
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
      creatorNotes: creatorNotes.isEmpty
          ? _str(d, 'creatorcomment')
          : creatorNotes,
      importedAvatarBase64: _importedAvatar(d),
      alternateGreetings: _strArray(d, 'alternate_greetings'),
      tags: _strTags(d, 'tags'),
      creator: _str(d, 'creator'),
      characterVersion: _str(d, 'character_version'),
      // talkativeness:V1 在顶层,V2/V3 在 data.extensions;两处都读。
      talkativeness: _str(d, 'talkativeness').isEmpty
          ? _ext(d, 'talkativeness')
          : _str(d, 'talkativeness'),
      // fav:V1 顶层,V2/V3 在 extensions;两处都读。
      fav: _extBool(d, 'fav') || d['fav'] == true,
      // depth_prompt:extensions.depth_prompt = {depth, prompt, role};仅接受
      // 字符串 prompt,缺失/非字符串回落空串 —— 对 null 调 toString() 会把
      // 字符串 "null" 当成真实提示词写回导出。
      depthPrompt: _extNestedStr(d, 'depth_prompt', 'prompt'),
      // MicroScritt 私有:角色级气泡样式(extensions.microscritt_bubble_style)。
      bubbleStyle: _extBubbleStyle(d),
      raw: json,
    );
  }

  /// 从仓储 data_json 读取;即使历史/手工数据残留内嵌图片,也不带进运行态。
  factory CharacterCard.fromStorageJson(Map<String, dynamic> json) =>
      CharacterCard.fromJson(_withoutEmbeddedImages(json));

  static String? _importedAvatar(Map<String, dynamic> d) {
    final direct = d['avatar'];
    if (direct is String) return direct;
    final assets = d['assets'];
    if (assets is! List) return null;
    String? fallback;
    for (final item in assets) {
      if (item is! Map<String, dynamic>) continue;
      final uri = item['uri'];
      if (uri is! String || !_isDataImageUri(uri)) continue;
      if (item['type'] == 'icon' && item['name'] == 'main') return uri;
      fallback ??= uri;
    }
    return fallback;
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

  /// `extensions.<key>.<field>` 字符串提取;只接受字符串,缺失/其它类型为空串。
  static String _extNestedStr(
    Map<String, dynamic> d,
    String key,
    String field,
  ) {
    final value = _extMap(d, key)?[field];
    return value is String ? value.trim() : '';
  }

  /// 数组字段提取;兼容单字符串形态(部分第三方导出工具把 alternate_greetings
  /// 写成字符串,而非数组);新建/编辑角色时逐行录入。
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

  /// 卡内没有头像时用 [hash] 回填;已有资产或待资产化导入头像时保持原样。
  CharacterCard withAvatar(String? hash) =>
      hash == null || avatarHash != null || importedAvatarBase64 != null
      ? this
      : _copyImages(avatarHash: hash);

  /// 卡内没有背景资产时用 [hash] 回填,已有背景则保持原样。
  CharacterCard withBackground(String? hash) =>
      hash == null || backgroundHash != null
      ? this
      : _copyImages(backgroundHash: hash);

  /// 替换原始 JSON 信封(raw),建模字段与图片引用保持不变。
  CharacterCard withRaw(Map<String, dynamic> raw) => CharacterCard(
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    mesExample: mesExample,
    systemPrompt: systemPrompt,
    postHistoryInstructions: postHistoryInstructions,
    creatorNotes: creatorNotes,
    avatarHash: avatarHash,
    backgroundHash: backgroundHash,
    importedAvatarBase64: importedAvatarBase64,
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

  /// 无条件替换头像资产;同时丢弃尚未资产化的导入 base64。
  CharacterCard replacingAvatar(String? hash) =>
      _copyImages(avatarHash: hash, clearImportedAvatar: true);

  /// 无条件替换背景资产。
  CharacterCard replacingBackground(String? hash) =>
      _copyImages(backgroundHash: hash);

  /// 仅在外部角色卡导入边界设置/清理短暂 base64,不改变已有资产 hash。
  CharacterCard replacingImportedAvatar(String? base64) => CharacterCard(
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    mesExample: mesExample,
    systemPrompt: systemPrompt,
    postHistoryInstructions: postHistoryInstructions,
    creatorNotes: creatorNotes,
    avatarHash: avatarHash,
    backgroundHash: backgroundHash,
    importedAvatarBase64: base64,
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

  CharacterCard _copyImages({
    Object? avatarHash = _unchangedImage,
    Object? backgroundHash = _unchangedImage,
    bool clearImportedAvatar = false,
  }) => CharacterCard(
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    mesExample: mesExample,
    systemPrompt: systemPrompt,
    postHistoryInstructions: postHistoryInstructions,
    creatorNotes: creatorNotes,
    avatarHash: identical(avatarHash, _unchangedImage)
        ? this.avatarHash
        : avatarHash as String?,
    backgroundHash: identical(backgroundHash, _unchangedImage)
        ? this.backgroundHash
        : backgroundHash as String?,
    importedAvatarBase64: clearImportedAvatar ? null : importedAvatarBase64,
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
          // 只有外部导入暂存值可进入完整卡 JSON;资产 hash 不是 ST avatar 协议。
          if (importedAvatarBase64 != null) 'avatar': importedAvatarBase64,
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
      (bubbleStyle != null && !bubbleStyle!.isDefault) ||
      depthPrompt.isNotEmpty ||
      fav;

  /// 把当前可编辑字段合并进 raw 副本;信封、世界书和未知扩展原样保留。
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

  /// data_json 落库用:剥掉顶层/信封 avatar 与标准 V3 assets 的 data-image URI。
  /// 图片字节只由文件资产库保存;远程 assets URI 与未知扩展不做盲目改写。
  Map<String, dynamic> toStorageJson() => _withoutEmbeddedImages(toJson());

  static Map<String, dynamic> _withoutEmbeddedImages(
    Map<String, dynamic> json,
  ) {
    Map<String, dynamic> clean(Map<String, dynamic> source) {
      final out = <String, dynamic>{...source}..remove('avatar');
      final assets = out['assets'];
      if (assets is List) {
        out['assets'] = [
          for (final item in assets)
            if (item is Map<String, dynamic> && _isDataImageUri(item['uri']))
              <String, dynamic>{...item}..remove('uri')
            else
              item,
        ];
      }
      return out;
    }

    final copy = clean(json);
    final data = json['data'];
    if (data is Map<String, dynamic>) copy['data'] = clean(data);
    return copy;
  }

  static bool _isDataImageUri(Object? value) =>
      value is String &&
      value.trimLeft().toLowerCase().startsWith('data:image/');

  /// 导出用序列化:不自动读取或补回 base64。
  ///
  /// 调用方只有在导出边界显式传入 [avatarBase64] 时,才为缺少内嵌头像的卡
  /// 写入 `avatar`/`data.avatar`;文件资产 hash 永不序列化成 ST 图片字段。
  Map<String, dynamic> toExportJson({String? avatarBase64}) {
    final json = toJson();
    final data = json['data'];
    final hasAvatar =
        json['avatar'] != null ||
        (data is Map<String, dynamic> && data['avatar'] != null);
    if (hasAvatar || avatarBase64 == null || avatarBase64.isEmpty) return json;
    if (data is Map<String, dynamic>) {
      return <String, dynamic>{
        ...json,
        'data': <String, dynamic>{...data, 'avatar': avatarBase64},
      };
    }
    return <String, dynamic>{...json, 'avatar': avatarBase64};
  }
}
