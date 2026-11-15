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

  test('round-trips layout, sidebar collapse and deck progress', () async {
    final file = UiPrefsFile(p.join(dir.path, UiPrefsFile.fileName));
    // 文件不存在:默认列表布局、侧栏展开、无牌堆进度。
    expect((await file.read()).characterLayout, CharacterLayout.list);
    expect((await file.read()).sidebarCollapsed, isFalse);
    expect((await file.read()).deckFrontCharacterId, isNull);

    await file.write(
      const UiPrefs(
        characterLayout: CharacterLayout.grid,
        sidebarCollapsed: true,
      ),
    );
    final readBack = await file.read();
    expect(readBack.characterLayout, CharacterLayout.grid);
    expect(readBack.sidebarCollapsed, isTrue);

    final raw =
        jsonDecode(await File(file.path).readAsString())
            as Map<String, dynamic>;
    expect(raw['version'], UiPrefsFile.formatVersion);
    expect(raw['characterLayout'], 'grid');
    expect(raw['sidebarCollapsed'], isTrue);

    await file.write(
      const UiPrefs(
        characterLayout: CharacterLayout.deck,
        deckFrontCharacterId: 42,
      ),
    );
    final deck = await file.read();
    expect(deck.characterLayout, CharacterLayout.deck);
    expect(deck.sidebarCollapsed, isFalse);
    expect(deck.deckFrontCharacterId, 42);
    final rawDeck =
        jsonDecode(await File(file.path).readAsString())
            as Map<String, dynamic>;
    expect(rawDeck['characterLayout'], 'deck');
    expect(rawDeck['deckFrontCharacterId'], 42);
  });

  test('layout button cycles list -> grid -> deck -> list', () {
    expect(CharacterLayout.list.next, CharacterLayout.grid);
    expect(CharacterLayout.grid.next, CharacterLayout.deck);
    expect(CharacterLayout.deck.next, CharacterLayout.list);
  });

  test('bad file and unknown values fall back to defaults', () async {
    final file = UiPrefsFile(p.join(dir.path, UiPrefsFile.fileName));

    await File(file.path).writeAsString('{broken');
    expect((await file.read()).characterLayout, CharacterLayout.list);

    await File(
      file.path,
    ).writeAsString('{"version":1,"characterLayout":"mosaic"}');
    expect((await file.read()).characterLayout, CharacterLayout.list);

    // 侧栏折叠非布尔值(fail-safe):一律回落展开。
    await File(
      file.path,
    ).writeAsString('{"version":1,"sidebarCollapsed":"yes"}');
    expect((await file.read()).sidebarCollapsed, isFalse);

    // 牌堆进度非整数(fail-safe):回落 null,由牌堆自己选第一张。
    await File(
      file.path,
    ).writeAsString('{"version":1,"deckFrontCharacterId":"2"}');
    expect((await file.read()).deckFrontCharacterId, isNull);
    await File(
      file.path,
    ).writeAsString('{"version":1,"deckFrontCharacterId":2.5}');
    expect((await file.read()).deckFrontCharacterId, isNull);
  });
}
