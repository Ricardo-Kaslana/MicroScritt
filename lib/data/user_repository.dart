/// 用户档案(`user_profile` 单行表)的持久化。
///
/// 头像只保存文件资产 hash,业务行与引用计数在同一事务内更新。
library;

import 'package:sqflite/sqflite.dart';
import '../models/user.dart';
import 'database.dart';

/// 用户档案仓储(单行表,id 恒为 1)。未保存过时 [load] 返回空档案。
class UserRepository {
  final AppDatabase db;
  UserRepository(this.db);

  /// 只取用户名(配置文件快照用)。
  Future<String> name() async {
    final rows = await db.db.query('user_profile', columns: ['name'], where: 'id = 1', limit: 1);
    return rows.isEmpty ? '' : (rows.first['name'] as String? ?? '');
  }

  /// 只改用户名并保留头像(配置文件应用/手改用户名时使用),不调整图片引用。
  Future<void> updateName(String name) =>
      db.db.transaction((txn) => updateNameInTransaction(txn, name));

  /// 在调用方事务内只改用户名;不自行开启/提交事务。
  Future<void> updateNameInTransaction(
    DatabaseExecutor executor,
    String name,
  ) async {
    final updated = await executor.update(
      'user_profile',
      {'name': name},
      where: 'id = 1',
    );
    if (updated == 0) {
      await executor.insert(
        'user_profile',
        {'id': 1, 'name': name},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<UserProfile> load() async {
    final rows = await db.db.query(
      'user_profile',
      columns: ['id', 'name', 'avatar_hash'],
      where: 'id = 1',
    );
    if (rows.isEmpty) return const UserProfile();
    final r = rows.first;
    return UserProfile(
      id: r['id'] as int?,
      name: r['name'] as String? ?? '',
      avatarHash: r['avatar_hash'] as String?,
    );
  }

  /// 按 id 读取头像资产 hash;行不存在或列为空时返回 null。
  Future<String?> avatarHashFor(int id) async {
    final rows = await db.db.query(
      'user_profile',
      columns: ['avatar_hash'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final hash = rows.first['avatar_hash'] as String?;
    return hash == null || hash.isEmpty ? null : hash;
  }

  /// 整行 upsert(id 恒为 1):先 acquire 新引用,写行成功后 release 旧引用。
  /// 相同 hash 也会先加后减,净计数不变;任一步失败整个事务回滚。
  Future<void> save(UserProfile p) async {
    await db.db.transaction((txn) async {
      final oldRows = await txn.query(
        'user_profile',
        columns: ['avatar_hash'],
        where: 'id = 1',
        limit: 1,
      );
      final oldHash = oldRows.isEmpty ? null : oldRows.first['avatar_hash'] as String?;
      final newHash = p.avatarHash == null || p.avatarHash!.isEmpty ? null : p.avatarHash;
      if (newHash != null) await db.images.acquire(txn, newHash);
      await txn.insert('user_profile', {
        'id': 1,
        'name': p.name,
        'avatar_hash': newHash,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (oldHash != null && oldHash.isNotEmpty) {
        await db.images.release(txn, oldHash);
      }
    });
  }
}
