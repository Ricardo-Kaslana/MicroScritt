/// 用户自定义生图风格(`image_styles` 表)的持久化。
library;

import 'package:sqflite/sqflite.dart';

import '../models/image_style_preset.dart';
import 'database.dart';

/// 用户自定义生图风格仓库:内置预设走 [kImageStylePresets] 常量列表,
/// 不经此仓库;两者在设置页下拉里混排。
class ImageStyleRepository {
  final AppDatabase db;
  ImageStyleRepository(this.db);

  Future<int> insert(ImageStylePreset s) => db.db.insert('image_styles', s.toMap());

  Future<List<ImageStylePreset>> all() async {
    final rows = await db.db.query('image_styles', orderBy: 'id');
    return rows.map(ImageStylePreset.fromMap).toList();
  }

  Future<void> update(ImageStylePreset s) async {
    await db.db.update('image_styles', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
  }

  Future<void> delete(int id) async {
    await db.db.delete('image_styles', where: 'id = ?', whereArgs: [id]);
  }

  /// 在调用方事务内整体替换自定义风格;空列表即清空。
  ///
  /// 风格没有排序位,按传入顺序插入(id 由库自增)。
  Future<void> replaceAllInTransaction(
    DatabaseExecutor executor,
    List<ImageStylePreset> styles,
  ) async {
    await executor.delete('image_styles');
    for (final style in styles) {
      final data = style.toMap();
      data.remove('id');
      await executor.insert('image_styles', data);
    }
  }
}
