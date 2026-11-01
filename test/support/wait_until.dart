// 条件轮询等待工具:替代固定延时,消除真实 I/O 在慢机器上的偶发失败。
import 'package:flutter_test/flutter_test.dart';

/// 轮询等待 [condition] 成立,最多 [maxPolls] 次、每次间隔 [interval]。
///
/// 用来替代固定的 `Future.delayed(...)`:widget 测试里等真实 I/O(DB 读取、
/// provider 解析)时,**固定延时在慢机器/全量套件并发跑时会偶发不够**,断言
/// 直接扑空。本仓库已经踩过不止一次 —— `context_panel_test.dart` 里四个测试
/// 为此把 150ms 放宽到 400ms,却漏改了第一个,2026-09-28 实测约 1/4 概率挂。
/// 按条件等待把"够不够"交给事实判断,不再靠猜时长。
///
/// 轮询期间必须留在 `runAsync` 里 —— 否则真实 I/O 不会推进,条件永远等不到
/// (widget 测试默认跑在假时钟上,`pumpAndSettle` 只推进假时钟)。结束时
/// `pumpAndSettle` 让最后一帧的动画收敛。
Future<void> waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPolls = 100,
  Duration interval = const Duration(milliseconds: 50),
}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < maxPolls; i++) {
      if (condition()) return;
      await Future<void>.delayed(interval);
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

/// [waitUntil] 的收尾版本:条件一直不成立时以 [reason] 失败,而不是让后续断言
/// 报一句"找不到某个 widget"——后者看不出是数据没到还是渲染错了。
Future<void> waitUntilOrFail(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxPolls = 100,
  Duration interval = const Duration(milliseconds: 50),
}) async {
  await waitUntil(tester, condition, maxPolls: maxPolls, interval: interval);
  expect(condition(), isTrue, reason: '等待超时:$reason');
}
