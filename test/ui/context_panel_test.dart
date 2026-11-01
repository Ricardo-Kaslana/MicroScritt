import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/prompt_item_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/prompt_item.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import 'package:microscritt/ui/context_panel.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  testWidgets('context panel shows baseline segments and token card', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice', description: 'a brave knight'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await PromptItemRepository(db).insert(const PromptItem(kind: PromptItemKind.preset, text: '永远风趣'));
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: const CharacterCard(name: 'Alice', description: 'a brave knight'),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();

    // 打开上下文面板
    await tester.tap(find.byTooltip('上下文'));
    await tester.pumpAndSettle();
    // 面板的分段与用量来自组装快照(异步链路),而 pumpAndSettle 只推进假时钟、
    // 不等真实 I/O —— 本测试此前只靠上面那段固定延时兜底,而 150ms 在全量套件
    // 并发跑时并不够(同文件另四个测试早已放宽到 400ms,这一处漏改)。2026-09-28
    // 实测约 1/4 概率在此处扑空,改为按条件等待。
    await waitUntil(tester, () => find.text('历史消息').evaluate().isNotEmpty);

    expect(find.text('会话上下文'), findsOneWidget);
    expect(find.text('Token 用量'), findsOneWidget);
    expect(find.text('历史消息'), findsOneWidget);
    expect(find.text('0 条'), findsOneWidget); // 尚无消息
    // 分段标签:角色卡(描述非空)与预设提示词
    expect(find.text('角色卡'), findsOneWidget);
    expect(find.text('预设提示词'), findsOneWidget);

    // 分段顺序按实际组装顺序:预设提示词在角色卡上方。
    final presetY = tester.getTopLeft(find.text('预设提示词')).dy;
    final charY = tester.getTopLeft(find.text('角色卡')).dy;
    expect(presetY, lessThan(charY));

    // 默认折叠:展开前看不到角色卡内容,展开后才能查看。
    expect(find.textContaining('brave knight'), findsNothing);
    await tester.tap(find.text('角色卡'));
    await tester.pumpAndSettle();
    expect(find.textContaining('brave knight'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('worldbook and history segments subdivide into entries on expand', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Alice', description: 'a brave knight'));
      sessionId = await SessionRepository(db).create(charId, 's');
      // 一条会命中的世界书条目 + 一条用作历史的消息 + 一条附件行
      // (CW 批起触发条目由发送管线命中后落库为附件行,面板按行展示)。
      db.db.execute('''
        INSERT INTO worldbook_entries(character_id, kind, "key", use_regex, constant, content, position, enabled)
        VALUES($charId, 'rule', '["sword"]', 0, 0, 'The sword is cursed', 0, 1)
      ''');
      db.db.execute('''
        INSERT INTO messages(session_id, role, content, seq, is_compacted)
        VALUES($sessionId, 'user', 'I draw my sword', 0, 0)
      ''');
      db.db.execute('''
        INSERT INTO messages(session_id, role, content, seq, is_compacted, kind, ref_id)
        VALUES($sessionId, 'user', '<system-reminder>以下是世界书条目「剑之诅咒」,因最近对话命中其关键词而注入。非对话内容,仅供设定参考。
The sword is cursed</system-reminder>', 1, 0, 'attachment', 'wb:1')
      ''');
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: const CharacterCard(name: 'Alice', description: 'a brave knight'),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      // 全量套件并发跑时 150ms 曾不够(DB 读取未收敛,截断标注缺席的偶发
      // 失败),放宽到 400ms。
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();

    await tester.tap(find.byTooltip('上下文'));
    await tester.pumpAndSettle();

    // 世界书与会话历史分段默认折叠:展开前看不到逐条划分的标签/内容。
    expect(find.textContaining('The sword is cursed'), findsNothing);
    expect(find.textContaining('触发: sword'), findsNothing);
    expect(find.text('用户'), findsNothing);

    // 展开会话历史:按消息逐条划分(语义顺序:system 稳定段 → 历史 → 状态旁路;
    // 列表惰性构建,先滚动到该分段;ensureVisible 防目标停在视口外缓存区)。
    final panel = find.byType(ContextPanel);
    await tester.scrollUntilVisible(find.text('会话历史'), 200, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('会话历史'));
    await tester.pump();
    await tester.tap(find.text('会话历史'));
    await tester.pumpAndSettle();
    expect(find.text('用户'), findsWidgets);
    // 条目默认折叠:面板内不显式展示消息内容(聊天列表在面板后仍渲染同一条
    // 消息,必须限定在面板子树里断言内容不可见)。
    expect(find.descendant(of: panel, matching: find.textContaining('I draw my sword')), findsNothing);

    // 展开世界书(触发):按条命中展示(历史之后的状态旁路段,继续向下滚动)。
    await tester.scrollUntilVisible(find.textContaining('附件'), 200, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.textContaining('附件'));
    await tester.pump();
    await tester.tap(find.textContaining('附件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('世界书'), findsWidgets);
    // 附件行同样默认折叠,内容不可见。
    expect(find.descendant(of: panel, matching: find.textContaining('The sword is cursed')), findsNothing);
    // 点击该条二级展开,内容才出现。
    await tester.ensureVisible(find.textContaining('世界书 ·'));
    await tester.pump();
    await tester.tap(find.textContaining('世界书 ·'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: panel, matching: find.textContaining('The sword is cursed')), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('every history message renders its role label on expand', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      // 8 条交替 user/assistant 消息;最后一条 assistant 内容带换行的长文本。
      db.db.execute('''
        INSERT INTO messages(session_id, role, content, seq, is_compacted)
        VALUES($sessionId, 'user', 'msg-u0', 0, 0)
      ''');
      for (var i = 1; i < 8; i++) {
        final role = i.isOdd ? 'assistant' : 'user';
        final content = i == 7 ? '长回复\n第二行\n第三行' : 'msg-$role$i';
        db.db.execute('''
          INSERT INTO messages(session_id, role, content, seq, is_compacted)
          VALUES($sessionId, '$role', '$content', $i, 0)
        ''');
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      // 全量套件并发跑时 150ms 曾不够(DB 读取未收敛,截断标注缺席的偶发
      // 失败),放宽到 400ms。
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();

    await tester.tap(find.byTooltip('上下文'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('会话历史'), 200, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('会话历史'));
    await tester.pump();
    await tester.tap(find.text('会话历史'));
    await tester.pumpAndSettle();

    // 展开后每条历史都必须渲染角色标签:用户/助手 各 4 条(条目默认折叠)。
    expect(find.text('用户'), findsNWidgets(4));
    expect(find.text('助手'), findsNWidgets(4));
    // 条目默认折叠:面板内不显示任何消息内容,也没有可选中块。注意聊天列表在
    // 面板后面仍渲染着同一条消息,所以必须限定在面板子树里断言。
    final panel = find.byType(ContextPanel);
    expect(find.descendant(of: panel, matching: find.byType(SelectionArea)), findsNothing);
    expect(find.descendant(of: panel, matching: find.textContaining('长回复')), findsNothing);
    // 最后一条(seq 7,长内容)是时间序里最后一个"助手"条目:点击其胶囊二级展开。
    final lastEntry = find.descendant(of: panel, matching: find.text('助手')).last;
    await tester.ensureVisible(lastEntry);
    await tester.pumpAndSettle();
    await tester.tap(lastEntry);
    await tester.pumpAndSettle();
    expect(find.descendant(of: panel, matching: find.byType(SelectionArea)), findsOneWidget);
    expect(find.descendant(of: panel, matching: find.textContaining('第三行')), findsWidgets);
    // 点击可选择全文也会收起该条(原始指针监听绕过 SelectionArea 对手势的占据),
    // 内容再次隐藏、面板内 SelectionArea 完全消失。
    await tester.tap(find.descendant(of: panel, matching: find.byType(SelectionArea)));
    await tester.pumpAndSettle();
    expect(find.descendant(of: panel, matching: find.byType(SelectionArea)), findsNothing);
    expect(find.descendant(of: panel, matching: find.textContaining('长回复')), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('every history entry keeps its highlight pill, including at the bottom', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 每条消息的标签"胶囊"类:由带 BoxDecoration 的 Container 承载。
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      for (var i = 0; i < 16; i++) {
        final role = i.isEven ? 'user' : 'assistant';
        db.db.execute('''
          INSERT INTO messages(session_id, role, content, seq, is_compacted)
          VALUES($sessionId, '$role', 'msg $i', $i, 0)
        ''');
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      // 全量套件并发跑时 150ms 曾不够(DB 读取未收敛,截断标注缺席的偶发
      // 失败),放宽到 400ms。
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();

    await tester.tap(find.byTooltip('上下文'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('会话历史'), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('会话历史'));
    await tester.pumpAndSettle();

    // 评分:每个"用户/助手"标签都被包在一个带背景装饰的胶囊 Container 里。
    int pillContainers(String role) {
      final pillFinder = find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration);
      var n = 0;
      for (var i = 0; i < find.text(role).evaluate().length; i++) {
        final ancestorPills = find.ancestor(of: find.text(role).at(i), matching: pillFinder).evaluate();
        if (ancestorPills.isNotEmpty) n++;
      }
      return n;
    }

    // 16 条全部应带胶囊(用户 8 + 助手 8),不得因位于列表底部而丢失背景。
    expect(pillContainers('用户'), 8);
    expect(pillContainers('助手'), 8);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('history beyond the display window is labelled as omitted, not lost', (tester) async {
    // 回归:加载窗口下界之外还有更早历史时,面板只显示已加载的部分 —— 不加
    // 说明会被误读成"旧消息被丢弃"。组装自 2026-09-28 批起不再按条数裁剪,
    // 「窗口之外」与「未进上下文」已是同一件事,判据收敛到 canLoadOlder。
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      // 350 条 > 300 条显示窗口 → 窗口下界之外仍有更早历史(canLoadOlder=true)。
      for (var i = 0; i < 350; i++) {
        final role = i.isEven ? 'user' : 'assistant';
        db.db.execute('''
          INSERT INTO messages(session_id, role, content, seq, is_compacted)
          VALUES($sessionId, '$role', 'msg $i', $i, 0)
        ''');
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatScreen(
            sessionId: sessionId,
            characterId: charId,
            character: const CharacterCard(name: 'Alice'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('上下文'));
    await tester.pumpAndSettle();

    // 350 条历史超出 300 条显示窗口:更早的行在窗口下界之外(canLoadOlder=true)。
    // 标注沿用面板既有折叠语言:收起态只有一行短提示,点击才展开完整说明。
    // 按条件等待,而不是靠固定延时 —— 350 条真实 DB 读取在全量并发下会超过
    // 任何猜出来的时长(2026-09-28 实测:沿用 120 条时代的 400ms 会扑空)。
    await waitUntilOrFail(
      tester,
      () => find.text('更早的历史未进入上下文(并未丢失)').evaluate().isNotEmpty,
      reason: '面板未渲染出历史截断标注(加载窗口/组装快照未收敛)',
    );
    expect(find.text('更早的历史未进入上下文(并未丢失)'), findsOneWidget);
    expect(find.textContaining('完整记录可在聊天区上滑加载查看'), findsNothing,
        reason: '收起态不应渲染完整说明');
    await tester.tap(find.text('更早的历史未进入上下文(并未丢失)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅展示实际发给模型的最近历史'), findsOneWidget);
    expect(find.textContaining('完整记录可在聊天区上滑加载查看'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });
}
