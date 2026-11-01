import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/ui_prefs_file.dart';
import 'package:microscritt/import/character_card_importer.dart';
import 'package:microscritt/import/worldbook_importer.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/ui_prefs.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/character_screen.dart';
import 'package:path/path.dart' as p;
import '../import/png_chunk_reader_test.dart' show buildPngWithText;
import '../support/test_database.dart';

Widget _harness(AppDatabase db) => ProviderScope(
  overrides: [databaseProvider.overrideWithValue(db)],
  child: const MaterialApp(home: CharacterScreen()),
);

Future<void> _pumpUntilLoaded(WidgetTester tester) async {
  // 角色列表已改为「头像按 id 惰性加载」:列表查询不拉大头像 BLOB(移动端
  // CursorWindow),预览图是异步 SQLite 读取。真实异步要用 runAsync 喂给
  // sqflite 的 isolate,所以轮询一段真实时间让列表 + 各卡片头像都就位。
  await tester.runAsync(() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

/// 用 dart:ui 画一块纯色矩形编码为 PNG 的 base64 —— 一颗真实可解码的头像
/// (硬编码 1×1 PNG 在测试解码器下可能不产出帧,配合 cacheWidth 更不可靠)。
Future<String> _pngBase64(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff5577aa),
  );
  final img = await recorder.endRecording().toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return base64Encode(data!.buffer.asUint8List());
}

