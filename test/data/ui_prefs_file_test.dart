// UI 偏好文件:布局往返与坏文件/未知值回落默认(fail-safe)。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/ui_prefs_file.dart';
import 'package:microscritt/models/ui_prefs.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ui_prefs_');
  });

  tearDown(() => dir.delete(recursive: true));

  test('round-trips the character layout', () async {
    final file = UiPrefsFile(p.join(dir.path, UiPrefsFile.fileName));
    // 文件不存在:默认列表布局。
    expect((await file.read()).characterLayout, CharacterLayout.list);

    await file.write(const UiPrefs(characterLayout: CharacterLayout.grid));
    expect((await file.read()).characterLayout, CharacterLayout.grid);

    final raw =
        jsonDecode(await File(file.path).readAsString())
            as Map<String, dynamic>;
    expect(raw['version'], UiPrefsFile.formatVersion);
    expect(raw['characterLayout'], 'grid');
  });

  test('bad file and unknown values fall back to defaults', () async {
    final file = UiPrefsFile(p.join(dir.path, UiPrefsFile.fileName));

    await File(file.path).writeAsString('{broken');
    expect((await file.read()).characterLayout, CharacterLayout.list);

    await File(
      file.path,
    ).writeAsString('{"version":1,"characterLayout":"mosaic"}');
    expect((await file.read()).characterLayout, CharacterLayout.list);
  });
}
