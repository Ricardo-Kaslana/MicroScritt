import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../models/character_card.dart';
import '../models/worldbook_entry.dart';

/// 世界书条目导入。两个入口:
///
/// - [extract]:从角色卡提取世界书条目(ST/RP-Hub `character_book`);
/// - [fromBytes] / [fromJson]:导入**独立世界书文件** —— ST World Info
///   (`entries` 对象或数组)、纯条目数组、单个条目对象,以及角色卡 JSON
///   (自动取其中的 `character_book`,等价于 [extract])。与 [WorldbookExporter]
///   的 ST 形态互为逆运算,往返不丢建模字段。
///
/// 归一化规则对齐参考实现(Scritt `src-tauri/src/cards.rs::parse_character_book`):
/// - entries 来源容错:`character_book.entries` 数组 / `entries` 对象(Object.values)
///   / `character_book` 本身为数组(RP-Hub app.js 兼容读取);
/// - keys 兼容数组 / 单字符串 / `key` 字段(ST World Info 的 `key` 也是数组),
///   按 `,`/`，` 切分并去重,非字符串值转字符串;
/// - `enabled=false`(ST 卡)或 `disabled=true`/`disable=true`(旧式反布尔 /
///   ST World Info)的条目按停用状态保真导入(EF 批:旧实现直接丢弃,归档往返/
///   重导入一次就丢一条内容);
/// - 按格式原生排序字段(RP-Hub `order` / ST `insertion_order`,另一字段兜底)升序稳定排序;
/// - 匹配语义提取:`secondary_keys`/`keysecondary`/`selective`/`case_sensitive`/
///   `caseSensitive`(ST 直连字段)、`match_whole_words`(ST 存于条目 `extensions`,
///   两级读取)、`use_regex`/`useRegex`(RP-Hub camelCase,双拼写);
/// - 显示名:`comment`(ST 条目显示名)trim 后写入 `name`,空则不设(UI 回退首关键词),
///   对齐参考实现 Scritt src-core/lorebook.ts 的 LoreEntry.name。
/// - 未建模字段(EJ 批):ST 专有字段与 extensions 自定义键原样存入
///   `WorldbookEntry.extra`,导出时合并回 `character_book`,第三方消费端不丢字段。
/// 世界书自 v37 起不再有「规则/技能」类型之分:全部条目统一按关键词/常驻触发。
class WorldbookImporter {
  /// 从角色卡提取世界书条目(ST/RP-Hub `character_book` → 我们的世界书条目)。
  static List<WorldbookEntry> extract(CharacterCard card) {
    final raw = card.raw;
    if (raw.isEmpty) return const [];
    final data = CharacterCard.fieldData(raw);
    final book = data['character_book'] ?? raw['character_book'];
    if (book == null) return const [];
    return _parseBook(book, isRpHub: _isRpHub(data, raw));
  }

