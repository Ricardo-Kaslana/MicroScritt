import 'package:sqflite/sqflite.dart';
import '../models/user.dart';
import 'database.dart';

/// 用户档案仓储(单行表,id 恒为 1)。未保存过时 load 返回空档案。
class UserRepository {
  final AppDatabase db;
  UserRepository(this.db);

  /// 头像 base64 分块读取的块大小(字符)。与 `MessageRepository.imageBase64For`
  /// 同款:必须远小于 Android CursorWindow 的 2MB 上限,给其余行留足余量。
  static const int _avatarChunkChars = 512 * 1024;

  /// 只取用户名(配置文件快照用,不触碰可能很大的头像列)。
  Future<String> name() async {
    final rows = await db.db.query('user_profile', columns: ['name'], where: 'id = 1', limit: 1);
    return rows.isEmpty ? '' : (rows.first['name'] as String? ?? '');
  }

  /// 只改用户名并保留头像(配置文件应用/手改用户名时使用)。
  Future<void> updateName(String name) async {
    final updated = await db.db.update('user_profile', {'name': name}, where: 'id = 1');
    if (updated == 0) {
      await db.db.insert('user_profile', {'id': 1, 'name': name}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<UserProfile> load() async {
    // 只投影 id/name,不整行 SELECT user_profile:头像列可能是几 MB 的 base64,
    // 连同其余列一起搬进 Android CursorWindow 会抛 "Row too big"(上限 2MB;
    // 桌面 FFI 无此限制)。头像经 [avatarBase64For] 按需分块读取,读不到
    // (NULL/历史超大残行)回退 null,绝不把启动/加载拖垮。
    final rows = await db.db.query(
      'user_profile',
      columns: ['id', 'name'],
      where: 'id = 1',
    );
    if (rows.isEmpty) return const UserProfile();
    final r = rows.first;
    final avatar = await avatarBase64For(1);
    return UserProfile(
      id: r['id'] as int?,
      name: r['name'] as String? ?? '',
      avatarBase64: avatar,
    );
  }

  /// 分块读取用户头像列。Android SQLite 的 CursorWindow 上限 2MB,单次整列
  /// SELECT 时超限行整行抛 Row too big —— 历史版本存的用户头像可能未经缩图
  /// (见 `shrinkBase64Image`),因此先查长度、再用 substr 分块读取、Dart 侧
  /// 拼接,任何平台的单次返回都远低于窗口上限;列为 NULL 返回 null。
  Future<String?> avatarBase64For(int id) async {
    final lenRows = await db.db.rawQuery(
      'SELECT length(avatar_base64) AS len FROM user_profile WHERE id = ? LIMIT 1',
      [id],
    );
    if (lenRows.isEmpty) return null;
    final len = lenRows.first['len'] as int?;
    if (len == null) return null; // 列为 NULL
    final buffer = StringBuffer();
    for (var start = 1; start <= len; start += _avatarChunkChars) {
      final chunk = await db.db.rawQuery(
        'SELECT substr(avatar_base64, ?, ?) AS piece FROM user_profile WHERE id = ? LIMIT 1',
        [start, _avatarChunkChars, id],
      );
      buffer.write(chunk.first['piece'] as String? ?? '');
    }
    return buffer.toString();
  }

  Future<void> save(UserProfile p) async {
    await db.db.insert('user_profile', {
      'id': 1,
      'name': p.name,
      'avatar_base64': p.avatarBase64,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}