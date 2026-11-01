/// 会话级记忆(`memories` 表,每会话至多一行)的持久化。
///
/// 后台快状态轮只读记忆;写入由用户触发的初始化/重生成与手工编辑产生。
library;

import '../models/memory.dart';
import 'database.dart';

/// 记忆仓储:按会话整段读写,支持手工逐条修订。
class MemoryRepository {
  final AppDatabase db;
  MemoryRepository(this.db);

  /// 会话的记忆行(正常至多一行)。
  Future<List<Memory>> bySession(int sessionId) async {
    final rows = await db.db.query('memories', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'updated_at');
    return rows.map(Memory.fromMap).toList();
  }

  /// 用 [content] 整段替换会话记忆(删旧插新);整段写入自带事务。
  Future<void> set(int sessionId, String content) async {
    await db.db.transaction((txn) async {
      await txn.delete('memories', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.insert('memories', {
        'session_id': sessionId,
        'content': content,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  Future<void> clear(int sessionId) async {
    await db.db.delete('memories', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  /// 删除单条记忆(UI 逐条删除)。
  Future<void> delete(int id) async {
    await db.db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  /// 编辑单条记忆内容(UI 手工修订);同时刷新 updated_at,
  /// 让后续读取(状态面板 / 上下文组装)拿到新文本。
  Future<void> update(int id, String content) async {
    await db.db.update(
      'memories',
      {'content': content, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
