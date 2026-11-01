/// 预设提示词/规则(`prompt_items` 表)的持久化。
library;

import '../models/prompt_item.dart';
import 'database.dart';

/// 提示词条目仓储:`kind` 区分预设与规则,`position` 决定组装顺序。
class PromptItemRepository {
  final AppDatabase db;
  PromptItemRepository(this.db);

  /// 新建条目,返回自增 id。
  Future<int> insert(PromptItem i) => db.db.insert('prompt_items', i.toMap());

  /// 全部条目,按 kind、position 排序(管理页展示)。
  Future<List<PromptItem>> all() async {
    final rows = await db.db.query('prompt_items', orderBy: 'kind, position');
    return rows.map(PromptItem.fromMap).toList();
  }

  /// 启用中的条目(主写组装用),按 kind、position 排序。
  Future<List<PromptItem>> allEnabled() async {
    final rows = await db.db.query('prompt_items', where: 'enabled = 1', orderBy: 'kind, position');
    return rows.map(PromptItem.fromMap).toList();
  }

  Future<void> update(PromptItem i) async {
    await db.db.update('prompt_items', i.toMap(), where: 'id = ?', whereArgs: [i.id]);
  }

  Future<void> delete(int id) async {
    await db.db.delete('prompt_items', where: 'id = ?', whereArgs: [id]);
  }
}