/// 轮询直到头像预览的 Image 出现(惰性加载 + 图片解码都是真实异步)。
Future<void> _pumpAvatarUntilImage(WidgetTester tester) async {
  for (var i = 0; i < 40 && find.byType(Image).evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

/// 列表预览当前实际使用的图片字节(拆开 cacheWidth 生成的 ResizeImage)。
Uint8List? _renderedAvatarBytes(WidgetTester tester) {
  final finder = find.byType(Image);
  if (finder.evaluate().isEmpty) return null;
  final provider = tester.widget<Image>(finder.first).image;
  final base = provider is ResizeImage ? provider.imageProvider : provider;
  return base is MemoryImage ? base.bytes : null;
}

void main() {
  testWidgets('empty database shows the empty state with import action', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);

    expect(find.text('暂无角色'), findsOneWidget);
    expect(find.text('导入角色卡'), findsWidgets);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('lists characters as cards with preview and action sheet', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice', description: 'a knight'));
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('a knight'), findsOneWidget);
    // 无头像时预览区显示名字首字
    expect(find.text('A'), findsOneWidget);
    expect(find.byType(Card), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('编辑角色卡'), findsOneWidget);
    expect(find.text('世界书'), findsOneWidget);
    expect(find.text('导出角色卡(JSON)'), findsOneWidget);
    expect(find.text('导出角色卡(PNG)'), findsOneWidget);
    expect(find.text('删除角色'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('card preview shows the avatar image when base64 is set', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      final b64 = await _pngBase64(64, 84);
      await CharacterRepository(db).insert(CharacterCard(name: 'Pixel', avatarBase64: b64));
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);
    // 头像按 id 惰性加载,轮询到 Image 出现(不再是占位首字)。
    await _pumpAvatarUntilImage(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('P'), findsNothing); // 有头像就不再显示占位首字
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('card preview shows a data-URI (data:image) avatar', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      // 常见角色卡把头像存成完整 data URI;以前 base64Decode 直接抛 → 渐变占位。
      final rawB64 = await _pngBase64(64, 84);
      await CharacterRepository(db).insert(CharacterCard(name: 'Pixel', avatarBase64: 'data:image/png;base64,$rawB64'));
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);
    await _pumpAvatarUntilImage(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('P'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('list preview refreshes when the card avatar changes', (
    tester,
  ) async {
    late final AppDatabase db;
    late final int cardId;
    late final String avatarA;
    late final String avatarB;
    await tester.runAsync(() async {
      db = await openTestDb();
      avatarA = await _pngBase64(32, 42);
      avatarB = await _pngBase64(64, 84);
      cardId = await CharacterRepository(
        db,
      ).insert(CharacterCard(name: 'Pixel', avatarBase64: avatarA));
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);
    await _pumpAvatarUntilImage(tester);
    expect(_renderedAvatarBytes(tester), base64Decode(avatarA));

    // 模拟编辑屏保存换头像:更新头像列,并像保存流程一样失效列表与头像 provider。
    await tester.runAsync(() async {
      final repo = CharacterRepository(db);
      final card = await repo.get(cardId);
      await repo.update(cardId, card!.replacingAvatar(avatarB));
    });
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CharacterScreen)),
    );
    container.invalidate(characterAvatarProvider(cardId));
    container.invalidate(charactersProvider);

    // 不回退成占位/灰块,直接等预览换成新图(旧实现会一直停在 avatarA)。
    final expected = base64Decode(avatarB);
    for (
      var i = 0;
      i < 40 && !listEquals(_renderedAvatarBytes(tester), expected);
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(_renderedAvatarBytes(tester), expected);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('layout toggle switches list/grid in place and keeps the query', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      final repo = CharacterRepository(db);
      await repo.insert(
        const CharacterCard(name: 'Alice', description: 'a knight'),
      );
      await repo.insert(
        const CharacterCard(name: 'Bob', description: 'a bard'),
      );
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);

    // 默认列表布局:描述正常显示。
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.text('a knight'), findsOneWidget);

    // 先搜索,再原地切到图片网格:检索词与过滤保留。
    await tester.enterText(find.byType(TextField), 'Alice');
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsNothing);

    await tester.tap(find.byTooltip('图片布局'));
    await tester.pumpAndSettle();
    final grid = find.byType(GridView);
    expect(grid, findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(
      find.descendant(of: grid, matching: find.text('Alice')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: grid, matching: find.text('a knight')),
      findsOneWidget,
    );
    expect(find.text('Bob'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Alice',
    );

    // 网格条目右上角的操作菜单可用。
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('编辑角色卡'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // 切回列表布局,搜索词仍保留。
    await tester.tap(find.byTooltip('列表布局'));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.text('a knight'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('layout choice is persisted and restored on next launch', (
    tester,
  ) async {
    late final AppDatabase db;
    late final Directory dir;
    await tester.runAsync(() async {
      db = await openTestDb();
      dir = await Directory.systemTemp.createTemp('ui_prefs_screen_');
      await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // Windows 上仍在收尾的写入偶尔会短暂占用目录;临时目录交给系统清理。
      }
    });
    final prefs = UiPrefsFile(p.join(dir.path, UiPrefsFile.fileName));

    Widget harnessWith(CharacterLayout initial) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        uiPrefsFileProvider.overrideWithValue(prefs),
        characterLayoutProvider.overrideWith((ref) => initial),
      ],
      child: const MaterialApp(home: CharacterScreen()),
    );

    await tester.pumpWidget(harnessWith(CharacterLayout.list));
    await _pumpUntilLoaded(tester);
    expect(find.byType(GridView), findsNothing);

    // 切到图片布局:立即生效并回写偏好文件(写盘是真实 IO,需要真实时间 +
    // 帧循环推进才能跑完回调)。
    await tester.tap(find.byTooltip('图片布局'));
    await tester.pump();
    expect(find.byType(GridView), findsOneWidget);
    UiPrefs? saved;
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      saved = await tester.runAsync(() => prefs.read());
      if (saved!.characterLayout == CharacterLayout.grid) break;
    }
    expect(saved!.characterLayout, CharacterLayout.grid);

    // 模拟下次启动:按文件内容重建根作用域,直接呈现网格布局。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(harnessWith(saved.characterLayout));
    await _pumpUntilLoaded(tester);
    expect(find.byType(GridView), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('oversized card rows still show their description', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      // data_json 超列表投影阈值(1.5M 字符):投影时整列被裁成空串,列表
      // 以前只剩名字;展示路径现在按 id 补读整列,描述与编辑页一致。
      await CharacterRepository(db).insert(
        CharacterCard(
          name: 'Big',
          description: '超大卡描述',
          personality: 'p' * 1600000,
        ),
      );
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);

    expect(find.text('Big'), findsOneWidget);
    expect(find.text('超大卡描述'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('card preview falls back to the avatar_base64 column when data_json lacks it', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      final rawB64 = await _pngBase64(64, 84);
      // 手工写入:avatar 只落在 characters.avatar_base64 列,data_json 里没有 avatar。
      await db.db.insert('characters', {
        'name': 'Legacy',
        'avatar_base64': rawB64,
        'data_json':
            '{"name":"Legacy","description":"","personality":"","scenario":'
            '"","first_mes":"","mes_example":"","system_prompt":"","post_history_instructions":"","creator_notes":""}',
      });
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);
    await _pumpAvatarUntilImage(tester);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('L'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('delete menu item removes the character after confirmation', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      await CharacterRepository(db).insert(const CharacterCard(name: 'Bob'));
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除角色'));
    await tester.pumpAndSettle();

    // 确认对话框出现,点确认删除。invalidate 触发的重载:轮询到 charactersProvider
    // 拿到不含 Bob 的新数据为止(先抽帧启动再等真实 I/O)。
    expect(find.text('删除角色?'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('删除').last);
      final container = ProviderScope.containerOf(tester.element(find.byType(CharacterScreen)));
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50)); // 真实时间,喂给 DB isolate
        await tester.pump();
        final st = container.read(charactersProvider);
        final stillThere = st.value?.any((c) => c.card.name == 'Bob') ?? true;
        if (!st.isLoading && !stillThere) break;
      }
      await tester.pumpAndSettle();
    });
    await _pumpUntilLoaded(tester);

    expect(find.text('Bob'), findsNothing);
    expect(find.text('暂无角色'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('imported PNG card shows its own image as the preview avatar', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      // 角色卡的标准 PNG:JSON 里没有 avatar,头像就是这张图本身。
      final json = jsonEncode({
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {'name': 'Pixel'},
      });
      final png = buildPngWithText('ccv3', base64.encode(utf8.encode(json)));
      final card = CharacterCardImporter.fromBytes(png);
      await CharacterRepository(db).insertWithWorldbook(card, WorldbookImporter.extract(card));
    });
    await tester.pumpWidget(_harness(db));
    await _pumpUntilLoaded(tester);
    await _pumpAvatarUntilImage(tester);

    expect(find.text('Pixel'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget); // 预览显示从 PNG 提取的角色图,而非占位首字
    await tester.runAsync(() => db.db.close());
  });
}
