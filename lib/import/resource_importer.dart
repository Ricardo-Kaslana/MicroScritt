import 'dart:convert';

import '../data/database.dart';
import '../data/hook_repository.dart';
import '../data/image_style_repository.dart';
import '../data/prompt_item_repository.dart';
import '../data/regex_script_repository.dart';
import '../data/skill_repository.dart';
import '../export/resource_exporter.dart';
import '../models/hook.dart';
import '../models/image_style_preset.dart';
import '../models/prompt_item.dart';
import '../models/regex_script.dart';
import '../models/skill.dart';

/// 资源导入结果:导入数 + 同名跳过数。
class ResourceImportResult {
  final int imported;
  final int skipped;
  const ResourceImportResult(this.imported, this.skipped);
}

/// 技能 / 全局提示词 / Hooks / 正则脚本 / 自定义生图风格的导入。
///
/// 统一策略:先整表解析校验(结构错误抛中文 [FormatException],不做半截写入),
/// 再按 name 去重插入 —— 已存在同名项跳过并计数,保持 [ResourceExporter]
/// 往返时的幂等性。导入保留文件里的 enabled 状态(用户主动迁移,不偷偷停用)。
class ResourceImporter {
  static Future<ResourceImportResult> importSkills(AppDatabase db, List<int> bytes) async {
    final items = _items(bytes, ResourceExporter.skillsFormat);
    final parsed = <Skill>[];
    for (final (index, raw) in items.indexed) {
      final map = _map(raw, index);
      parsed.add(Skill(
        name: _requiredString(map, 'name', index),
        description: _string(map, 'description'),
        content: _string(map, 'content'),
        enabled: map['enabled'] != false,
      ));
    }
    final repo = SkillRepository(db);
    final existing = {for (final s in await repo.all()) s.name};
    var imported = 0;
    var skipped = 0;
    for (final skill in parsed) {
      if (!existing.add(skill.name)) {
        skipped++;
        continue;
      }
      await repo.insert(skill);
      imported++;
    }
    return ResourceImportResult(imported, skipped);
  }

  static Future<ResourceImportResult> importPromptItems(AppDatabase db, List<int> bytes) async {
    final items = _items(bytes, ResourceExporter.promptItemsFormat);
    final parsed = <PromptItem>[];
    for (final (index, raw) in items.indexed) {
      final map = _map(raw, index);
      parsed.add(PromptItem(
        kind: PromptItem.kindFrom(_string(map, 'kind')),
        name: _string(map, 'name'),
        text: _string(map, 'text'),
        enabled: map['enabled'] != false,
        position: _int(map, 'position', fallback: index),
      ));
    }
    final repo = PromptItemRepository(db);
    final existing = <String>{
      for (final item in await repo.all()) _promptKey(item.kind, item.name, item.text),
    };
    var imported = 0;
    var skipped = 0;
    for (final item in parsed) {
      if (!existing.add(_promptKey(item.kind, item.name, item.text))) {
        skipped++;
        continue;
      }
      await repo.insert(item);
      imported++;
    }
    return ResourceImportResult(imported, skipped);
  }

  static Future<ResourceImportResult> importHooks(AppDatabase db, List<int> bytes) async {
    final items = _items(bytes, ResourceExporter.hooksFormat);
    final parsed = <Hook>[];
    for (final (index, raw) in items.indexed) {
      final map = _map(raw, index);
      final wire = _string(map, 'triggerPoint');
      final point = HookTriggerPoint.values.where((p) => p.name == wire).firstOrNull;
      if (point == null) {
        throw FormatException('items[$index].triggerPoint 无效:$wire');
      }
      parsed.add(Hook(
        name: _requiredString(map, 'name', index),
        triggerPoint: point,
        jsCode: _string(map, 'jsCode'),
        enabled: map['enabled'] != false,
      ));
    }
    final repo = HookRepository(db);
    final existing = {for (final h in await repo.all()) h.name};
    var imported = 0;
    var skipped = 0;
    for (final hook in parsed) {
      if (!existing.add(hook.name)) {
        skipped++;
        continue;
      }
      await repo.insert(hook);
      imported++;
    }
    return ResourceImportResult(imported, skipped);
  }

