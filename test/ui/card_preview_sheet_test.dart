// 最终卡预览:窄屏名片、分区内容、空态与世界书展开。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/ui/card_studio/card_preview_sheet.dart';
import 'package:microscritt/ui/theme/app_theme.dart';

void main() {
  void useSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPreview(
    WidgetTester tester, {
    required CharacterCard card,
    List<WorldbookEntry> entries = const [],
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
          body: CardPreviewSheet(card: card, entries: entries),
        ),
      ),
    );
  }

  testWidgets('窄屏使用横向名片并保留完整分区', (tester) async {
    useSurface(tester, const Size(360, 800));
    await pumpPreview(
      tester,
      card: const CharacterCard(
        name: '星港引路人',
        description: '在废弃空间站等待旅人的向导。',
        personality: '安静而可靠',
        firstMessage: '欢迎回来，旅人。',
        alternateGreetings: ['今晚的星潮很平静。'],
        creator: '测试作者',
        characterVersion: '1.0',
        tags: ['科幻', '治愈'],
      ),
      entries: const [
        WorldbookEntry(
          characterId: 1,
          name: '星港',
          keys: ['港口', '空间站'],
          content: '星港环绕一颗蓝巨星运行。',
          enabled: false,
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('card_preview_identity_sidebar')),
      findsNothing,
    );
    final cover = find.byKey(const ValueKey('card_preview_cover'));
    expect(tester.getSize(cover).width, 144);
    expect(tester.getSize(cover).height, 180);
    expect(find.text('角色设定'), findsOneWidget);
    expect(find.text('对话开场'), findsOneWidget);
    expect(find.text('世界书 · 1 条'), findsOneWidget);
    expect(find.text('高级字段 · 2 项'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('星港'),
      240,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('card_preview_sheet')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('星港'));
    await tester.pumpAndSettle();
    expect(find.text('星港环绕一颗蓝巨星运行。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空卡显示名称回退与世界书空态', (tester) async {
    useSurface(tester, const Size(360, 800));
    await pumpPreview(tester, card: const CharacterCard());
    await tester.pumpAndSettle();

    expect(find.text('未命名角色'), findsOneWidget);
    expect(find.text('世界书 · 0 条'), findsOneWidget);
    expect(find.text('这张角色卡没有世界书条目'), findsOneWidget);
    expect(find.text('角色设定'), findsNothing);
    expect(find.text('对话开场'), findsNothing);
    expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
