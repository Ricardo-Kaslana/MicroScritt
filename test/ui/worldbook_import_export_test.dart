import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/worldbook_screen.dart';
import '../support/fake_file_picker.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

/// 世界书导入导出的**端到端**界面测试:选择文件 → 读字节 → 解析 → 合并 → 落库
/// → 列表刷新。这条链路此前零覆盖(它是唯一依赖原生文件选择器的路径),靠
/// [FakeFilePicker] 注入 `FilePickerPlatform.instance` 才测得动 —— 默认实现是
/// MethodChannel,测试环境里没有原生侧响应。
///
/// 等待一律走 [waitUntil] 按条件轮询,不用固定 `Future.delayed`:这条链路每步都
/// 是真实 I/O(读文件、写 DB、provider 重取),固定延时在并发跑全量套件时不够。
void main() {
  late AppDatabase db;
  late int charId;
  late Directory tmp;

  Widget harness() => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(home: WorldbookScreen(characterId: charId, characterName: 'Alice')),
  );

  setUp(() async {
    db = await openTestDb();
    charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    tmp = await Directory.systemTemp.createTemp('wb_io_test');
  });

  tearDown(() async {
    await db.db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File writeJson(String name, String content) {
    final f = File('${tmp.path}/$name');
    f.writeAsStringSync(content);
    return f;
  }

  Future<List<WorldbookEntry>> rows(WidgetTester tester) async {
    late List<WorldbookEntry> out;
    await tester.runAsync(() async {
      out = await WorldbookRepository(db).byCharacter(charId);
    });
    return out;
  }

  /// 挂上屏幕并等世界书的首次加载收敛(loading 分支是 CircularProgressIndicator)。
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await waitUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await waitUntil(tester, () => find.text('导入条目').evaluate().isNotEmpty);
  }

  Future<void> tapText(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> waitForText(WidgetTester tester, String fragment) =>
      waitUntil(tester, () => find.textContaining(fragment).evaluate().isNotEmpty);

  testWidgets('exports the current entries to a file', (tester) async {
    await tester.runAsync(() async {
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, name: '王都', keys: ['王都', '首都'], content: 'desc', position: 1),
      ]);
    });
    final fake = FakeFilePicker.install(savePath: '${tmp.path}/out.json');
    await pumpScreen(tester);
    await openMenu(tester);
    await tapText(tester, '导出条目(JSON)');
    await waitForText(tester, '已导出');

    expect(fake.saveCalls, 1);
    final saved = jsonDecode(utf8.decode(fake.savedBytes!)) as Map<String, dynamic>;
    final entry = (saved['entries'] as Map<String, dynamic>)['0'] as Map<String, dynamic>;
    expect(entry['comment'], '王都');
    expect(entry['key'], ['王都', '首都']);
    expect(entry['content'], 'desc');
  });

  testWidgets('imports into an empty book without asking for a mode', (tester) async {
    final file = writeJson(
      'book.json',
      jsonEncode({
        'entries': {
          '0': {'key': ['a'], 'content': '第一条'},
          '1': {'key': ['b'], 'content': '第二条'},
        },
      }),
    );
    final fake = FakeFilePicker.install(pickedPath: file.path);
    await pumpScreen(tester);
    expect(find.text('暂无世界书条目'), findsOneWidget);

    await tapText(tester, '导入条目');
    await waitForText(tester, '已导入');

    expect(fake.pickCalls, 1);
    // 空书没有可覆盖的东西,不该弹「追加/替换」。
    expect(find.text('导入方式'), findsNothing);
    final list = await rows(tester);
    expect(list.map((e) => e.content).toList(), ['第一条', '第二条']);
    expect(list.map((e) => e.position).toList(), [0, 1]);
    // 列表刷新:导入的条目可见(无名称时回退首关键词)。
    await waitUntil(tester, () => find.text('a').evaluate().isNotEmpty);
  });

  testWidgets('appends imported entries after the existing max position', (tester) async {
    await tester.runAsync(() async {
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, name: '旧', keys: ['old'], content: '旧条目', position: 5),
      ]);
    });
    final file = writeJson(
      'book.json',
      jsonEncode({
        'entries': [
          {'key': ['a'], 'content': '新一'},
          {'key': ['b'], 'content': '新二'},
        ],
      }),
    );
    FakeFilePicker.install(pickedPath: file.path);
    await pumpScreen(tester);
    await openMenu(tester);
    await tapText(tester, '导入条目');
    await waitUntil(tester, () => find.text('导入方式').evaluate().isNotEmpty);

    await tapText(tester, '追加');
    await waitForText(tester, '已导入');

    final list = await rows(tester);
    expect(list.map((e) => e.content).toList(), ['旧条目', '新一', '新二']);
    // 追加的条目顺延到现有最大 position(5)之后,不会插到旧条目前面。
    expect(list.map((e) => e.position).toList(), [5, 6, 7]);
    expect(find.textContaining('已导入 2 条条目(追加)'), findsOneWidget);
  });

  testWidgets('replacing drops the existing entries', (tester) async {
    await tester.runAsync(() async {
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, name: '旧', keys: ['old'], content: '旧条目', position: 5),
      ]);
    });
    final file = writeJson(
      'book.json',
      jsonEncode({
        'entries': [
          {'key': ['a'], 'content': '新一'},
        ],
      }),
    );
    FakeFilePicker.install(pickedPath: file.path);
    await pumpScreen(tester);
    await openMenu(tester);
    await tapText(tester, '导入条目');
    await waitUntil(tester, () => find.text('导入方式').evaluate().isNotEmpty);

    await tapText(tester, '替换');
    await waitForText(tester, '已导入');

    final list = await rows(tester);
    expect(list.map((e) => e.content).toList(), ['新一']);
    expect(list.single.position, 0);
    expect(find.textContaining('已导入 1 条条目(替换原 1 条)'), findsOneWidget);
  });

  testWidgets('cancelling the mode dialog leaves the book untouched', (tester) async {
    await tester.runAsync(() async {
      await WorldbookRepository(db).replaceForCharacter(charId, const [
        WorldbookEntry(characterId: 0, name: '旧', keys: ['old'], content: '旧条目', position: 0),
      ]);
    });
    final file = writeJson('book.json', jsonEncode({'entries': [{'key': ['a'], 'content': '新'}]}));
    FakeFilePicker.install(pickedPath: file.path);
    await pumpScreen(tester);
    await openMenu(tester);
    await tapText(tester, '导入条目');
    await waitUntil(tester, () => find.text('导入方式').evaluate().isNotEmpty);

    await tapText(tester, '取消');
    await waitForText(tester, '已取消导入');

    final list = await rows(tester);
    expect(list.map((e) => e.content).toList(), ['旧条目']);
  });

  testWidgets('reports a failure when the picker returns nothing', (tester) async {
    FakeFilePicker.install(pickedPath: null); // 用户在原生对话框里取消
    await pumpScreen(tester);
    await tapText(tester, '导入条目');
    await waitForText(tester, '导入失败:未读取到所选文件');

    expect(await rows(tester), isEmpty);
  });

  testWidgets('reports a failure when the picked file is not json', (tester) async {
    final file = writeJson('bad.json', 'not json at all');
    FakeFilePicker.install(pickedPath: file.path);
    await pumpScreen(tester);
    await tapText(tester, '导入条目');
    await waitForText(tester, '导入失败:文件不是有效的 JSON');

    expect(await rows(tester), isEmpty);
  });

  testWidgets('reports a failure when the json holds no worldbook', (tester) async {
    final file = writeJson('empty.json', jsonEncode({'hello': 'world'}));
    FakeFilePicker.install(pickedPath: file.path);
    await pumpScreen(tester);
    await tapText(tester, '导入条目');
    await waitForText(tester, '导入失败:未找到世界书条目');

    expect(await rows(tester), isEmpty);
  });
}
