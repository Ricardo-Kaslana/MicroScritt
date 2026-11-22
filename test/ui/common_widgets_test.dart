// 通用小组件:EmptyState、确认对话框返回值、可搜索列表(列表/网格)与
// 搜索框的焦点及清除行为。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/app_search_field.dart';
import 'package:microscritt/ui/common/app_snack_bar.dart';
import 'package:microscritt/ui/common/confirm_dialog.dart';
import 'package:microscritt/ui/common/empty_state.dart';
import 'package:microscritt/ui/common/info_dialog.dart';
import 'package:microscritt/ui/common/inline_spinner.dart';
import 'package:microscritt/ui/common/list_page_scaffold.dart';
import 'package:microscritt/ui/common/searchable_list.dart';
import 'package:microscritt/ui/common/section_header.dart';
import 'package:microscritt/ui/common/unsaved_changes_guard.dart';

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

  testWidgets('SurfaceCard 整卡水波点击与自定义底色', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SurfaceCard(
            color: Colors.amber,
            onTap: () => tapped++,
            child: const Text('入口'),
          ),
        ),
      ),
    );
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SurfaceCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, Colors.amber);
    await tester.tap(find.text('入口'));
    expect(tapped, 1);
  });

  testWidgets('SectionHeader 支持行尾动作', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SectionHeader(
            '用量',
            trailing: TextButton(onPressed: () {}, child: const Text('全部')),
          ),
        ),
      ),
    );
    expect(find.text('用量'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
  });

  testWidgets('ListPageScaffold 列表默认留出水平 16', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ListPageScaffold<String>(
          title: '列表',
          emptyState: const EmptyState(
            icon: Icons.inbox,
            title: '空',
            message: '空',
          ),
          searchHint: '搜索',
          searchText: (s) => s,
          items: const ['alpha'],
          itemBuilder: (context, s) => Text(s),
        ),
      ),
    );
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.padding, const EdgeInsets.fromLTRB(16, 4, 16, 96));
  });

  testWidgets('SearchableList no-match state clears the query', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchableList<String>(
            items: const ['alpha', 'beta'],
            searchText: (s) => s,
            itemBuilder: (context, s) => Text(s),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'gamma');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配项'), findsOneWidget);
    expect(find.text('清除搜索'), findsOneWidget);

    await tester.tap(find.text('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
  });

  testWidgets('UnsavedChangesGuard asks before discarding changes', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'initial');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => UnsavedChangesGuard(
                      hasChanges: () => controller.text != 'initial',
                      changes: [controller],
                      child: Scaffold(
                        appBar: AppBar(),
                        body: TextField(controller: controller),
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 无修改:返回直接退出,不弹确认。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'changed');
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('放弃未保存的修改?'), findsOneWidget);
    // 取消:留在编辑页。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
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

  testWidgets('InlineSpinner 使用指定边长与描边', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: InlineSpinner(size: 18, strokeWidth: 3)),
        ),
      ),
    );
    expect(tester.getSize(find.byType(InlineSpinner)), const Size(18, 18));
    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.strokeWidth, 3);
  });

  testWidgets('showAppSnack 窄窗保持满宽并替换当前条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                ElevatedButton(
                  onPressed: () => showAppSnack(context, '第一条'),
                  child: const Text('one'),
                ),
                ElevatedButton(
                  onPressed: () => showAppSnack(context, '第二条'),
                  child: const Text('two'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('one'));
    await tester.pump();
    expect(find.text('第一条'), findsOneWidget);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).width, isNull);

    await tester.tap(find.text('two'));
    await tester.pumpAndSettle();
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('第一条'), findsNothing);
  });

  testWidgets('showAppSnack 宽窗封顶 480 并透传动作', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var undone = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAppSnack(
                context,
                '已删除',
                action: SnackBarAction(
                  label: '撤销',
                  onPressed: () => undone = true,
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.width, 480);
    expect(bar.behavior, SnackBarBehavior.floating);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(undone, isTrue);
  });

  testWidgets('showInfoDialog 渲染要点/注释/脚注并可关闭', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showInfoDialog(
                context,
                title: '说明标题',
                bullets: const ['要点一', '要点二'],
                note: '补充注释',
                footnotes: const ['脚注'],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('说明标题'), findsOneWidget);
    expect(find.text('要点一'), findsOneWidget);
    expect(find.text('要点二'), findsOneWidget);
    expect(find.text('补充注释'), findsOneWidget);
    expect(find.text('脚注'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('说明标题'), findsNothing);
  });
}
