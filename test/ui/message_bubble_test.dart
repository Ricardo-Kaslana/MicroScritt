// 消息气泡:文件资产/URL/磁盘缓存、解码帧复用、尺寸上限与全屏查看器;
// 另覆盖气泡宽度上限、{{user}} 替换、可折叠指令块与 @skill 记号染色。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/disk_image_cache.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/common/chat_layout.dart';
import 'package:microscritt/ui/skill_highlight.dart';
import 'package:microscritt/ui/text_syntax.dart';
import 'package:microscritt/ui/widgets/image_asset_preview.dart';
import 'package:microscritt/ui/widgets/message_bubble.dart';
import 'package:microscritt/ui/widgets/message_list.dart';

import '../support/test_database.dart';

late AppDatabase _db;

/// 生成真实 PNG;本地消息资产与 URL 磁盘缓存共用同一图片编码。
Future<Uint8List> _pngBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff4477aa),
  );
  final image = await recorder.endRecording().toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 写入内容寻址资产并预生成预览,避免后台预览完成影响帧身份断言。
Future<String> _pngHash(int width, int height) async {
  final ref = await _db.images.putBytes(await _pngBytes(width, height));
  await ImagePreviewCache.ensure(_db.images, ref.hash);
  return ref.hash;
}

Widget _app({required Widget home}) => ProviderScope(
  overrides: [databaseProvider.overrideWithValue(_db)],
  child: MaterialApp(home: home),
);

/// 反复 pump 直到 [condition] 成立(图片解码是真实异步,固定延时在负载下会抖)。
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 30 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue);
}

