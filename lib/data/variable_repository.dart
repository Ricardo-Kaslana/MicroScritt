/// 会话级变量(`variables`)及其回收站/待确认删除的持久化。
///
/// 变量只进后台 agent 的上下文,不参与主写组装,故写入不触发 `refreshContext()`;
/// 自动写入走 revision CAS,删除在事务内按当前权限二次校验并先进回收站
/// (严格模式只落待确认提案)。
library;

import 'package:sqflite/sqflite.dart';
import '../models/variable.dart';
import 'database.dart';

/// 变量仓储:快照、revision CAS 写入与三档权限的删除防护。
///
/// 变更安全:
/// - 所有自动写入走 [compareAndApply] 的 revision CAS,人工改动会让在途旧结果
///   整体失效;
/// - 删除只在**事务内**按当前权限二次校验,提示词里的权限列表不是安全边界;
/// - 删除先进 [VariableTrashEntry] 回收站(软删除),可恢复;
/// - 严格模式(`confirmRemovals`)下只写 [VariableDeletionProposal],由用户
///   在状态面板确认后才移入回收站。
class VariableRepository {
  // revision 必须跨 repository 实例共享:同一进程里可能存在多个实例
  // (provider、临时构造、测试各开库),实例级计数会让另一实例的写入不可见,
  // 在途 CAS 会错误通过。按底层 Database 对象做 Expando 键,测试各开内存库时
  // 天然隔离;进程重启后在途结果已不存在,计数归零无害。
  static final _revisions = Expando<Map<int, int>>();

  /// 单轮后台删除的实际上限:限制一次误判/越权提议的爆炸半径。删除失败或
  /// 被截断到上限的键会在下一轮重新评估,不影响增量游标。
  static const int maxRemovalsPerRound = 5;

  final AppDatabase db;
  VariableRepository(this.db);

  Map<int, int> get _sessionRevisions => _revisions[db.db] ??= <int, int>{};

  int _revision(int sessionId) => _sessionRevisions[sessionId] ?? 0;

  void _advanceRevision(int sessionId) {
    _sessionRevisions[sessionId] = _revision(sessionId) + 1;
  }