  static Future<ResourceImportResult> importRegexScripts(AppDatabase db, List<int> bytes) async {
    final items = _items(bytes, ResourceExporter.regexScriptsFormat);
    final parsed = <RegexScript>[];
    for (final (index, raw) in items.indexed) {
      final map = _map(raw, index);
      parsed.add(RegexScript(
        name: _requiredString(map, 'name', index),
        findRegex: _string(map, 'findRegex'),
        replace: _string(map, 'replace'),
        enabled: map['enabled'] != false,
        position: _int(map, 'position', fallback: index),
      ));
    }
    final repo = RegexScriptRepository(db);
    final existing = {for (final s in await repo.all()) s.name};
    var imported = 0;
    var skipped = 0;
    for (final script in parsed) {
      if (!existing.add(script.name)) {
        skipped++;
        continue;
      }
      // 直接写表以保留归档里的 position;仓库 insert 会强制排到末尾。
      await db.db.insert('regex_scripts', {
        'name': script.name,
        'find_regex': script.findRegex,
        'replace': script.replace,
        'enabled': script.enabled ? 1 : 0,
        'position': script.position,
      });
      imported++;
    }
    return ResourceImportResult(imported, skipped);
  }

  static Future<ResourceImportResult> importImageStyles(AppDatabase db, List<int> bytes) async {
    final items = _items(bytes, ResourceExporter.imageStylesFormat);
    final parsed = <ImageStylePreset>[];
    for (final (index, raw) in items.indexed) {
      final map = _map(raw, index);
      parsed.add(ImageStylePreset(
        name: _requiredString(map, 'name', index),
        artist: _optionalString(map, 'artist'),
        sampler: _optionalString(map, 'sampler'),
        noiseSchedule: _optionalString(map, 'noiseSchedule'),
        scale: _optionalInt(map, 'scale'),
        cfg: _optionalNumber(map, 'cfg'),
        negative: _optionalString(map, 'negative'),
      ));
    }
    final repo = ImageStyleRepository(db);
    // 内置预设不落表,但同名自定义风格会覆盖下拉里的"快捷填充"语义,直接跳过。
    final occupied = <String>{
      for (final preset in kImageStylePresets) preset.name,
      for (final style in await repo.all()) style.name,
    };
    var imported = 0;
    var skipped = 0;
    for (final style in parsed) {
      if (!occupied.add(style.name)) {
        skipped++;
        continue;
      }
      await repo.insert(style);
      imported++;
    }
    return ResourceImportResult(imported, skipped);
  }

  static String _promptKey(PromptItemKind kind, String name, String text) =>
      name.isNotEmpty ? '${kind.name}|$name' : '${kind.name}|text:$text';

  static List<dynamic> _items(List<int> bytes, String expectedFormat) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      throw FormatException('不是有效的 JSON 文件:$e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('不是资源导出文件(缺少顶层对象)');
    }
    final format = decoded['format'];
    if (format != expectedFormat) {
      throw const FormatException('文件类型不匹配(不是该类资源的导出文件)');
    }
    final version = decoded['version'];
    if (version is int && version > ResourceExporter.formatVersion) {
      throw const FormatException('文件版本过新,请升级应用');
    }
    final items = decoded['items'];
    if (items is! List) throw const FormatException('资源导出文件缺少 items 数组');
    return items;
  }

  static Map<String, dynamic> _map(Object? raw, int index) {
    if (raw is! Map<String, dynamic>) throw FormatException('items[$index] 必须是对象');
    return raw;
  }

  static String _string(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return '';
    if (value is! String) throw FormatException('$key 必须是字符串');
    return value;
  }

  static String _requiredString(Map<String, dynamic> map, String key, int index) {
    final value = _string(map, key).trim();
    if (value.isEmpty) throw FormatException('items[$index].$key 不能为空');
    return value;
  }

  static String? _optionalString(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('$key 必须是字符串');
    return value;
  }

  static int _int(Map<String, dynamic> map, String key, {required int fallback}) {
    final value = map[key];
    return value is int ? value : fallback;
  }

  static int? _optionalInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is! int) throw FormatException('$key 必须是整数');
    return value;
  }

  /// 可小数的数值字段(如 cfg):旧档写整数、新档可能写小数,都按 num 收下。
  static double? _optionalNumber(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is! num) throw FormatException('$key 必须是数字');
    return value.toDouble();
  }
}
