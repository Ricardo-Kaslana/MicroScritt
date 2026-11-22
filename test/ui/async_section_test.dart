// AsyncSection:data/loading/error 三态、重试回调与紧凑/整页尺寸。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/async_section.dart';
import 'package:microscritt/ui/common/inline_spinner.dart';

void main() {
  testWidgets('AsyncSection data 态只渲染 builder 内容', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AsyncSection<String>(
            value: AsyncValue.data('ready'),
            builder: _buildData,
          ),
        ),
      ),
    );
    expect(find.text('ready'), findsOneWidget);
    expect(find.byType(InlineSpinner), findsNothing);
  });

  testWidgets('AsyncSection 紧凑档 loading 使用 24 加载圈', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AsyncSection<String>(
            value: AsyncValue.loading(),
            builder: _buildData,
          ),
        ),
      ),
    );
    final spinner = tester.widget<InlineSpinner>(find.byType(InlineSpinner));
    expect(spinner.size, 24);
    expect(spinner.strokeWidth, 2.5);
  });

  testWidgets('AsyncSection 整页 loading 使用 36 加载圈', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AsyncSection<String>(
            value: AsyncValue.loading(),
            compact: false,
            builder: _buildData,
          ),
        ),
      ),
    );
    final spinner = tester.widget<InlineSpinner>(find.byType(InlineSpinner));
    expect(spinner.size, 36);
    expect(spinner.strokeWidth, 4);
  });

  testWidgets('AsyncSection error 态展示错误与重试回调', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncSection<String>(
            value: AsyncValue.error('加载炸了', StackTrace.empty),
            onRetry: () => retried++,
            builder: _buildData,
          ),
        ),
      ),
    );

    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('加载炸了'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, 1);
  });

  testWidgets('AsyncSection errorBuilder 可覆盖错误版式', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AsyncSection<String>(
            value: AsyncValue.error('boom', StackTrace.empty),
            errorBuilder: _buildError,
            builder: _buildData,
          ),
        ),
      ),
    );
    expect(find.text('自定义错误：boom'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
  });
}

Widget _buildData(BuildContext context, String data) => Text(data);

Widget _buildError(BuildContext context, Object error) => Text('自定义错误：$error');
