// 制卡工作台 widget 测试:移动双 Tab/桌面双栏、diff 渲染、完整生成到应用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/card_studio_draft_file.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/engine/card_studio/card_diff.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/image_result.dart';
import 'package:microscritt/models/llm_tool.dart';
import 'package:microscritt/state/card_studio_controller.dart';
import 'package:microscritt/state/card_studio_draft_codec.dart';
import 'package:microscritt/state/card_studio_state.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/card_studio/card_preview_sheet.dart';
import 'package:microscritt/ui/card_studio/card_studio_screen.dart';
import 'package:microscritt/ui/card_studio/diff_text_view.dart';
import 'package:microscritt/ui/common/section_header.dart';
import '../support/scripted_llm_backend.dart';
import '../support/test_database.dart';

class _FixedImageBackend implements ImageBackend {
  final String base64;
  _FixedImageBackend(this.base64);

  @override
  String get id => 'fixed';

  @override
  Future<ImageResult> generateImage(String prompt) async =>
      ImageResult.single(base64: base64);
}

/// 用 dart:ui 画一块纯色矩形并编码为 PNG base64(测试解码器可产出帧)。
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

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await openTestDb();
  });

  /// sqflite 是真实 I/O:先在假时钟环境拆树,再让出真实时间关库,避免在途
  /// 查询撞锁或测试进程悬挂。
  Future<void> closeDb(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await db.db.close();
    });
  }

  ScriptedLlmBackend twoStepBackend(String name) => ScriptedLlmBackend([
    [
      ToolCallsEvent([
        ToolCall(
          id: 'c1',
          name: 'setCardFields',
          arguments: jsonEncode({
            'fields': {'name': name, 'description': '一段描述'},
          }),
        ),
      ]),
      const DoneEvent(),
    ],
    [
      ToolCallsEvent([
        ToolCall(
          id: 'c2',
          name: 'finish',
          arguments: jsonEncode({'summary': '完成'}),
        ),
      ]),
      const DoneEvent(),
    ],
  ]);

  Widget app(
    LlmBackend backend, {
    int? characterId,
    CardStudioDraftFile? draftFile,
    ImageBackend? imageBackend,
  }) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      backendConfigProvider.overrideWith(
        (ref) => const BackendConfig(
          provider: BackendProvider.openai,
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-test',
          model: 'test-model',
        ),
      ),
      backendProvider.overrideWith((ref) => backend),
      imageBackendProvider.overrideWith((ref) => imageBackend),
      appSettingsProvider.overrideWith((ref) => const AppSettings()),
      if (draftFile != null)
        cardStudioDraftFileProvider.overrideWithValue(draftFile),
    ],
    child: MaterialApp(home: CardStudioScreen(characterId: characterId)),
  );

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    String? message,
  }) async {
    for (var i = 0; i < 150; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 20));
    }
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .join(' | ');
    fail('${message ?? 'not found within 3s: $finder'}\nTexts: $texts');
  }

  /// sqflite 事务是真实 I/O:widget 测试的假时钟推不动它,交替让出真实
  /// 时间与帧回调,直到目标出现。
  Future<void> pumpUntilFoundReal(
    WidgetTester tester,
    Finder finder, {
    String? message,
  }) async {
    for (var i = 0; i < 80; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .join(' | ');
    fail('${message ?? 'not found within real 2.4s: $finder'}\nTexts: $texts');
  }

  Future<void> sendBrief(WidgetTester tester, String text) async {
    await pumpUntilFound(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
    // 键盘发送动作直接走 onSubmitted,避免依赖按钮启用帧。
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
  }

  void useSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('mobile: tabs, generated diff and apply flow', (tester) async {
    useSurface(tester, const Size(360, 800));
    final backend = twoStepBackend('移动端角色');
    await tester.pumpWidget(app(backend));
    await tester.pump();
    // 等基线加载完成(idle)再输入,否则发送按钮仍禁用。
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));

    await sendBrief(tester, '写一个角色');
    await pumpUntilFound(
      tester,
      find.text('角色卡 · 2 项修改'),
      message: '生成完成后应自动切到变更 Tab 并显示字段 diff',
    );
    expect(find.byType(SegmentedButton<int>), findsOneWidget);
    expect(find.text('变更 (2)'), findsOneWidget);
    expect(find.textContaining('移动端角色'), findsWidgets);
    expect(find.byType(DiffTextView), findsNWidgets(2));

    final acceptAll = find.widgetWithText(TextButton, '全部接受');
    final rejectAll = find.widgetWithText(TextButton, '全部拒绝');
    expect(
      tester.getSize(acceptAll).width,
      tester.getSize(rejectAll).width,
      reason: '移动端批量操作应等宽并排',
    );
    expect(tester.getCenter(acceptAll).dy, tester.getCenter(rejectAll).dy);
    expect(
      tester.getTopRight(acceptAll).dx,
      lessThan(tester.getTopLeft(rejectAll).dx),
    );

    await tester.ensureVisible(find.text('应用变更 (2)'));
    await tester.tap(find.text('应用变更 (2)'));
    await pumpUntilFoundReal(tester, find.text('已应用到角色卡'));

    final backButton = find.widgetWithText(OutlinedButton, '返回列表');
    final continueButton = find.widgetWithText(FilledButton, '继续打磨');
    final openButton = find.widgetWithText(FilledButton, '打开角色卡');
    expect(
      tester.getCenter(backButton).dy,
      tester.getCenter(continueButton).dy,
      reason: '窄屏按钮保持单行',
    );
    expect(tester.getCenter(backButton).dy, tester.getCenter(openButton).dy);
    expect(
      tester.getSize(openButton).width,
      greaterThan(tester.getSize(backButton).width),
      reason: '等比缩小不改变按钮原有相对宽度',
    );

    late List<CharacterRecord> chars;
    await tester.runAsync(() async {
      chars = await CharacterRepository(db).all();
    });
    expect(chars, hasLength(1));
    expect(chars.single.card.name, '移动端角色');
    expect(chars.single.card.description, '一段描述');

    // 应用后可留在工作台继续打磨:回到对话 Tab 并保留已应用基线。
    await tester.tap(find.text('继续打磨'));
    await tester.pump();
    await pumpUntilFoundReal(tester, find.text('已应用，可继续描述要调整的内容。'));
    expect(find.text('对话'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CardStudioScreen)),
    );
    expect(
      container.read(cardStudioControllerProvider).phase,
      CardStudioPhase.idle,
    );

    await closeDb(tester);
  });

  testWidgets('composer reuses the chat input card without command tools', (
    tester,
  ) async {
    useSurface(tester, const Size(360, 800));
    await tester.pumpWidget(app(twoStepBackend('输入框角色')));
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));

    // 复用聊天输入卡:模型 chip 与上下文圆环在,命令/技能入口已删。
    final chip = find.byKey(const ValueKey('model_selector'));
    expect(chip, findsOneWidget);
    // 精简模式(无命令入口)下模型 chip 贴输入框最左侧,不再悬在右半区。
    expect(tester.getTopLeft(chip).dx, lessThan(60), reason: '模型选择区域应位于输入框最左侧');
    expect(find.byTooltip('未设置上下文容量'), findsOneWidget);
    expect(find.byTooltip('插入技能(@)'), findsNothing);
    expect(find.byTooltip('展开命令按钮行'), findsNothing);
    expect(find.byTooltip('收起命令按钮行'), findsNothing);
    await closeDb(tester);
  });

  testWidgets('avatar tiles open the fullscreen viewer', (tester) async {
    useSurface(tester, const Size(360, 800));
    final avatar = await tester.runAsync(() => _pngBase64(64, 64));
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c1',
            name: 'setCardFields',
            arguments: jsonEncode({
              'fields': {'name': '头像角色'},
            }),
          ),
          ToolCall(
            id: 'c2',
            name: 'setAvatarPrompt',
            arguments: jsonEncode({'prompt': '1girl'}),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c3',
            name: 'finish',
            arguments: jsonEncode({'summary': '完成'}),
          ),
        ]),
        const DoneEvent(),
      ],
    ]);
    await tester.pumpWidget(
      app(backend, imageBackend: _FixedImageBackend(avatar!)),
    );
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写一个头像');

    final preview = find.byKey(const ValueKey('card_avatar_preview_new'));
    await pumpUntilFoundReal(tester, preview, message: '头像生成后应可点击预览');
    final tileSize = tester.getSize(preview);
    expect(tileSize.width, tileSize.height, reason: '头像格保持正方形');
    expect(tileSize.width, greaterThan(108), reason: '头像格随可用宽度放大');
    expect(
      tester.getCenter(find.text('原头像')).dy,
      tester.getCenter(find.text('新头像')).dy,
      reason: '窄屏放得下时双头像并排',
    );
    await tester.tap(preview);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.byTooltip('下载图片'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byTooltip('关闭'), findsNothing);
    await closeDb(tester);
  });

  testWidgets(
    'reused avatar prompt without a new image shows one current avatar',
    (tester) async {
      useSurface(tester, const Size(360, 800));
      final avatar = await tester.runAsync(() => _pngBase64(64, 64));
      final backend = ScriptedLlmBackend([
        [
          ToolCallsEvent([
            ToolCall(
              id: 'c1',
              name: 'setCardFields',
              arguments: jsonEncode({
                'fields': {'name': '头像续轮'},
              }),
            ),
            ToolCall(
              id: 'c2',
              name: 'setAvatarPrompt',
              arguments: jsonEncode({'prompt': '1girl'}),
            ),
          ]),
          const DoneEvent(),
        ],
        [
          ToolCallsEvent([
            ToolCall(
              id: 'c3',
              name: 'finish',
              arguments: jsonEncode({'summary': '完成'}),
            ),
          ]),
          const DoneEvent(),
        ],
        [
          ToolCallsEvent([
            ToolCall(
              id: 'c4',
              name: 'setCardFields',
              arguments: jsonEncode({
                'fields': {'description': '续轮描述'},
              }),
            ),
          ]),
          const DoneEvent(),
        ],
        [
          ToolCallsEvent([
            ToolCall(
              id: 'c5',
              name: 'finish',
              arguments: jsonEncode({'summary': '完成'}),
            ),
          ]),
          const DoneEvent(),
        ],
      ]);
      await tester.pumpWidget(
        app(backend, imageBackend: _FixedImageBackend(avatar!)),
      );
      await tester.pump();
      await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
      await sendBrief(tester, '写一个头像');
      await pumpUntilFoundReal(
        tester,
        find.byKey(const ValueKey('card_avatar_preview_new')),
        message: '首轮应生成新头像',
      );

      await tester.ensureVisible(find.text('应用变更 (2)'));
      await tester.tap(find.text('应用变更 (2)'));
      await pumpUntilFoundReal(tester, find.text('已应用到角色卡'));
      await tester.tap(find.text('继续打磨'));
      await tester.pump();
      await pumpUntilFoundReal(tester, find.text('已应用，可继续描述要调整的内容。'));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CardStudioScreen)),
      );
      await container.read(cardStudioControllerProvider.notifier).run('只改描述');
      await tester.pumpAndSettle();

      final state = container.read(cardStudioControllerProvider);
      expect(state.phase, CardStudioPhase.review);
      expect(state.diff!.avatar, isNull, reason: '续轮没有生成新头像');
      expect(state.draftCard!.avatarBase64, isNotNull, reason: '已应用头像继续作为基线');
      expect(
        find.byKey(const ValueKey('card_avatar_preview_current')),
        findsOneWidget,
      );
      expect(find.text('当前头像'), findsOneWidget);
      expect(find.text('原头像'), findsNothing);
      expect(find.text('新头像'), findsNothing);
      expect(
        find.byKey(const ValueKey('card_avatar_preview_old')),
        findsNothing,
      );
      await closeDb(tester);
    },
  );

  testWidgets('avatar diff tiles scale up on wide layouts', (tester) async {
    useSurface(tester, const Size(1280, 900));
    final avatar = await tester.runAsync(() => _pngBase64(64, 64));
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c1',
            name: 'setCardFields',
            arguments: jsonEncode({
              'fields': {'name': '宽屏角色'},
            }),
          ),
          ToolCall(
            id: 'c2',
            name: 'setAvatarPrompt',
            arguments: jsonEncode({'prompt': '1girl'}),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c3',
            name: 'finish',
            arguments: jsonEncode({'summary': '完成'}),
          ),
        ]),
        const DoneEvent(),
      ],
    ]);
    await tester.pumpWidget(
      app(backend, imageBackend: _FixedImageBackend(avatar!)),
    );
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写一个头像');

    final preview = find.byKey(const ValueKey('card_avatar_preview_new'));
    await pumpUntilFoundReal(tester, preview, message: '头像生成后应可点击预览');
    final tileSize = tester.getSize(preview);
    expect(tileSize.width, tileSize.height, reason: '头像格保持正方形');
    expect(tileSize.width, 200, reason: '宽屏头像格放大到上限');
    expect(
      tester.getCenter(find.text('原头像')).dy,
      tester.getCenter(find.text('新头像')).dy,
      reason: '宽屏双头像并排',
    );
    await closeDb(tester);
  });

  testWidgets('narrow layouts stack the avatar comparison', (tester) async {
    useSurface(tester, const Size(320, 800));
    final avatar = await tester.runAsync(() => _pngBase64(64, 64));
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c1',
            name: 'setCardFields',
            arguments: jsonEncode({
              'fields': {'name': '窄屏角色'},
            }),
          ),
          ToolCall(
            id: 'c2',
            name: 'setAvatarPrompt',
            arguments: jsonEncode({'prompt': '1girl'}),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c3',
            name: 'finish',
            arguments: jsonEncode({'summary': '完成'}),
          ),
        ]),
        const DoneEvent(),
      ],
    ]);
    await tester.pumpWidget(
      app(backend, imageBackend: _FixedImageBackend(avatar!)),
    );
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写一个头像');

    final preview = find.byKey(const ValueKey('card_avatar_preview_new'));
    await pumpUntilFoundReal(tester, preview, message: '头像生成后应可点击预览');
    expect(
      tester.getCenter(find.text('新头像')).dy,
      greaterThan(tester.getCenter(find.text('原头像')).dy),
      reason: '极窄屏改为纵向堆叠',
    );
    final tileSize = tester.getSize(preview);
    expect(tileSize.width, tileSize.height, reason: '头像格保持正方形');
    expect(tileSize.width, 200, reason: '堆叠时头像格按最大边长展示');
    await closeDb(tester);
  });

  testWidgets('wide preview uses identity sidebar and grouped content', (
    tester,
  ) async {
    useSurface(tester, const Size(1280, 900));
    final avatar = await tester.runAsync(() => _pngBase64(64, 64));
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c1',
            name: 'setCardFields',
            arguments: jsonEncode({
              'fields': {
                'name': '预览角色',
                'description': '一段描述',
                'firstMessage': '开场白内容',
              },
            }),
          ),
          ToolCall(
            id: 'c2',
            name: 'setAvatarPrompt',
            arguments: jsonEncode({'prompt': '1girl'}),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c3',
            name: 'finish',
            arguments: jsonEncode({'summary': '完成'}),
          ),
        ]),
        const DoneEvent(),
      ],
    ]);
    await tester.pumpWidget(
      app(backend, imageBackend: _FixedImageBackend(avatar!)),
    );
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写一个角色');
    await pumpUntilFoundReal(
      tester,
      find.byKey(const ValueKey('card_avatar_preview_new')),
      message: '头像生成后应可预览',
    );

    await tester.tap(find.byTooltip('预览最终卡'));
    await tester.pumpAndSettle();
    final preview = find.byKey(const ValueKey('card_preview_sheet'));
    expect(preview, findsOneWidget);
    expect(tester.getSize(preview).width, 760, reason: '正文位于 280 宽侧栏右侧');
    expect(
      find.byKey(const ValueKey('card_preview_identity_sidebar')),
      findsOneWidget,
    );

    final descTitle = find.descendant(of: preview, matching: find.text('描述'));
    final greetingTitle = find.descendant(
      of: preview,
      matching: find.text('开场白'),
    );
    expect(descTitle, findsOneWidget);
    expect(greetingTitle, findsOneWidget);
    expect(
      tester.getTopLeft(greetingTitle).dy,
      greaterThan(tester.getTopLeft(descTitle).dy),
      reason: '正文按角色设定、对话开场顺排',
    );
    expect(
      tester.getTopLeft(greetingTitle).dx,
      moreOrLessEquals(tester.getTopLeft(descTitle).dx, epsilon: 2),
      reason: '所有正文分区共用同一阅读栏',
    );

    // 侧栏使用竖向角色名片,正文空间不再被横幅封面占用。
    final cover = find.byKey(const ValueKey('card_preview_cover'));
    expect(cover, findsOneWidget);
    final coverSize = tester.getSize(cover);
    expect(
      coverSize.width,
      moreOrLessEquals(232, epsilon: 1),
      reason: '名片头像铺满侧栏内容宽度',
    );
    expect(coverSize.height, 270, reason: '名片头像使用固定竖向高度');
    expect(
      find.descendant(of: preview, matching: find.byTooltip('查看头像大图')),
      findsNothing,
      reason: '预览内直接展示大图,不再需要点击查看',
    );
    await closeDb(tester);
  });

  testWidgets('desktop: two-pane layout without tabs', (tester) async {
    useSurface(tester, const Size(1280, 900));
    final backend = twoStepBackend('桌面角色');
    await tester.pumpWidget(app(backend));
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));

    // 桌面双栏:左侧对话输入 + 右侧审阅占位同时可见。
    await pumpUntilFound(tester, find.byType(TextField));
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.text('变更预览会出现在这里'), findsOneWidget);

    await sendBrief(tester, '写一个角色');
    await pumpUntilFound(tester, find.text('角色卡 · 2 项修改'));
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.text('应用变更 (2)'), findsOneWidget);
    // 对话面板仍在左侧可见。
    expect(find.text('写一个角色'), findsOneWidget);
    await closeDb(tester);
  });

  testWidgets('review reflects inline edits and gates empty acceptance', (
    tester,
  ) async {
    useSurface(tester, const Size(1280, 900));
    final backend = twoStepBackend('手工角色');
    await tester.pumpWidget(app(backend));
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写一个角色');
    await pumpUntilFound(tester, find.text('角色卡 · 2 项修改'));

    final descriptionCard = find.ancestor(
      of: find.text('描述'),
      matching: find.byType(SurfaceCard),
    );
    expect(descriptionCard, findsOneWidget);
    await tester.tap(
      find.descendant(of: descriptionCard, matching: find.byTooltip('编辑')),
    );
    await tester.pumpAndSettle();
    expect(find.text('编辑「描述」'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '手工描述');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('手工描述'), findsOneWidget);

    await tester.tap(find.byTooltip('预览最终卡'));
    await tester.pumpAndSettle();
    final preview = find.byKey(const ValueKey('card_preview_sheet'));
    expect(preview, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CardPreviewSheet),
        matching: find.text('手工角色'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.text('手工描述')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(preview, findsNothing);

    await tester.tap(find.text('全部拒绝'));
    await tester.pump();
    expect(find.text('应用变更 (0)'), findsOneWidget);
    expect(find.textContaining('尚未接受任何变更'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '应用变更 (0)'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('全部接受'));
    await tester.pump();
    expect(find.text('应用变更 (2)'), findsOneWidget);
    await closeDb(tester);
  });

  testWidgets('entry editor exposes and saves advanced flags', (tester) async {
    useSurface(tester, const Size(1280, 900));
    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c1',
            name: 'setCardFields',
            arguments: jsonEncode({
              'fields': {'name': '条目卡'},
            }),
          ),
          ToolCall(
            id: 'c2',
            name: 'upsertWorldbookEntries',
            arguments: jsonEncode({
              'entries': [
                {
                  'name': 'W',
                  'keys': ['w'],
                  'content': 'lore',
                },
              ],
            }),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c3',
            name: 'finish',
            arguments: jsonEncode({'summary': '完成'}),
          ),
        ]),
        const DoneEvent(),
      ],
    ]);
    await tester.pumpWidget(app(backend));
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写世界书');
    await pumpUntilFound(tester, find.text('世界书 · 新增 1'));

    await tester.ensureVisible(find.text('编辑条目'));
    await tester.tap(find.text('编辑条目'));
    await tester.pumpAndSettle();
    expect(find.text('次关键词（逗号分隔）'), findsOneWidget);
    await tester.ensureVisible(find.text('高级选项'));
    await tester.tap(find.text('高级选项'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('启用'));
    await tester.tap(find.text('启用'));
    await tester.pump();
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CardStudioScreen)),
    );
    final state = container.read(cardStudioControllerProvider);
    final decision = state.decisions.entry(
      state.diff!.entries.single.reviewKey,
    );
    expect(decision.editedEntry, isNotNull);
    expect(decision.editedEntry!.enabled, isFalse);
    await closeDb(tester);
  });

  testWidgets('discard menu clears the draft proposal', (tester) async {
    useSurface(tester, const Size(360, 800));
    final backend = twoStepBackend('丢弃角色');
    await tester.pumpWidget(app(backend));
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写一个角色');
    await pumpUntilFound(tester, find.text('角色卡 · 2 项修改'));

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃当前草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '丢弃'));
    await tester.pump();
    await pumpUntilFound(tester, find.text('已丢弃当前草稿。'));
    expect(find.textContaining('应用变更'), findsNothing);
    await closeDb(tester);
  });

  testWidgets('restored continue-polishing session can be discarded', (
    tester,
  ) async {
    useSurface(tester, const Size(360, 800));
    late int charId;
    late Directory dir;
    // widget 测试跑在虚拟时钟里,真实文件/数据库 IO 必须经 runAsync。
    await tester.runAsync(() async {
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: '会话角色'));
      dir = await Directory.systemTemp.createTemp('card-studio-ui-');
    });
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final draftFile = CardStudioDraftFile(dir.path);
    const card = CharacterCard(name: '会话角色');
    await tester.runAsync(
      () => draftFile.write(
        charId,
        encodeCardStudioDraft(
          CardStudioDraftSnapshot(
            targetCharacterId: charId,
            baseCard: card,
            baseEntries: const [],
            draftCard: card,
            draftEntries: const [],
            decisions: ReviewDecisions.acceptAll,
            entries: const [
              CardStudioEntry.user('上次的调整'),
              CardStudioEntry.notice('已应用，可继续描述要调整的内容。'),
            ],
            sessionLog: const ['用户：上次的调整'],
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      app(twoStepBackend('会话角色'), characterId: charId, draftFile: draftFile),
    );
    await tester.pump();
    // 草稿文件是真实 IO,恢复需要让出真实事件循环。
    await pumpUntilFoundReal(tester, find.textContaining('已恢复上次制卡对话'));
    expect(find.text('上次的调整'), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃当前草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '丢弃'));
    await tester.pump();
    await pumpUntilFound(tester, find.text('已丢弃当前草稿。'));
    // 删除走串行写队列 + 真实 IO:交替让出真实时间与帧,直到文件消失。
    var leftover = true;
    for (var i = 0; i < 40 && leftover; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      leftover = File(draftFile.pathFor(charId)).existsSync();
    }
    expect(leftover, isFalse);
    await closeDb(tester);
  });

  testWidgets('diff view renders gutters, colors and expansion', (
    tester,
  ) async {
    final diff = diffText('a\nold line\nb', 'a\nnew line\nb');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DiffTextView(diff: diff)),
      ),
    );
    expect(find.text('-'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
    expect(find.text('old line'), findsOneWidget);
    expect(find.text('new line'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    await closeDb(tester);
  });

  testWidgets('diff view folds long unchanged runs', (tester) async {
    final oldText = List.generate(40, (i) => 'line$i').join('\n');
    final newText = oldText.replaceFirst('line20', 'changed');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DiffTextView(diff: diffText(oldText, newText)),
          ),
        ),
      ),
    );
    expect(find.textContaining('行未变'), findsWidgets);
    expect(find.text('changed'), findsOneWidget);
    await closeDb(tester);
  });

  testWidgets('user instruction supports copy and edit-with-rerun', (
    tester,
  ) async {
    useSurface(tester, const Size(360, 800));
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final backend = ScriptedLlmBackend([
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c1',
            name: 'setCardFields',
            arguments: jsonEncode({
              'fields': {'name': '旧角色', 'description': '旧描述'},
            }),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c2',
            name: 'finish',
            arguments: jsonEncode({'summary': '第一轮完成'}),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c3',
            name: 'setCardFields',
            arguments: jsonEncode({
              'fields': {'name': '新角色'},
            }),
          ),
        ]),
        const DoneEvent(),
      ],
      [
        ToolCallsEvent([
          ToolCall(
            id: 'c4',
            name: 'finish',
            arguments: jsonEncode({'summary': '重跑完成'}),
          ),
        ]),
        const DoneEvent(),
      ],
    ]);
    await tester.pumpWidget(app(backend));
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '写一个角色');
    await pumpUntilFound(tester, find.text('角色卡 · 2 项修改'));

    // 生成完成会自动切到「变更」Tab;回到对话。
    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();

    // 长按仍提供完整动作单。
    await tester.longPress(find.text('写一个角色'));
    await tester.pumpAndSettle();
    expect(find.text('复制内容'), findsOneWidget);
    expect(find.text('编辑指令'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 点击气泡选中 → 下方出现复制/编辑操作排。
    await tester.tap(find.text('写一个角色'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('card-studio-action-copy')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('card-studio-action-edit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('card-studio-action-more')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('card-studio-action-copy')));
    await tester.pumpAndSettle();
    expect(copied, ['写一个角色']);
    expect(find.text('已复制到剪贴板'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // 再点气泡收起操作排,再点一次重新展开。
    await tester.tap(find.text('写一个角色'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-studio-action-copy')), findsNothing);
    await tester.tap(find.text('写一个角色'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('card-studio-action-edit')));
    await tester.pumpAndSettle();
    expect(find.text('编辑指令'), findsWidgets);
    expect(find.textContaining('将撤回该指令对应的本轮生成结果'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '改成另一个角色');
    await tester.pump();
    await tester.tap(find.text('保存并重新生成'));
    await tester.pumpAndSettle();
    // 重跑完成后自动切到变更 Tab;回到对话确认旧气泡已被替换。
    await pumpUntilFound(tester, find.text('角色卡 · 1 项修改'));
    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();
    expect(find.text('改成另一个角色'), findsOneWidget);
    expect(find.text('写一个角色'), findsNothing);
    await pumpUntilFound(tester, find.textContaining('重跑完成'));
    expect(find.textContaining('第一轮完成'), findsNothing);
    expect(backend.requests.last.messages.first.content, contains('改成另一个角色'));

    await closeDb(tester);
  });

  testWidgets('edit action is disabled while the agent is running', (
    tester,
  ) async {
    useSurface(tester, const Size(360, 800));
    final gate = Completer<void>();
    final backend = ScriptedLlmBackend(
      [
        [
          ToolCallsEvent([
            ToolCall(
              id: 'c1',
              name: 'setCardFields',
              arguments: jsonEncode({
                'fields': {'name': '运行中角色'},
              }),
            ),
          ]),
          const DoneEvent(),
        ],
        [
          ToolCallsEvent([
            ToolCall(
              id: 'c2',
              name: 'finish',
              arguments: jsonEncode({'summary': '完成'}),
            ),
          ]),
          const DoneEvent(),
        ],
      ],
      gates: {0: gate},
    );
    await tester.pumpWidget(app(backend));
    await tester.pump();
    await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
    await sendBrief(tester, '运行中的指令');
    await pumpUntilFound(tester, find.text('运行中的指令'));

    // 点击气泡同样展开操作排,但编辑键置灰并提示原因。
    await tester.tap(find.text('运行中的指令'));
    // 运行中草稿气泡是无限进度动画,pumpAndSettle 永不收敛。
    await tester.pump(const Duration(milliseconds: 300));
    final editButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('card-studio-action-edit')),
    );
    expect(editButton.onPressed, isNull);
    expect(find.byTooltip('正在生成或应用中'), findsOneWidget);

    await tester.longPress(find.text('运行中的指令'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('复制内容'), findsOneWidget);
    expect(find.text('编辑指令'), findsOneWidget);
    expect(find.text('正在生成或应用中'), findsOneWidget);

    await tester.tap(find.text('编辑指令'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('保存并重新生成'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));

    gate.complete();
    await pumpUntilFound(tester, find.text('角色卡 · 1 项修改'));
    await closeDb(tester);
  });

  testWidgets(
    'editing a cancelled instruction is described as consequence-free',
    (tester) async {
      useSurface(tester, const Size(360, 800));
      final gate = Completer<void>();
      final backend = ScriptedLlmBackend(
        [
          [const TextDelta('partial'), const DoneEvent()],
          [
            ToolCallsEvent([
              ToolCall(
                id: 'c1',
                name: 'setCardFields',
                arguments: jsonEncode({
                  'fields': {'name': '重跑角色'},
                }),
              ),
            ]),
            const DoneEvent(),
          ],
          [
            ToolCallsEvent([
              ToolCall(
                id: 'c2',
                name: 'finish',
                arguments: jsonEncode({'summary': '重跑完成'}),
              ),
            ]),
            const DoneEvent(),
          ],
        ],
        gates: {0: gate},
      );
      await tester.pumpWidget(app(backend));
      await tester.pump();
      await pumpUntilFound(tester, find.text('用一句话描述你的角色'));
      await sendBrief(tester, '会取消的指令');
      await pumpUntilFound(tester, find.text('会取消的指令'));

      // 停止本轮:没有产出任何卡面变更。
      await tester.tap(find.byTooltip('停止'));
      await pumpUntilFound(tester, find.text('已取消本轮生成。'));
      gate.complete();

      // 点击气泡 → 编辑:底单不再出现「撤回本轮生成结果」警告。
      await tester.tap(find.text('会取消的指令'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('card-studio-action-edit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未对角色卡产生实际修改'), findsOneWidget);
      expect(find.textContaining('将撤回该指令对应的本轮生成结果'), findsNothing);

      await tester.enterText(find.byType(TextField).last, '改后的指令');
      await tester.pump();
      await tester.tap(find.text('保存并重新生成'));
      await tester.pumpAndSettle();
      await pumpUntilFound(tester, find.text('角色卡 · 1 项修改'));
      await tester.tap(find.text('对话'));
      await tester.pumpAndSettle();
      expect(find.text('改后的指令'), findsOneWidget);
      expect(find.text('会取消的指令'), findsNothing);
      expect(find.text('已取消本轮生成。'), findsNothing);
      expect(backend.requests.last.messages.first.content, contains('改后的指令'));

      await closeDb(tester);
    },
  );
}
