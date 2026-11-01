/// 生图配置(`image_providers` 多行表)的持久化。
///
/// 一行一套完整配置(自带 `api_key` 与 `is_active`),凭据互不覆盖;运行
/// 链路只消费活跃行映射出的中立 [ImageConfig],本仓库不 import 任何生图后端。
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import '../models/image_config.dart';
import 'database.dart';

/// 生图配置仓储:多行 CRUD、活跃行切换与运行链路配置投影。
///
/// 每行自带凭据与活跃标记,切服务不需要重新粘贴密钥。生图只有单一插件
/// 路径:[loadActiveConfig] 把活跃行剥回 [ImageConfig],调用方零改动;
/// 没有活跃行时返回 null,调用方据此跳过生图。
class ImageConfigRepository {
  final AppDatabase db;
  ImageConfigRepository(this.db);

  static const String _table = 'image_providers';

  /// 全部配置,按 position 序(与 `LlmProviderRepository.all()` 同款排序口径,
  /// 不依赖"重插后 rowid 恰好单调"的隐性巧合)。
  Future<List<ImageProviderRecord>> all() async {
    final rows = await db.db.query(_table, orderBy: 'position ASC, id ASC');
    return [for (final r in rows) _fromRow(r)];
  }

  Future<ImageProviderRecord?> byId(int id) async {
    final rows = await db.db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// 新建(id=0)或更新一条配置,返回其库内 id。
  ///
  /// **首条落库的配置自动置为活跃** —— 否则用户新增后忘了点「设为当前使用」,
  /// 生图会因为"没有任何活跃配置"而整轮静默跳过(`imageBackendProvider` 在
  /// 配置为 null 时返回 null)。
  Future<int> saveProvider(ImageProviderRecord r) async {
    return db.db.transaction((txn) async {
      final Map<String, Object?> data = {
        'display_name': r.displayName,
        'kind': r.config.kind.wire,
        'base_url': r.config.baseUrl,
        'api_key': r.config.apiKey,
        'model': r.config.model,
        'size': r.config.size,
        'scale': r.config.scale,
        'cfg': r.config.cfg,
        'negative': r.config.negative,
        'sampler': r.config.sampler,
        'artist': r.config.artist,
        'noise_schedule': r.config.noiseSchedule,
        'steps': r.config.steps,
        'count': r.config.count,
        'plugin_id': r.config.pluginId,
        'settings_json': jsonEncode(r.config.pluginSettings),
        'is_active': r.isActive ? 1 : 0,
        'position': r.position,
      };
      if (r.id != 0) {
        await txn.update(_table, data, where: 'id = ?', whereArgs: [r.id]);
        return r.id;
      }
      final count =
          Sqflite.firstIntValue(
            await txn.rawQuery('SELECT COUNT(*) FROM $_table'),
          ) ??
          0;
      if (count == 0) data['is_active'] = 1;
      return txn.insert(_table, data);
    });
  }

  /// 删除一条配置。删掉的若是**当前在用**的那套,顺位补一条为活跃 —— 否则会
  /// 留下"有配置但无活跃"的状态,生图静默跳过而 UI 上看不出原因。
  Future<void> deleteProvider(int id) async {
    await db.db.transaction((txn) async {
      final rows = await txn.query(
        _table,
        columns: ['is_active'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      final wasActive =
          rows.isNotEmpty && ((rows.first['is_active'] as int?) ?? 0) != 0;
      await txn.delete(_table, where: 'id = ?', whereArgs: [id]);
      if (!wasActive) return;
      final next = await txn.query(
        _table,
        columns: ['id'],
        orderBy: 'position ASC, id ASC',
        limit: 1,
      );
      if (next.isNotEmpty) {
        await txn.update(
          _table,
          {'is_active': 1},
          where: 'id = ?',
          whereArgs: [next.first['id']],
        );
      }
    });
  }

  /// 把某条置为当前使用(全表互斥),与 `LlmProviderRepository.setActive` 同款。
  Future<void> setActive(int id) async {
    await db.db.rawUpdate(
      'UPDATE $_table SET is_active = CASE WHEN id = ? THEN 1 ELSE 0 END',
      [id],
    );
  }

  /// 当前活跃配置,剥回运行链路消费的 [ImageConfig]。没有活跃行时返回 null,
  /// 调用方据此整轮跳过生图。
  Future<ImageConfig?> loadActiveConfig() async {
    final rows = await db.db.query(_table, where: 'is_active = 1', limit: 1);
    if (rows.isEmpty) return null;
    return _configFromRow(rows.first);
  }

  ImageProviderRecord _fromRow(Map<String, Object?> r) => ImageProviderRecord(
    id: r['id'] as int,
    displayName: (r['display_name'] as String?) ?? '',
    isActive: ((r['is_active'] as int?) ?? 0) != 0,
    position: (r['position'] as int?) ?? 0,
    config: _configFromRow(r),
  );

  ImageConfig _configFromRow(Map<String, Object?> r) => ImageConfig(
    // kind 脏值/历史协议名一律回落插件路径([ImageBackendKind.plugin])。
    kind: ImageBackendKind.fromWire(r['kind'] as String?),
    baseUrl: r['base_url'] as String,
    apiKey: r['api_key'] as String,
    model: r['model'] as String,
    size: r['size'] as String?,
    scale: r['scale'] as int?,
    // INTEGER 亲和列存非整数 REAL 时会原样保留,历史行读回 int、小数读回
    // double,统一按 num 收敛(schema 无需改动)。
    cfg: (r['cfg'] as num?)?.toDouble(),
    negative: r['negative'] as String?,
    sampler: r['sampler'] as String?,
    steps: r['steps'] as int?,
    artist: r['artist'] as String?,
    noiseSchedule: r['noise_schedule'] as String?,
    // count 缺失/脏值回落 1;防御性钳制到 1-6(设置页同范围)。
    count: ((r['count'] as int?) ?? 1).clamp(1, 6),
    pluginId: r['plugin_id'] as String?,
    pluginSettings: _pluginSettingsFromJson(r['settings_json'] as String?),
  );

  // settings_json 在启动水合时即被读取:手改库/坏 JSON/非对象一律回落空表,
  // 脏值不得炸掉生图配置加载。
  static Map<String, dynamic> _pluginSettingsFromJson(String? source) {
    if (source == null || source.isEmpty) return const {};
    try {
      final decoded = jsonDecode(source);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}
