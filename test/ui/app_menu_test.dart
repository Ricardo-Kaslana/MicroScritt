// 菜单公共组件与主题令牌的回归:三点菜单排版/危险项红色、底部操作弹层
// 返回值语义、主题层菜单外观(圆角/白面)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/app_menu.dart';
import 'package:microscritt/ui/theme/app_theme.dart';

void main() {
  Widget harness(Widget child) => MaterialApp(theme: AppTheme.light(), home: Scaffold(body: child));

  group('theme menu tokens', () {
    for (final (name, theme) in [('light', AppTheme.light()), ('dark', AppTheme.dark())]) {
      test('popup menu and bottom sheet tokens ($name)', () {
        final scheme = theme.colorScheme;
        final popup = theme.popupMenuTheme;
        expect(popup.color, scheme.surface);
        expect(popup.surfaceTintColor, Colors.transparent);
        final shape = popup.shape as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(14));
        expect(shape.side.color, scheme.outlineVariant.withValues(alpha: 0.45));

        final sheet = theme.bottomSheetTheme;
        expect(sheet.backgroundColor, scheme.surface);
        expect(sheet.surfaceTintColor, Colors.transparent);
        final sheetShape = sheet.shape as RoundedRectangleBorder;
        expect(sheetShape.borderRadius, const BorderRadius.vertical(top: Radius.circular(20)));
      });
    }
  });

  testWidgets('AppPopupMenuButton renders items with icon and destructive red', (tester) async {
    final scheme = AppTheme.light().colorScheme;
    String? selected;
    await tester.pumpWidget(
      harness(
        AppPopupMenuButton<String>(
          tooltip: '操作',
          onSelected: (v) => selected = v,
          actions: const [
            MenuAction(value: 'edit', label: '编辑', icon: Icons.edit_outlined),
            MenuAction(value: 'delete', label: '删除', icon: Icons.delete_outline, destructive: true),
          ],
        ),
      ),
    );

    expect(find.byTooltip('操作'), findsOneWidget);
    await tester.tap(find.byTooltip('操作'));
    await tester.pumpAndSettle();

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    // 普通项图标吃主题 iconColor(onSurfaceVariant),危险项上 error 红。
    final editIcon = tester.widget<Icon>(find.descendant(of: find.byType(PopupMenuItem<String>), matching: find.byIcon(Icons.edit_outlined)));
    expect(editIcon.color, isNull);
    final deleteIcon = tester.widget<Icon>(find.byIcon(Icons.delete_outline));
    expect(deleteIcon.color, scheme.error);
    expect(tester.widget<Text>(find.text('删除')).style?.color, scheme.error);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(selected, 'delete');
  });

  testWidgets('showAppActionSheet returns picked value and renders subtitle', (tester) async {
    String? picked;
    await tester.pumpWidget(
      harness(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              picked = await showAppActionSheet<String>(
                context,
                actions: const [
                  MenuAction(value: 'import', label: '导入', icon: Icons.file_upload_outlined, subtitle: 'PNG 或 JSON'),
                  MenuAction(value: 'delete', label: '删除', icon: Icons.delete_outline, destructive: true),
                ],
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('导入'), findsOneWidget);
    expect(find.text('PNG 或 JSON'), findsOneWidget);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(picked, 'import');
  });

  testWidgets('showAppActionSheet returns null when dismissed by barrier', (tester) async {
    bool settled = false;
    String? picked = 'unset';
    await tester.pumpWidget(
      harness(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              picked = await showAppActionSheet<String>(
                context,
                actions: const [MenuAction(value: 'a', label: '甲', icon: Icons.circle)],
              );
              settled = true;
            },
            child: const Text('go'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(settled, isTrue);
    expect(picked, isNull);
  });
}
