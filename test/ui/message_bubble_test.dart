// 消息气泡:图片渲染(base64/URL/磁盘缓存、解码帧复用、尺寸上限)与全屏查看器;
// 另覆盖气泡宽度上限、{{user}} 替换、可折叠指令块与 @skill 记号染色。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/disk_image_cache.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/ui/skill_highlight.dart';
import 'package:microscritt/ui/widgets/message_bubble.dart';
import 'package:microscritt/ui/widgets/message_list.dart';

/// 用 dart:ui 画一块纯色矩形并编码为 PNG 的 base64,得到一张"真实已知宽高比"
/// 的图片(测试解码后气泡按固有比例自适应,不再被固定 200 高 cover 裁切)。
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

/// 反复 pump 直到 [condition] 成立(图片解码是真实异步,固定延时在负载下会抖)。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 30 && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  testWidgets('renders the image when imageBase64 is set', (tester) async {
    // 用引擎生成的合法 PNG(硬编码 1x1 base64 在测试解码器下可能不产出帧)。
    final base64 = await tester.runAsync(() => _pngBase64(1, 1));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    // 图片解码是真实异步:等 RawImage(解码帧)出现。
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('renders a data-URI (data:image) message image', (tester) async {
    final raw = await tester.runAsync(() => _pngBase64(1, 1));
    final msg = Message(sessionId: 1, role: 'user', content: '', seq: 0, imageBase64: 'data:image/png;base64,$raw');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('renders no image (and does not crash) on corrupt base64', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'bad image',
      seq: 0,
      imageBase64: 'not-valid-base64!!!',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    expect(find.byType(RawImage), findsNothing);
    expect(find.text('bad image'), findsOneWidget);
  });

  testWidgets('renders a network image when imageUrl is set', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'cloud img',
      seq: 0,
      imageUrl: 'https://img.example.com/api/images/img_x/content',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    // flutter_test 默认把网络图片请求打成 400 → 无帧可显(仅历史 URL 消息走网络,
    // 新生成的图都已在生成时下载落库为 base64)。气泡文本与其余部分不受影响。
    expect(find.text('cloud img'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed network image shows a broken placeholder instead of spinning forever', (tester) async {
    // 回归防护「URL-only 消息在重启/联网失败时无限转圈」:flutter_test 把网络
    // 请求打成 400 → 下载失败 → 静态破碎占位替代永不停歇的 CircularProgressIndicator。
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageUrl: 'https://img.example.com/api/images/img_x/content',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(tester, () => find.byIcon(Icons.broken_image_outlined).evaluate().isNotEmpty);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('URL bubble renders from the disk cache without hitting the network', (tester) async {
    // 回归防护「气泡与其全屏查看器状态不一致」:URL-only 消息磁盘缓存命中时必须
    // 从本地字节解码出帧 —— 测试环境网络一律 400,若误走 NetworkImage 则无帧可显。
    final tmp = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('msc_bubble_net');
      DiskImageCache.overrideRoot = () async => dir;
      return dir;
    }))!;
    addTearDown(() async {
      DiskImageCache.overrideRoot = null;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    const url = 'https://img.example.com/api/images/disk_hit';
    final png = (await tester.runAsync(() => _pngBase64(30, 20)))!;
    await tester.runAsync(() => DiskImageCache.write(url, base64Decode(png)));

    const msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageUrl: url);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('memory image reuses the same decoded frame across rebuilds', (tester) async {
    // 回归防护「已生成的图片在对话中反复重新加载」:同一 base64 重建气泡时,
    // _CachedMemoryImage 的 State 缓存解码结果,_AdaptiveImage 不重新解析,
    // 渲染的仍是同一帧(RawImage.image 指向同一个 ui.Image)。
    final base64 = await tester.runAsync(() => _pngBase64(1, 1));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    final first = tester.widget<RawImage>(find.byType(RawImage)).image;

    // 同一 base64 重建 → 同一解码帧(未重新解码)。
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    final second = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(identical(first, second), isTrue);
  });

  testWidgets('tall portrait images decode within the bubble height cap', (tester) async {
    // 回归防护「竖图按宽度解码出超高帧」:100×4000 的图只按宽度上限解码会得到
    // 100×(1520/100×4000) 的超大帧;宽高双上限后应封在图片框高度(520 逻辑像素)。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final base64 = await tester.runAsync(() => _pngBase64(100, 4000));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(image.height, 520);
    expect(image.width, lessThanOrEqualTo(100));
  });

  testWidgets('long press invokes the callback', (tester) async {
    var pressed = false;
    const msg = Message(sessionId: 1, role: 'user', content: 'press me', seq: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: msg, onLongPress: () => pressed = true),
        ),
      ),
    );
    await tester.longPress(find.text('press me'));
    expect(pressed, isTrue);
  });

  testWidgets('assistant bubble hugs content and caps at the mobile max width', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 短消息:按内容自适应,远小于满行宽。
    const short = Message(sessionId: 1, role: 'assistant', content: 'hi', seq: 0);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MessageBubble(message: short))));
    final shortBox = tester.widget<Container>(
      find.ancestor(of: find.text('hi'), matching: find.byType(Container)).first,
    );
    final shortWidth = tester.getSize(find.byWidget(shortBox)).width;
    expect(shortWidth, lessThan(200));
    expect(shortWidth, greaterThan(0));

    // 长文本:被限制在移动端助手上限(整行 320,不含左右 12 边距)。
    final longText = '这是一条非常长的助手消息,用于验证移动端助手气泡在内容超出时封顶在满行宽,而不是无限撑开。' * 6;
    final long = Message(sessionId: 1, role: 'assistant', content: longText, seq: 1);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: long))));
    final longBox = tester.widget<Container>(
      find.ancestor(of: find.textContaining('这是一条非常长'), matching: find.byType(Container)).first,
    );
    // 容器总宽 = 气泡 296 + 左右各 12 边距 = 320。
    expect(tester.getSize(find.byWidget(longBox)).width, closeTo(320, 0.5));
  });

  testWidgets('user bubble hugs the content width (short text is not stretched full-width)', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const msg = Message(sessionId: 1, role: 'user', content: 'hi', seq: 0);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );

    final container = tester.widget<Container>(
      find.ancestor(of: find.text('hi'), matching: find.byType(Container)).first,
    );
    // 短消息应按内容自适应,远小于 520 上限(否则说明 stretch 把文字撑满了)。
    final width = tester.getSize(find.byWidget(container)).width;
    expect(width, lessThan(200));
    expect(width, greaterThan(0));
  });

  testWidgets('user bubble caps at the normal max width for long text', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longText = '这是一条非常非常长的用户消息,用来验证桌面端用户气泡被限在正常宽度而不是被拉成助手那样的大宽。' * 6;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: Message(sessionId: 1, role: 'user', content: longText, seq: 0),
          ),
        ),
      ),
    );

    final container = tester.widget<Container>(
      find.ancestor(of: find.textContaining('这是一条'), matching: find.byType(Container)).first,
    );
    final width = tester.getSize(find.byWidget(container)).width;
    expect(width, lessThanOrEqualTo(520 + 24 + 0.5)); // 520 上限 + 左右 12 边距
    expect(width, lessThan(760));
  });

  testWidgets('secondary tap (right-click, desktop) invokes the callback', (tester) async {
    var pressed = false;
    const msg = Message(sessionId: 1, role: 'assistant', content: 'right click me', seq: 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: msg, onLongPress: () => pressed = true),
        ),
      ),
    );
    await tester.tap(find.text('right click me'), buttons: kSecondaryButton);
    expect(pressed, isTrue);
  });

  testWidgets('assistant bubble hugs content and caps at the desktop max width', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 短消息:按内容自适应,远小于桌面上限 784。
    const short = Message(sessionId: 1, role: 'assistant', content: 'hi', seq: 0);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MessageBubble(message: short))));
    final shortBox = tester.widget<Container>(
      find.ancestor(of: find.text('hi'), matching: find.byType(Container)).first,
    );
    final shortWidth = tester.getSize(find.byWidget(shortBox)).width;
    expect(shortWidth, lessThan(400));
    expect(shortWidth, greaterThan(0));

    // 长文本:被封顶在桌面助手上限 760(含左右 12 边距 = 784)。
    final longText = '这是一条非常长的助手消息,用于验证桌面端助手气泡在内容超出时封顶在 760 上限,而不是无限撑开。' * 8;
    final long = Message(sessionId: 1, role: 'assistant', content: longText, seq: 1);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: long))));
    final longBox = tester.widget<Container>(
      find.ancestor(of: find.textContaining('这是一条非常长'), matching: find.byType(Container)).first,
    );
    expect(tester.getSize(find.byWidget(longBox)).width, 784);
  });

  testWidgets('user bubble stays at normal width on a desktop surface (not stretched to 760)', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const msg = Message(sessionId: 1, role: 'user', content: 'hi', seq: 0);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );

    final container = tester.widget<Container>(
      find.ancestor(of: find.text('hi'), matching: find.byType(Container)).first,
    );
    // 用户气泡不强制撑到 760(助手那档),而是按内容自适应、最多 520。
    final width = tester.getSize(find.byWidget(container)).width;
    expect(width, lessThan(760));
    expect(width, lessThanOrEqualTo(520 + 24 + 0.5)); // 520 上限 + 左右 12 边距
  });

  testWidgets('assistant bubble caps wider than the user bubble on desktop (760 vs 520)', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 用同样长的长文本:用户封顶 520、助手封顶 760,助手明显更宽。
    final longText = '这是一条非常非常长的消息,用来验证桌面端助手与用户气泡在内容超出时各自封顶在不同的最大宽度。' * 8;
    final user = Message(sessionId: 1, role: 'user', content: longText, seq: 0);
    final ai = Message(sessionId: 1, role: 'assistant', content: longText, seq: 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageBubble(message: user),
              MessageBubble(message: ai),
            ],
          ),
        ),
      ),
    );

    final userWidth = tester
        .getSize(find.ancestor(of: find.textContaining('这是一条非常非常长').first, matching: find.byType(Container)).first)
        .width;
    final aiWidth = tester
        .getSize(find.ancestor(of: find.textContaining('这是一条非常非常长').last, matching: find.byType(Container)).first)
        .width;
    expect(aiWidth, closeTo(784, 0.5)); // 助手封顶 760 + 边距
    expect(userWidth, lessThan(aiWidth)); // 用户封顶更窄(520)
    expect(userWidth, lessThanOrEqualTo(520 + 24 + 0.5));
  });

  testWidgets('replaces {{user}} in the displayed text only when a username is given', (tester) async {
    const raw = Message(
      sessionId: 1,
      role: 'assistant',
      content: '你好 {{user}},欢迎回来 {{user}}',
      seq: 0,
    );
    // 未提供用户名 → 原样保留占位符(存储不被动)。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MessageBubble(message: raw))),
    );
    expect(find.text('你好 {{user}},欢迎回来 {{user}}'), findsOneWidget);

    // 提供用户名 → 显示层替换,但 message.content 本身仍保留 {{user}}。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MessageBubble(message: raw, displayUserName: '小明'))),
    );
    expect(find.text('你好 小明,欢迎回来 小明'), findsOneWidget);
    expect(raw.content, '你好 {{user}},欢迎回来 {{user}}');
  });

  testWidgets('a wide image is sized by its aspect ratio instead of a fixed 200-height crop', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 2:1 宽图:气泡应按"宽度 = 固有比例"定高(高 = 宽/2),而不是固定 200 高 + cover 裁切。
    // toImage/toByteData 是真实异步,必须在 tester.runAsync 窗口内完成。
    final base64 = await tester.runAsync(() => _pngBase64(200, 100));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    // 等到解码帧出现且按固有 2:1 比例定高(不再是解码前的方形占位)。
    await _pumpUntil(tester, () {
      final img = find.byType(RawImage);
      if (img.evaluate().isEmpty) return false;
      final s = tester.getSize(img);
      return s.height > 0 && (s.height - s.width / 2).abs() < 3;
    });

    final size = tester.getSize(find.byType(RawImage));
    expect(size.height, closeTo(size.width / 2, 2)); // 按固有 2:1 比例
    expect(size.height, lessThan(200)); // 不再是固定 200 高的裁切框
  });

  testWidgets('a portrait image keeps its full shape (no vertical crop)', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 3:4 竖图:高 = 宽 × 4/3,完整展示。
    final base64 = await tester.runAsync(() => _pngBase64(120, 160));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () {
      final img = find.byType(RawImage);
      if (img.evaluate().isEmpty) return false;
      final s = tester.getSize(img);
      return s.height > 0 && (s.height - s.width * 4 / 3).abs() < 3;
    });

    final size = tester.getSize(find.byType(RawImage));
    expect(size.height, closeTo(size.width * 4 / 3, 2)); // 3:4 比例,无上下裁切
  });

  testWidgets('a square image bubble keeps the square shape on desktop (no side letterbox)', (tester) async {
    // 回归防护「生图气泡形状贴合图片」:方图在桌面宽气泡上自然高(满宽 732)超过
    // 520 上限,旧实现只压高度不压宽度 → 732×520 宽框 + contain 左右留边,气泡
    // 形状与图片不符。现在按比例同步收窄宽度:框 = 520×520,形状与图片一致。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base64 = await tester.runAsync(() => _pngBase64(100, 100));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () {
      final img = find.byType(RawImage);
      if (img.evaluate().isEmpty) return false;
      final s = tester.getSize(img);
      return s.width > 0 && (s.width - 520).abs() < 3 && (s.height - 520).abs() < 3;
    });

    final size = tester.getSize(find.byType(RawImage));
    expect(size.width, closeTo(520, 2));
    expect(size.height, closeTo(520, 2));
    expect(size.width, lessThan(700)); // 不再是 732 满宽框
  });

  testWidgets('a portrait image bubble keeps its shape on desktop (width shrinks, no letterbox)', (tester) async {
    // 3:4 竖图在桌面气泡上:自然高 976 > 520 → 旧实现 732×520 留边;现在
    // 收窄宽度到 520×3/4 = 390,框比例 == 图比例,气泡贴合竖图形状。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base64 = await tester.runAsync(() => _pngBase64(90, 120));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () {
      final img = find.byType(RawImage);
      if (img.evaluate().isEmpty) return false;
      final s = tester.getSize(img);
      return s.width > 0 && (s.height - 520).abs() < 3;
    });

    final size = tester.getSize(find.byType(RawImage));
    expect(size.height, closeTo(520, 2));
    expect(size.width, closeTo(520 * 3 / 4, 3)); // 按固有比例收窄,不再 732 满宽
  });

  testWidgets('a wide image still fills the bubble width on desktop (no needless shrink)', (tester) async {
    // 2:1 横图:自然高 732/2 = 366 < 520 上限 → 维持满宽,只是不再裁切。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base64 = await tester.runAsync(() => _pngBase64(200, 100));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () {
      final img = find.byType(RawImage);
      if (img.evaluate().isEmpty) return false;
      final s = tester.getSize(img);
      return s.width > 0 && (s.height - s.width / 2).abs() < 3;
    });

    final size = tester.getSize(find.byType(RawImage));
    expect(size.width, closeTo(732, 2)); // 满气泡内容宽
    expect(size.height, closeTo(366, 2)); // 2:1 比例
  });

  testWidgets('a tall portrait image keeps its shape on mobile (no side letterbox)', (tester) async {
    // 9:16 长图在手机气泡上:自然高 348×16/9 ≈ 619 > 520 → 旧实现 348×520
    // contain 左右留边;现在收窄宽度到 520×9/16 = 292.5,形状贴合长图。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base64 = await tester.runAsync(() => _pngBase64(90, 160));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () {
      final img = find.byType(RawImage);
      if (img.evaluate().isEmpty) return false;
      final s = tester.getSize(img);
      return s.width > 0 && (s.height - 520).abs() < 3;
    });

    final size = tester.getSize(find.byType(RawImage));
    expect(size.height, closeTo(520, 2));
    expect(size.width, closeTo(520 * 9 / 16, 3)); // 按固有比例收窄,不再 348 满宽
  });

  testWidgets('prefers the local base64 image over a network url (no re-fetch)', (tester) async {
    // 生成时已把云端图下载落库为 base64:同一消息同时带 url 与 base64 时,
    // 必须从本地字节解码出图(RawImage 出现),而不是回退 URL —— 测试环境网络
    // 一律 400,若走 URL 路径则不会有任何帧可显。
    final base64 = await tester.runAsync(() => _pngBase64(20, 20));
    final msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageBase64: base64,
      imageUrl: 'https://example.com/x.png',
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('image bubbles keep the decoded frame when a new message is sent', (tester) async {
    // 回归防护「发送新消息产生新对话时,已生成的图片重新加载」:气泡在对话变长、
    // 流式草稿更新等整树重建中,State 必须被保留 → _AdaptiveImage 不重新解析、
    // RawImage 仍是同一解码帧(不再出现占位→重新解码的闪一次)。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base64 = await tester.runAsync(() => _pngBase64(200, 100));
    // 带 id:列表 reverse:true 下"追加新消息"会让图片气泡的下标整体上移
    // (下标 0 恒为最新),只有按 id 生成的稳定 key 才能让 sliver 把 Element
    // 搬到新下标而不是销毁重建 —— 生产路径的消息一律有 id。
    final imageMsg = Message(sessionId: 1, role: 'assistant', content: 'scene', id: 1, seq: 0, imageBase64: base64);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    // 先只有一条图片消息。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageList(messages: [imageMsg], draft: '', streaming: false, controller: scroll),
      ),
    ));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    final first = tester.widget<RawImage>(find.byType(RawImage)).image;

    // 模拟"发送新消息":追加一条 user 消息 + 流式草稿,列表整体重建。
    final userMsg = Message(sessionId: 1, role: 'user', content: 'new turn', id: 2, seq: 1);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageList(
          messages: [imageMsg, userMsg],
          draft: 'reply…',
          streaming: true,
          controller: scroll,
        ),
      ),
    ));
    await tester.pump();

    // 图片消息仍显示,且是同一解码帧(没有重新解码/重新加载)。
    final second = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(identical(first, second), isTrue);
  });

  testWidgets('image frames survive a sibling bar being inserted above the message list', (tester) async {
    // 回归防护:ChatScreen 把 MessageList 放在 Column 里,上方有"token 用量条 /
    // 后台状态条"等**条件渲染**的 sibling。发送新消息时首段 token 使用量条出现、
    // 后台轮使状态条出现 —— 这些 sibling 插入到 MessageList 上方会把它的元素
    // 挤到新下标 → 无稳定 key 时整个 MessageList 子树被重建 → 所有图片气泡重建
    // → 已生成的图片重新解码/重新加载。给常驻 sibling 与 MessageList 加稳定 key,
    // 让元素按 key 匹配而非下标,跨插入保持 State。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base64 = await tester.runAsync(() => _pngBase64(200, 100));
    final imageMsg = Message(sessionId: 1, role: 'assistant', content: 'scene', seq: 0, imageBase64: base64);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    var showBar = false;
    Widget build() => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            // 模拟发送新消息时"token 用量条"出现:在 MessageList 上方插入 sibling。
            if (showBar) const SizedBox(height: 40, child: ColoredBox(color: Color(0xff999999))),
            // 常驻 sibling(如 PanelWidget),与真实布局保持一致。
            const SizedBox.shrink(),
            Expanded(
              // 与 ChatScreen 一致:给消息区稳定 key,跨 sibling 插入不被重建。
              key: const ValueKey('messages-area'),
              child: MessageList(messages: [imageMsg], draft: '', streaming: false, controller: scroll),
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(build());
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    final first = tester.widget<RawImage>(find.byType(RawImage)).image;

    // 发送新消息 → 用量条插入到 MessageList 上方。
    showBar = true;
    await tester.pumpWidget(build());
    await tester.pump();

    final second = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(identical(first, second), isTrue); // 跨 sibling 插入保持同一解码帧
  });

  testWidgets('deleting an earlier image message keeps the later image frame (no reload)', (tester) async {
    // 回归防护「删第一张图、第二张图转圈重载」:多图回复各成一条图片消息,
    // 删除前一条后下方消息整体上移一位 —— 列表项无稳定 key 时 Flutter 按位置
    // 复用 Element,幸存图片消息的 State 被就地改写成"另一条消息",图片控件
    // 检测到数据变化清空缓存全量重载(转圈占位 → 重新解码后图片才回来;期间
    // 点开大图却正常,因为全屏页用的是另一份全尺寸字节)。按消息 id 给列表项
    // 加 key 后,删除只影响被删条目自己:幸存气泡原地保留同一解码帧。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 两张尺寸不同的图,保证两条消息的解码帧是不同实例(断言可信)。
    final pngA = await tester.runAsync(() => _pngBase64(200, 100));
    final pngB = await tester.runAsync(() => _pngBase64(160, 100));
    final msgA = Message(sessionId: 1, role: 'assistant', content: '', id: 1, seq: 0, imageBase64: pngA);
    final msgB = Message(sessionId: 1, role: 'assistant', content: '', id: 2, seq: 1, imageBase64: pngB);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageList(messages: [msgA, msgB], draft: '', streaming: false, controller: scroll),
      ),
    ));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().length == 2);
    // 列表 reverse:true —— 树里的顺序是"最新在下标 0",故 at(0) 是 msgB、at(1) 是 msgA。
    final frameB = tester.widget<RawImage>(find.byType(RawImage).at(0)).image;
    final frameA = tester.widget<RawImage>(find.byType(RawImage).at(1)).image;
    expect(identical(frameA, frameB), isFalse);

    // 模拟删除第一张图:_refreshMessages 回来的是全新 Message 实例(同值同 id)。
    final msgBReloaded = Message(sessionId: 1, role: 'assistant', content: '', id: 2, seq: 1, imageBase64: pngB);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageList(messages: [msgBReloaded], draft: '', streaming: false, controller: scroll),
      ),
    ));
    await tester.pump();

    // 幸存的第二条:同一解码帧原地保留 —— 无占位转圈、无重新解码。
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(identical(tester.widget<RawImage>(find.byType(RawImage)).image, frameB), isTrue);
  });

  testWidgets('tapping an image opens the fullscreen viewer and tapping closes it', (tester) async {
    final base64 = await tester.runAsync(() => _pngBase64(40, 40));
    final msg = Message(sessionId: 1, role: 'assistant', content: 'scene pic', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    // 点击图片 → 打开全屏查看页(黑底 + 可缩放 + 关闭按钮)。
    await tester.tap(find.byType(RawImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // 路由淡入完成
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    // 点击全屏页任意处退出。
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 路由淡出完成
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('fullscreen viewer has a download button; save failure reports feedback', (tester) async {
    final base64 = await tester.runAsync(() => _pngBase64(30, 30));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    // 打开全屏查看页:右上角「下载图片」与「关闭」两个按钮并存。
    await tester.tap(find.byType(RawImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('下载图片'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    // 测试环境没有 file_picker 平台宿主 → 保存抛 MissingPluginException,被
    // saveBytesFile 捕获并落到失败 SnackBar —— 下载入口可用、失败不崩溃。
    // 异常跨通道回包是真实异步:沿用 _pumpUntil 条件轮询,不赌固定延时窗口。
    await tester.tap(find.byTooltip('下载图片'));
    await _pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('fullscreen viewer offers image deletion behind a confirmation', (tester) async {
    final base64 = await tester.runAsync(() => _pngBase64(30, 30));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', id: 7, seq: 0, imageBase64: base64);
    var deletedId = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          message: msg,
          onImageDelete: (id) async => deletedId = id,
        ),
      ),
    ));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    // 提供 onImageDelete 时全屏页右上角出现「删除图片」;点击先弹确认框。
    await tester.tap(find.byType(RawImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('删除图片'), findsOneWidget);
    await tester.tap(find.byTooltip('删除图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AlertDialog), findsOneWidget);

    // 取消:不触发删除回调,全屏页原地保留。
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(deletedId, -1);
    expect(find.byTooltip('删除图片'), findsOneWidget);

    // 确认:回调收到该条消息的 id,成功后自动退出全屏页回聊天流。
    await tester.tap(find.byTooltip('删除图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(deletedId, 7);
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('viewer hides the delete button when no onImageDelete callback given', (tester) async {
    final base64 = await tester.runAsync(() => _pngBase64(30, 30));
    final msg = Message(sessionId: 1, role: 'assistant', content: '', seq: 0, imageBase64: base64);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageBubble(message: msg))));
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    // 无删除回调(如其他入口打开查看器):只有下载与关闭,不出现删除入口。
    await tester.tap(find.byType(RawImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('删除图片'), findsNothing);
    expect(find.byTooltip('下载图片'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
  });

  testWidgets('tapping the image opens the viewer instead of selecting the message', (tester) async {
    // 图片自身的点击手势必须赢过气泡的"选中消息"单击,二者不互相干扰;
    // 图片之外的区域单击仍正常走气泡回调。
    final base64 = await tester.runAsync(() => _pngBase64(30, 30));
    var bubbleTapped = false;
    final msg = Message(sessionId: 1, role: 'user', content: 'pic', seq: 0, imageBase64: base64);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: msg, onTap: () => bubbleTapped = true),
        ),
      ),
    );
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    // 点图:开全屏,不触发气泡单击。
    await tester.tap(find.byType(RawImage));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(bubbleTapped, isFalse);

    // 退出后点文字区:气泡单击正常触发。
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.tap(find.text('pic'));
    await tester.pump();
    expect(bubbleTapped, isTrue);
  });

  testWidgets('user bubble folds <tag> hook notes by default and expands on tap', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: '我推门走进酒馆<main_note>主导模式\n本回合请详细描写,篇幅加长。</main_note>',
      seq: 0,
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MessageBubble(message: msg))),
    );

    // 默认折叠:说明行作 chip 标签可见,指令正文不可见;普通正文照常显示。
    expect(find.text('我推门走进酒馆'), findsOneWidget);
    expect(find.text('主导模式'), findsOneWidget);
    expect(find.textContaining('详细描写', findRichText: true), findsNothing);

    // 点击 chip 展开:正文出现;再点收起。
    await tester.tap(find.text('主导模式'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本回合请详细描写', findRichText: true), findsOneWidget);

    await tester.tap(find.text('主导模式'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本回合请详细描写', findRichText: true), findsNothing);
  });

  testWidgets('user bubble renders @skill tokens in the token color', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: '@剑术 我拔剑了',
      seq: 0,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: msg, skillNames: {'剑术'}),
        ),
      ),
    );

    final element = tester.element(find.byType(MessageBubble));
    final scheme = Theme.of(element).colorScheme;
    final expected = skillTokenColor(scheme, onPrimaryBubble: true);

    // 收集气泡内全部富文本叶 span。
    final spans = <TextSpan>[];
    void collect(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.text != null) spans.add(span);
      span.children?.forEach(collect);
    }
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      collect(rt.text);
    }

    // 记号段染记号色:与共享选色助手一致(蓝底上取紫色对比色),且与白字正文可区分。
    final colored = spans.where((s) => s.text == '@剑术').toList();
    expect(colored, hasLength(1));
    expect(colored.single.style?.color, expected);
    expect(colored.single.style?.color, isNot(scheme.onPrimary));
    // 记号外的正文仍是气泡正文色。
    final plain = spans.where((s) => s.text?.contains('我拔剑了') ?? false).toList();
    expect(plain, hasLength(1));
    expect(plain.single.style?.color, scheme.onPrimary);
  });

  testWidgets('assistant bubble does not highlight @skill tokens', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '@剑术 你拔剑了',
      seq: 0,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: msg, skillNames: {'剑术'}),
        ),
      ),
    );

    final spans = <TextSpan>[];
    void collect(InlineSpan span) {
      if (span is! TextSpan) return;
      if (span.text != null) spans.add(span);
      span.children?.forEach(collect);
    }
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      collect(rt.text);
    }

    // 助手气泡不拆分记号:整条正文是单个原色段,无独立染色记号段。
    expect(spans.where((s) => s.text == '@剑术'), isEmpty);
    expect(spans.where((s) => s.text?.contains('你拔剑了') ?? false), hasLength(1));
  });
}
