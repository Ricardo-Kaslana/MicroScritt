// 桌面端输入区弹卡:斜杠建议卡(键盘导航)、@ 技能建议卡与过滤、命令卡、
// 技能卡、推理卡。
// 输入区直接上树(不经 ChatScreen),宿主行为(写命令文本/刷新建议)按
// ChatScreen._insertCommand 的契约模拟。平台钉 windows 走桌面弹卡分支。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/app_settings_repository.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/models/app_settings.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/state/slash_commands.dart';
import 'package:microscritt/ui/model_selector_bar.dart';
import 'package:microscritt/ui/widgets/chat_composer.dart';
import '../support/test_database.dart';

/// 宿主桩:持有输入控制器与建议状态,复刻 ChatScreen 的最小接线。
class _ComposerHarness extends StatefulWidget {
  const _ComposerHarness();

  @override
  State<_ComposerHarness> createState() => _ComposerHarnessState();
}

class _ComposerHarnessState extends State<_ComposerHarness> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  List<SlashCommand> _suggestions = const [];

  void _onChanged(String text) {
    setState(() => _suggestions = slashSuggestions(text));
  }

  /// 与 ChatScreen._insertCommand 同契约:写入 `/命令 `、光标在末尾、聚焦
  /// 并刷新建议(建议清空 → 建议弹卡自动关闭)。
  void _insertCommand(SlashCommand cmd) {
    final text = '${slashCommandSlash(cmd)} ';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
    _onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    // 与聊天页一致把输入区沉到列底:composer 内部的 Align(topCenter) 会吃掉
    // 外层 Align 的对齐语义,必须用 Spacer 顶到底,弹卡才有「向上展开」的
    // 真实锚定空间。
    return Scaffold(
      body: Column(
        children: [
          const Spacer(),
          ChatComposer(
            interruptible: false,
            suggestions: _suggestions,
            inputController: _input,
            inputFocusNode: _focus,
            usage: const ContextLink(estimateTokens: 0),
            onChanged: _onChanged,
            onInsertCommand: _insertCommand,
            onSend: () {},
            onInterrupt: () {},
            submitOnEnter: true,
          ),
        ],
      ),
    );
  }
}

