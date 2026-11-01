import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/image_plugin.dart';
import '../models/image_plugin_seeds.dart';
import 'database.dart';

class ImagePluginRepository {
  final AppDatabase db;

  ImagePluginRepository(this.db);

  /// 每次启动按 id 刷新内置协议插件(manifest/JS/版本),使 App 更新能传播协议
  /// 修复;保留用户的启用状态,且不触碰用户自导插件。仅覆盖 `microscritt.*`
  /// 保留命名空间里、且当前行仍与某个内置 seed 同 id 的记录。
  Future<void> upsertBuiltins() async {
    for (final seed in kDefaultImagePluginSeeds) {
      final existing = await db.db.query(
        'image_plugins',
        columns: const ['id'],
        where: 'id = ?',
        whereArgs: [seed.id],
        limit: 1,
      );
      if (existing.isEmpty) {
        await db.db.insert('image_plugins', {
          'id': seed.id,
          'name': seed.name,
          'version': seed.version,
          'manifest_json': seed.toManifestJson(),
          'js_code': seed.code,
          'enabled': 1,
        });
      } else {
        await db.db.update(
          'image_plugins',
          {
            'name': seed.name,
            'version': seed.version,
            'manifest_json': seed.toManifestJson(),
            'js_code': seed.code,
          },
          where: 'id = ?',
          whereArgs: [seed.id],
        );
      }
    }
  }

  Future<List<ImagePlugin>> all() async {
    final rows = await db.db.query(
      'image_plugins',
      orderBy: 'name COLLATE NOCASE, id',
    );
    final plugins = <ImagePlugin>[];
    for (final row in rows) {
      try {
        plugins.add(_fromRow(row));
      } catch (error) {
        debugPrint('生图插件行解析失败(已跳过,id=${row['id']}):$error');
      }
    }
    return plugins;
  }

  Future<void> save(ImagePlugin plugin) async {
    await db.db.insert('image_plugins', {
      'id': plugin.id,
      'name': plugin.name,
      'version': plugin.version,
      'manifest_json': plugin.toManifestJson(),
      'js_code': plugin.code,
      'enabled': plugin.enabled ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await db.db.update(
      'image_plugins',
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> isInUse(String id) async {
    final rows = await db.db.query(
      'image_providers',
      columns: const ['id'],
      where: 'plugin_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> delete(String id) async {
    if (await isInUse(id)) throw StateError('该插件仍被生图配置使用，请先删除或更改相关配置');
    await db.db.delete('image_plugins', where: 'id = ?', whereArgs: [id]);
  }

  static ImagePlugin _fromRow(Map<String, Object?> row) =>
      ImagePlugin.fromStorageJson(
        row['manifest_json'] as String,
        row['js_code'] as String,
        (row['enabled'] as int? ?? 1) != 0,
      );
}
