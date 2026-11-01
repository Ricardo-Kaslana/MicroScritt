/// 全局文本资产(技能/提示词/Hooks/正则脚本/生图风格)的导出。
///
/// 统一使用 `{format, version, items}` 信封,便于导入端识别类型并在版本
/// 升级时向后兼容;id 不出现在文件里,跨设备迁移不依赖原库自增 id。
library;

import 'dart:convert';

import '../models/hook.dart';
import '../models/image_style_preset.dart';
import '../models/prompt_item.dart';
import '../models/regex_script.dart';
import '../models/skill.dart';

/// 全局文本资产的导出:统一 `{format, version, items}` 信封,便于识别类型
/// 并在版本升级时向后兼容。id 一律不出现在文件里 —— 导入端按名称去重后
/// 重新分配(提示词按 kind+name),跨设备迁移不依赖原库自增 id。
class ResourceExporter {
  /// 信封 `version` 的当前值;导入端遇到更大的版本会拒绝导入。
  static const int formatVersion = 1;

  static const String skillsFormat = 'microscritt.skills';
  static const String promptItemsFormat = 'microscritt.prompt_items';
  static const String hooksFormat = 'microscritt.hooks';
  static const String regexScriptsFormat = 'microscritt.regex_scripts';
  static const String imageStylesFormat = 'microscritt.image_styles';

  static String skills(List<Skill> items) => _encode(skillsFormat, [
    for (final s in items)
      {
        'name': s.name,
        'description': s.description,
        'content': s.content,
        'enabled': s.enabled,
      },
  ]);

  static String promptItems(List<PromptItem> items) => _encode(promptItemsFormat, [
    for (final i in items)
      {
        'kind': i.kind.name,
        'name': i.name,
        'text': i.text,
        'enabled': i.enabled,
        'position': i.position,
      },
  ]);

  static String hooks(List<Hook> items) => _encode(hooksFormat, [
    for (final h in items)
      {
        'name': h.name,
        'triggerPoint': h.triggerPoint.name,
        'jsCode': h.jsCode,
        'enabled': h.enabled,
      },
  ]);

  static String regexScripts(List<RegexScript> items) => _encode(regexScriptsFormat, [
    for (final s in items)
      {
        'name': s.name,
        'findRegex': s.findRegex,
        'replace': s.replace,
        'enabled': s.enabled,
        'position': s.position,
      },
  ]);

  static String imageStyles(List<ImageStylePreset> items) => _encode(imageStylesFormat, [
    for (final s in items)
      {
        'name': s.name,
        'artist': s.artist,
        'sampler': s.sampler,
        'noiseSchedule': s.noiseSchedule,
        'scale': s.scale,
        'cfg': s.cfg,
        'negative': s.negative,
      },
  ]);

  static String _encode(String format, List<Map<String, Object?>> items) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': format,
        'version': formatVersion,
        'items': items,
      });
}
