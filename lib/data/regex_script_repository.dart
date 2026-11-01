import '../models/regex_script.dart';
import 'database.dart';

class RegexScriptRepository {
  final AppDatabase db;
  RegexScriptRepository(this.db);

  /// 全部脚本,按应用序(position 升序、同序按 id)。
  Future<List<RegexScript>> all() async {
    final rows = await db.db.query('regex_scripts', orderBy: 'position, id');
    return rows.map(RegexScript.fromMap).toList();
  }

  /// 新脚本插入到列表末尾(position = max + 1)。
  Future<int> insert(RegexScript s) async {
    final next = await nextPosition();
    return db.db.insert('regex_scripts', s.copyWith(position: next).toMap());
  }

  Future<void> update(RegexScript s) async {
    await db.db.update('regex_scripts', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
  }

  Future<void> delete(int id) async {
    await db.db.delete('regex_scripts', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> nextPosition() async {
    final rows = await db.db.rawQuery(
      'SELECT COALESCE(MAX(position), -1) + 1 AS next FROM regex_scripts',
    );
    return rows.first['next'] as int? ?? 0;
  }
}
