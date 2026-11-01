import '../models/prompt_item.dart';
import 'database.dart';

class PromptItemRepository {
  final AppDatabase db;
  PromptItemRepository(this.db);

  Future<int> insert(PromptItem i) => db.db.insert('prompt_items', i.toMap());

  Future<List<PromptItem>> all() async {
    final rows = await db.db.query('prompt_items', orderBy: 'kind, position');
    return rows.map(PromptItem.fromMap).toList();
  }

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
