// 回归:桌面侧栏分组不得依赖 `charactersProvider(.future)`。
// Riverpod 3.3.2 在 TickerMode 恢复被暂停的订阅时会 flush 依赖
// (riverpod#4805,3.4+ 才修且要求更高 Dart SDK):provider 之间的异步依赖
// 会在 widget build 期触发 scheduleRefresh → "setState() called during
// build"。这里直接守住设计不变量:刷新角色列表不得连带重查侧栏分组。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/providers.dart';
import '../support/test_database.dart';

class _CountingCharacters extends CharacterRepository {
  _CountingCharacters(super.db);
  int allCalls = 0;

  @override
  Future<List<CharacterRecord>> all({bool hydrateOversized = false}) {
    allCalls++;
    return super.all(hydrateOversized: hydrateOversized);
  }
}

class _CountingSessions extends SessionRepository {
  _CountingSessions(super.db);
  int infosAllCalls = 0;

  @override
  Future<List<SessionInfo>> infosAll() {
    infosAllCalls++;
    return super.infosAll();
  }
}

void main() {
  testWidgets('刷新角色列表不连带重查侧栏分组', (tester) async {
    late final AppDatabase db;
    late final _CountingCharacters characters;
    late final _CountingSessions sessions;
    await tester.runAsync(() async {
      db = await openTestDb();
      characters = _CountingCharacters(db);
      sessions = _CountingSessions(db);
      final charId = await characters.insert(const CharacterCard(name: 'Alice'));
      await sessions.create(charId, 's');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          characterRepositoryProvider.overrideWithValue(characters),
          sessionRepositoryProvider.overrideWithValue(sessions),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(charactersProvider);
              ref.watch(sessionGroupsProvider);
              return const Text('probe');
            },
          ),
        ),
      ),
    );

    // 等两份首查落定(交替真实异步与推帧;不要在 runAsync 里直接 await
    // provider.future —— 首次构建依赖假时钟调度,会死锁)。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Consumer)),
    );
    Future<void> settleUntil(bool Function() ready) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 8)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        if (ready()) return;
      }
      expect(ready(), isTrue, reason: '首查未完成');
    }

    await settleUntil(
      () =>
          container.read(charactersProvider).hasValue &&
          container.read(sessionGroupsProvider).hasValue,
    );

    // 失效角色列表:列表确实重查,但侧栏分组(直接读仓库、不 watch 列表)
    // 不应被连带重查。旧实现 watch charactersProvider.future,这里会多一次
    // infosAll —— 也正是上游 TickerMode resume 崩溃的依赖链。
    final characterCallsBefore = characters.allCalls;
    final sessionCallsBefore = sessions.infosAllCalls;
    container.invalidate(charactersProvider);
    await settleUntil(
      () =>
          characters.allCalls > characterCallsBefore &&
          container.read(charactersProvider).hasValue,
    );
    // 多推一段真实异步 + 帧:旧实现的连带失效由 Riverpod 调度器延后触发,
    // 要给足它"犯错"的窗口,断言才有一票否决权。
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(characters.allCalls, greaterThan(characterCallsBefore));
    expect(sessions.infosAllCalls, sessionCallsBefore);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.runAsync(() => db.db.close());
  });
}
