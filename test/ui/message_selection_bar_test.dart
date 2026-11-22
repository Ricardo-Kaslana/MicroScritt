// 多选快捷栏响应式布局:窄屏左右分组、宽屏单行居中,删除/导出在 AppBar。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/chat_layout.dart';
import 'package:microscritt/ui/widgets/message_selection_bar.dart';

Widget _harness() => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: MessageSelectionBar(
        onSelectAll: () {},
        onClearSelection: () {},
        onSelectImages: () {},
        onSelectText: () {},
      ),
    ),
  ),
);

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Rect _rect(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(ValueKey(key)));

void main() {
  testWidgets('窄屏左右分组且删除/导出不在底部栏', (tester) async {
    _setView(tester, const Size(360, 640));
    await tester.pumpWidget(_harness());
    await tester.pump();

    final all = _rect(tester, 'message_selection_all');
    final none = _rect(tester, 'message_selection_none');
    final images = _rect(tester, 'message_selection_images');
    final text = _rect(tester, 'message_selection_text');
    final bar = _rect(tester, 'message_selection_bar');

    // 左组贴左、右组贴右,中间留出分组空隙;4 个快捷项同一行。
    expect(all.left, closeTo(bar.left + 10, 1));
    expect(text.right, closeTo(bar.right - 10, 1));
    expect(none.right, lessThan(images.left));
    expect(none.center.dy, closeTo(all.center.dy, 0.5));
    expect(images.center.dy, closeTo(all.center.dy, 0.5));
    expect(text.center.dy, closeTo(all.center.dy, 0.5));

    // 操作按钮已移到 AppBar,底部栏只占一行。
    expect(
      find.byKey(const ValueKey('message_selection_delete')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('message_selection_export')),
      findsNothing,
    );
    expect(bar.height, lessThan(60));
  });

  testWidgets('宽屏单行居中且内容封顶', (tester) async {
    _setView(tester, const Size(1400, 900));
    await tester.pumpWidget(_harness());
    await tester.pump();

    final all = _rect(tester, 'message_selection_all');
    final text = _rect(tester, 'message_selection_text');
    final bar = _rect(tester, 'message_selection_bar');

    // 四个快捷项同一水平带,整体居中。
    expect(text.center.dy, closeTo(all.center.dy, 0.5));
    expect((all.center.dx + text.center.dx) / 2, closeTo(700, 8));
    // 宽窗内容列封顶 880,左右各留 12,居中于视口。
    expect(bar.width, lessThanOrEqualTo(chatColumnMaxWidth(1400) - 24));
    expect(bar.center.dx, closeTo(700, 0.5));
  });
}