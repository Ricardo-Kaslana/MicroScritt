import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/models/llm_provider.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/provider_edit_screen.dart';
import '../support/test_database.dart';

/// Provider 编辑页的「官方 OpenAI 参数风格」开关与「测试连接」入口回归:
/// 开关往返持久化,探测入口在模型目录为空时禁用。
///
/// 测试内所有真实 DB I/O 一律包 `tester.runAsync`(character_edit_screen_test
/// 同款);ListView 懒加载,断言下方条目前先 scrollUntilVisible。
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

    // 三枚开关(官方参数风格 + 工具通道回复/随机前缀);兼容选项默认全关。
    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(3));
    expect(tester.widget<Switch>(switches.at(0)).value, isFalse);
    expect(tester.widget<Switch>(switches.at(1)).value, isFalse);
    expect(tester.widget<Switch>(switches.at(2)).value, isFalse);

    await tester.ensureVisible(switches.at(0));
    await tester.pump();
    await tester.tap(switches.at(0));
    await tester.pump();

    // 「保存」在懒加载列表底部,先滚动到可见再点。
    await tester.scrollUntilVisible(find.text('保存'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
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

  testWidgets('probe entry is listed for a provider with models', (tester) async {
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(harness(provider()));
    await open(tester);

    await tester.scrollUntilVisible(find.text('开始探测'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    // 有模型时探测入口可点(懒加载列表滚动到位后按钮应在树中)。
    // TextButton.icon 的运行时类型是私有子类,byType 精确匹配会漏,用谓词。
    final probeButton = find.ancestor(of: find.text('开始探测'), matching: find.byWidgetPredicate((w) => w is TextButton));
    expect(probeButton, findsOneWidget);
    expect(tester.widget<TextButton>(probeButton).onPressed, isNotNull);
  });
}