void main() {
  setUp(() async => _db = await openTestDb());
  tearDown(() => _db.db.close());

  testWidgets('多选态暴露 selected/button 语义', (tester) async {
    const msg = Message(sessionId: 1, role: 'assistant', content: '你好', seq: 0);
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            selectionMode: true,
            selected: true,
            onTap: () {},
          ),
        ),
      ),
    );
    final semantics = tester.widgetList<Semantics>(find.byType(Semantics));
    expect(
      semantics.any(
        (s) => s.properties.selected == true && s.properties.button == true,
      ),
      isTrue,
    );
  });

  testWidgets('多选态气泡内显示勾选圆点,并随选中态切换', (tester) async {
    const msg = Message(sessionId: 1, role: 'assistant', content: '你好', seq: 0);
    Widget bubble({required bool selected, bool selectionMode = true}) => _app(
      home: Scaffold(
        body: MessageBubble(
          message: msg,
          selectionMode: selectionMode,
          selected: selected,
          onTap: () {},
        ),
      ),
    );

    double badgeOpacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(const ValueKey('message_selection_check')),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    await tester.pumpWidget(bubble(selected: false));
    expect(find.byKey(const ValueKey('message_selection_check')), findsOneWidget);
    expect(badgeOpacity(), 0);

    await tester.pumpWidget(bubble(selected: true));
    await tester.pumpAndSettle();
    expect(badgeOpacity(), 1);

    // 非多选态不显示勾选圆点,点击仍打开操作排。
    await tester.pumpWidget(bubble(selected: false, selectionMode: false));
    await tester.pump();
    expect(find.byKey(const ValueKey('message_selection_check')), findsNothing);
  });

  testWidgets('图片消息带可读语义标签', (tester) async {
    final handle = tester.ensureSemantics();
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageUrl: 'https://img.example.com/api/images/label',
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    expect(find.bySemanticsLabel('查看图片'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('renders the image when imageHash is set', (tester) async {
    final hash = await tester.runAsync(() => _pngHash(1, 1));
    final msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash: hash,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('missing local file falls back to imageUrl', (tester) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      imageUrl: 'https://img.example.com/api/images/missing_local',
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byIcon(Icons.broken_image_outlined).evaluate().isNotEmpty,
    );
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });

  testWidgets('missing local file without URL shows the broken placeholder', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'bad image',
      seq: 0,
      imageHash:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byIcon(Icons.broken_image_outlined).evaluate().isNotEmpty,
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
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    // flutter_test 默认把网络图片请求打成 400 → 无帧可显(仅历史 URL 消息走网络,
    // 新生成的图都已在生成时下载落库为 base64)。气泡文本与其余部分不受影响。
    expect(find.text('cloud img'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed network image shows a broken placeholder instead of spinning forever',
    (tester) async {
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
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byIcon(Icons.broken_image_outlined).evaluate().isNotEmpty,
      );
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('empty imageHash falls back to imageUrl', (tester) async {
    // 历史导入/轻量查询可能留下空串 base64;它不能挡住 URL 回退。
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash: '',
      imageUrl: 'https://img.example.com/api/images/img_x/content',
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byIcon(Icons.broken_image_outlined).evaluate().isNotEmpty,
    );
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });

  testWidgets(
    'URL bubble renders from the disk cache without hitting the network',
    (tester) async {
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
      final png = (await tester.runAsync(() => _pngBytes(30, 20)))!;
      await tester.runAsync(() => DiskImageCache.write(url, png));

      const msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageUrl: url,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );
      expect(find.byType(RawImage), findsOneWidget);
    },
  );

  testWidgets('file image reuses the same decoded frame across rebuilds', (
    tester,
  ) async {
    // 同一 hash 重建气泡时,文件路径与预览尺寸不变,Flutter ImageCache 复用
    // 解码帧(RawImage.image 指向同一个 ui.Image)。
    final hash = await tester.runAsync(() => _pngHash(1, 1));
    final msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash: hash,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    final first = tester.widget<RawImage>(find.byType(RawImage)).image;

    // 同一 hash 重建 → 同一解码帧(未重新解码)。
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    final second = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(identical(first, second), isTrue);
  });

  testWidgets('tall portrait images decode within the bubble height cap', (
    tester,
  ) async {
    // 回归防护「竖图按宽度解码出超高帧」:100×4000 的图只按宽度上限解码会得到
    // 100×(1520/100×4000) 的超大帧;宽高双上限后应封在图片框高度(520 逻辑像素)。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final hash = await tester.runAsync(() => _pngHash(100, 4000));
    final msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash: hash,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);

    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(image.height, 520);
    expect(image.width, lessThanOrEqualTo(100));
  });

  testWidgets('long press invokes the callback', (tester) async {
    var pressed = false;
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: 'press me',
      seq: 0,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(message: msg, onLongPress: () => pressed = true),
        ),
      ),
    );
    await tester.longPress(find.text('press me'));
    expect(pressed, isTrue);
  });

  testWidgets(
    'assistant bubble hugs content and caps at the mobile max width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 短消息:按内容自适应,远小于满行宽。
      const short = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'hi',
        seq: 0,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: short)),
        ),
      );
      final shortBox = tester.widget<Container>(
        find
            .ancestor(of: find.text('hi'), matching: find.byType(Container))
            .first,
      );
      final shortWidth = tester.getSize(find.byWidget(shortBox)).width;
      expect(shortWidth, lessThan(200));
      expect(shortWidth, greaterThan(0));

      // 长文本:被限制在移动端助手上限(整行 320,不含左右 12 边距)。
      final longText = '这是一条非常长的助手消息,用于验证移动端助手气泡在内容超出时封顶在满行宽,而不是无限撑开。' * 6;
      final long = Message(
        sessionId: 1,
        role: 'assistant',
        content: longText,
        seq: 1,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: long)),
        ),
      );
      final longBox = tester.widget<Container>(
        find
            .ancestor(
              of: find.textContaining('这是一条非常长'),
              matching: find.byType(Container),
            )
            .first,
      );
      // 容器总宽 = 气泡 296 + 左右各 12 边距 = 320。
      expect(tester.getSize(find.byWidget(longBox)).width, closeTo(320, 0.5));
    },
  );

  testWidgets(
    'user bubble hugs the content width (short text is not stretched full-width)',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const msg = Message(sessionId: 1, role: 'user', content: 'hi', seq: 0);
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );

      final container = tester.widget<Container>(
        find
            .ancestor(of: find.text('hi'), matching: find.byType(Container))
            .first,
      );
      // 短消息应按内容自适应,远小于 520 上限(否则说明 stretch 把文字撑满了)。
      final width = tester.getSize(find.byWidget(container)).width;
      expect(width, lessThan(200));
      expect(width, greaterThan(0));
    },
  );

  testWidgets('user bubble caps at the normal max width for long text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longText = '这是一条非常非常长的用户消息,用来验证桌面端用户气泡被限在正常宽度而不是被拉成助手那样的大宽。' * 6;
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(
            message: Message(
              sessionId: 1,
              role: 'user',
              content: longText,
              seq: 0,
            ),
          ),
        ),
      ),
    );

    final container = tester.widget<Container>(
      find
          .ancestor(
            of: find.textContaining('这是一条'),
            matching: find.byType(Container),
          )
          .first,
    );
    final width = tester.getSize(find.byWidget(container)).width;
    expect(width, lessThanOrEqualTo(520 + 24 + 0.5)); // 520 上限 + 左右 12 边距
    expect(width, lessThan(880)); // 远窄于助手上限(与输入卡同宽 856 + 边距)
  });

  testWidgets('secondary tap (right-click, desktop) invokes the callback', (
    tester,
  ) async {
    var pressed = false;
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'right click me',
      seq: 0,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(message: msg, onLongPress: () => pressed = true),
        ),
      ),
    );
    await tester.tap(find.text('right click me'), buttons: kSecondaryButton);
    expect(pressed, isTrue);
  });

  testWidgets(
    'assistant bubble hugs content and caps at the desktop max width',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 短消息:按内容自适应,远小于桌面列宽上限。
      const short = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'hi',
        seq: 0,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: short)),
        ),
      );
      final shortBox = tester.widget<Container>(
        find
            .ancestor(of: find.text('hi'), matching: find.byType(Container))
            .first,
      );
      final shortWidth = tester.getSize(find.byWidget(shortBox)).width;
      expect(shortWidth, lessThan(400));
      expect(shortWidth, greaterThan(0));

      // 长文本:被封顶在与输入卡同宽的列内容宽(列宽 − 24)。
      final longText =
          '这是一条非常长的助手消息,用于验证桌面端助手气泡在内容超出时封顶在与输入卡同宽的上限,而不是无限撑开。' * 8;
      final long = Message(
        sessionId: 1,
        role: 'assistant',
        content: longText,
        seq: 1,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: long)),
        ),
      );
      final longBox = tester.widget<Container>(
        find
            .ancestor(
              of: find.textContaining('这是一条非常长'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        tester.getSize(find.byWidget(longBox)).width,
        chatColumnMaxWidth(1400),
      );
    },
  );

  testWidgets(
    'user bubble stays at normal width on a desktop surface (not stretched to the assistant cap)',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const msg = Message(sessionId: 1, role: 'user', content: 'hi', seq: 0);
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );

      final container = tester.widget<Container>(
        find
            .ancestor(of: find.text('hi'), matching: find.byType(Container))
            .first,
      );
      // 用户气泡不跟助手一起撑到输入卡同宽,而是按内容自适应、最多 520。
      final width = tester.getSize(find.byWidget(container)).width;
      expect(width, lessThan(880));
      expect(width, lessThanOrEqualTo(520 + 24 + 0.5)); // 520 上限 + 左右 12 边距
    },
  );

  testWidgets(
    'assistant bubble caps at the input width, wider than the user bubble',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 用同样长的长文本:用户封顶 520、助手封顶与输入卡同宽,助手明显更宽。
      final longText = '这是一条非常非常长的消息,用来验证桌面端助手与用户气泡在内容超出时各自封顶在不同的最大宽度。' * 8;
      final user = Message(
        sessionId: 1,
        role: 'user',
        content: longText,
        seq: 0,
      );
      final ai = Message(
        sessionId: 1,
        role: 'assistant',
        content: longText,
        seq: 1,
      );
      await tester.pumpWidget(
        _app(
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
          .getSize(
            find
                .ancestor(
                  of: find.textContaining('这是一条非常非常长').first,
                  matching: find.byType(Container),
                )
                .first,
          )
          .width;
      final aiWidth = tester
          .getSize(
            find
                .ancestor(
                  of: find.textContaining('这是一条非常非常长').last,
                  matching: find.byType(Container),
                )
                .first,
          )
          .width;
      expect(aiWidth, closeTo(chatColumnMaxWidth(1400), 0.5)); // 助手封顶 = 列宽(输入卡同宽 + 边距)
      expect(userWidth, lessThan(aiWidth)); // 用户封顶更窄(520)
      expect(userWidth, lessThanOrEqualTo(520 + 24 + 0.5));
    },
  );

  testWidgets(
    'replaces {{user}} in the displayed text only when a username is given',
    (tester) async {
      const raw = Message(
        sessionId: 1,
        role: 'assistant',
        content: '你好 {{user}},欢迎回来 {{user}}',
        seq: 0,
      );
      // 未提供用户名 → 原样保留占位符(存储不被动)。
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: raw)),
        ),
      );
      expect(find.text('你好 {{user}},欢迎回来 {{user}}'), findsOneWidget);

      // 提供用户名 → 显示层替换,但 message.content 本身仍保留 {{user}}。
      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: MessageBubble(message: raw, displayUserName: '小明'),
          ),
        ),
      );
      expect(find.text('你好 小明,欢迎回来 小明'), findsOneWidget);
      expect(raw.content, '你好 {{user}},欢迎回来 {{user}}');
    },
  );

  testWidgets(
    'a wide image is sized by its aspect ratio instead of a fixed 200-height crop',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 2:1 宽图:气泡应按"宽度 = 固有比例"定高(高 = 宽/2),而不是固定 200 高 + cover 裁切。
      // toImage/toByteData 是真实异步,必须在 tester.runAsync 窗口内完成。
      final hash = await tester.runAsync(() => _pngHash(200, 100));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
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
    },
  );

  testWidgets('a portrait image keeps its full shape (no vertical crop)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 3:4 竖图:高 = 宽 × 4/3,完整展示。
    final hash = await tester.runAsync(() => _pngHash(120, 160));
    final msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash: hash,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );
    await _pumpUntil(tester, () {
      final img = find.byType(RawImage);
      if (img.evaluate().isEmpty) return false;
      final s = tester.getSize(img);
      return s.height > 0 && (s.height - s.width * 4 / 3).abs() < 3;
    });

    final size = tester.getSize(find.byType(RawImage));
    expect(size.height, closeTo(size.width * 4 / 3, 2)); // 3:4 比例,无上下裁切
  });

  testWidgets(
    'a square image bubble keeps the square shape on desktop (no side letterbox)',
    (tester) async {
      // 回归防护「生图气泡形状贴合图片」:方图在桌面宽气泡上自然高(满宽 732)超过
      // 520 上限,旧实现只压高度不压宽度 → 732×520 宽框 + contain 左右留边,气泡
      // 形状与图片不符。现在按比例同步收窄宽度:框 = 520×520,形状与图片一致。
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(100, 100));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(tester, () {
        final img = find.byType(RawImage);
        if (img.evaluate().isEmpty) return false;
        final s = tester.getSize(img);
        return s.width > 0 &&
            (s.width - 520).abs() < 3 &&
            (s.height - 520).abs() < 3;
      });

      final size = tester.getSize(find.byType(RawImage));
      expect(size.width, closeTo(520, 2));
      expect(size.height, closeTo(520, 2));
      expect(size.width, lessThan(700)); // 不再是 732 满宽框
    },
  );

  testWidgets(
    'a portrait image bubble keeps its shape on desktop (width shrinks, no letterbox)',
    (tester) async {
      // 3:4 竖图在桌面气泡上:自然高 976 > 520 → 旧实现 732×520 留边;现在
      // 收窄宽度到 520×3/4 = 390,框比例 == 图比例,气泡贴合竖图形状。
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(90, 120));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(tester, () {
        final img = find.byType(RawImage);
        if (img.evaluate().isEmpty) return false;
        final s = tester.getSize(img);
        return s.width > 0 && (s.height - 520).abs() < 3;
      });

      final size = tester.getSize(find.byType(RawImage));
      expect(size.height, closeTo(520, 2));
      expect(size.width, closeTo(520 * 3 / 4, 3)); // 按固有比例收窄,不再 732 满宽
    },
  );

  testWidgets(
    'a wide image still fills the bubble width on desktop (no needless shrink)',
    (tester) async {
      // 2:1 横图:自然高 826/2 = 413 < 520 上限 → 维持满宽,只是不再裁切。
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(200, 100));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(tester, () {
        final img = find.byType(RawImage);
        if (img.evaluate().isEmpty) return false;
        final s = tester.getSize(img);
        return s.width > 0 && (s.height - s.width / 2).abs() < 3;
      });

      final size = tester.getSize(find.byType(RawImage));
      expect(size.width, closeTo(chatColumnMaxWidth(1400) - 54, 2)); // 满气泡内容宽(列内容宽 − 内边距/描边)
      expect(
        size.height,
        closeTo((chatColumnMaxWidth(1400) - 54) / 2, 2),
      ); // 2:1 比例
    },
  );

  testWidgets(
    'a tall portrait image keeps its shape on mobile (no side letterbox)',
    (tester) async {
      // 9:16 长图在手机气泡上:自然高 348×16/9 ≈ 619 > 520 → 旧实现 348×520
      // contain 左右留边;现在收窄宽度到 520×9/16 = 292.5,形状贴合长图。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(90, 160));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(tester, () {
        final img = find.byType(RawImage);
        if (img.evaluate().isEmpty) return false;
        final s = tester.getSize(img);
        return s.width > 0 && (s.height - 520).abs() < 3;
      });

      final size = tester.getSize(find.byType(RawImage));
      expect(size.height, closeTo(520, 2));
      expect(size.width, closeTo(520 * 9 / 16, 3)); // 按固有比例收窄,不再 348 满宽
    },
  );

  testWidgets(
    'prefers the local base64 image over a network url (no re-fetch)',
    (tester) async {
      // 生成时已把云端图下载落库为 base64:同一消息同时带 url 与 base64 时,
      // 必须从本地字节解码出图(RawImage 出现),而不是回退 URL —— 测试环境网络
      // 一律 400,若走 URL 路径则不会有任何帧可显。
      final hash = await tester.runAsync(() => _pngHash(20, 20));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
        imageUrl: 'https://example.com/x.png',
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );
      expect(find.byType(RawImage), findsOneWidget);
    },
  );

  testWidgets(
    'image bubbles keep the decoded frame when a new message is sent',
    (tester) async {
      // 回归防护「发送新消息产生新对话时,已生成的图片重新加载」:气泡在对话变长、
      // 流式草稿更新等整树重建中,State 必须被保留 → _AdaptiveImage 不重新解析、
      // RawImage 仍是同一解码帧(不再出现占位→重新解码的闪一次)。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(200, 100));
      // 带 id:列表 reverse:true 下"追加新消息"会让图片气泡的下标整体上移
      // (下标 0 恒为最新),只有按 id 生成的稳定 key 才能让 sliver 把 Element
      // 搬到新下标而不是销毁重建 —— 生产路径的消息一律有 id。
      final imageMsg = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'scene',
        id: 1,
        seq: 0,
        imageHash: hash,
      );
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      // 先只有一条图片消息。
      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: MessageList(
              messages: [imageMsg],
              draft: '',
              streaming: false,
              controller: scroll,
            ),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );
      final first = tester.widget<RawImage>(find.byType(RawImage)).image;

      // 模拟"发送新消息":追加一条 user 消息 + 流式草稿,列表整体重建。
      final userMsg = Message(
        sessionId: 1,
        role: 'user',
        content: 'new turn',
        id: 2,
        seq: 1,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: MessageList(
              messages: [imageMsg, userMsg],
              draft: 'reply…',
              streaming: true,
              controller: scroll,
            ),
          ),
        ),
      );
      await tester.pump();

      // 图片消息仍显示,且是同一解码帧(没有重新解码/重新加载)。
      final second = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(identical(first, second), isTrue);
    },
  );

  testWidgets(
    '首次展示生成的图片时,原图切换到预览后不会一直转圈',
    (tester) async {
      // 回归防护「生图气泡首次加载一直转圈」:生图刚落库时还没有 1600 预览,
      // 气泡先用原图渲染,后台生成完成后 provider 换成预览文件。此时必须当场
      // 重新解析;旧实现只清 _resolved 等 didChangeDependencies,普通 setState
      // 重建不会触发它 → 永久停在占位,而点开全屏读原图却正常。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() async {
        final ref = await _db.images.putBytes(await _pngBytes(800, 400));
        return ref.hash;
      });
      expect(hash, isNotNull);
      final existingPreview = await tester.runAsync(
        () => _db.images.previewFileFor(hash!),
      );
      expect(existingPreview, isNull);

      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );
      final originalFrame = tester
          .widget<RawImage>(find.byType(RawImage))
          .image;

      // 后台 _generate 已随首次渲染启动。这里不能用 runAsync await 同一个
      // fake-zone Future(compute 的完成回调要靠 pump 推进,互相等待会死锁);
      // 用真实异步窗口 + pump 推进生成与切换。
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        final images = find.byType(RawImage);
        if (images.evaluate().isNotEmpty &&
            !identical(
              tester.widget<RawImage>(images.first).image,
              originalFrame,
            )) {
          break;
        }
      }
      // 预览文件确实生成,且气泡已换到预览的新解码帧(而不是停在旧帧或占位)。
      final preview = await tester.runAsync(
        () => _db.images.previewFileFor(hash!),
      );
      expect(preview, isNotNull);
      expect(find.byType(RawImage), findsOneWidget);
      expect(
        identical(
          tester.widget<RawImage>(find.byType(RawImage)).image,
          originalFrame,
        ),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    '调整屏幕宽度时图片气泡保留当前帧而不是闪灰',
    (tester) async {
      // 回归防护「拖拽窗口宽度图片气泡闪灰」:解码上限随宽度变化时,
      // ImageAssetPreview 必须保留当前帧继续铺满新框,后台按新尺寸重建
      // provider;若先清空 provider,每次 MediaQuery 变化都会回到灰块占位。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(200, 100));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );
      final before = tester.widget<RawImage>(find.byType(RawImage)).image;

      // 加宽视口:气泡解码尺寸上限随之变化,provider 在后台重建。
      tester.view.physicalSize = const Size(800, 800);
      await tester.pump();

      // 新帧解码完成前仍显示旧帧,不出现灰块占位。
      expect(find.byType(RawImage), findsOneWidget);
      expect(
        identical(tester.widget<RawImage>(find.byType(RawImage)).image, before),
        isTrue,
      );

      // 新 provider 最终解码完成并替换旧帧。
      await _pumpUntil(tester, () {
        final images = find.byType(RawImage);
        return images.evaluate().isNotEmpty &&
            !identical(
              tester.widget<RawImage>(images.first).image,
              before,
            );
      });
      expect(find.byType(RawImage), findsOneWidget);
    },
  );

  testWidgets(
    '窗口跨过宽窗断点时图片气泡不重建',
    (tester) async {
      // 回归防护「拖拽窗口跨断点闪灰」:消息行在窄窗曾直接返回 KeyedSubtree,
      // 宽窗返回 Align;runtimeType 变化会让 sliver 即使 key 相同也销毁
      // 整条消息子树,图片 State 与解码帧一起丢失(灰块重载)。根结构必须在
      // 所有宽度下保持一致。
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(200, 100));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        id: 1,
        seq: 0,
        imageHash: hash,
      );
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: MessageList(
              messages: [msg],
              draft: '',
              streaming: false,
              controller: scroll,
            ),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );

      // 跨过 1000 宽窗断点:窄/宽的列包装必须是同一 widget 类型,图片气泡
      // 不能回到灰块占位。
      tester.view.physicalSize = const Size(1400, 800);
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);

      // 再跨回窄窗,同样不能重建。
      tester.view.physicalSize = const Size(800, 800);
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
    },
  );

  testWidgets(
    'image frames survive a sibling bar being inserted above the message list',
    (tester) async {
      // 回归防护:ChatScreen 把 MessageList 放在 Column 里,上方有"token 用量条 /
      // 后台状态条"等**条件渲染**的 sibling。发送新消息时首段 token 使用量条出现、
      // 后台轮使状态条出现 —— 这些 sibling 插入到 MessageList 上方会把它的元素
      // 挤到新下标 → 无稳定 key 时整个 MessageList 子树被重建 → 所有图片气泡重建
      // → 已生成的图片重新解码/重新加载。给常驻 sibling 与 MessageList 加稳定 key,
      // 让元素按 key 匹配而非下标,跨插入保持 State。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final hash = await tester.runAsync(() => _pngHash(200, 100));
      final imageMsg = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'scene',
        seq: 0,
        imageHash: hash,
      );
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      var showBar = false;
      Widget build() => _app(
        home: Scaffold(
          body: Column(
            children: [
              // 模拟发送新消息时"token 用量条"出现:在 MessageList 上方插入 sibling。
              if (showBar)
                const SizedBox(
                  height: 40,
                  child: ColoredBox(color: Color(0xff999999)),
                ),
              // 常驻 sibling(如 PanelWidget),与真实布局保持一致。
              const SizedBox.shrink(),
              Expanded(
                // 与 ChatScreen 一致:给消息区稳定 key,跨 sibling 插入不被重建。
                key: const ValueKey('messages-area'),
                child: MessageList(
                  messages: [imageMsg],
                  draft: '',
                  streaming: false,
                  controller: scroll,
                ),
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(build());
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );
      final first = tester.widget<RawImage>(find.byType(RawImage)).image;

      // 发送新消息 → 用量条插入到 MessageList 上方。
      showBar = true;
      await tester.pumpWidget(build());
      await tester.pump();

      final second = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(identical(first, second), isTrue); // 跨 sibling 插入保持同一解码帧
    },
  );

  testWidgets(
    'deleting an earlier image message keeps the later image frame (no reload)',
    (tester) async {
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
      final pngA = await tester.runAsync(() => _pngHash(200, 100));
      final pngB = await tester.runAsync(() => _pngHash(160, 100));
      final msgA = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        id: 1,
        seq: 0,
        imageHash: pngA,
      );
      final msgB = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        id: 2,
        seq: 1,
        imageHash: pngB,
      );
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: MessageList(
              messages: [msgA, msgB],
              draft: '',
              streaming: false,
              controller: scroll,
            ),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().length == 2,
      );
      // 列表 reverse:true —— 树里的顺序是"最新在下标 0",故 at(0) 是 msgB、at(1) 是 msgA。
      final frameB = tester.widget<RawImage>(find.byType(RawImage).at(0)).image;
      final frameA = tester.widget<RawImage>(find.byType(RawImage).at(1)).image;
      expect(identical(frameA, frameB), isFalse);

      // 模拟删除第一张图:_refreshMessages 回来的是全新 Message 实例(同值同 id)。
      final msgBReloaded = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        id: 2,
        seq: 1,
        imageHash: pngB,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: MessageList(
              messages: [msgBReloaded],
              draft: '',
              streaming: false,
              controller: scroll,
            ),
          ),
        ),
      );
      await tester.pump();

      // 幸存的第二条:同一解码帧原地保留 —— 无占位转圈、无重新解码。
      expect(find.byType(RawImage), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        identical(tester.widget<RawImage>(find.byType(RawImage)).image, frameB),
        isTrue,
      );
    },
  );

  testWidgets(
    'tapping an image opens the fullscreen viewer and tapping closes it',
    (tester) async {
      final hash = await tester.runAsync(() => _pngHash(40, 40));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: 'scene pic',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );

      // 点击图片 → 打开全屏查看页(黑底 + 可缩放 + 关闭按钮)。
      await tester.tap(find.byType(RawImage));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250)); // 路由淡入完成
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
      final fullscreenImage = tester.widget<Image>(
        find.descendant(
          of: find.byType(InteractiveViewer),
          matching: find.byType(Image),
        ),
      );
      final resized = fullscreenImage.image as ResizeImage;
      expect(
        (resized.imageProvider as FileImage).file.path,
        _db.images.fileFor(hash!).path,
        reason: '全屏必须读取原图,不能使用聊天预览文件',
      );

      // 点击全屏页任意处退出。
      await tester.tap(find.byType(InteractiveViewer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200)); // 路由淡出完成
      expect(find.byType(InteractiveViewer), findsNothing);
    },
  );

  testWidgets(
    'fullscreen viewer has a download button; save failure reports feedback',
    (tester) async {
      final hash = await tester.runAsync(() => _pngHash(30, 30));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );

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
      await _pumpUntil(
        tester,
        () => find.byType(SnackBar).evaluate().isNotEmpty,
      );
      expect(find.byType(SnackBar), findsOneWidget);
    },
  );

  testWidgets('fullscreen viewer offers image deletion behind a confirmation', (
    tester,
  ) async {
    final hash = await tester.runAsync(() => _pngHash(30, 30));
    final msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      id: 7,
      seq: 0,
      imageHash: hash,
    );
    var deletedId = -1;
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            onImageDelete: (id) async => deletedId = id,
          ),
        ),
      ),
    );
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

  testWidgets(
    'viewer hides the delete button when no onImageDelete callback given',
    (tester) async {
      final hash = await tester.runAsync(() => _pngHash(30, 30));
      final msg = Message(
        sessionId: 1,
        role: 'assistant',
        content: '',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );

      // 无删除回调(如其他入口打开查看器):只有下载与关闭,不出现删除入口。
      await tester.tap(find.byType(RawImage));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byTooltip('删除图片'), findsNothing);
      expect(find.byTooltip('下载图片'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping the image opens the viewer instead of selecting the message',
    (tester) async {
      // 图片自身的点击手势必须赢过气泡的"选中消息"单击,二者不互相干扰;
      // 图片之外的区域单击仍正常走气泡回调。
      final hash = await tester.runAsync(() => _pngHash(30, 30));
      var bubbleTapped = false;
      final msg = Message(
        sessionId: 1,
        role: 'user',
        content: 'pic',
        seq: 0,
        imageHash: hash,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: MessageBubble(message: msg, onTap: () => bubbleTapped = true),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(RawImage).evaluate().isNotEmpty,
      );

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
    },
  );

  testWidgets(
    'user bubble folds <tag> hook notes by default and expands on tap',
    (tester) async {
      const msg = Message(
        sessionId: 1,
        role: 'user',
        content: '我推门走进酒馆<main_note>主导模式\n本回合请详细描写,篇幅加长。</main_note>',
        seq: 0,
      );
      await tester.pumpWidget(
        _app(
          home: Scaffold(body: MessageBubble(message: msg)),
        ),
      );

      // 默认折叠:说明行作 chip 标签可见,指令正文不可见;普通正文照常显示。
      expect(find.text('我推门走进酒馆'), findsOneWidget);
      expect(find.text('主导模式'), findsOneWidget);
      expect(find.textContaining('详细描写', findRichText: true), findsNothing);

      // 点击 chip 展开:正文出现;再点收起。
      await tester.tap(find.text('主导模式'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('本回合请详细描写', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text('主导模式'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本回合请详细描写', findRichText: true), findsNothing);
    },
  );

  testWidgets('folds hyphenated hook tags but never system-reminder', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content:
          '我走进酒馆<system-reminder>隐藏的注入</system-reminder>'
          '<main-note>说明\n正文内容</main-note>',
      seq: 0,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
      ),
    );

    expect(find.text('我走进酒馆'), findsOneWidget);
    expect(find.textContaining('隐藏的注入'), findsNothing);
    expect(find.text('说明'), findsOneWidget);
    expect(find.textContaining('正文内容', findRichText: true), findsNothing);

    await tester.tap(find.text('说明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('正文内容', findRichText: true), findsOneWidget);
  });

  testWidgets('user bubble renders style tags and chips instead of folding', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: '前<b>粗</b>后<chip>时间</chip>',
      seq: 0,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(body: MessageBubble(message: msg)),
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

    // <b> 走行内样式而不是 hook 便签;chip 走胶囊而不是折叠块。
    expect(
      spans.firstWhere((s) => s.text == '粗').style?.fontWeight,
      FontWeight.bold,
    );
    expect(find.text('时间'), findsOneWidget);
    expect(find.textContaining('<b>', findRichText: true), findsNothing);
    expect(find.textContaining('<chip>', findRichText: true), findsNothing);
  });

  testWidgets('foldable note body highlights skill and command tokens', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: '<note>说明\n@剑术 /rerun 正文</note>',
      seq: 0,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            syntax: CompiledSyntax.compile(skillNames: {'剑术'}),
          ),
        ),
      ),
    );

    expect(find.textContaining('正文', findRichText: true), findsNothing);
    await tester.tap(find.text('说明'));
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(MessageBubble));
    final scheme = Theme.of(element).colorScheme;
    final palette = SyntaxPalette.of(
      scheme,
      SyntaxSurface.userBubble,
      baseTextColor: scheme.onPrimary,
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

    final skill = spans.where((s) => s.text == '@剑术').toList();
    expect(skill, hasLength(1));
    expect(
      skill.single.style?.color,
      skillTokenColor(scheme, onPrimaryBubble: true),
    );
    final command = spans.where((s) => s.text == '/rerun').toList();
    expect(command, hasLength(1));
    expect(command.single.style?.color, palette.command);
    expect(command.single.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('user bubble highlights skill and command tokens', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'user',
      content: '@剑术 /rerun 我拔剑了',
      seq: 0,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            syntax: CompiledSyntax.compile(skillNames: {'剑术'}),
          ),
        ),
      ),
    );

    final element = tester.element(find.byType(MessageBubble));
    final scheme = Theme.of(element).colorScheme;
    final palette = SyntaxPalette.of(
      scheme,
      SyntaxSurface.userBubble,
      baseTextColor: scheme.onPrimary,
    );

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

    // 技能段沿用蓝底紫色对比色;命令名单独染色并加粗。
    final skill = spans.where((s) => s.text == '@剑术').toList();
    expect(skill, hasLength(1));
    expect(
      skill.single.style?.color,
      skillTokenColor(scheme, onPrimaryBubble: true),
    );
    final command = spans.where((s) => s.text == '/rerun').toList();
    expect(command, hasLength(1));
    expect(command.single.style?.color, palette.command);
    expect(command.single.style?.fontWeight, FontWeight.w600);
    // 记号外的正文仍是气泡正文色。
    final plain = spans
        .where((s) => s.text?.contains('我拔剑了') ?? false)
        .toList();
    expect(plain, hasLength(1));
    expect(plain.single.style?.color, scheme.onPrimary);
  });

  testWidgets('assistant bubble highlights skill and command tokens', (
    tester,
  ) async {
    const msg = Message(
      sessionId: 1,
      role: 'assistant',
      content: '@剑术 /rerun 你拔剑了',
      seq: 0,
    );
    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            syntax: CompiledSyntax.compile(skillNames: {'剑术'}),
          ),
        ),
      ),
    );

    final element = tester.element(find.byType(MessageBubble));
    final scheme = Theme.of(element).colorScheme;
    final palette = SyntaxPalette.of(
      scheme,
      SyntaxSurface.assistantBubble,
      baseTextColor: scheme.onSurface,
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

    final skill = spans.where((s) => s.text == '@剑术').toList();
    expect(skill, hasLength(1));
    expect(skill.single.style?.color, palette.skill);
    final command = spans.where((s) => s.text == '/rerun').toList();
    expect(command, hasLength(1));
    expect(command.single.style?.color, palette.command);
    expect(command.single.style?.fontWeight, FontWeight.w600);
    expect(spans.where((s) => s.text?.contains('你拔剑了') ?? false), hasLength(1));
  });
}
