import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import '../models/image_config.dart';
import 'database.dart';

/// 生图配置持久化(多行表 `image_providers`,一行一套完整配置)。
///
/// 每行自带 `api_key` 与 `is_active` —— 两家的凭据因此互不覆盖,切服务不再需要
/// 重新粘贴密钥(旧单行 `image_configs` 只有一个 `api_key` 列,切一次覆盖一次)。
///
/// 与旧表的关系:老表 `image_configs` 原地保留、**不再读写**(与 `backend_configs`
/// 在 `llm_providers` 落地后的处置一致,降级回旧版时旧代码仍能读到原配置);
/// v60 迁移把老行搬成第一套并置为活跃。
///
/// 运行链路(两个生图后端 / `imageBackendProvider` / 编排器)只消费
/// `models/` 的中立 [ImageConfig] —— [loadActiveConfig] 把活跃行剥回它,故调用方
/// 零改动。本仓库只依赖 `models/`,不 import 任何生图后端。
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

  /// 当前活跃配置,剥回运行链路消费的 [ImageConfig]。没有活跃行时返回 null
  /// (调用方据此跳过生图,与旧单行配置为空时的行为一致)。
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
    // 老库(无 kind 列 / 值为 null)回落对话式网关,与历史列默认值一致。
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
    // 老库迁移后 count 为默认 1;防御性钳制到 1-6(设置页同范围)。
    count: ((r['count'] as int?) ?? 1).clamp(1, 6),
    pluginId: r['plugin_id'] as String?,
    pluginSettings: _pluginSettingsFromJson(r['settings_json'] as String?),
  );

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
