/// Hook 脚本(`hooks` 表)的持久化。
///
/// 行解析失败(如手改库写入未知 `trigger_point`)只跳过该行并打日志,
/// 不拖垮管理页或发送管线。
library;

import 'package:flutter/foundation.dart';

import '../models/hook.dart';
import 'database.dart';

/// Hook 仓储:管理页 CRUD 与执行管线按触发点取用共用。
class HookRepository {
  final AppDatabase db;
  HookRepository(this.db);

  /// 某触发点下启用中的 hook,按 id 升序。
  Future<List<Hook>> byTriggerPoint(HookTriggerPoint point) async {
    final rows = await db.db.query('hooks',
        where: 'trigger_point = ? AND enabled = 1', whereArgs: [point.name], orderBy: 'id');
    return _parseRows(rows);
  }

  Future<List<Hook>> all() async {
    final rows = await db.db.query('hooks', orderBy: 'id');
    return _parseRows(rows);
  }

  Future<int> insert(Hook h) => db.db.insert('hooks', h.toMap());

  Future<void> update(Hook h) async {
    await db.db.update('hooks', h.toMap(), where: 'id = ?', whereArgs: [h.id]);
  }

  Future<void> delete(int id) async {
    await db.db.delete('hooks', where: 'id = ?', whereArgs: [id]);
  }

  /// 逐行解析,坏行(如手改库产生的未知 trigger_point —— 领域枚举按约定
  /// fail-loud 抛错)跳过并记日志,不炸整页加载/整轮发送管线;用户在管理页
  /// 仍能看到其余 hook 并修复或删除坏行。
  static List<Hook> _parseRows(List<Map<String, Object?>> rows) {
    final hooks = <Hook>[];
    for (final row in rows) {
      try {
        hooks.add(Hook.fromMap(row));
      } catch (e) {
        debugPrint('hook 行解析失败(已跳过,id=${row['id']}):$e');
      }
    }
    return hooks;
  }
}
