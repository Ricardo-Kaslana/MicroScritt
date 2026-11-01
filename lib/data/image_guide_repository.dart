import '../models/image_guide.dart';
import 'database.dart';

/// 会话级生图指导读写(schema v38 `image_guides` 表,与 memories 对称):
/// 每会话至多一行。后台agent 每轮读取最新文本携带进生图维护;用户在状态面板
/// 手动编辑或 LLM 生成初始指导后落库,下一轮后台即生效(无冻结语义)。
class ImageGuideRepository {
  final AppDatabase db;
  ImageGuideRepository(this.db);

  Future<List<ImageGuide>> bySession(int sessionId) async {
    final rows = await db.db.query('image_guides', where: 'session_id = ?', whereArgs: [sessionId]);
    return rows.map(ImageGuide.fromMap).toList();
  }

  /// 用 [content] 整段替换会话生图指导(删旧插新,单事务)。
  Future<void> set(int sessionId, String content) async {
    await db.db.transaction((txn) async {
      await txn.delete('image_guides', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.insert('image_guides', {
        'session_id': sessionId,
        'content': content,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  Future<void> clear(int sessionId) async {
    await db.db.delete('image_guides', where: 'session_id = ?', whereArgs: [sessionId]);
  }
}
