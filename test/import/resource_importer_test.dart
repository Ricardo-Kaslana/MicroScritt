import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/hook_repository.dart';
import 'package:microscritt/data/image_style_repository.dart';
import 'package:microscritt/data/prompt_item_repository.dart';
import 'package:microscritt/data/regex_script_repository.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/export/resource_exporter.dart';
import 'package:microscritt/import/resource_importer.dart';
import 'package:microscritt/models/hook.dart';
import 'package:microscritt/models/image_style_preset.dart';
import 'package:microscritt/models/prompt_item.dart';
import 'package:microscritt/models/skill.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('resource_io');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 独立文件库(内存库在 ffi 下多连接共享,导出/导入两侧必须分开)。
  /// 同时清掉默认正则脚本,避免与自定义脚本的 position 断言互相干扰。
  Future<AppDatabase> openDb(String name) async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: p.join(tmp.path, '$name.db'),
    );
    final scripts = RegexScriptRepository(db);
    for (final script in await scripts.all()) {
      await scripts.delete(script.id!);
    }
    return db;
  }

  Future<void> seed(AppDatabase db) async {
    await SkillRepository(db).insert(
      const Skill(name: '技能A', description: '描述', content: '内容', enabled: false),
    );
    await PromptItemRepository(db).insert(
      const PromptItem(kind: PromptItemKind.rule, name: '规则A', text: '规则正文', enabled: false, position: 9),
    );
    await HookRepository(db).insert(
      const Hook(
        name: 'HookA',
        triggerPoint: HookTriggerPoint.afterStream,
        jsCode: 'ctx.text = ctx.text;',
        enabled: false,
      ),
    );
    await db.db.insert('regex_scripts', {
      'name': '脚本B',
      'find_regex': 'b',
      'replace': '<b>B</b>',
      'enabled': 0,
      'position': 5,
    });
    await db.db.insert('regex_scripts', {
      'name': '脚本A',
      'find_regex': 'a',
      'replace': '<i>A</i>',
      'enabled': 1,
      'position': 1,
    });
    await ImageStyleRepository(db).insert(
      const ImageStylePreset(name: '风格A', artist: 'artist', sampler: 'k_euler', scale: 6, cfg: 0.5, negative: 'low'),
    );
  }

  test('round-trips all five resource types into a fresh database', () async {
    final source = await openDb('source');
    final target = await openDb('target');
    addTearDown(() async {
      await source.db.close();
      await target.db.close();
    });
    await seed(source);

    final skills = ResourceExporter.skills(await SkillRepository(source).all());
    final prompts = ResourceExporter.promptItems(await PromptItemRepository(source).all());
    final hooks = ResourceExporter.hooks(await HookRepository(source).all());
    final regexes = ResourceExporter.regexScripts(await RegexScriptRepository(source).all());
    final styles = ResourceExporter.imageStyles(await ImageStyleRepository(source).all());

    final skillResult = await ResourceImporter.importSkills(target, utf8.encode(skills));
    expect(skillResult.imported, 1);
    final skill = (await SkillRepository(target).all()).single;
    expect(skill.name, '技能A');
    expect(skill.description, '描述');
    expect(skill.enabled, isFalse);

    final promptResult = await ResourceImporter.importPromptItems(target, utf8.encode(prompts));
    expect(promptResult.imported, 1);
    final prompt = (await PromptItemRepository(target).all()).singleWhere((i) => i.name == '规则A');
    expect(prompt.kind, PromptItemKind.rule);
    expect(prompt.text, '规则正文');
    expect(prompt.position, 9);
    expect(prompt.enabled, isFalse);

    final hookResult = await ResourceImporter.importHooks(target, utf8.encode(hooks));
    expect(hookResult.imported, 1);
    final hook = (await HookRepository(target).all()).singleWhere((h) => h.name == 'HookA');
    expect(hook.triggerPoint, HookTriggerPoint.afterStream);
    expect(hook.enabled, isFalse);

    final regexResult = await ResourceImporter.importRegexScripts(target, utf8.encode(regexes));
    expect(regexResult.imported, 2);
    final restoredScripts = await RegexScriptRepository(target).all();
    expect(restoredScripts.map((s) => s.name), ['脚本A', '脚本B']);
    expect(restoredScripts.map((s) => s.position), [1, 5]);
    expect(restoredScripts.first.replace, '<i>A</i>');

    final styleResult = await ResourceImporter.importImageStyles(target, utf8.encode(styles));
    expect(styleResult.imported, 1);
    final style = (await ImageStyleRepository(target).all()).single;
    expect(style.name, '风格A');
    expect(style.isCustom, isTrue);
    expect(style.scale, 6);
    expect(style.cfg, 0.5);
    expect(style.negative, 'low');

    // 再导入一遍:全部按同名跳过。
    expect((await ResourceImporter.importSkills(target, utf8.encode(skills))).imported, 0);
    expect((await ResourceImporter.importImageStyles(target, utf8.encode(styles))).imported, 0);
  });

  test('custom style colliding with a built-in preset name is skipped', () async {
    final db = await openDb('collide');
    addTearDown(() => db.db.close());
    await ImageStyleRepository(db).insert(const ImageStylePreset(name: '清晰锐利', sampler: 'k_dpmpp_2m'));

    final bytes = utf8.encode(ResourceExporter.imageStyles(await ImageStyleRepository(db).all()));
    final result = await ResourceImporter.importImageStyles(db, bytes);
    expect(result.imported, 0);
    expect(result.skipped, 1);
  });

  test('rejects invalid hook trigger points and mismatched formats', () async {
    final db = await openDb('invalid');
    addTearDown(() => db.db.close());

    await expectLater(
      ResourceImporter.importHooks(db, utf8.encode(jsonEncode({
        'format': ResourceExporter.hooksFormat,
        'version': 1,
        'items': [
          {'name': 'x', 'triggerPoint': 'not-a-point', 'jsCode': ''},
        ],
      }))),
      throwsA(isA<FormatException>()),
    );

    await expectLater(
      ResourceImporter.importSkills(db, utf8.encode(jsonEncode({
        'format': ResourceExporter.hooksFormat,
        'version': 1,
        'items': const [],
      }))),
      throwsA(isA<FormatException>()),
    );

    await expectLater(
      ResourceImporter.importRegexScripts(db, utf8.encode('not json')),
      throwsA(isA<FormatException>()),
    );
  });
}
