import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/worldbook_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import '../support/test_database.dart';

/// 名词释义卡(点气泡内高亮词条弹出的底部卡)的布局回归。
void main() {
  /// 等 ChatController.load 完成 + llmProviders/worldbook 就绪 —— 词条高亮
  /// 依赖世界书 FutureProvider 解析完成后气泡才带点选手势。
  Future<void> settle(WidgetTester tester, int characterId) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
        final loaded = container.read(chatControllerProvider).sessionId != null;
        final llmReady = !container.read(llmProvidersProvider).isLoading;
        final wbReady = !container.read(worldbookProvider(characterId)).isLoading;
        if (loaded && llmReady && wbReady) break;
      }
      await tester.pumpAndSettle();
    });
  }

  testWidgets('term card header wraps long titles without overflowing the row', (tester) async {
    // 320 逻辑像素宽的窄视口(弹层内容区 320-40=280):旧实现的标题胶囊按自然
    // 宽度参与 Row 布局,长词条名直接把 Row 顶出右缘(RenderFlex overflow)。
    tester.view
      ..physicalSize = const Size(640, 800)
      ..devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final longTitle = '极长词条名' * 20; // 测试字体下 14px/字 ≈ 1400px,远超 280
    late final AppDatabase db;
    late int sessionId;
    late int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      // 填充两条普通消息:列表正常揭示后,顶部悬浮「灵动岛」会接管其悬浮区
      // 内的点击(DX 批设计);词条若在首条消息(正处岛下)将点不到。垫高让
      // 词条消息落在岛区之下的可点范围。
      await MessageRepository(db).append(sessionId: sessionId, role: 'assistant', content: '开场白一条。');
      await MessageRepository(db).append(sessionId: sessionId, role: 'user', content: '回应一句。');
      await MessageRepository(db).append(sessionId: sessionId, role: 'assistant', content: '魔力');
      await WorldbookRepository(db).replaceForCharacter(charId, [
        WorldbookEntry(characterId: charId, name: longTitle, keys: const ['魔力'], content: '词条正文。'),
      ]);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(sessionId: sessionId, characterId: charId, character: const CharacterCard(name: 'Alice')),
        ),
      ),
    );
    await settle(tester, charId);

    // 正文恰为词条本身:整段文本带点选手势,点中即弹释义卡。
    await tester.tap(find.text('魔力'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 释义卡打开:长词条名标题 + 关闭按钮并存;旧代码在此抛 RenderFlex overflow。
    expect(find.text(longTitle), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
