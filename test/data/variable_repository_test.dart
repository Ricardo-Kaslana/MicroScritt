import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/data/variable_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/variable.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show createDatabaseFactoryFfi;
import '../support/test_database.dart';

void main() {
  test('upsert inserts then replaces by session+key', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final vars = VariableRepository(db);

    await vars.upsert(sessionId, 'hp', '10');
    await vars.upsert(sessionId, 'hp', '8');
    await vars.upsert(sessionId, 'location', 'cave');

    expect(await vars.bySession(sessionId), {'hp': '8', 'location': 'cave'});
  });

  test('delete removes one key and leaves the others', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final vars = VariableRepository(db);
    await vars.upsert(sessionId, 'hp', '8');
    await vars.upsert(sessionId, 'location', 'cave');

    await vars.delete(sessionId, 'hp');

    expect(await vars.bySession(sessionId), {'location': 'cave'});
  });

  test('clear empties only the target session', () async {
    final db = await openTestDb();
    final chars = CharacterRepository(db);
    final sessions = SessionRepository(db);
    final sessionA = await sessions.create(await chars.insert(const CharacterCard(name: 'A')), 'sa');
    final sessionB = await sessions.create(await chars.insert(const CharacterCard(name: 'B')), 'sb');
    final vars = VariableRepository(db);
    await vars.upsert(sessionA, 'hp', '8');
    await vars.upsert(sessionB, 'hp', '3');

    await vars.clear(sessionA);

    expect(await vars.bySession(sessionA), isEmpty);
    expect(await vars.bySession(sessionB), {'hp': '3'});
  });

  test('update renames the key without leaving the old row behind', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final vars = VariableRepository(db);
    await vars.upsert(sessionId, 'hp', '8');

    await vars.update(sessionId, oldKey: 'hp', newKey: 'health', value: '8/10');

    expect(await vars.bySession(sessionId), {'health': '8/10'});
    // 显式核对行数:改名必须"删旧 + 插新",不能两行并存。
    final rows = await db.db.query('variables', where: 'session_id = ?', whereArgs: [sessionId]);
    expect(rows.length, 1);
  });

  test('update with the same key behaves like upsert (single row)', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final vars = VariableRepository(db);
    await vars.upsert(sessionId, 'hp', '8');

    await vars.update(sessionId, oldKey: 'hp', newKey: 'hp', value: '5');

    expect(await vars.bySession(sessionId), {'hp': '5'});
    final rows = await db.db.query('variables', where: 'session_id = ?', whereArgs: [sessionId]);
    expect(rows.length, 1);
  });

  test('update onto an occupied key replaces that row instead of duplicating', () async {
    final db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
    final sessionId = await SessionRepository(db).create(charId, 's');
    final vars = VariableRepository(db);
    await vars.upsert(sessionId, 'a', '1');
    await vars.upsert(sessionId, 'b', '2');

    // 用户把 a 改名成已存在的 b:覆盖 b,而不是留下两行 a/b。
    await vars.update(sessionId, oldKey: 'a', newKey: 'b', value: '9');

    expect(await vars.bySession(sessionId), {'b': '9'});
    final rows = await db.db.query('variables', where: 'session_id = ?', whereArgs: [sessionId]);
    expect(rows.length, 1);
  });

  group('snapshot and compareAndApply', () {
    late AppDatabase db;
    late SessionRepository sessions;
    late VariableRepository vars;
    late VariableRepository other;
    late int charId;
    late int sessionId;

    setUp(() async {
      db = await openTestDb();
      addTearDown(db.db.close);
      sessions = SessionRepository(db);
      charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
      sessionId = await sessions.create(charId, 's');
      vars = VariableRepository(db);
      other = VariableRepository(AppDatabase(db.db));
    });

    test('snapshots are immutable and shared by underlying database identity', () async {
      final empty = await vars.snapshot(sessionId);
      expect(empty.values, isEmpty);
      expect(empty.revision, 0);
      expect(() => empty.values['hp'] = '9', throwsUnsupportedError);

      await other.upsert(sessionId, 'hp', '10');
      final before = await vars.snapshot(sessionId);
      final shared = await other.snapshot(sessionId);
      expect(shared.values, before.values);
      expect(shared.revision, before.revision);
      expect(before.revision, greaterThan(empty.revision));
      expect(() => before.values.clear(), throwsUnsupportedError);

      await other.upsert(sessionId, 'hp', '5');
      expect(empty.values, isEmpty);
      expect(before.values, {'hp': '10'});
      expect((await vars.snapshot(sessionId)).values, {'hp': '5'});
    });

    for (final change in <({
      String name,
      Future<void> Function(VariableRepository, int) apply,
      Map<String, String> values,
    })>[
      (
        name: 'manual upsert',
        apply: (repo, id) => repo.upsert(id, 'hp', '5'),
        values: {'hp': '5', 'location': 'cave'},
      ),
      (
        name: 'manual same-key update',
        apply: (repo, id) => repo.update(id, oldKey: 'hp', newKey: 'hp', value: '5'),
        values: {'hp': '5', 'location': 'cave'},
      ),
      (
        name: 'manual rename',
        apply: (repo, id) => repo.update(id, oldKey: 'hp', newKey: 'health', value: '5'),
        values: {'health': '5', 'location': 'cave'},
      ),
      (
        name: 'manual delete',
        apply: (repo, id) => repo.delete(id, 'hp'),
        values: {'location': 'cave'},
      ),
      (
        name: 'manual clear',
        apply: (repo, id) => repo.clear(id),
        values: {},
      ),
      (
        name: 'value ABA',
        apply: (repo, id) async {
          await repo.upsert(id, 'hp', '5');
          await repo.upsert(id, 'hp', '10');
        },
        values: {'hp': '10', 'location': 'cave'},
      ),
      (
        name: 'rename ABA',
        apply: (repo, id) async {
          await repo.update(id, oldKey: 'hp', newKey: 'health', value: '10');
          await repo.update(id, oldKey: 'health', newKey: 'hp', value: '10');
        },
        values: {'hp': '10', 'location': 'cave'},
      ),
      (
        name: 'same-value upsert',
        apply: (repo, id) => repo.upsert(id, 'hp', '10'),
        values: {'hp': '10', 'location': 'cave'},
      ),
    ]) {
      test('${change.name} invalidates another instance snapshot', () async {
        await vars.upsert(sessionId, 'hp', '10');
        await vars.upsert(sessionId, 'location', 'cave');
        final before = await vars.snapshot(sessionId);

        await change.apply(other, sessionId);

        final after = await vars.snapshot(sessionId);
        expect(after.revision, greaterThan(before.revision));
        expect(after.values, change.values);
        expect(
          (await vars.compareAndApply(
            sessionId,
            expectedRevision: before.revision,
            updates: {'hp': '8', 'mana': '3'},
          )).applied,
          isFalse,
        );
        expect(
          (await vars.compareAndApply(sessionId, expectedRevision: before.revision, updates: {})).applied,
          isFalse,
        );
        expect(await vars.bySession(sessionId), change.values);
      });
    }

    for (final operation in ['delete', 'clear']) {
      test('$operation with no matching rows still invalidates a snapshot', () async {
        final before = await vars.snapshot(sessionId);
        if (operation == 'delete') {
          await other.delete(sessionId, 'missing');
        } else {
          await other.clear(sessionId);
        }

        final after = await vars.snapshot(sessionId);
        expect(after.values, isEmpty);
        expect(after.revision, greaterThan(before.revision));
        expect(
          (await vars.compareAndApply(
            sessionId,
            expectedRevision: before.revision,
            updates: {'hp': '8'},
          )).applied,
          isFalse,
        );
        expect(
          (await vars.compareAndApply(sessionId, expectedRevision: before.revision, updates: {})).applied,
          isFalse,
        );
        expect(await vars.bySession(sessionId), isEmpty);
      });
    }

    test('a matching revision applies all updates and invalidates the old snapshot', () async {
      await vars.upsert(sessionId, 'hp', '10');
      await vars.upsert(sessionId, 'location', 'cave');
      final before = await vars.snapshot(sessionId);

      expect(
        (await other.compareAndApply(
          sessionId,
          expectedRevision: before.revision,
          updates: {'hp': '8', 'mana': '3'},
        )).applied,
        isTrue,
      );

      final after = await vars.snapshot(sessionId);
      expect(after.values, {'hp': '8', 'location': 'cave', 'mana': '3'});
      expect(after.revision, greaterThan(before.revision));
      expect(
        (await vars.compareAndApply(
          sessionId,
          expectedRevision: before.revision,
          updates: {'hp': '6'},
        )).applied,
        isFalse,
      );
      expect(await vars.bySession(sessionId), after.values);
    });

    test('matching empty updates confirm progress without changing revision', () async {
      await vars.upsert(sessionId, 'hp', '10');
      final before = await vars.snapshot(sessionId);

      expect(
        (await other.compareAndApply(sessionId, expectedRevision: before.revision, updates: {})).applied,
        isTrue,
      );

      final after = await vars.snapshot(sessionId);
      expect(after.revision, before.revision);
      expect(after.values, before.values);
      expect(
        (await vars.compareAndApply(
          sessionId,
          expectedRevision: before.revision,
          updates: {'hp': '8'},
        )).applied,
        isTrue,
      );
    });

    test('revisions are isolated between sessions', () async {
      final sessionB = await sessions.create(charId, 'b');
      await vars.upsert(sessionId, 'hp', '10');
      await vars.upsert(sessionB, 'hp', '3');
      final beforeA = await vars.snapshot(sessionId);
      final beforeB = await vars.snapshot(sessionB);

      await other.clear(sessionId);

      expect((await vars.snapshot(sessionB)).revision, beforeB.revision);
      expect(
        (await other.compareAndApply(sessionB, expectedRevision: beforeB.revision, updates: {'hp': '2'})).applied,
        isTrue,
      );
      expect(
        (await vars.compareAndApply(sessionId, expectedRevision: beforeA.revision, updates: {'hp': '8'})).applied,
        isFalse,
      );
      expect(await vars.bySession(sessionId), isEmpty);
      expect(await vars.bySession(sessionB), {'hp': '2'});
    });

    test('different database objects do not share session revisions', () async {
      final separateDb = await AppDatabase.open(
        factory: createDatabaseFactoryFfi(noIsolate: true),
        path: inMemoryDatabasePath,
      );
      addTearDown(separateDb.db.close);
      final separateCharId = await CharacterRepository(separateDb).insert(const CharacterCard(name: 'B'));
      final separateSessionId = await SessionRepository(separateDb).create(separateCharId, 'b');
      final separateVars = VariableRepository(separateDb);
      expect(identical(db.db, separateDb.db), isFalse);
      expect(separateSessionId, sessionId);
      final before = await separateVars.snapshot(separateSessionId);

      await vars.upsert(sessionId, 'hp', '10');

      expect((await separateVars.snapshot(separateSessionId)).revision, before.revision);
      expect(
        (await separateVars.compareAndApply(
          separateSessionId,
          expectedRevision: before.revision,
          updates: {'hp': '3'},
        )).applied,
        isTrue,
      );
      expect(await vars.bySession(sessionId), {'hp': '10'});
      expect(await separateVars.bySession(separateSessionId), {'hp': '3'});
    });

    test('deleted sessions reject both writes and empty progress confirmations', () async {
      await vars.upsert(sessionId, 'hp', '10');
      final before = await vars.snapshot(sessionId);
      await sessions.deleteWithCascade(sessionId);

      for (final updates in <Map<String, String>>[{'hp': '8'}, {}]) {
        expect(
          (await vars.compareAndApply(sessionId, expectedRevision: before.revision, updates: updates)).applied,
          isFalse,
        );
      }
      expect(await vars.bySession(sessionId), isEmpty);
    });

    test('nonexistent sessions reject writes and empty updates at revision zero', () async {
      final before = await vars.snapshot(-1);
      expect(before.values, isEmpty);
      expect(before.revision, 0);

      for (final updates in <Map<String, String>>[{'hp': '8'}, {}]) {
        expect(
          (await vars.compareAndApply(-1, expectedRevision: before.revision, updates: updates)).applied,
          isFalse,
        );
      }
      expect(await vars.bySession(-1), isEmpty);
    });

    test('queued snapshot reads values and revision after the preceding write', () async {
      await vars.upsert(sessionId, 'hp', '10');
      final before = await vars.snapshot(sessionId);
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = db.db.transaction((txn) async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      final write = other.upsert(sessionId, 'hp', '5');
      final pendingSnapshot = vars.snapshot(sessionId);
      release.complete();
      await blocker;
      await write;
      final after = await pendingSnapshot;

      expect(after.values, {'hp': '5'});
      expect(after.revision, greaterThan(before.revision));
      expect(after.revision, (await other.snapshot(sessionId)).revision);
    });

    test('concurrent applications of one snapshot allow only one writer', () async {
      await vars.upsert(sessionId, 'hp', '10');
      final before = await vars.snapshot(sessionId);

      final results = await Future.wait([
        vars.compareAndApply(sessionId, expectedRevision: before.revision, updates: {'hp': '8'}),
        other.compareAndApply(sessionId, expectedRevision: before.revision, updates: {'hp': '6'}),
      ]);

      expect(results.where((result) => result.applied), hasLength(1));
      expect(await vars.bySession(sessionId), {'hp': results.first.applied ? '8' : '6'});
      expect((await vars.snapshot(sessionId)).revision, greaterThan(before.revision));
    });

    for (final updates in <Map<String, String>>[{}, {'hp': '8', 'mana': '3'}]) {
      test('cancellation before applying ${updates.length} updates changes nothing', () async {
        await vars.upsert(sessionId, 'hp', '10');
        final before = await vars.snapshot(sessionId);

        expect(
          (await vars.compareAndApply(
            sessionId,
            expectedRevision: before.revision,
            updates: updates,
            shouldCancel: () => true,
          )).applied,
          isFalse,
        );
        expect(await vars.bySession(sessionId), before.values);
      });
    }

    test('cancellation while waiting for a transaction is checked after acquiring it', () async {
      await vars.upsert(sessionId, 'hp', '10');
      final before = await vars.snapshot(sessionId);
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = db.db.transaction((txn) async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      var cancelled = false;
      final pending = vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {'hp': '8', 'mana': '3'},
        shouldCancel: () => cancelled,
      );
      cancelled = true;
      release.complete();
      await blocker;

      expect((await pending).applied, isFalse);
      expect(await vars.bySession(sessionId), before.values);
    });

    for (final updates in <Map<String, String>>[{'hp': '8'}, {'hp': '8', 'mana': '3'}]) {
      test('cancellation during an awaited write rolls back ${updates.length} updates', () async {
        await vars.upsert(sessionId, 'hp', '10');
        final before = await vars.snapshot(sessionId);
        await db.db.execute('''
          CREATE TEMP TRIGGER reject_write_after_cancellation
          BEFORE INSERT ON variables
          WHEN NEW.key = 'mana'
          BEGIN
            SELECT RAISE(ABORT, 'cancelled batch reached second write');
          END
        ''');
        var scheduled = false;
        var cancelled = false;

        expect(
          (await vars.compareAndApply(
            sessionId,
            expectedRevision: before.revision,
            updates: updates,
            shouldCancel: () {
              if (!scheduled) {
                scheduled = true;
                scheduleMicrotask(() => cancelled = true);
              }
              return cancelled;
            },
          )).applied,
          isFalse,
        );
        expect(cancelled, isTrue);
        expect(await vars.bySession(sessionId), before.values);
      });
    }

    test('a real second-write database error rolls back and propagates', () async {
      await vars.upsert(sessionId, 'hp', '10');
      await vars.upsert(sessionId, 'location', 'cave');
      final before = await vars.snapshot(sessionId);
      await db.db.execute('''
        CREATE TEMP TRIGGER fail_second_variable_write
        BEFORE INSERT ON variables
        WHEN NEW.key = 'mana'
        BEGIN
          SELECT CASE WHEN (
            SELECT value FROM variables
            WHERE session_id = NEW.session_id AND key = 'hp'
          ) = '8' THEN RAISE(ABORT, 'second variable write failed') END;
        END
      ''');

      await expectLater(
        vars.compareAndApply(
          sessionId,
          expectedRevision: before.revision,
          updates: {'hp': '8', 'mana': '3'},
        ),
        throwsA(isA<DatabaseException>().having(
          (error) => error.toString(),
          'message',
          contains('second variable write failed'),
        )),
      );
      expect(await vars.bySession(sessionId), before.values);
      expect((await vars.snapshot(sessionId)).revision, greaterThanOrEqualTo(before.revision));

      await db.db.execute('DROP TRIGGER fail_second_variable_write');
      expect(
        (await other.compareAndApply(
          sessionId,
          expectedRevision: (await vars.snapshot(sessionId)).revision,
          updates: {'hp': '8', 'mana': '3'},
        )).applied,
        isTrue,
      );
      expect(await vars.bySession(sessionId), {'hp': '8', 'location': 'cave', 'mana': '3'});
    });
  });

  group('variable access, removal and recovery', () {
    late AppDatabase db;
    late VariableRepository vars;
    late int sessionId;

    setUp(() async {
      db = await openTestDb();
      addTearDown(db.db.close);
      final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'A'));
      sessionId = await SessionRepository(db).create(charId, 's');
      vars = VariableRepository(db);
    });

    test('manual variables default to protected; agent-created variables are full', () async {
      await vars.upsert(sessionId, 'manual', '1');
      final before = await vars.snapshot(sessionId);
      expect(before.access['manual'], VariableAccess.protected);

      final result = await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {'auto': '2'},
      );
      expect(result.applied, isTrue);
      final after = await vars.snapshot(sessionId);
      expect(after.access['auto'], VariableAccess.full);
      expect(after.access['manual'], VariableAccess.protected);
    });

    test('readonly updates are ignored and non-full removals are refused', () async {
      await vars.upsert(sessionId, 'constant', 'gold', access: VariableAccess.readonly);
      await vars.upsert(sessionId, 'keep', 'x', access: VariableAccess.protected);
      final before = await vars.snapshot(sessionId);

      final result = await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {'constant': 'silver', 'keep': 'y'},
        removals: ['constant', 'keep'],
      );

      expect(result.updates, {'keep': 'y'});
      expect(result.removals, isEmpty);
      // keep 同时出现在 updates 与 removals:更新优先,不计入"被权限拒绝"。
      expect(result.ignoredRemovals, 1);
      expect(await vars.bySession(sessionId), {'constant': 'gold', 'keep': 'y'});
    });

    test('explicit removals move full variables to trash; updates win over removals', () async {
      await vars.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      await vars.upsert(sessionId, 'b', '2', access: VariableAccess.full);
      final before = await vars.snapshot(sessionId);

      final result = await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {'a': '3'},
        removals: ['a', 'b', 'missing'],
      );

      expect(result.updates, {'a': '3'});
      expect(result.removals, ['b']);
      expect(await vars.bySession(sessionId), {'a': '3'});
      final trash = await vars.trash(sessionId);
      expect(trash.single.key, 'b');
      expect(trash.single.value, '2');
      expect(trash.single.agentAccess, VariableAccess.full);
      expect(trash.single.byAgent, isTrue);
    });

    test('a single round removes at most five variables', () async {
      for (var i = 0; i < 7; i++) {
        await vars.upsert(sessionId, 'v$i', '$i', access: VariableAccess.full);
      }
      final before = await vars.snapshot(sessionId);
      final result = await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {},
        removals: [for (var i = 0; i < 7; i++) 'v$i'],
      );

      expect(result.removals, ['v0', 'v1', 'v2', 'v3', 'v4']);
      expect(result.ignoredRemovals, 2);
      expect(await vars.bySession(sessionId), {'v5': '5', 'v6': '6'});
    });

    test('confirm mode stages proposals without changing active variables', () async {
      await vars.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      final before = await vars.snapshot(sessionId);

      final result = await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {},
        removals: ['a'],
        confirmRemovals: true,
      );

      expect(result.removals, isEmpty);
      expect(result.proposedRemovals, ['a']);
      expect((await vars.snapshot(sessionId)).revision, before.revision);
      expect(await vars.bySession(sessionId), {'a': '1'});
      final pending = await vars.pendingDeletions(sessionId);
      expect(pending.single.key, 'a');
      expect(pending.single.value, '1');

      final approved = await vars.approveDeletion(sessionId, pending.single.id!);
      expect(approved.removed, 1);
      expect(approved.stale, 0);
      expect(await vars.bySession(sessionId), isEmpty);
      expect(await vars.pendingDeletions(sessionId), isEmpty);
      expect((await vars.trash(sessionId)).single.key, 'a');
      expect((await vars.snapshot(sessionId)).revision, greaterThan(before.revision));
    });

    test('a proposal whose value changed is stale and is discarded on approval', () async {
      await vars.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      final before = await vars.snapshot(sessionId);
      await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {},
        removals: ['a'],
        confirmRemovals: true,
      );
      // 绕过仓库直接改值,模拟未经过清理路径的外部写入。
      await db.db.update('variables', {'value': '2'}, where: 'session_id = ? AND key = ?', whereArgs: [sessionId, 'a']);

      final pending = await vars.pendingDeletions(sessionId);
      final approved = await vars.approveDeletion(sessionId, pending.single.id!);
      expect(approved.removed, 0);
      expect(approved.stale, 1);
      expect(await vars.bySession(sessionId), {'a': '2'});
      expect(await vars.pendingDeletions(sessionId), isEmpty);
    });

    test('dismissing and manual edits clear pending proposals', () async {
      await vars.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      var before = await vars.snapshot(sessionId);
      await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {},
        removals: ['a'],
        confirmRemovals: true,
      );
      await vars.dismissAllDeletions(sessionId);
      expect(await vars.pendingDeletions(sessionId), isEmpty);

      before = await vars.snapshot(sessionId);
      await vars.compareAndApply(
        sessionId,
        expectedRevision: before.revision,
        updates: {},
        removals: ['a'],
        confirmRemovals: true,
      );
      await vars.update(sessionId, oldKey: 'a', newKey: 'a', value: '9');
      expect(await vars.pendingDeletions(sessionId), isEmpty);
      expect(await vars.bySession(sessionId), {'a': '9'});
    });

    test('manual delete and clear move entries to trash', () async {
      await vars.upsert(sessionId, 'a', '1');
      await vars.upsert(sessionId, 'b', '2');
      await vars.delete(sessionId, 'a');
      expect((await vars.trash(sessionId)).single.key, 'a');
      expect((await vars.trash(sessionId)).single.byAgent, isFalse);

      await vars.clear(sessionId);
      expect(await vars.bySession(sessionId), isEmpty);
      expect((await vars.trash(sessionId)).map((e) => e.key).toSet(), {'a', 'b'});
    });

    test('restore brings a row back as protected and rejects an occupied key', () async {
      await vars.upsert(sessionId, 'a', '1', access: VariableAccess.full);
      await vars.delete(sessionId, 'a');
      final trash = (await vars.trash(sessionId)).single;

      expect(await vars.restore(sessionId, trash.id!), isTrue);
      expect(await vars.bySession(sessionId), {'a': '1'});
      expect((await vars.snapshot(sessionId)).access['a'], VariableAccess.protected);
      expect(await vars.trash(sessionId), isEmpty);

      // 再删一条,先占用同名 active 键 → 恢复被拒绝,回收站条目保留。
      await vars.delete(sessionId, 'a');
      final second = (await vars.trash(sessionId)).single;
      await vars.upsert(sessionId, 'a', '9', access: VariableAccess.full);
      expect(await vars.restore(sessionId, second.id!), isFalse);
      expect(await vars.bySession(sessionId), {'a': '9'});
      expect((await vars.trash(sessionId)).single.key, 'a');
    });

    test('purgeTrashEntry permanently removes one entry scoped to its session', () async {
      final otherChar = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'B'));
      final otherSession = await SessionRepository(db).create(
        otherChar,
        'other',
      );
      await vars.upsert(sessionId, 'a', '1');
      await vars.upsert(sessionId, 'b', '2');
      await vars.delete(sessionId, 'a');
      await vars.delete(sessionId, 'b');
      await vars.upsert(otherSession, 'a', '9');
      await vars.delete(otherSession, 'a');

      final target = (await vars.trash(sessionId)).first;
      expect(target.key, 'b');
      // 其它会话持有同一 trash id 也不能删掉本会话的条目。
      expect(await vars.purgeTrashEntry(otherSession, target.id!), isFalse);
      expect((await vars.trash(sessionId)).length, 2);

      expect(await vars.purgeTrashEntry(sessionId, target.id!), isTrue);
      final left = await vars.trash(sessionId);
      expect(left.single.key, 'a');
      expect((await vars.trash(otherSession)).single.key, 'a');
      // 已删除的 id 再删返回 false。
      expect(await vars.purgeTrashEntry(sessionId, target.id!), isFalse);
    });

    test('clearTrash empties only the target session and returns the count', () async {
      final otherChar = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'B'));
      final otherSession = await SessionRepository(db).create(
        otherChar,
        'other',
      );
      await vars.upsert(sessionId, 'a', '1');
      await vars.upsert(sessionId, 'b', '2');
      await vars.clear(sessionId);
      await vars.upsert(otherSession, 'a', '9');
      await vars.delete(otherSession, 'a');

      expect(await vars.clearTrash(sessionId), 2);
      expect(await vars.trash(sessionId), isEmpty);
      expect((await vars.trash(otherSession)).single.key, 'a');
      expect(await vars.clearTrash(sessionId), 0);
    });
  });
}