void main() {
  late AppDatabase db;

  // 平台覆盖必须在测试体内复位:binding 的 foundation 不变量校验在
  // testWidgets 回调结束时、tearDown 之前执行。
  Future<void> withWindowsPlatform(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }

  /// 有上限的收敛等待:弹卡内容出现加载圈(如技能目录)时,假异步 pumping
  /// 永远不收敛,pumpAndSettle 默认 10 分钟超时会把整轮测试挂死 —— 这里手写
  /// 有界循环(pumpAndSettle 的 timeout 形参依赖未导出的 EnginePhase),
  /// 异常在秒级暴露。
  Future<void> pumpCard(
    WidgetTester tester, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    var elapsed = Duration.zero;
    const step = Duration(milliseconds: 100);
    while (tester.binding.hasScheduledFrame && elapsed < timeout) {
      await tester.pump(step);
      elapsed += step;
    }
    await tester.pump();
  }

  /// runAsync 轮询等待真实异步(DB 读取)完成并上树,复刻
  /// chat_command_test 状态面板的等待模式。
  Future<void> waitUntilVisible(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 80; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (finder.evaluate().isNotEmpty) break;
      }
      await tester.pump();
    });
  }

  Future<void> pumpHarness(
    WidgetTester tester, {
    ReasoningLevel? reasoning,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          databaseProvider.overrideWithValue(db),
          if (reasoning != null)
            appSettingsProvider.overrideWith(
              (ref) => AppSettings(reasoningLevel: reasoning),
            ),
        ],
        child: const MaterialApp(home: _ComposerHarness()),
      ),
    );
    await settle(tester);
  }

  testWidgets('typing / opens the suggestion flyout above the input card', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await pumpHarness(tester);

      await tester.enterText(find.byType(TextField), '/c');
      await pumpCard(tester);

      // 弹卡列出前缀匹配的命令,整体在输入卡上方;移动端的内联 chip 行不再出现。
      expect(find.byType(ActionChip), findsNothing);
      expect(find.text('/clear 清空历史'), findsOneWidget);
      expect(find.text('/compact 主动压缩'), findsOneWidget);
      final cardRect = tester.getRect(find.text('/clear 清空历史'));
      final cardTop = tester
          .getRect(find.byKey(const ValueKey('composer_card')))
          .top;
      expect(
        cardRect.bottom,
        lessThanOrEqualTo(cardTop),
        reason: '建议弹卡应悬在输入卡上方',
      );

      // 点击建议:命令文本写入输入框,建议清空 → 弹卡自动关闭。
      await tester.tap(find.text('/clear 清空历史'));
      await pumpCard(tester);
      expect(find.text('/clear 清空历史'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '/clear ');

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('arrow keys navigate and Enter inserts the highlighted command', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await pumpHarness(tester);

      // /c 前缀命中 continue/clear/compact 三条;↓ 两次落在第三条。
      await tester.enterText(find.byType(TextField), '/c');
      await pumpCard(tester);
      expect(find.text('/continue 推动剧情'), findsOneWidget);
      expect(find.text('/clear 清空历史'), findsOneWidget);
      expect(find.text('/compact 主动压缩'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      // 高亮行带 Enter 提示。
      expect(find.text('Enter'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpCard(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '/compact ', reason: 'Enter 应插入高亮命令');

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('tab completes the highlighted command suggestion', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await pumpHarness(tester);

      await tester.enterText(find.byType(TextField), '/c');
      await pumpCard(tester);
      expect(find.text('/continue 推动剧情'), findsOneWidget);

      // Tab 与 Enter 同义:补全当前高亮项,而不是把焦点移出输入框。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await pumpCard(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '/continue ');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(find.text('/continue 推动剧情'), findsNothing);

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('escape closes the suggestion flyout and Enter sends again', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await pumpHarness(tester);

      await tester.enterText(find.byType(TextField), '/c');
      await pumpCard(tester);
      expect(find.text('/clear 清空历史'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpCard(tester);
      expect(find.text('/clear 清空历史'), findsNothing);
      // 文本保留,Esc 只关弹卡。
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '/c');

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('terminal button opens the full command flyout', (tester) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await pumpHarness(tester);

      await tester.tap(find.byTooltip('命令'));
      await pumpCard(tester);
      // 五条命令全部在场,且无内联 chip。
      expect(find.byType(ActionChip), findsNothing);
      for (final label in [
        '/test 测试生成',
        '/continue 推动剧情',
        '/clear 清空历史',
        '/compact 主动压缩',
        '/rerun 重跑后台',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      // 点选一条:写入输入框并关闭弹卡。
      await tester.tap(find.text('/rerun 重跑后台'));
      await pumpCard(tester);
      expect(find.text('/rerun 重跑后台'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '/rerun ');

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('skill flyout lists enabled skills and inserts the token', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
        await SkillRepository(db).insert(
          const Skill(name: '剑术', description: '挥剑的姿势', content: '# 剑术'),
        );
        await SkillRepository(
          db,
        ).insert(const Skill(name: '禁用技能', enabled: false, content: 'x'));
      });
      await pumpHarness(tester);

      await tester.tap(find.byTooltip('调用技能(@)'));
      // 技能目录是 DB 异步读取:弹卡会先出现加载圈,假异步 pumping 不收敛,
      // 用 runAsync 轮询等真实数据上树(加载圈消失)再继续。
      await waitUntilVisible(tester, find.text('@剑术'));
      await tester.pump();

      // 只列启用中的技能;点选后令牌写入输入框并聚焦,弹卡关闭。
      expect(find.text('@剑术'), findsOneWidget);
      expect(find.text('挥剑的姿势'), findsOneWidget);
      expect(find.text('@禁用技能'), findsNothing);
      await tester.tap(find.text('@剑术'));
      await pumpCard(tester);
      expect(find.text('@剑术'), findsNothing);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '@剑术 ');
      expect(field.focusNode!.hasFocus, isTrue);

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets(
    'typing @ opens the skill suggestion flyout and filters by prefix',
    (tester) async {
      await withWindowsPlatform(() async {
        await tester.runAsync(() async {
          db = await openTestDb();
          await SkillRepository(db).insert(
            const Skill(name: '剑术', description: '挥剑的姿势', content: '# 剑术'),
          );
          await SkillRepository(
            db,
          ).insert(const Skill(name: '魔法', description: '施法', content: '# 魔法'));
          await SkillRepository(
            db,
          ).insert(const Skill(name: '禁用技能', enabled: false, content: 'x'));
        });
        await pumpHarness(tester);

        await tester.enterText(find.byType(TextField), '@');
        await waitUntilVisible(tester, find.text('@剑术'));
        await tester.pump();

        // 空前缀列出全部启用技能;禁用项不进候选。
        expect(find.text('@剑术'), findsOneWidget);
        expect(find.text('@魔法'), findsOneWidget);
        expect(find.text('@禁用技能'), findsNothing);

        // 继续输入前缀只保留命中的技能。
        await tester.enterText(find.byType(TextField), '@魔');
        await pumpCard(tester);
        expect(find.text('@魔法'), findsOneWidget);
        expect(find.text('@剑术'), findsNothing);

        await tester.runAsync(() => db.db.close());
      });
    },
  );

  testWidgets('keyboard selection replaces the typed @ prefix', (tester) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
        await SkillRepository(
          db,
        ).insert(const Skill(name: '剑术', content: '# 剑术'));
        await SkillRepository(
          db,
        ).insert(const Skill(name: '剑舞', content: '# 剑舞'));
      });
      await pumpHarness(tester);

      await tester.enterText(find.byType(TextField), '@剑');
      await waitUntilVisible(tester, find.text('@剑术'));
      await tester.pump();

      // ↓ 落到第二条(剑舞),Enter 插入完整令牌并替换已输入的前缀。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.text('Enter'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpCard(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '@剑舞 ');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(find.text('@剑术'), findsNothing);

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('tab completes the highlighted skill and replaces the prefix', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
        await SkillRepository(
          db,
        ).insert(const Skill(name: '剑术', content: '# 剑术'));
        await SkillRepository(
          db,
        ).insert(const Skill(name: '剑舞', content: '# 剑舞'));
      });
      await pumpHarness(tester);

      await tester.enterText(find.byType(TextField), '@剑');
      await waitUntilVisible(tester, find.text('@剑术'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await pumpCard(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '@剑术 ');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(find.text('@剑术'), findsNothing);

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('reasoning badge flyout persists slider changes and stays open', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await pumpHarness(tester, reasoning: ReasoningLevel.high);

      // 合并胶囊的模型段与推理段同厚,整颗 pill 齐平。
      expect(
        tester.getSize(find.byTooltip('推理等级:High')).height,
        closeTo(
          tester.getSize(find.byKey(const ValueKey('model_selector'))).height,
          0.5,
        ),
      );

      await tester.tap(find.byTooltip('推理等级:High'));
      await pumpCard(tester);
      expect(find.text('推理等级'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byTooltip('关闭'), findsNothing);

      // 拖到最左 = 关;落库成功后徽标消失,弹卡随锚点卸载而关闭。
      await tester.drag(find.byType(Slider), const Offset(-600, 0));
      await pumpCard(tester);

      late ReasoningLevel persisted;
      await tester.runAsync(() async {
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          persisted = (await AppSettingsRepository(db).load()).reasoningLevel;
          if (persisted == ReasoningLevel.off) break;
        }
      });
      expect(persisted, ReasoningLevel.off);
      // 落库成功后 provider 更新触发的重建帧在 runAsync(真实异步窗)期间入队,
      // 补帧把「徽标卸载 + 弹卡随锚点关闭」渲染出来再断言。
      await pumpCard(tester);
      expect(find.byTooltip('推理等级:High'), findsNothing);

      await tester.runAsync(() => db.db.close());
    });
  });

  testWidgets('desktop footer fuses model and reasoning into one capsule', (
    tester,
  ) async {
    await withWindowsPlatform(() async {
      await tester.runAsync(() async {
        db = await openTestDb();
      });
      await pumpHarness(tester, reasoning: ReasoningLevel.high);

      final capsule = find.byKey(const ValueKey('model_reasoning_capsule'));
      final divider = find.byKey(const ValueKey('model_reasoning_divider'));
      final chip = find.byKey(const ValueKey('model_selector'));
      final badge = find.byTooltip('推理等级:High');
      expect(capsule, findsOneWidget);
      expect(divider, findsOneWidget);

      // 两段紧贴同一条发丝线:模型段右缘 = 分隔线左缘,推理段左缘紧接
      // 分隔线右缘 —— 不再是两块各自上色、各自收圆角的胶囊硬拼。
      final chipRect = tester.getRect(chip);
      final dividerRect = tester.getRect(divider);
      final badgeRect = tester.getRect(badge);
      expect(dividerRect.left - chipRect.right, closeTo(0, 0.5));
      expect(badgeRect.left - dividerRect.right, closeTo(0, 0.5));
      // 胶囊与圆环同高;圆环、发送键与胶囊保持同一档间距(10)。
      final capsuleRect = tester.getRect(capsule);
      final ringRect = tester.getRect(find.byType(ContextUsageRing));
      final sendRect = tester.getRect(find.byTooltip('发送'));
      expect(capsuleRect.height, closeTo(ringRect.height, 0.5));
      expect(ringRect.left - capsuleRect.right, closeTo(10, 0.5));
      expect(sendRect.left - ringRect.right, closeTo(10, 0.5));

      await tester.runAsync(() => db.db.close());
    });
  });
}