  Future<Map<String, String>> bySession(int sessionId) async {
    final rows = await db.db.query(
      'variables',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  /// 状态面板用:带权限元数据的 active 变量行。
  Future<List<Variable>> rowsBySession(int sessionId) async {
    final rows = await db.db.query(
      'variables',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'id',
    );
    return [for (final row in rows) Variable.fromMap(row)];
  }

  /// 读一致性快照:值、权限与 revision 在同一读事务内取,作为后台轮次的
  /// CAS 基线(rev 之后若有人工写入,compareAndApply 会整体放弃)。
  Future<
    ({
      Map<String, String> values,
      Map<String, VariableAccess> access,
      int revision,
    })
  >
  snapshot(int sessionId) {
    return db.db.transaction((txn) async {
      final rows = await txn.query(
        'variables',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      return (
        values: Map<String, String>.unmodifiable({
          for (final row in rows) row['key'] as String: row['value'] as String,
        }),
        access: Map<String, VariableAccess>.unmodifiable({
          for (final row in rows)
            row['key'] as String: VariableAccess.fromStorage(
              row['agent_access'],
            ),
        }),
        revision: _revision(sessionId),
      );
    });
  }

  /// 后台一轮变量结果的原子落库。
  ///
  /// [updates] 为 LLM 给出的变化键;`readonly` 键在事务内被过滤。
  /// [removals] 为 LLM 显式给出的删除键;只允许删除当前存在且权限为
  /// [VariableAccess.full] 的键,且单轮至多 [maxRemovalsPerRound] 个。
  /// [confirmRemovals] 为 true 时**不删除**,只把可删键写入待确认提案。
  ///
  /// 返回实际应用的 updates/removals 与本次写入的提案;调用方据此展示真实
  /// 摘要(而不是模型提议了什么)。revision 不匹配、会话不存在或被取消时
  /// `applied == false`,不写任何数据。
  Future<VariableApplyResult> compareAndApply(
    int sessionId, {
    required int expectedRevision,
    required Map<String, String> updates,
    List<String> removals = const [],
    bool confirmRemovals = false,
    bool Function()? shouldCancel,
  }) async {
    void checkCancelled() {
      if (shouldCancel?.call() ?? false) throw const _VariableApplyCancelled();
    }

    try {
      return await db.db.transaction((txn) async {
        final sessions = await txn.query(
          'sessions',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [sessionId],
          limit: 1,
        );
        if (sessions.isEmpty || _revision(sessionId) != expectedRevision) {
          return const VariableApplyResult(applied: false);
        }
        checkCancelled();

        final rows = await txn.query(
          'variables',
          where: 'session_id = ?',
          whereArgs: [sessionId],
        );
        final accessByKey = <String, VariableAccess>{
          for (final row in rows)
            row['key'] as String: VariableAccess.fromStorage(
              row['agent_access'],
            ),
        };
        final valueByKey = <String, String>{
          for (final row in rows) row['key'] as String: row['value'] as String,
        };

        final appliedUpdates = <String, String>{};
        for (final entry in updates.entries) {
          if (entry.key.trim().isEmpty) continue;
          if (accessByKey[entry.key] == VariableAccess.readonly) continue;
          appliedUpdates[entry.key] = entry.value;
        }

        final removalCandidates = <String>[];
        final seen = <String>{};
        var ignoredRemovals = 0;
        for (final key in removals) {
          if (key.isEmpty || !seen.add(key)) continue;
          // 同一键既改又删:更新优先,删除忽略。
          if (appliedUpdates.containsKey(key)) continue;
          if (!valueByKey.containsKey(key)) continue;
          if (accessByKey[key] != VariableAccess.full) {
            ignoredRemovals++;
            continue;
          }
          if (removalCandidates.length >= maxRemovalsPerRound) {
            ignoredRemovals++;
            continue;
          }
          removalCandidates.add(key);
        }

        for (final entry in appliedUpdates.entries) {
          checkCancelled();
          if (accessByKey.containsKey(entry.key)) {
            await txn.update(
              'variables',
              {'value': entry.value},
              where: 'session_id = ? AND key = ?',
              whereArgs: [sessionId, entry.key],
            );
          } else {
            await txn.insert('variables', {
              'session_id': sessionId,
              'key': entry.key,
              'value': entry.value,
              // 后台新建的变量默认由后台托管:后续才能被清理。
              'agent_access': VariableAccess.full.name,
            });
          }
          // 值变了,旧的删除建议不再可信。
          await txn.delete(
            'variable_deletion_proposals',
            where: 'session_id = ? AND key = ?',
            whereArgs: [sessionId, entry.key],
          );
        }

        checkCancelled();
        final now = DateTime.now().millisecondsSinceEpoch;
        final proposed = <String>[];
        if (confirmRemovals) {
          for (final key in removalCandidates) {
            checkCancelled();
            await txn.insert(
              'variable_deletion_proposals',
              {
                'session_id': sessionId,
                'key': key,
                'value': valueByKey[key]!,
                'created_at': now,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            proposed.add(key);
          }
        } else {
          for (final key in removalCandidates) {
            checkCancelled();
            await _moveToTrash(
              txn,
              sessionId: sessionId,
              key: key,
              value: valueByKey[key]!,
              access: accessByKey[key]!,
              deletedBy: 'agent',
              deletedAt: now,
            );
            await txn.delete(
              'variables',
              where: 'session_id = ? AND key = ?',
              whereArgs: [sessionId, key],
            );
            await txn.delete(
              'variable_deletion_proposals',
              where: 'session_id = ? AND key = ?',
              whereArgs: [sessionId, key],
            );
          }
        }

        checkCancelled();
        if (appliedUpdates.isNotEmpty ||
            (!confirmRemovals && removalCandidates.isNotEmpty)) {
          _advanceRevision(sessionId);
        }
        return VariableApplyResult(
          applied: true,
          updates: Map.unmodifiable(appliedUpdates),
          removals: confirmRemovals
              ? const []
              : List.unmodifiable(removalCandidates),
          proposedRemovals: confirmRemovals
              ? List.unmodifiable(proposed)
              : const [],
          ignoredRemovals: ignoredRemovals,
        );
      });
    } on _VariableApplyCancelled {
      return const VariableApplyResult(applied: false);
    }
  }

  /// 人工新增/导入:默认 protected —— 后台可继续更新值,但不会删除。
  Future<void> upsert(
    int sessionId,
    String key,
    String value, {
    VariableAccess access = VariableAccess.protected,
  }) async {
    await db.db.transaction((txn) async {
      await txn.insert('variables', {
        'session_id': sessionId,
        'key': key,
        'value': value,
        'agent_access': access.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _clearProposal(txn, sessionId, key);
      _advanceRevision(sessionId);
    });
  }

  /// 删除单条变量(状态面板手工清理):移入回收站,可恢复。
  Future<void> delete(int sessionId, String key) async {
    await db.db.transaction((txn) async {
      final rows = await txn.query(
        'variables',
        where: 'session_id = ? AND key = ?',
        whereArgs: [sessionId, key],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        await _moveToTrash(
          txn,
          sessionId: sessionId,
          key: key,
          value: rows.first['value'] as String,
          access: VariableAccess.fromStorage(rows.first['agent_access']),
          deletedBy: 'user',
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await txn.delete(
          'variables',
          where: 'session_id = ? AND key = ?',
          whereArgs: [sessionId, key],
        );
      }
      await _clearProposal(txn, sessionId, key);
      // 维持既有语义:即使没有命中行,也作废在途旧快照。
      _advanceRevision(sessionId);
    });
  }

  /// 清空会话全部变量(状态面板手工清理):全部移入回收站。
  Future<void> clear(int sessionId) async {
    await db.db.transaction((txn) async {
      final rows = await txn.query(
        'variables',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in rows) {
        await _moveToTrash(
          txn,
          sessionId: sessionId,
          key: row['key'] as String,
          value: row['value'] as String,
          access: VariableAccess.fromStorage(row['agent_access']),
          deletedBy: 'user',
          deletedAt: now,
        );
      }
      await txn.delete(
        'variables',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      await txn.delete(
        'variable_deletion_proposals',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      _advanceRevision(sessionId);
    });
  }

  /// 编辑单条:键未变时等价于 [upsert];键变更时在同一事务里删旧键、插新键,
  /// 避免中途失败留下"新旧两行并存"的中间态。
  ///
  /// [newKey] 与另一条变量同名时按 [ConflictAlgorithm.replace] 覆盖那条 ——
  /// 覆盖与否由 UI 在保存前显式告知用户。[access] 为 null 时沿用旧键权限。
  Future<void> update(
    int sessionId, {
    required String oldKey,
    required String newKey,
    required String value,
    VariableAccess? access,
  }) async {
    await db.db.transaction((txn) async {
      final oldRows = await txn.query(
        'variables',
        where: 'session_id = ? AND key = ?',
        whereArgs: [sessionId, oldKey],
        limit: 1,
      );
      final effectiveAccess =
          access ??
          (oldRows.isEmpty
              ? VariableAccess.protected
              : VariableAccess.fromStorage(oldRows.first['agent_access']));
      if (oldKey != newKey) {
        await txn.delete(
          'variables',
          where: 'session_id = ? AND key = ?',
          whereArgs: [sessionId, oldKey],
        );
      }
      await txn.insert('variables', {
        'session_id': sessionId,
        'key': newKey,
        'value': value,
        'agent_access': effectiveAccess.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _clearProposal(txn, sessionId, oldKey);
      await _clearProposal(txn, sessionId, newKey);
      _advanceRevision(sessionId);
    });
  }

  Future<List<VariableTrashEntry>> trash(int sessionId) async {
    final rows = await db.db.query(
      'variable_trash',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'deleted_at DESC, id DESC',
    );
    return [for (final row in rows) VariableTrashEntry.fromMap(row)];
  }

  /// 从回收站恢复:同名 active 变量存在时拒绝(返回 false);恢复后自动
  /// 降为 protected,避免下一轮又被后台删掉。
  Future<bool> restore(int sessionId, int trashId) async {
    return db.db.transaction((txn) async {
      final rows = await txn.query(
        'variable_trash',
        where: 'session_id = ? AND id = ?',
        whereArgs: [sessionId, trashId],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final row = rows.first;
      final key = row['key'] as String;
      final active = await txn.query(
        'variables',
        columns: ['id'],
        where: 'session_id = ? AND key = ?',
        whereArgs: [sessionId, key],
        limit: 1,
      );
      if (active.isNotEmpty) return false;
      await txn.insert('variables', {
        'session_id': sessionId,
        'key': key,
        'value': row['value'] as String,
        'agent_access': VariableAccess.protected.name,
      });
      await txn.delete(
        'variable_trash',
        where: 'session_id = ? AND id = ?',
        whereArgs: [sessionId, trashId],
      );
      await _clearProposal(txn, sessionId, key);
      _advanceRevision(sessionId);
      return true;
    });
  }

  /// 从回收站彻底删除单条(不可恢复);按会话限定,避免跨会话误删。
  /// 回收站不参与后台快照,因此无需推进 revision。
  Future<bool> purgeTrashEntry(int sessionId, int trashId) async {
    final count = await db.db.delete(
      'variable_trash',
      where: 'session_id = ? AND id = ?',
      whereArgs: [sessionId, trashId],
    );
    return count > 0;
  }

  /// 清空本会话回收站(不可恢复),返回实际删除条数。
  Future<int> clearTrash(int sessionId) {
    return db.db.delete(
      'variable_trash',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<List<VariableDeletionProposal>> pendingDeletions(int sessionId) async {
    final rows = await db.db.query(
      'variable_deletion_proposals',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at DESC, id DESC',
    );
    return [for (final row in rows) VariableDeletionProposal.fromMap(row)];
  }

  /// 确认单条待删除建议:变量必须在、仍为 full、且值与提议时一致;
  /// 否则视为失效建议并清掉。
  Future<VariableApprovalResult> approveDeletion(
    int sessionId,
    int proposalId,
  ) => _approveDeletions(sessionId, proposalId: proposalId);

  /// 确认全部待删除建议(同一事务)。
  Future<VariableApprovalResult> approveAllDeletions(int sessionId) =>
      _approveDeletions(sessionId);

  // 批准前逐条复核:变量仍存在、仍为 full、值与提议时一致,否则按失效建议
  // 清掉;复核与移动在同一事务内,防止确认期间后台又改动变量。
  Future<VariableApprovalResult> _approveDeletions(
    int sessionId, {
    int? proposalId,
  }) async {
    return db.db.transaction((txn) async {
      final rows = await txn.query(
        'variable_deletion_proposals',
        where: proposalId == null
            ? 'session_id = ?'
            : 'session_id = ? AND id = ?',
        whereArgs: proposalId == null ? [sessionId] : [sessionId, proposalId],
        orderBy: 'id',
      );
      var removed = 0;
      var stale = 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final proposal in rows) {
        final key = proposal['key'] as String;
        final proposedValue = proposal['value'] as String;
        final active = await txn.query(
          'variables',
          where: 'session_id = ? AND key = ?',
          whereArgs: [sessionId, key],
          limit: 1,
        );
        final valid =
            active.isNotEmpty &&
            VariableAccess.fromStorage(active.first['agent_access']) ==
                VariableAccess.full &&
            active.first['value'] as String == proposedValue;
        if (!valid) {
          await txn.delete(
            'variable_deletion_proposals',
            where: 'id = ?',
            whereArgs: [proposal['id']],
          );
          stale++;
          continue;
        }
        await _moveToTrash(
          txn,
          sessionId: sessionId,
          key: key,
          value: proposedValue,
          access: VariableAccess.full,
          deletedBy: 'agent',
          deletedAt: now,
        );
        await txn.delete(
          'variables',
          where: 'session_id = ? AND key = ?',
          whereArgs: [sessionId, key],
        );
        await txn.delete(
          'variable_deletion_proposals',
          where: 'id = ?',
          whereArgs: [proposal['id']],
        );
        removed++;
      }
      if (removed > 0) _advanceRevision(sessionId);
      return VariableApprovalResult(removed: removed, stale: stale);
    });
  }

  /// 忽略单条待删除建议;返回是否命中。
  Future<bool> dismissDeletion(int sessionId, int proposalId) async {
    final count = await db.db.delete(
      'variable_deletion_proposals',
      where: 'session_id = ? AND id = ?',
      whereArgs: [sessionId, proposalId],
    );
    return count > 0;
  }

  /// 忽略全部待删除建议(严格模式关闭/用户批量清理时用)。
  Future<int> dismissAllDeletions(int sessionId) {
    return db.db.delete(
      'variable_deletion_proposals',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  // 同键重复删除会覆盖回收站旧行(UNIQUE(session_id, key)):回收站只保留
  // 该键最近一次删除的值,足够恢复一档。
  Future<void> _moveToTrash(
    Transaction txn, {
    required int sessionId,
    required String key,
    required String value,
    required VariableAccess access,
    required String deletedBy,
    required int deletedAt,
  }) {
    return txn.insert('variable_trash', {
      'session_id': sessionId,
      'key': key,
      'value': value,
      'agent_access': access.name,
      'deleted_at': deletedAt,
      'deleted_by': deletedBy,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _clearProposal(Transaction txn, int sessionId, String key) {
    return txn.delete(
      'variable_deletion_proposals',
      where: 'session_id = ? AND key = ?',
      whereArgs: [sessionId, key],
    );
  }
}

/// 一次后台变量落库的实际结果。[applied] 为 false 表示 revision 冲突/取消,
/// 未写任何数据。
class VariableApplyResult {
  final bool applied;
  final Map<String, String> updates;
  final List<String> removals;
  final List<String> proposedRemovals;
  final int ignoredRemovals;

  const VariableApplyResult({
    required this.applied,
    this.updates = const {},
    this.removals = const [],
    this.proposedRemovals = const [],
    this.ignoredRemovals = 0,
  });
}

/// 待确认删除的批准结果:[removed] 实际移入回收站, [stale] 因变量已变化/
/// 已删除/权限收紧而作废。
class VariableApprovalResult {
  final int removed;
  final int stale;
  const VariableApprovalResult({required this.removed, required this.stale});
}

class _VariableApplyCancelled implements Exception {
  const _VariableApplyCancelled();
}
