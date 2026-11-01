import '../models/skill.dart';
import 'database.dart';

/// 全局技能目录(v37 起):技能不再归属会话,全 App 共享一份;
/// 启用中的技能在所有会话的上下文组装里全局生效。
class SkillRepository {
  final AppDatabase db;
  SkillRepository(this.db);

  /// 全部技能(按 id 稳定排序,管理页展示)。
  Future<List<Skill>> all() async {
    final rows = await db.db.query('skills', orderBy: 'id');
    return rows.map(Skill.fromMap).toList();
  }

  /// 启用中的技能(上下文组装用;全局生效)。
  Future<List<Skill>> allEnabled() async {
    final rows = await db.db.query('skills', where: 'enabled = 1', orderBy: 'id');
    return rows.map(Skill.fromMap).toList();
  }

  /// 新建技能,返回自增 id。
  Future<int> insert(Skill s) => db.db.insert('skills', {
        'name': s.name,
        'description': s.description,
        'content': s.content,
        'enabled': s.enabled ? 1 : 0,
      });

  /// 整条更新技能(编辑页保存)。
  Future<void> update(Skill s) => db.db.update(
        'skills',
        {
          'name': s.name,
          'description': s.description,
          'content': s.content,
          'enabled': s.enabled ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [s.id],
      );

  /// 只切启用开关(列表页 Switch 直改,不整条重写)。
  Future<void> setEnabled(int id, bool enabled) => db.db.update(
        'skills',
        {'enabled': enabled ? 1 : 0},
        where: 'id = ?',
        whereArgs: [id],
      );

  Future<void> delete(int id) => db.db.delete('skills', where: 'id = ?', whereArgs: [id]);

  /// 按 name 幂等批量导入(世界书 → 技能):已存在同名技能的跳过。
  /// 返回 (导入数, 同名跳过数)。[enabled] 控制导入后的初始启用状态。
  Future<(int imported, int skipped)> importAll(
    List<Skill> skills, {
    bool enabled = true,
  }) async {
    var imported = 0;
    var skipped = 0;
    for (final s in skills) {
      final existing = await db.db.query('skills', where: 'name = ?', whereArgs: [s.name], limit: 1);
      if (existing.isNotEmpty) {
        skipped++;
        continue;
      }
      await insert(Skill(name: s.name, description: s.description, content: s.content, enabled: enabled));
      imported++;
    }
    return (imported, skipped);
  }
}
