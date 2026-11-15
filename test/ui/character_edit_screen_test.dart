// 角色编辑屏 widget 测试:新建/编辑模式的保存回退、空名校验与字段预填。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/models/bubble_style.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/character_edit_screen.dart';
import '../support/test_database.dart';

/// 把编辑屏压在一个真实路由栈上,保存后可以断言 pop 回退。
Widget _harness(AppDatabase db, {int? characterId}) => ProviderScope(
  overrides: [databaseProvider.overrideWithValue(db)],
  child: MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () =>
              Navigator.push(context, MaterialPageRoute(builder: (_) => CharacterEditScreen(characterId: characterId))),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
  // 不用 pumpAndSettle:编辑模式的加载指示器在 fake-async 下会无限动画。
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('create mode saves a new character and pops', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(_harness(db));
    await _open(tester);
    expect(find.text('新建角色'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('field_名字 *')), 'Carol');
    await tester.enterText(find.byKey(const ValueKey('field_描述')), 'a mage');

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      // 等真实 I/O(insert + invalidate + pop)完成
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    // 保存后回退到入口页
    expect(find.byType(CharacterEditScreen), findsNothing);
    late final List<CharacterRecord> all;
    await tester.runAsync(() async {
      all = await CharacterRepository(db).all();
    });
    expect(all.single.card.name, 'Carol');
    expect(all.single.card.description, 'a mage');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('create mode refuses an empty name', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(_harness(db));
    await _open(tester);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();
    });

    expect(find.text('名字不能为空'), findsOneWidget);
    expect(find.byType(CharacterEditScreen), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('edit mode prefills existing card fields', (tester) async {
    late final AppDatabase db;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice', description: 'knight', scenario: 'castle'));
    });
    await tester.pumpWidget(_harness(db, characterId: charId));
    await _open(tester);

    // 载入是异步的,等真实 I/O 完成
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.text('编辑角色'), findsOneWidget);
    expect(find.byKey(const ValueKey('field_名字 *')), findsOneWidget);
    final nameField = tester.widget<TextField>(find.byKey(const ValueKey('field_名字 *')));
    expect(nameField.controller?.text, 'Alice');
    // 新增聊天背景字段后表单变长,'场景'落到首屏下方(懒加载 ListView 尚未构建),先滚动再断言。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('field_场景')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final scenarioField = tester.widget<TextField>(find.byKey(const ValueKey('field_场景')));
    expect(scenarioField.controller?.text, 'castle');
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('selecting the default bubble color clears a custom color', (tester) async {
    late final AppDatabase db;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(
        name: 'Alice',
        bubbleStyle: BubbleStyle(bubbleColor: 0xFF283593, radius: 22),
      ));
    });
    await tester.pumpWidget(_harness(db, characterId: charId));
    await _open(tester);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    // 气泡色板在表单下方(懒加载 ListView),先滚到「默认」色块再点。
    final defaultSwatch = find.byTooltip('默认');
    await tester.scrollUntilVisible(
      defaultSwatch,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(defaultSwatch);
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    late final CharacterCard? card;
    await tester.runAsync(() async {
      card = await CharacterRepository(db).get(charId);
    });
    // 底色回到默认(null),其余定制字段保留;不再需要点「恢复默认」。
    expect(card!.bubbleStyle, isNotNull);
    expect(card!.bubbleStyle!.bubbleColor, isNull);
    expect(card!.bubbleStyle!.radius, 22);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('font size slider saves a custom bubble font size', (tester) async {
    late final AppDatabase db;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    });
    await tester.pumpWidget(_harness(db, characterId: charId));
    await _open(tester);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    // 字号滑杆在表单下方(懒加载 ListView),先滚到标签再点滑轨右侧。
    await tester.scrollUntilVisible(
      find.text('正文字号'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final sliderRect = tester.getRect(find.byType(Slider).first);
    await tester.tapAt(Offset(sliderRect.left + sliderRect.width * 0.8, sliderRect.center.dy));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    late final CharacterCard? card;
    await tester.runAsync(() async {
      card = await CharacterRepository(db).get(charId);
    });
    expect(card!.bubbleStyle?.fontSize, isNotNull);
    expect(card!.bubbleStyle!.fontSize, greaterThan(kBubbleDefaultFontSize));
    await tester.runAsync(() => db.db.close());
  });
}
