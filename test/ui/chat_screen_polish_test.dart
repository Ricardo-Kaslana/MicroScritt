import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/skill_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/skill.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/chat_screen.dart';
import '../support/test_database.dart';

/// 只发错误事件的后端,用来驱动错误横幅。
class _ErrorBackend implements LlmBackend {
  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) => Stream.fromIterable(const [ErrorEvent('boom'), DoneEvent()]);
}

void main() {
  testWidgets('renders rounded input bar with hint and send button', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
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
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.text('输入消息…(/ 命令 · @ 技能)'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(find.byTooltip('会话操作'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('long-press on a message opens the copy/delete sheet', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(db).append(sessionId: sessionId, role: 'user', content: '可以长按我');
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
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    await tester.longPress(find.text('可以长按我'));
    await tester.pumpAndSettle();

    expect(find.text('复制内容'), findsOneWidget);
    expect(find.text('删除消息'), findsOneWidget);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('delete sheet action removes the message row', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await MessageRepository(db).append(sessionId: sessionId, role: 'user', content: '待删除消息');
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
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    await tester.longPress(find.text('待删除消息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除消息'));
    // deleteMessage 是真 I/O:轮询到消息落库消失再抽帧渲染
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final msgs = await MessageRepository(db).bySession(sessionId);
        if (msgs.isEmpty) break;
      }
      await tester.pumpAndSettle();
    });

    expect(find.text('待删除消息'), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('backend error shows a dismissible banner', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendConfigProvider.overrideWith(
            (ref) => const BackendConfig(
              provider: BackendProvider.openai,
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'sk-test',
              model: 'gpt-4o',
            ),
          ),
          backendProvider.overrideWith((ref) => _ErrorBackend()),
        ],
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
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('发送'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });

    // 错误以灵岛警报粒呈现(取代旧 MaterialBanner):主文本是富文本 span。
    expect(find.textContaining('boom', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    // 压过警报粒的退场动画(淡出期内旧胶囊仍挂在树上)。
    await tester.pumpAndSettle();
    expect(find.textContaining('boom', findRichText: true), findsNothing);
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('@ button opens skill sheet and inserts token at cursor', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      final repo = SkillRepository(db);
      await repo.insert(const Skill(name: '剑术', description: '挥剑的姿势', content: '# 剑术'));
      await repo.insert(const Skill(name: '禁用技能', enabled: false, content: 'x'));
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
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    await tester.tap(find.byTooltip('插入技能(@)'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pumpAndSettle();
    });

    // 只列启用中的技能;禁用的不出现。
    expect(find.text('调用技能'), findsOneWidget);
    expect(find.text('@剑术'), findsOneWidget);
    expect(find.text('挥剑的姿势'), findsOneWidget);
    expect(find.text('@禁用技能'), findsNothing);

    // 点选后 @token 插入输入框,弹层关闭。
    await tester.tap(find.text('@剑术'));
    await tester.pumpAndSettle();
    expect(find.text('调用技能'), findsNothing);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '@剑术 ');
    expect(
      field.controller!.selection,
      const TextSelection.collapsed(offset: '@剑术 '.length),
    );
    await tester.runAsync(() => db.db.close());
  });

  testWidgets('@skill token renders in the primary color inside the input', (tester) async {
    late final AppDatabase db;
    late final int sessionId;
    late final int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
      sessionId = await SessionRepository(db).create(charId, 's');
      await SkillRepository(db).insert(const Skill(name: '剑术', description: '', content: '# 剑术'));
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
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    // 输入含 @记号的文本;控制器在 build 时拿到已启用技能名集合。
    await tester.enterText(find.byType(TextField), '试试@剑术看看');
    await tester.pump();

    final element = tester.element(find.byType(TextField));
    final primary = Theme.of(element).colorScheme.primary;
    final span = tester.widget<TextField>(find.byType(TextField)).controller!
        .buildTextSpan(context: element, style: null, withComposing: false);
    final children = span.children?.whereType<TextSpan>().toList() ?? const <TextSpan>[];
    final colored = children.where((s) => s.text == '@剑术').toList();
    expect(colored, hasLength(1));
    expect(colored.single.style?.color, primary);
    // 记号外的正文不带染色(样式为空)。
    expect(children.any((s) => s.text == '试试' && s.style == null), isTrue);
    expect(children.any((s) => s.text == '看看' && s.style == null), isTrue);

    // 未启用技能的普通 @ 词不染色。
    final plainSpan = tester.widget<TextField>(find.byType(TextField)).controller!
        .buildTextSpan(context: element, style: null, withComposing: false);
    expect(plainSpan.children!.whereType<TextSpan>().where((s) => s.text == '@别人'), isEmpty);
    await tester.runAsync(() => db.db.close());
  });
}
