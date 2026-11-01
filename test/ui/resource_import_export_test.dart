// 技能页与生图风格页的资源 JSON 导出/导入:信封格式、同名跳过,
// 以及内置风格预设不落表、导入时被拒。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_style_repository.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/export/resource_exporter.dart';
import 'package:microscritt/models/image_style_preset.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/image_styles_screen.dart';
import 'package:microscritt/ui/skills_screen.dart';
import '../support/fake_file_picker.dart';
import '../support/test_database.dart';

/// 只 pump 不 pumpAndSettle:加载中/导入后的 CircularProgressIndicator 永远不会
/// 收敛,不能用 pumpAndSettle 等状态。
Future<void> pumpUntil(WidgetTester tester, bool Function() condition, {int polls = 120}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < polls; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  await tester.pump();
}

void main() {
  late AppDatabase db;
  late Directory tmp;

  setUp(() async {
    db = await openTestDb();
    tmp = await Directory.systemTemp.createTemp('resource_ui');
  });

  tearDown(() async {
    await db.db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Widget skillsHarness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const MaterialApp(home: SkillsScreen()),
  );

  testWidgets('skills screen exports all rows and imports by name', (tester) async {
    await tester.runAsync(
      () => SkillRepository(db).insert(const Skill(name: '导出技能', description: 'd', content: 'c')),
    );
    final savePath = '${tmp.path}/skills.json';
    // 桌面分支把 bytes 交给 file_picker;替身只记录不落盘,导出内容从它取。
    final fake = FakeFilePicker.install(savePath: savePath);
    await tester.pumpWidget(skillsHarness());
    await pumpUntil(tester, () => find.text('导出技能').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('导出 JSON'));
    await pumpUntil(tester, () => fake.savedBytes != null);
    final exported = jsonDecode(utf8.decode(fake.savedBytes!)) as Map<String, dynamic>;
    expect(exported['format'], ResourceExporter.skillsFormat);
    expect((exported['items'] as List).single['name'], '导出技能');

    final importPath = '${tmp.path}/import.json';
    File(importPath).writeAsStringSync(
      ResourceExporter.skills([
        const Skill(name: '导出技能', content: 'dup'),
        const Skill(name: '导入技能', content: 'new', enabled: false),
      ]),
    );
    FakeFilePicker.install(pickedPath: importPath);
    await tester.tap(find.byTooltip('导入 JSON'));
    await pumpUntil(tester, () => find.text('导入技能').evaluate().isNotEmpty);
    expect(find.textContaining('已导入 1 项技能,跳过 1 项'), findsOneWidget);

    final rows = await tester.runAsync(() => SkillRepository(db).all());
    expect(rows!.map((s) => s.name), containsAll(['导出技能', '导入技能']));
    expect(rows.singleWhere((s) => s.name == '导入技能').enabled, isFalse);
  });

  testWidgets('image styles screen exports and imports custom styles only', (tester) async {
    await tester.runAsync(
      () => ImageStyleRepository(db).insert(const ImageStylePreset(name: '导出风格', sampler: 'k_euler', scale: 6)),
    );
    final savePath = '${tmp.path}/styles.json';
    final fake = FakeFilePicker.install(savePath: savePath);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(
        home: ImageStylesScreen(prefill: ImageStylePreset(name: '')),
      ),
    ));
    await pumpUntil(tester, () => find.text('导出风格').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('导出 JSON'));
    await pumpUntil(tester, () => fake.savedBytes != null);
    final exported = jsonDecode(utf8.decode(fake.savedBytes!)) as Map<String, dynamic>;
    expect(exported['format'], ResourceExporter.imageStylesFormat);
    final items = exported['items'] as List;
    expect(items, hasLength(1));
    expect(items.single['name'], '导出风格');
    // 内置预设是常量、不落表,导出文件里不会出现。
    expect(items.map((item) => item['name']), isNot(contains('清晰锐利')));

    final importPath = '${tmp.path}/styles-import.json';
    File(importPath).writeAsStringSync(
      ResourceExporter.imageStyles([
        const ImageStylePreset(name: '新风格', artist: 'a'),
        const ImageStylePreset(name: '清晰锐利'),
      ]),
    );
    FakeFilePicker.install(pickedPath: importPath);
    await tester.tap(find.byTooltip('导入 JSON'));
    await pumpUntil(tester, () => find.text('新风格').evaluate().isNotEmpty);
    expect(find.textContaining('已导入 1 项生图风格,跳过 1 项'), findsOneWidget);
    final styles = await tester.runAsync(() => ImageStyleRepository(db).all());
    expect(styles, hasLength(2));
  });
}
