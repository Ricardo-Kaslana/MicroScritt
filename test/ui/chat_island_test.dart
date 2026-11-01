// 灵动岛(聊天页顶部悬浮状态胶囊)的纯 widget 测试:直构 ChatState 驱动,
// 覆盖模式优先级、闪示 TTL、展开明细与各动作回调,不触达 DB。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/background_status.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/ui/widgets/chat_island.dart';

void main() {
  // 灵岛文本多为 Text.rich(主文亮 + 后缀灰两段 span),统一带 findRichText。
  Finder rich(String s) => find.textContaining(s, findRichText: true);

  Widget host(
    ChatState chat, {
    bool memoryInitPrompt = false,
    bool compacting = false,
    bool hidden = false,
    bool idleHushed = false,
    IslandHub? hub,
    VoidCallback? onOpenStatus,
    VoidCallback? onInterrupt,
    VoidCallback? onInitMemory,
    VoidCallback? onDismissMemoryInit,
    VoidCallback? onDismissError,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const SizedBox.expand(),
            ChatIsland(
              key: const ValueKey('chat-island'),
              chat: chat,
              memoryInitPrompt: memoryInitPrompt,
              compacting: compacting,
              hidden: hidden,
              idleHushed: idleHushed,
              hub: hub,
              onOpenStatus: onOpenStatus ?? () {},
              onInterrupt: onInterrupt ?? () {},
              onInitMemory: onInitMemory ?? () {},
              onDismissMemoryInit: onDismissMemoryInit ?? () {},
              onDismissError: onDismissError ?? () {},
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('空会话(无用量/无活动/无提示)灵岛整体隐藏', (tester) async {
    await tester.pumpWidget(host(const ChatState()));
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('用量粒:折叠显示主写摘要,点开有三路引擎分账 + 合计,再点收起', (tester) async {
    const chat = ChatState(
      inputTokens: 1200,
      outputTokens: 50,
      cachedInputTokens: 900,
      backgroundInputTokens: 100,
      backgroundOutputTokens: 10,
      backgroundCachedInputTokens: 40,
      compactInputTokens: 800,
      compactOutputTokens: 20,
      compactCachedInputTokens: 700,
    );
    await tester.pumpWidget(host(chat));
    await tester.pumpAndSettle();

    // 折叠粒只显示主写 in/out 摘要(千位折 k),不直接铺明细。
    expect(rich('in 1.2k'), findsOneWidget);
    expect(find.text('主写'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-island')));
    await tester.pumpAndSettle();
    expect(find.text('主写'), findsOneWidget);
    expect(find.text('后台'), findsOneWidget);
    expect(find.text('压缩'), findsOneWidget);
    expect(find.text('合计'), findsOneWidget);
    // 命中率明细:主写 cached 900/1200 → 75%,后台 40/100 → 40%。
    expect(rich('hit 75%'), findsOneWidget);
    expect(rich('hit 40%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-island')));
    await tester.pumpAndSettle();
    expect(find.text('主写'), findsNothing);
  });

  testWidgets('贴顶翻历史时用量粒让位(idleHushed),活动态不受影响', (tester) async {
    await tester.pumpWidget(
      host(
        const ChatState(inputTokens: 100, outputTokens: 5),
        idleHushed: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);

    // 同参数下有活动(错误警报)则照常显示:让位只作用于常驻用量粒。
    await tester.pumpWidget(
      host(const ChatState(error: '生成失败'), idleHushed: true),
    );
    await tester.pumpAndSettle();
    expect(rich('生成失败'), findsOneWidget);
  });

  testWidgets('流式活动态:波形 + 生成中秒表 + 本轮 out 增量,可展开分账,无中断钮', (tester) async {
    var interrupted = false;
    // 挂载先于任何 token 到达(outputTokens 0),增量基线归零;随后流内块把
    // 累计推到 456 —— 灵岛展示的是本轮增量 out +456,不是会话累计。
    const empty = ChatState(streaming: true);
    await tester.pumpWidget(host(empty, onInterrupt: () => interrupted = true));
    await tester.pump(const Duration(milliseconds: 300)); // 模式切换动画
    expect(rich('生成中'), findsOneWidget);
    // 流式期间灵岛不提供中断钮(输入区发送键已是中断,避免双重入口)。
    expect(find.byIcon(Icons.stop_rounded), findsNothing);

    // 流内推进:累计输出到达 456。
    await tester.pumpWidget(
      host(
        const ChatState(streaming: true, inputTokens: 200, outputTokens: 456),
        onInterrupt: () => interrupted = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(rich('out +456'), findsOneWidget);

    // 秒表走 Timer.periodic:FakeAsync 里 pump 一秒走一格。
    await tester.pump(const Duration(seconds: 1));
    expect(rich(' · 1s · '), findsOneWidget);

    // 流式粒可展开查看分账。
    await tester.tap(find.byKey(const ValueKey('chat-island')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('合计'), findsOneWidget);
    expect(rich('本轮 out +456'), findsOneWidget);
    expect(interrupted, isFalse);
  });

  testWidgets('后台维护中:状态 + 中断钮;点中断触发回调', (tester) async {
    var interrupted = false;
    await tester.pumpWidget(
      host(
        const ChatState(
          backgroundStatus: BackgroundStatus.running,
          backgroundSummary: '',
        ),
        onInterrupt: () => interrupted = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(rich('后台agent'), findsOneWidget);
    expect(rich('状态维护中'), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    expect(interrupted, isTrue);
  });

  testWidgets('后台收尾闪示:弹出运行后摘要,点粒进状态面板,TTL 后收敛回用量粒', (tester) async {
    var opened = false;
    const chat = ChatState(inputTokens: 100, outputTokens: 5);
    await tester.pumpWidget(
      host(
        chat.copyWith(backgroundStatus: BackgroundStatus.running),
        onOpenStatus: () => opened = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 轮次收尾:running → succeeded(带摘要),闪示弹出。
    await tester.pumpWidget(
      host(
        chat.copyWith(
          backgroundStatus: BackgroundStatus.succeeded,
          backgroundSummary: '变量 mood=calm',
        ),
        onOpenStatus: () => opened = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(rich('后台agent · 已完成'), findsOneWidget);
    expect(rich('变量 mood=calm'), findsOneWidget);

    // 点击闪示进状态面板。
    await tester.tap(find.byKey(const ValueKey('chat-island')));
    await tester.pump();
    expect(opened, isTrue);

    // TTL(5s)过后收敛回用量粒,后台摘要不再常驻顶部。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(rich('后台agent'), findsNothing);
    expect(rich('in 100'), findsOneWidget);
  });

  testWidgets('错误警报:显示错误文本,点关闭触发 onDismissError', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      host(
        const ChatState(error: '生成失败:网络超时'),
        onDismissError: () => dismissed = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(rich('生成失败:网络超时'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(dismissed, isTrue);
  });

  testWidgets('错误警报:收拢两行省略,点粒展开看全文,再点收起,关闭仍可用(EO 批)', (tester) async {
    var dismissed = false;
    const tail = '结尾标记ENDMARK';
    final longError = '生成失败:${'网关 502 · 上游错误,' * 30}$tail';
    await tester.pumpWidget(
      host(ChatState(error: longError), onDismissError: () => dismissed = true),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 收拢态:警报粒只有 Text.rich(maxLines: 2 绘制层省略),没有全文载体。
    expect(find.byType(SelectableText), findsNothing);

    // 点胶囊主体展开(收拢态胶囊中央就是错误文本,无内部命中区):
    // SelectableText 承载完整错误,逐字节无损。
    await tester.tap(find.byType(ChatIsland));
    await tester.pumpAndSettle();
    final shown = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data;
    expect(shown, longError, reason: '展开态必须逐字节显示完整错误');

    // 再点头部收起:全文载体退场,回到两行省略的警报粒。
    await tester.tap(find.text('请求出错(点击收起)').first);
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);

    // 关闭钮(收拢/展开两态都有)仍是抹掉错误,不是收起。
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(dismissed, isTrue);
  });

  testWidgets('初始化记忆行动项:按钮与关闭各自触发回调(替代旧提示条)', (tester) async {
    var initialized = false;
    var dismissed = false;
    await tester.pumpWidget(
      host(
        const ChatState(),
        memoryInitPrompt: true,
        onInitMemory: () => initialized = true,
        onDismissMemoryInit: () => dismissed = true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('新会话记忆为空'), findsOneWidget);
    expect(find.text('初始化记忆'), findsOneWidget);

    await tester.tap(find.text('初始化记忆'));
    await tester.pump();
    expect(initialized, isTrue);

    await tester.tap(find.byTooltip('关闭初始化提示'));
    await tester.pump();
    expect(dismissed, isTrue);
  });

  testWidgets('压缩中活动态:显示正在压缩文案', (tester) async {
    await tester.pumpWidget(host(const ChatState(), compacting: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在压缩会话历史…'), findsOneWidget);
  });

  testWidgets('命令反馈闪示(IslandHub):推入即显,TTL 后自动消失', (tester) async {
    final hub = IslandHub();
    addTearDown(hub.dispose);
    await tester.pumpWidget(host(const ChatState(), hub: hub));
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);

    hub.push('已压缩 12 条历史并生成摘要,保留最近 6 条', tone: IslandTone.success);
    // pumpAndSettle(而非单次 pump):胶囊从隐藏态形变到目标高度至少要两帧,
    // 单帧时外层 AnimatedSize 还停在零高盒,点击会落空。
    await tester.pumpAndSettle();
    expect(rich('已压缩 12 条'), findsOneWidget);

    // 点击闪示立即收起。
    await tester.tap(find.byKey(const ValueKey('chat-island')));
    await tester.pumpAndSettle();
    expect(rich('已压缩 12 条'), findsNothing);

    // 再推一条,不点击,TTL 到期自动消失(回到底层的隐藏态)。
    hub.push('已压缩 3 条历史并生成摘要,保留最近 6 条', tone: IslandTone.success);
    await tester.pump(const Duration(milliseconds: 300));
    expect(rich('已压缩 3 条'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('hidden:入场收敛期灵岛整体退场', (tester) async {
    await tester.pumpWidget(
      host(const ChatState(inputTokens: 100), hidden: true),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);
  });
}
