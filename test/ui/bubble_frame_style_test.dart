// 气泡边框样式:默认面/圆角、定制色与透明度、尾巴角固定、用户气泡
// 不受定制,以及高亮描边与文字色自动对比。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/bubble_style.dart';
import 'package:microscritt/ui/widgets/message_bubble.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  BoxDecoration? decorationOf(WidgetTester tester) {
    final frame = tester.widget<Container>(
      find.descendant(of: find.byType(ChatBubbleFrame), matching: find.byType(Container)).first,
    );
    return frame.decoration as BoxDecoration?;
  }

  BorderRadius radiusOf(BoxDecoration d) => d.borderRadius as BorderRadius;

  testWidgets('default assistant frame uses surface + kChatBubbleRadius', (tester) async {
    await tester.pumpWidget(host(const ChatBubbleFrame(
      isUser: false,
      groupStart: true,
      groupEnd: true,
      child: Text('hi'),
    )));
    final d = decorationOf(tester)!;
    expect(d.color, ThemeData().colorScheme.surface); // 浅色主题 surface
    expect(radiusOf(d).topLeft, const Radius.circular(kChatBubbleRadius));
  });

  testWidgets('style applies color/opacity/radius to assistant frame only', (tester) async {
    const style = BubbleStyle(bubbleColor: 0xFF283593, radius: 24, opacity: 0.5);
    await tester.pumpWidget(host(const ChatBubbleFrame(
      isUser: false,
      groupStart: true,
      groupEnd: true,
      style: style,
      child: Text('hi'),
    )));
    final d = decorationOf(tester)!;
    expect(d.color, const Color(0xFF283593).withValues(alpha: 0.5));
    expect(radiusOf(d).topLeft, const Radius.circular(24));
    // 组内末条:尾巴角不随定制半径变化。
    expect(radiusOf(d).bottomLeft, const Radius.circular(kChatTailRadius));

    // 用户气泡不受 style 影响,仍是主色 + 默认圆角。
    await tester.pumpWidget(host(const ChatBubbleFrame(
      isUser: true,
      groupStart: true,
      groupEnd: true,
      style: style,
      child: Text('hi'),
    )));
    final du = decorationOf(tester)!;
    expect(du.color, isNot(const Color(0xFF283593).withValues(alpha: 0.5)));
    expect(radiusOf(du).topLeft, const Radius.circular(kChatBubbleRadius));
  });

  testWidgets('highlighted frame draws a tertiary border with glow', (tester) async {
    await tester.pumpWidget(host(const ChatBubbleFrame(
      isUser: false,
      groupStart: true,
      groupEnd: true,
      highlighted: true,
      child: Text('hi'),
    )));
    final d = decorationOf(tester)!;
    final scheme = ThemeData().colorScheme;
    final border = d.border! as Border;
    expect(border.top.color, scheme.tertiary);
    expect(border.top.width, 2);
    expect(d.boxShadow, isNotNull);
    expect(d.boxShadow!.single.color.a, greaterThan(0));
  });

  test('resolveAssistantTextColor: 显式色优先,否则按底色亮度自动', () {
    final scheme = ThemeData.light().colorScheme;
    // 深底 → 自动浅字;浅底 → 自动深字;显式字色最高优先。
    expect(
      resolveAssistantTextColor(scheme, const BubbleStyle(bubbleColor: 0xFF283593)),
      Colors.white,
    );
    expect(
      resolveAssistantTextColor(scheme, const BubbleStyle(bubbleColor: 0xFFFFB300)),
      const Color(0xFF1B1B1F),
    );
    expect(
      resolveAssistantTextColor(
        scheme,
        const BubbleStyle(bubbleColor: 0xFF283593, textColor: 0xFF123456),
      ),
      const Color(0xFF123456),
    );
    // 未定制 → 主题 onSurface;只定制文字色 → 直接用。
    expect(resolveAssistantTextColor(scheme, null), scheme.onSurface);
    expect(
      resolveAssistantTextColor(scheme, const BubbleStyle(textColor: 0xFFABCDEF)),
      const Color(0xFFABCDEF),
    );
  });
}
