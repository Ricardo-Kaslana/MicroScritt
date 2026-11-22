// 桌面键盘发送:Enter 提交、Shift+Enter 换行、IME 组合中不提交、
// 忙碌期不重复触发。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import 'package:microscritt/ui/widgets/chat_composer.dart';

void main() {
  Future<void> pumpComposer(
    WidgetTester tester, {
    required TextEditingController controller,
    required FocusNode focus,
    required VoidCallback onSend,
    bool interruptible = false,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith((ref) => const AppSettings()),
          llmProvidersProvider.overrideWith(
            (ref) => const <LlmProviderConfig>[],
          ),
        ],
        child: MaterialApp(
          // 主题平台决定输入框的桌面/移动高度档位;显式传入,避免依赖宿主
          // 默认平台(测试默认 android)导致桌面分支不生效。关闭主题过渡,
          // 否则一次 pump 后 Theme 仍停在上一档 platform。
          theme: ThemeData(platform: platform),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatComposer(
                interruptible: interruptible,
                inputController: controller,
                inputFocusNode: focus,
                usage: const ContextLink(estimateTokens: 0),
                onSend: onSend,
                onInterrupt: () {},
                submitOnEnter: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    focus.requestFocus();
    await tester.pump();
  }

  testWidgets('Enter 发送,Shift+Enter 与 IME 组合不发送', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var sends = 0;
    await pumpComposer(
      tester,
      controller: controller,
      focus: focus,
      onSend: () => sends++,
    );

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, 1, reason: '桌面 Enter 应提交');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(sends, 1, reason: 'Shift+Enter 应放行换行');

    controller.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 1, end: 2),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, 1, reason: '输入法组合中的确认键不能被当成发送');
  });

  testWidgets('忙碌期 Enter 不发送', (tester) async {
    final controller = TextEditingController(text: 'hello');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var sends = 0;
    await pumpComposer(
      tester,
      controller: controller,
      focus: focus,
      onSend: () => sends++,
      interruptible: true,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, 0);
  });

  testWidgets('桌面输入框比移动端略高', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    Future<double> composerHeight(TargetPlatform platform) async {
      await pumpComposer(
        tester,
        controller: controller,
        focus: focus,
        onSend: () {},
        platform: platform,
      );
      final card = find.byKey(const ValueKey('composer_card'));
      expect(Theme.of(tester.element(card)).platform, platform);
      return tester.getSize(card).height;
    }

    final mobile = await composerHeight(TargetPlatform.android);
    final desktop = await composerHeight(TargetPlatform.windows);
    // 桌面端输入框上下各垫 8px,补偿桌面 InputDecorator 更紧的默认密度;
    // 桌面输入卡最终比移动端高 6。
    expect(desktop - mobile, closeTo(6, 0.5));
  });
}
