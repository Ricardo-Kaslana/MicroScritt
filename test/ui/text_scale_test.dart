// 大字号可访问性:共享设置行、下拉、批量选择栏与空态在 1.5x 字号下
// 不横向溢出;标题允许换行,长说明不被单行省略。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/common/form_field.dart';
import 'package:microscritt/ui/common/form_row.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import 'package:microscritt/ui/theme/app_theme.dart';
import 'package:microscritt/ui/widgets/chat_composer.dart';
import 'package:microscritt/ui/widgets/chat_empty_state.dart';
import 'package:microscritt/ui/widgets/chat_island.dart';
import 'package:microscritt/ui/widgets/message_selection_bar.dart';

void main() {
  void useLargeText(WidgetTester tester, {double scale = 1.5}) {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets('设置行在 1.5 倍字号下不横向溢出', (tester) async {
    useLargeText(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                SettingsSwitchTile(
                  title: '变量删除前确认与后台维护严格模式说明',
                  description: '开启后后台删除变量只写入待确认建议,需要在状态面板逐条确认。',
                  titleTrailing: const Icon(Icons.info_outline, size: 18),
                  value: true,
                  onChanged: (_) {},
                ),
                SettingsFormRow(
                  title: '后台专用模型与推理强度设置',
                  description: '未选择时跟随主写引擎当前模型,和主对话互相独立。',
                  control: Switch(value: true, onChanged: (_) {}),
                ),
                SettingsSliderTile(
                  title: '自动压缩触发阈值',
                  valueLabel: '最多 10 条',
                  value: 0.6,
                  min: 0,
                  max: 1,
                  onChanged: (_) {},
                ),
                FormDropdownField<String>(
                  value: 'off',
                  label: '后台推理强度',
                  helperText: '仅影响后台请求,与主对话的推理等级互相独立;默认关闭。',
                  items: const ['off'],
                  labelOf: (value) => value,
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final title = tester.widget<Text>(find.text('后台专用模型与推理强度设置'));
    expect(title.maxLines, 2);
  });

  testWidgets('批量选择栏与聊天空态在 1.5 倍字号下不横向溢出', (tester) async {
    useLargeText(tester);
    const character = CharacterCard(
      name: 'Alice',
      firstMessage: '主开场白:欢迎来到这家只在雨夜营业的酒馆,壁炉旁还留着你的位置。',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ChatEmptyState(character: character, onGreeting: (_) {}),
              ),
              MessageSelectionBar(
                selectedCount: 0,
                totalCount: 4,
                imageCount: 2,
                textCount: 2,
                onSelectAll: () {},
                onClearSelection: () {},
                onSelectImages: () {},
                onSelectText: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('图片 2'), findsOneWidget);
    expect(find.text('文本 2'), findsOneWidget);
  });

  testWidgets('灵岛展开明细在 2 倍字号下不横向溢出', (tester) async {
    useLargeText(tester, scale: 2.0);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Stack(
            children: [
              const SizedBox.expand(),
              ChatIsland(
                key: const ValueKey('chat-island'),
                chat: const ChatState(
                  inputTokens: 1200,
                  outputTokens: 300,
                  backgroundInputTokens: 400,
                  backgroundOutputTokens: 40,
                  compactInputTokens: 200,
                  compactOutputTokens: 20,
                ),
                memoryInitPrompt: false,
                compacting: false,
                hidden: false,
                idleHushed: false,
                onOpenStatus: () {},
                onInterrupt: () {},
                onInitMemory: () {},
                onDismissMemoryInit: () {},
                onDismissError: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-island')));
    await tester.pumpAndSettle();

    expect(find.text('合计'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('聊天输入卡底栏在 1.5 倍字号下不横向溢出', (tester) async {
    useLargeText(tester);
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith((ref) => const AppSettings()),
          llmProvidersProvider.overrideWith(
            (ref) => const <LlmProviderConfig>[],
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatComposer(
                interruptible: false,
                inputController: controller,
                inputFocusNode: focus,
                usage: const ContextLink(estimateTokens: 0),
                onSend: () {},
                onInterrupt: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('未选择模型'), findsOneWidget);
  });
}
