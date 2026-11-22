// 牌堆布局 widget 测试:正面/侧翼卡渲染、点侧卡换牌、按钮与轻扫翻牌、
// 列表变化时按 id 保住正面卡、大牌堆的可见窗口与头像惰性加载。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/widgets/character_deck.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';

CharacterRecord _record(int id, String name, String description) =>
    CharacterRecord(
      id: id,
      card: CharacterCard(name: name, description: description),
    );

final _three = [
  _record(1, 'Alice', 'a knight'),
  _record(2, 'Bob', 'a bard'),
  _record(3, 'Carol', 'a mage'),
];

/// 头像 provider 是真实异步 SQLite 读取,用 runAsync 喂帧让它就位。
Future<void> _pumpDeck(
  WidgetTester tester,
  AppDatabase db,
  List<CharacterRecord> records, {
  ValueChanged<CharacterRecord>? onOpen,
  ValueChanged<CharacterRecord>? onActions,
  int? initialFrontId,
  ValueChanged<int>? onFrontChanged,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Scaffold(
          body: CharacterDeckView(
            records: records,
            initialFrontId: initialFrontId,
            onFrontChanged: onFrontChanged,
            onOpen: onOpen ?? (_) {},
            onActions: onActions ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('front card shows description; side cards only names', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three);

    expect(find.text('1 / 3 · 点两侧卡切换,左右轻扫翻牌'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
    // 只有正面卡带描述与操作菜单。
    expect(find.text('a knight'), findsOneWidget);
    expect(find.text('a bard'), findsNothing);
    expect(find.text('a mage'), findsNothing);
    expect(find.byTooltip('更多操作'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('tapping a side card brings it to the front', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three);

    // Carol 在左翼,名字靠外缘对齐,露出部分可点。
    await tester.tap(find.text('Carol'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3 · 点两侧卡切换,左右轻扫翻牌'), findsOneWidget);
    expect(find.text('a mage'), findsOneWidget);
    expect(find.text('a knight'), findsNothing);

    // Alice 现在右翼,名字靠右外缘,仍可点回正面。
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3 · 点两侧卡切换,左右轻扫翻牌'), findsOneWidget);
    expect(find.text('a knight'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('next/previous buttons cycle with wrap-around', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three);

    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 3'), findsOneWidget);
    expect(find.text('a bard'), findsOneWidget);

    await tester.tap(find.byTooltip('上一张'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 3'), findsOneWidget);

    // 首张再往前 wraps 到末张。
    await tester.tap(find.byTooltip('上一张'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 3'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('horizontal swipe flips through the deck', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three);

    await tester.fling(
      find.byType(CharacterDeckView),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 3'), findsOneWidget);

    await tester.fling(
      find.byType(CharacterDeckView),
      const Offset(300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 3'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('slow horizontal drag still flips the deck', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three);

    expect(find.textContaining('1 / 3'), findsOneWidget);
    // 慢拖(低速度)越过位移阈值后松手:旧实现只看速度,这类手势没有反应。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CharacterDeckView)),
    );
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-12, 0));
      await tester.pump(const Duration(milliseconds: 80));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 3'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('drag follows with tilt and springs back below threshold', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three);

    Matrix4 deckTransform() =>
        tester
            .widget<AnimatedContainer>(find.byType(AnimatedContainer))
            .transform!;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CharacterDeckView)),
    );
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(-12, 0));
      await tester.pump(const Duration(milliseconds: 80));
    }
    // 拖动中:整副牌跟手左移、微微上抬并同向倾斜,而不是只有平移。
    final dragging = deckTransform();
    expect(dragging.entry(0, 3), lessThan(0));
    expect(dragging.entry(1, 3), lessThan(0));
    expect(dragging.entry(1, 0), isNot(0));

    // 停顿让松手速度归零:位移不足阈值,牌堆回弹且不翻牌。
    await tester.pump(const Duration(milliseconds: 150));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('1 / 3'), findsOneWidget);
    final settled = deckTransform();
    expect(settled.entry(0, 3), closeTo(0, 0.001));
    expect(settled.entry(1, 0), closeTo(0, 0.001));
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('front tap, enter button and menu act on the front record', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    final opened = <CharacterRecord>[];
    final acted = <CharacterRecord>[];
    await _pumpDeck(
      tester,
      db,
      _three,
      onOpen: opened.add,
      onActions: acted.add,
    );

    await tester.tap(find.text('a knight'));
    await tester.pumpAndSettle();
    expect(opened.single.id, 1);

    await tester.tap(find.text('进入对话'));
    await tester.pumpAndSettle();
    expect(opened.last.id, 1);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(acted.single.id, 1);

    // 换到 Bob 后,点卡面与菜单都作用于新的正面卡。
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('a bard'));
    await tester.pumpAndSettle();
    expect(opened.last.id, 2);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('single record hides flip controls and still opens', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    final opened = <CharacterRecord>[];
    await _pumpDeck(tester, db, [_three.first], onOpen: opened.add);

    expect(find.byTooltip('上一张'), findsNothing);
    expect(find.byTooltip('下一张'), findsNothing);
    // 索引行恒占位:单卡也显示「1 / 1」,卡区高度不随角色数跳变。
    expect(find.textContaining('1 / 1'), findsOneWidget);
    expect(find.text('a knight'), findsOneWidget);
    await tester.tap(find.text('进入对话'));
    await tester.pumpAndSettle();
    expect(opened.single.id, 1);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('restores the persisted front card by id', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three, initialFrontId: 2);

    expect(find.textContaining('2 / 3'), findsOneWidget);
    expect(find.text('a bard'), findsOneWidget);
    expect(find.text('a knight'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('missing persisted front id falls back to the first card', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three, initialFrontId: 99);

    expect(find.textContaining('1 / 3'), findsOneWidget);
    expect(find.text('a knight'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('front changes report the new character id', (tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    final changed = <int>[];
    await _pumpDeck(tester, db, _three, onFrontChanged: changed.add);

    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(changed, [2]);

    await tester.tap(find.text('Carol'));
    await tester.pumpAndSettle();
    expect(changed, [2, 3]);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('list changes keep the front card by id, else clamp', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    await _pumpDeck(tester, db, _three);
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 / 3'), findsOneWidget);

    // Carol 被过滤掉:下标 clamp 到末位,Bob 成为正面。
    await _pumpDeck(tester, db, [_three[0], _three[1]]);
    expect(find.textContaining('2 / 2'), findsOneWidget);
    expect(find.text('a bard'), findsOneWidget);

    // Bob 仍在列表里:按 id 保住正面,不因下标变化换卡(单卡仍显示索引行)。
    await _pumpDeck(tester, db, [_three[1]]);
    expect(find.textContaining('1 / 1'), findsOneWidget);
    expect(find.text('a bard'), findsOneWidget);
    await _pumpDeck(tester, db, _three);
    expect(find.textContaining('2 / 3'), findsOneWidget);
    expect(find.text('a bard'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('large deck bounds the visible fan and cycles cleanly', (
    tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async => db = await openTestDb());
    final nine = [for (var i = 1; i <= 9; i++) _record(i, 'Card$i', 'd$i')];
    await _pumpDeck(tester, db, nine);

    expect(find.textContaining('1 / 9'), findsOneWidget);
    // 正面 + 每侧 2 张可见;更深的卡是卡背,不带名字。
    expect(find.text('Card2'), findsOneWidget);
    expect(find.text('Card3'), findsOneWidget);
    expect(find.text('Card8'), findsOneWidget);
    expect(find.text('Card9'), findsOneWidget);
    expect(find.text('Card4'), findsNothing);
    expect(find.text('Card7'), findsNothing);
    expect(find.byTooltip('更多操作'), findsOneWidget);

    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 / 9'), findsOneWidget);
    expect(find.text('d2'), findsOneWidget);
    // 离开的正面卡流转到左翼,仍然可见。
    expect(find.text('Card1'), findsOneWidget);

    // 点可见侧翼卡直接换到正面。
    await tester.tap(find.text('Card4'));
    await tester.pumpAndSettle();
    expect(find.textContaining('4 / 9'), findsOneWidget);
    expect(find.text('d4'), findsOneWidget);

    // 连续翻完一整圈回到起点,不抛异常。
    for (var i = 0; i < 9; i++) {
      await tester.tap(find.byTooltip('下一张'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('4 / 9'), findsOneWidget);
    // 翻牌触发的头像读取是真实异步 DB 查询,结束前 drain 掉,不留 pending timer。
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('deck avatars load lazily through the shared provider', (
    tester,
  ) async {
    late final AppDatabase db;
    late final List<CharacterRecord> records;
    await tester.runAsync(() async {
      db = await openTestDb();
      final avatar = await putTestImageHash(db, width: 64, height: 84);
      final repo = CharacterRepository(db);
      await repo.insert(CharacterCard(name: 'Pixel', avatarHash: avatar));
      await repo.insert(CharacterCard(name: 'Quill', avatarHash: avatar));
      records = await repo.all();
    });
    await _pumpDeck(tester, db, records);
    await tester.runAsync(() async {
      for (var i = 0; i < 40 && find.byType(Image).evaluate().length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    // 正面与侧翼卡都走同一份惰性头像 provider。
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('P'), findsNothing);
    expect(find.text('Q'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });
}
