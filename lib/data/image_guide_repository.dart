/// 会话级生图指导(`image_guides` 表)的读写,与 memories 对称。
library;

import '../models/image_guide.dart';
import 'database.dart';

/// 会话级生图指导仓储:每会话至多一行。
///
/// 生图轮每轮读取最新文本注入后台提示词,不冻结;用户在状态面板手动编辑
/// 或触发生成初始指导后落库,下一轮即生效。
class ImageGuideRepository {
  final AppDatabase db;
  ImageGuideRepository(this.db);

  /// 会话的生图指导行(空列表 = 尚未生成)。
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

  /// 清空会话生图指导(删行;下一轮后台不再携带指导)。
  Future<void> clear(int sessionId) async {
    await db.db.delete('image_guides', where: 'session_id = ?', whereArgs: [sessionId]);
  }
}
