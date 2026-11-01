import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/app_search_field.dart';
import 'package:microscritt/ui/common/confirm_dialog.dart';
import 'package:microscritt/ui/common/empty_state.dart';
import 'package:microscritt/ui/common/searchable_list.dart';

void main() {
  testWidgets('EmptyState renders icon, title, message and action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyState(
            icon: Icons.person_add,
            title: '暂无角色',
            message: '导入一张角色卡开始',
            action: Text('导入'),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.person_add), findsOneWidget);
    expect(find.text('暂无角色'), findsOneWidget);
    expect(find.text('导入一张角色卡开始'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
  });

  testWidgets('confirm dialog returns true when confirmed', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showConfirmDialog(
                context,
                title: '删除会话?',
                message: '不可恢复',
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('删除会话?'), findsOneWidget);
    expect(find.text('不可恢复'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets(
    'SearchableList filters items and shows scroll-to-top after scrolling',
    (tester) async {
      final items = List.generate(40, (i) => 'item $i');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchableList<String>(
              items: items,
              searchText: (s) => s,
              itemBuilder: (context, s) => SizedBox(height: 60, child: Text(s)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('item 0'), findsOneWidget);
      expect(find.byTooltip('回到顶部'), findsNothing);

      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(find.byTooltip('回到顶部'), findsOneWidget);

      await tester.tap(find.byTooltip('回到顶部'));
      await tester.pumpAndSettle();
      expect(find.text('item 0'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'item 39');
      await tester.pumpAndSettle();
      // 输入框自身也会显示查询串,这里限定在列表内部匹配条目。
      final listItem = find.descendant(
        of: find.byType(ListView),
        matching: find.text('item 39'),
      );
      expect(listItem, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('item 0'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('SearchableList grid mode renders a GridView and filters', (
    tester,
  ) async {
    final items = List.generate(8, (i) => 'item $i');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchableList<String>(
            items: items,
            searchText: (s) => s,
            grid: true,
            itemBuilder: (context, s) => Text(s),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);

    await tester.enterText(find.byType(TextField), 'item 7');
    await tester.pumpAndSettle();
    final grid = find.byType(GridView);
    expect(
      find.descendant(of: grid, matching: find.text('item 7')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: grid, matching: find.text('item 0')),
      findsNothing,
    );
  });

  testWidgets('AppSearchField releases focus when tapping outside', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AppSearchField(controller: controller, onChanged: (_) {}),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final focusNode = tester
        .widget<TextField>(find.byType(TextField))
        .focusNode!;
    expect(focusNode.hasFocus, isTrue);

    // 测试宿主默认平台为 Android;若不主动失焦,点框外不会退出输入态。
    await tester.tapAt(const Offset(400, 500));
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
  });

  testWidgets('AppSearchField clear button exits input state', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AppSearchField(controller: controller, onChanged: (_) {}),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '角色');
    await tester.pumpAndSettle();
    final focusNode = tester
        .widget<TextField>(find.byType(TextField))
        .focusNode!;
    expect(focusNode.hasFocus, isTrue);

    await tester.tap(find.byTooltip('清除'));
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(focusNode.hasFocus, isFalse);
  });

  testWidgets('confirm dialog returns false when cancelled', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showConfirmDialog(context, title: '删除?');
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