  /// 从文件字节导入独立世界书。
  ///
  /// 优先按 UTF-8 解码;非 UTF-8(部分工具导出的 GBK/Latin-1 文件)退回
  /// Latin-1 直译,至少让纯 ASCII 内容可读。JSON 解析失败抛 [FormatException]。
  static List<WorldbookEntry> fromBytes(Uint8List bytes) {
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = latin1.decode(bytes);
    }
    // UTF-8 BOM:部分 Windows 工具导出时带,直接 jsonDecode 会报错。
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('文件不是有效的 JSON');
    }
    return fromJson(decoded);
  }

  /// 从已解析的 JSON 导入独立世界书条目。
  ///
  /// 支持的形态(按序探测):
  /// - 条目数组 `[{...}, ...]`;
  /// - 角色卡 JSON(顶层或 `data` 信封里的 `character_book`);
  /// - 世界书对象 `{ "entries": {...} | [...] }`;
  /// - 单个条目对象 `{ "content": "...", ... }`。
  ///
  /// 与 [extract] 的「无书即空」不同,这里是文件导入入口:探测不到世界书、
  /// 或结果为空(条目内容全空)都抛 [FormatException],由调用方原样提示用户。
  static List<WorldbookEntry> fromJson(Object? decoded) {
    final List<WorldbookEntry> entries;
    if (decoded is List) {
      entries = _parseBook(decoded, isRpHub: false);
    } else if (decoded is Map<String, dynamic>) {
      final data = CharacterCard.fieldData(decoded);
      final book = data['character_book'] ?? decoded['character_book'];
      if (book != null) {
        entries = _parseBook(book, isRpHub: _isRpHub(data, decoded));
      } else if (decoded['entries'] != null) {
        entries = _parseBook(decoded, isRpHub: false);
      } else if (decoded['content'] != null) {
        entries = _parseItems([decoded], isRpHub: false);
      } else {
        throw const FormatException('未找到世界书条目(缺少 entries / character_book)');
      }
    } else {
      throw const FormatException('文件不是世界书 JSON(应为对象或数组)');
    }
    if (entries.isEmpty) {
      throw const FormatException('文件里没有可导入的世界书条目(内容为空)');
    }
    return entries;
  }

  /// 把导入条目并入现有条目,返回应整组落库的列表
  /// ([WorldbookRepository.replaceForCharacter] 的入参口径)。
  ///
  /// [replace] 为真时丢弃现有条目(整组替换);为假时追加到现有条目之后。
  /// 两种情况下导入条目的 `position` 都重排:追加时顺延到现有最大 position
  /// 之后 —— 否则它们会以 0..n 插进现有条目中间,列表顺序看着像被打乱;
  /// 替换时从 0 起排。现有条目自身的 position 原样保留(用户手填的值不动)。
  ///
  /// [imported] 为空时返回 [existing] 不变 —— "用空集合覆盖"是明确的破坏性
  /// 误操作(整本书被清空),这里按 no-op 处理,把判定留给调用方提示。
  static List<WorldbookEntry> mergeInto(
    List<WorldbookEntry> existing,
    List<WorldbookEntry> imported, {
    required bool replace,
  }) {
    if (imported.isEmpty) return existing;
    final base = replace || existing.isEmpty ? 0 : existing.map((e) => e.position).reduce(max) + 1;
    return [
      if (!replace) ...existing,
      for (final (i, e) in imported.indexed) e.copyWith(position: base + i),
    ];
  }

  /// 解析「书」容器:数组本身、或含 `entries` 的对象(数组 / Object.values 两形态)。
  static List<WorldbookEntry> _parseBook(Object? book, {required bool isRpHub}) {
    final Object? rawEntries;
    if (book is List) {
      // `character_book` 本身为数组(RP-Hub 容错形态)。
      rawEntries = book;
    } else if (book is Map<String, dynamic>) {
      rawEntries = book['entries'];
    } else {
      return const [];
    }
    final items = <Map<String, dynamic>>[];
    if (rawEntries is List) {
      for (final e in rawEntries) {
        if (e is Map<String, dynamic>) items.add(e);
      }
    } else if (rawEntries is Map<String, dynamic>) {
      // `entries` 为对象(Object.values)。
      items.addAll(rawEntries.values.whereType<Map<String, dynamic>>());
    }
    return _parseItems(items, isRpHub: isRpHub);
  }

  /// 条目列表归一化 + 稳定排序。排序键按来源格式选择:RP-Hub 条目用 `order`
  /// (无 insertion_order),ST(V1/V2/V3 卡)用 `insertion_order`;另一字段兜底。
  static List<WorldbookEntry> _parseItems(List<Map<String, dynamic>> items, {required bool isRpHub}) {
    if (items.isEmpty) return const [];
    final primaryOrder = isRpHub ? 'order' : 'insertion_order';
    final fallbackOrder = isRpHub ? 'insertion_order' : 'order';

    final indexed = <(int, Map<String, dynamic>)>[];
    for (final (i, item) in items.indexed) {
      final content = (item['content'] ?? '').toString();
      if (content.trim().isEmpty) continue;
      // 停用条目不再丢弃(EF 批):照原 enabled 状态导入 —— 引擎本就不注入
      // 停用条目,行为等价,而内容不再在"导出→导入"或重导入一次后凭空丢失。
      // 无关键词且非常驻的条目同样保留(引擎永不触发,纯惰性数据),避免
      // 第三方卡里"占位草稿条目"被静默裁剪。
      indexed.add((i, item));
    }
    // 稳定排序:同 order 保持原始条目序。
    indexed.sort((a, b) {
      final oa = _orderOf(a.$2, primaryOrder, fallbackOrder);
      final ob = _orderOf(b.$2, primaryOrder, fallbackOrder);
      final byOrder = oa.compareTo(ob);
      return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
    });

    return [for (final (i, (_, item)) in indexed.indexed) _entry(item, i)];
  }

  /// 提取条目里我们**未建模**的字段(EJ 批,存 WorldbookEntry.extra):
  /// ST 专有的 position/probability/selectiveLogic/role/depth/递归标志等与
  /// `extensions` 里的自定义键。建模字段剥离 —— 导出时由建模状态重新生成、
  /// 必须以库中现值为准;sort 用的 order/insertion_order 也剥离(导入时已
  /// 折算为 position 序号,导出按现值重写)。
  static Map<String, dynamic> _extraOf(Map<String, dynamic> item) {
    const modeled = {
      'comment', 'name', 'keys', 'key', 'content', 'enabled', 'disabled',
      'disable', 'constant', 'insertion_order', 'order', 'case_sensitive',
      'caseSensitive', 'selective', 'secondary_keys', 'secondary_key',
      'keysecondary', 'use_regex', 'useRegex', 'extensions',
      'match_whole_words', 'matchWholeWords', 'background', 'uid',
    };
    final rest = <String, dynamic>{for (final e in item.entries) if (!modeled.contains(e.key)) e.key: e.value};
    final ext = item['extensions'];
    if (ext is Map<String, dynamic>) {
      // extensions 里只有 match_whole_words 被建模,其余自定义键照留。
      const modeledExt = {'match_whole_words', 'matchWholeWords'};
      final restExt = {
        for (final e in ext.entries) if (!modeledExt.contains(e.key)) e.key: e.value,
      };
      if (restExt.isNotEmpty) rest['extensions'] = restExt;
    }
    return rest;
  }

  static WorldbookEntry _entry(Map<String, dynamic> item, int position) {
    final secondaryKeys = _strArrayValue(item, 'secondary_keys', alt: 'keysecondary');
    return WorldbookEntry(
      characterId: 0, // set by the repository on insert
      name: (item['comment'] ?? '').toString().trim(),
      keys: _parseKeys(item),
      useRegex: item['use_regex'] == true || item['useRegex'] == true,
      caseSensitive: item['case_sensitive'] == true || item['caseSensitive'] == true,
      matchWholeWords: _extBool(item, 'match_whole_words') ||
          item['match_whole_words'] == true ||
          item['matchWholeWords'] == true,
      selective: item['selective'] == true,
      secondaryKeys: secondaryKeys,
      constant: item['constant'] == true,
      // 后台锚定选择:本端导出带 `background` 时以它为准(往返保真);
      // 第三方卡没有该字段时回退按常驻初始化(与本端 v52 迁移的同款口径)
      // —— 导入即获得与升级前一致的后台锚定段,用户之后可在状态面板调整。
      background: item['background'] is bool ? item['background'] as bool : item['constant'] == true,
      content: (item['content'] ?? '').toString(),
      // 导入时 position 承载排序后的序号,供世界书列表稳定展示。
      position: position,
      enabled: _enabled(item),
      extra: _extraOf(item),
    );
  }

  /// 条目启用判定:`enabled` 缺失视为启用;`enabled=false`(ST 卡)或
  /// `disabled=true`(旧式反布尔)/ `disable=true`(ST World Info)视为停用。
  static bool _enabled(Map<String, dynamic> item) {
    final enabled = item['enabled'];
    final disabled = item['disabled'];
    return (enabled is! bool || enabled) && disabled != true && item['disable'] != true;
  }

  /// 归一化条目关键词:`keys` / `key`(均为数组或单字符串),
  /// 逗号/中文逗号切分、trim、去重;数字/布尔值转字符串(容忍非规范形态)。
  static List<String> _parseKeys(Map<String, dynamic> item) {
    final out = <String>[];
    void push(String s) {
      for (final part in s.split(RegExp(r'[，,]'))) {
        final t = part.trim();
        if (t.isNotEmpty && !out.contains(t)) out.add(t);
      }
    }

    void pushValue(Object? v) {
      if (v is List) {
        for (final x in v) {
          if (x is String) {
            push(x);
          } else if (x is num || x is bool) {
            push(x.toString());
          }
        }
      } else if (v is String) {
        push(v);
      } else if (v is num || v is bool) {
        push(v.toString());
      }
    }

    // `keys`(角色卡形态)优先;缺失/形态不可识别时回退 `key`(ST World Info)。
    final keys = item['keys'];
    if (keys is List || keys is String || keys is num || keys is bool) {
      pushValue(keys);
    } else {
      pushValue(item['key']);
    }
    return out;
  }

  /// 数组字段提取;兼容单字符串形态。[alt] 为另一拼写的同名键(ST `keysecondary`)。
  static List<String> _strArrayValue(Map<String, dynamic> item, String key, {String? alt}) {
    final v = item[key] ?? (alt == null ? null : item[alt]);
    if (v is List) {
      return [for (final x in v) if (x is String) x];
    }
    if (v is String) return [v];
    return const [];
  }

  /// ST 把 `match_whole_words` 放在条目 `extensions`(v2DataWorldInfoEntryExtensionInfos)。
  static bool _extBool(Map<String, dynamic> item, String key) {
    final e = item['extensions'];
    if (e is Map<String, dynamic>) {
      return e[key] == true || e['matchWholeWords'] == true;
    }
    return false;
  }

  /// 排序键读取:主键缺失回退另一字段。
  static int _orderOf(Map<String, dynamic> item, String primary, String fallback) {
    final v = item[primary] ?? item[fallback];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 0;
  }

  /// RP-Hub 来源识别(水印或专属扩展键;另:无 spec 且顶层无 name 的 data 信封)。
  static bool _isRpHub(Map<String, dynamic> data, Map<String, dynamic> raw) {
    final ext = data['extensions'];
    if (ext is Map<String, dynamic>) {
      if (ext['rp_hub_watermark'] == 'rp-hub') return true;
      if (ext.containsKey('rp_hub_ui_templates')) return true;
      if (ext.containsKey('regex_scripts')) return true;
    }
    final hasSpec = raw['spec'] != null;
    final topName = (raw['name'] ?? '').toString();
    final hasData = raw['data'] is Map<String, dynamic>;
    return hasData && !hasSpec && topName.isEmpty;
  }
}
