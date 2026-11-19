// 后台运行摘要的结构化渲染:成功摘要按变量/移除/待确认/生图分组拆条,
// 审计与重跑有独立标题行,失败摘要把引擎诊断拆到第二行;
// 认不出的文案仍整段回退,不丢信息。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/background_status.dart';
import 'package:microscritt/ui/status/status_widgets.dart';

void main() {
  Future<void> pumpSummary(
    WidgetTester tester,
    String text, {
    BackgroundStatus status = BackgroundStatus.succeeded,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: BackgroundSummaryView(text: text, status: status),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('成功摘要按变量/移除/待确认/生图分组展示', (tester) async {
    await pumpSummary(
      tester,
      '变量 mood=calm focus=high · 移除变量 old_flag · '
      '建议删除变量 temp,待确认 · 图片生成中',
    );

    expect(find.byKey(const ValueKey('background-summary-box')), findsOneWidget);
    for (final label in ['变量', '移除', '待确认', '生图']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('mood = calm', findRichText: true), findsOneWidget);
    expect(find.text('focus = high', findRichText: true), findsOneWidget);
    final removed = tester.widget<Text>(find.text('old_flag'));
    expect(removed.style?.decoration, TextDecoration.lineThrough);
    expect(find.text('temp'), findsOneWidget);
    expect(find.text('图片生成中'), findsOneWidget);
    // 结构化后不再整段平铺原始摘要。
    expect(find.textContaining('建议删除变量 temp,待确认'), findsNothing);
  });

  testWidgets('审计摘要以标题行与统计条呈现', (tester) async {
    await pumpSummary(tester, '审计完成:更新 3 键,删除 1 键');

    expect(find.text('审计完成'), findsOneWidget);
    expect(find.text('更新 3 键'), findsOneWidget);
    expect(find.text('删除 1 键'), findsOneWidget);
  });

  testWidgets('重跑与无变化摘要合并为标题行', (tester) async {
    await pumpSummary(tester, '重跑完成 · 状态维护完成(无明显变化)');

    expect(find.text('重跑完成 · 状态维护完成'), findsOneWidget);
    expect(find.text('无明显变化'), findsOneWidget);
  });

  testWidgets('失败摘要把引擎诊断拆到第二行', (tester) async {
    await pumpSummary(
      tester,
      '后台维护异常,已安全跳过(网关 502 · 上游错误)',
      status: BackgroundStatus.failed,
    );

    expect(find.text('后台维护异常,已安全跳过'), findsOneWidget);
    expect(find.text('诊断摘要:网关 502 · 上游错误'), findsOneWidget);
  });

  testWidgets('无法识别的成功摘要保持整段文本', (tester) async {
    const raw = '本轮维护成功:变量板与生图均已刷新。';
    await pumpSummary(tester, raw);

    expect(find.text(raw), findsOneWidget);
    expect(find.text('变量'), findsNothing);
  });

  testWidgets('变量值含空格时仍结构化,不整段回退', (tester) async {
    await pumpSummary(tester, '变量 mood=心情 很好 focus=high · 图片已生成');

    expect(find.text('变量'), findsOneWidget);
    expect(find.text('mood = 心情 很好', findRichText: true), findsOneWidget);
    expect(find.text('focus = high', findRichText: true), findsOneWidget);
    expect(find.textContaining('mood=心情 很好'), findsNothing);
  });

  testWidgets('窄屏组名在胶囊上方,宽屏组名在左', (tester) async {
    const summary = '变量 mood=calm';
    await pumpSummary(tester, summary);
    double labelY() => tester.getCenter(find.text('变量')).dy;
    double chipY() =>
        tester.getCenter(find.text('mood = calm', findRichText: true)).dy;
    expect(labelY(), lessThan(chipY()));

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpSummary(tester, summary);
    expect((labelY() - chipY()).abs(), lessThan(4));
  });
}
