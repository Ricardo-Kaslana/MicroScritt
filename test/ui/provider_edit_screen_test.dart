// Provider 编辑页回归:modernParams 开关默认关闭并随保存持久化,
// 以及有模型时「开始测试」入口可点。
//
// 真实 DB I/O 一律包 `tester.runAsync`;页面是懒加载 ListView,
// 开关与保存按钮先 ensureVisible 或 scrollUntilVisible 再操作。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/provider_edit_screen.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;

  LlmProviderConfig provider({bool modernParams = false}) => LlmProviderConfig(
        id: 0,
        providerId: 'openai',
        displayName: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        protocol: LlmProtocol.openaiCompat,
        apiKey: 'public',
        modernParams: modernParams,
        models: const [
          LlmModelEntry(
            id: 0,
            providerId: 0,
            modelId: 'gpt-4o',
            displayName: 'GPT-4o',
            contextCapacity: 128000,
          ),
        ],
      );

  Widget harness(LlmProviderConfig? existing) => ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ProviderEditScreen(existing: existing)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('modernParams toggle persists through save', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness(provider()));
    await open(tester);

    // 一枚开关(官方参数风格),默认关闭。
    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(1));
    expect(tester.widget<Switch>(switches.at(0)).value, isFalse);

    await tester.ensureVisible(switches.at(0));
    await tester.pump();
    await tester.tap(switches.at(0));
    await tester.pump();

    // 底部保存键是 FilledButton(AppBar 上另有一枚 TextButton 保存键),
    // 按类型精确定位避免 find.text('保存') 命中两枚;先滚动到可见再点。
    final saveButton = find.widgetWithText(FilledButton, '保存');
    await tester.scrollUntilVisible(saveButton, 300, scrollable: find.byType(Scrollable).first);
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(saveButton);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    expect(find.byType(ProviderEditScreen), findsNothing); // 保存后 pop
    final saved = (await tester.runAsync(() async {
      final all = await LlmProviderRepository(db).all();
      return all.single;
    }));
    expect(saved!.modernParams, isTrue);
  });

  testWidgets('existing provider with modernParams on shows the switch on', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
      await LlmProviderRepository(db).saveProvider(provider(modernParams: true));
    });
    final persisted = (await tester.runAsync(() async {
      final all = await LlmProviderRepository(db).all();
      return all.single;
    }));

    await tester.pumpWidget(harness(persisted));
    await open(tester);

    expect(tester.widget<Switch>(find.byType(Switch).at(0)).value, isTrue);
  });

  testWidgets('base URL hint follows the selected protocol', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness(null));
    await open(tester);

    // 新建页默认 OpenAI 兼容:示例地址含 /v1。
    expect(find.text('如 https://api.openai.com/v1'), findsOneWidget);

    final protocolField = find.byKey(const ValueKey('field_协议'));
    await tester.ensureVisible(protocolField);
    await tester.pump();
    await tester.tap(protocolField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();

    // Anthropic 后端自行拼 /v1/messages,示例为根地址、不得带 /v1。
    expect(find.text('如 https://api.anthropic.com(不含 /v1)'), findsOneWidget);
    expect(find.text('如 https://api.openai.com/v1'), findsNothing);
  });

  testWidgets('probe entry is listed for a provider with models', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness(provider()));
    await open(tester);

    await tester.scrollUntilVisible(find.text('开始测试'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    // 有模型时探测入口可点(懒加载列表滚动到位后按钮应在树中)。
    // TextButton.icon 的运行时类型是私有子类,byType 精确匹配会漏,用谓词。
    final probeButton = find.ancestor(of: find.text('开始测试'), matching: find.byWidgetPredicate((w) => w is TextButton));
    expect(probeButton, findsOneWidget);
    expect(tester.widget<TextButton>(probeButton).onPressed, isNotNull);
  });
}
