import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import '../support/test_database.dart';

/// 用 dart:ui 画纯色矩形并编码为 PNG base64(宽高比确定、可解码)。
Future<String> _pngBase64(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff4477aa),
  );
  final img = await recorder.endRecording().toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return base64Encode(data!.buffer.asUint8List());
}

/// 主写后端:只吐一段正文。发送流程本身不需要更多。
class _FakeBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    yield const TextDelta('这是一条回复正文。');
    yield const DoneEvent();
  }
}

/// 只等真实异步完成、不主动 pump(贴近真机:数据帧由 vsync 驱动)。
Future<void> _waitForMessages(WidgetTester tester, int expected) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      if (container.read(chatControllerProvider).messages.length == expected) {
        return;
      }
    }
  });
}

void main() {
  testWidgets('长会话+图片:进入即贴底,发送消息与图片改高全程视口纹丝不动', (tester) async {
    // 用户报告:几百条消息 + 图片的会话里,发送消息会让列表「先快速滚到远处
    // 又滚回来」,有时干脆滚不回来。根因是贴底跟随要跳到 `maxScrollExtent` ——
    // 懒加载列表里它是「已布局窗口平均高度 × 剩余条数」的估算,而本列表条目
    // 高度差异极大(短文本 ~100px vs 图片气泡数百 px)且图片高度异步变化,实测
    // 可偏离真值 2.6 倍;`jumpTo` 不做边界钳制,落点越过真实末尾落进空白死区,
    // 再被弹簧拖回。
    //
    // 列表改 `reverse: true` 后贴底恒为 offset 0:内容在偏移更大的一侧生长,
    // 不移动 offset 0 处的内容,所以发送消息、图片解码改高、视口缩放都**不可能**
    // 让视口离开底部。本用例守这条不变量 —— 逐帧断言 offset 恒为 0 且从不越界。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      // 250 条:每 2 条一张竖图(2:3 → 真实高约为宽的 1.5 倍,远高于占位),
      // 制造与真机同源的"图片陆续解码改高"。
      final portrait = await _pngBase64(40, 60);
      final repo = MessageRepository(db);
      for (var i = 0; i < 250; i++) {
        await repo.append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '消息 $i:${'一段用来撑高的正文内容。' * 6}',
          imageBase64: i.isEven ? portrait : null,
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith((ref) => _FakeBackend()),
        ],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _waitForMessages(tester, 250);
    await tester.pump();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

    // 进入即贴底(reverse:offset 0),首屏就是最新消息。
    expect(position.pixels, 0, reason: '进入会话应直接落在底部');
    expect(position.outOfRange, isFalse);
    expect(find.textContaining('消息 249'), findsOneWidget, reason: '首屏应是最新消息');

    // 逐帧记录:图片解码改高期间视口必须纹丝不动。
    var maxAbsDelta = 0.0;
    var prev = position.pixels;
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final delta = (position.pixels - prev).abs();
      if (delta > maxAbsDelta) maxAbsDelta = delta;
      prev = position.pixels;
      expect(position.pixels, 0, reason: '第 $i 帧:图片改高期间视口应停在底部');
      expect(position.outOfRange, isFalse, reason: '第 $i 帧:视口越界');
    }
    expect(maxAbsDelta, 0, reason: '图片改高不应移动视口一像素');

    // 发送一轮:消息落库 + 流式草稿 + 落库替换,全程逐帧断言视口不动。
    final accepted = container.read(chatControllerProvider.notifier).trySend('再来一轮');
    expect(accepted, isTrue, reason: '测试前提:发送应被接受');
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      final delta = (position.pixels - prev).abs();
      if (delta > maxAbsDelta) maxAbsDelta = delta;
      prev = position.pixels;
      expect(position.pixels, 0, reason: '第 $i 帧:发送过程中视口应停在底部');
      expect(position.outOfRange, isFalse, reason: '第 $i 帧:视口越界');
    }
    expect(maxAbsDelta, 0, reason: '发送消息不应移动视口一像素(不得出现"滚到远处又滚回来")');
    // 发送后的最新内容就在眼前(视口没有被甩走)。
    expect(find.textContaining('再来一轮'), findsOneWidget, reason: '刚发送的消息应可见');

    await tester.runAsync(() => db.db.close());
  });

  testWidgets('补页不移动视口:旧页追加在列表远端,无需锚定', (tester) async {
    // 非反向坐标下"前拼旧页"会让已有内容整体下移一页,必须按 maxScrollExtent
    // 增量把视口前移来抵消(锚定)。reverse 下补页是追加到列表**远端**(更大
    // 下标),已有条目到内容底部的距离不变 —— 视口原地不动,用户继续上滑即可
    // 看到新页。本用例把视口放在中部(远离两端,不会触发贴顶分页/贴底跟随)后
    // 直接补一页,守这条不变量:补页不得让视口移动哪怕一像素。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late final AppDatabase db;
    late final int sid;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sid = await SessionRepository(db).create(charId, 's');
      final repo = MessageRepository(db);
      for (var i = 0; i < 400; i++) {
        await repo.append(
          sessionId: sid,
          role: i.isEven ? 'user' : 'assistant',
          content: '补页消息 $i:${'正文' * 40}',
        );
      }
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sid,
            characterId: 1,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await _waitForMessages(tester, 300); // 显示窗口 = 尾部 300 行
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('messages-area')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(position.pixels, 0, reason: '进入应贴底');
    expect(container.read(chatControllerProvider).canLoadOlder, isTrue, reason: '测试前提:还有更早的页');

    // 视口放到列表中部:远离贴顶/贴底邻域,滚动回调不会自发触发分页。
    position.jumpTo(position.maxScrollExtent * 0.5);
    await tester.pumpAndSettle();
    final before = position.pixels;
    expect(before, greaterThan(80), reason: '测试前提:已离开底部邻域');

    // 直接补一页更早的历史(不经过贴顶回调),检查视口是否被移动。
    await tester.runAsync(
      () => container.read(chatControllerProvider.notifier).loadOlder(),
    );
    await tester.pumpAndSettle();

    expect(container.read(chatControllerProvider).messages.length, 400, reason: '旧页应已补入');
    expect(container.read(chatControllerProvider).canLoadOlder, isFalse);
    expect(
      position.pixels,
      closeTo(before, 1.0),
      reason: '补页不得移动视口(reverse 下旧页追加在远端,无需锚定)',
    );

    await tester.runAsync(() => db.db.close());
  });
}
