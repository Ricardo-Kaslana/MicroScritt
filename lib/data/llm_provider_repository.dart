import '../backend/backend_config.dart';
import '../models/endpoint_compat.dart';
import '../models/llm_provider.dart';
import 'database.dart';

/// 按 provider 分组的 LLM 后端配置持久化。
///
/// 管理 `llm_providers` + `llm_models` 两张表,并把"当前在用的 provider+模型"
/// 映射为运行链路消费的 `BackendConfig`(与旧单行配置接口对接)。
class LlmProviderRepository {
  final AppDatabase db;
  LlmProviderRepository(this.db);

  Future<List<LlmProviderConfig>> all() async {
    final providerRows = await db.db.query('llm_providers', orderBy: 'position ASC, id ASC');
    // position 序即用户排列序;与 loadBackendConfig 的模型排序口径一致,
    // 不依赖"重插后 rowid 恰好单调"的隐性巧合。
    final modelRows = await db.db.query('llm_models', orderBy: 'position ASC, id ASC');
    final modelsByProvider = <int, List<LlmModelEntry>>{};
    for (final m in modelRows) {
      final pid = m['provider_id'] as int;
      modelsByProvider.putIfAbsent(pid, () => []).add(_modelFromRow(m));
    }
    return [for (final p in providerRows) _providerFromRow(p, modelsByProvider[p['id'] as int] ?? const [])];
  }

  Future<LlmProviderConfig?> byId(int id) async {
    final rows = await db.db.query('llm_providers', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final modelRows = await db.db.query('llm_models', where: 'provider_id = ?', whereArgs: [id]);
    return _providerFromRow(rows.first, [for (final m in modelRows) _modelFromRow(m)]);
  }

  /// 保存 provider 及其模型目录。
  ///
  /// 模型行按 id **upsert**(有 id 的 update、无 id 的 insert、消失的 delete),
  /// 而不是整批删了重插:重插会让所有模型拿到新自增 id,而
  /// `app_settings.background_model_id` 等按 `llm_models.id` 引用的配置随即
  /// 悬空 —— 后台 agent 会静默回退主写模型,用户无任何提示。upsert 保住
  /// 未变行的 id,引用稳定。
  Future<void> saveProvider(LlmProviderConfig c) async {
    await db.db.transaction((txn) async {
      int id = c.id;
      final data = {
        'provider_id': c.providerId,
        'display_name': c.displayName,
        'base_url': c.baseUrl,
        'protocol': c.protocol.wire,
        'api_key': c.apiKey,
        'is_active': c.isActive ? 1 : 0,
        'position': c.position,
        'extra_headers': LlmProviderConfig.extraHeadersWire(c.extraHeaders),
        'modern_params': c.modernParams ? 1 : 0,
        'compat_flags': c.compat.toWire(),
      };
      if (c.id == 0) {
        id = await txn.insert('llm_providers', data);
      } else {
        await txn.update('llm_providers', data, where: 'id = ?', whereArgs: [c.id]);
        // 删除本次保存中消失的模型行(新 provider 无旧行可删)。
        final keptIds = c.models.map((m) => m.id).where((mid) => mid != 0).toSet();
        final existingIds = (await txn.query(
          'llm_models',
          columns: ['id'],
          where: 'provider_id = ?',
          whereArgs: [id],
        ))
            .map((r) => r['id'] as int)
            .toSet();
        for (final gone in existingIds.difference(keptIds)) {
          await txn.delete('llm_models', where: 'id = ?', whereArgs: [gone]);
        }
      }
      for (var i = 0; i < c.models.length; i++) {
        final m = c.models[i];
        final modelData = {
          'provider_id': id,
          'model_id': m.modelId,
          'display_name': m.displayName,
          'context_capacity': m.contextCapacity,
          'max_output': m.maxOutput,
          'temperature': m.temperature,
          'is_active': m.isActive ? 1 : 0,
          'position': i,
        };
        if (c.id != 0 && m.id != 0) {
          await txn.update('llm_models', modelData, where: 'id = ?', whereArgs: [m.id]);
        } else {
          await txn.insert('llm_models', modelData);
        }
      }
    });
  }

  Future<void> deleteProvider(int id) async {
    await db.db.transaction((txn) async {
      await txn.delete('llm_models', where: 'provider_id = ?', whereArgs: [id]);
      await txn.delete('llm_providers', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 选择某个 provider 为当前在用,并(可选)指定其下某个模型为选中模型。
  Future<void> setActive({required int providerId, int? modelId}) async {
    await db.db.transaction((txn) async {
      await txn.rawUpdate('UPDATE llm_providers SET is_active = CASE WHEN id = ? THEN 1 ELSE 0 END', [providerId]);
      if (modelId != null) {
        await txn.rawUpdate(
          'UPDATE llm_models SET is_active = CASE WHEN id = ? THEN 1 ELSE 0 END WHERE provider_id = ?',
          [modelId, providerId],
        );
      }
    });
  }

  /// 把"当前在用的 provider + 选中模型"映射为运行链路消费的 [BackendConfig]。
  /// 没有任何可用的 provider/模型时返回 null。
  Future<BackendConfig?> loadBackendConfig() async {
    final providerRows = await db.db.query('llm_providers', where: 'is_active = 1', limit: 1);
    if (providerRows.isEmpty) return null;
    final p = providerRows.first;
    final modelRows = await db.db.query(
      'llm_models',
      where: 'provider_id = ?',
      whereArgs: [p['id']],
      orderBy: 'is_active DESC, position ASC, id ASC',
      limit: 1,
    );
    if (modelRows.isEmpty) return null;
    return _configFromProvider(p, modelRows.first);
  }

  /// 解析某一个指定模型的 [BackendConfig](用于后台agent 专用模型选择)。
  /// 给定 llm_models.id,反查其所属 provider,组装成运行链路消费的配置;
  /// 找不到该模型或其 provider 时返回 null。
  Future<BackendConfig?> loadConfigForModel(int modelId) async {
    final modelRows = await db.db.query('llm_models', where: 'id = ?', whereArgs: [modelId], limit: 1);
    if (modelRows.isEmpty) return null;
    final m = modelRows.first;
    final pid = m['provider_id'] as int;
    final providerRows = await db.db.query('llm_providers', where: 'id = ?', whereArgs: [pid], limit: 1);
    if (providerRows.isEmpty) return null;
    return _configFromProvider(providerRows.first, m);
  }

  BackendConfig _configFromProvider(Map<String, Object?> p, Map<String, Object?> m) {
    final protocol = LlmProtocol.fromWire(p['protocol'] as String);
    return BackendConfig(
      provider: protocol == LlmProtocol.anthropic ? BackendProvider.anthropic : BackendProvider.openai,
      baseUrl: p['base_url'] as String,
      apiKey: p['api_key'] as String,
      model: m['model_id'] as String,
      maxTokens: (m['max_output'] as int?),
      temperature: (m['temperature'] as num?)?.toDouble() ?? 0.7,
      extraHeaders: LlmProviderConfig.extraHeadersFromWire(p['extra_headers'] as String?),
      modernParams: (p['modern_params'] as int? ?? 0) != 0,
      compat: EndpointCompat.fromWire(p['compat_flags'] as String?),
    );
  }

  LlmProviderConfig _providerFromRow(Map<String, Object?> r, List<LlmModelEntry> models) => LlmProviderConfig(
    id: r['id'] as int,
    providerId: r['provider_id'] as String,
    displayName: r['display_name'] as String,
    baseUrl: r['base_url'] as String,
    protocol: LlmProtocol.fromWire(r['protocol'] as String),
    apiKey: r['api_key'] as String,
    isActive: (r['is_active'] as int) != 0,
    position: (r['position'] as int?) ?? 0,
    models: models,
    extraHeaders: LlmProviderConfig.extraHeadersFromWire(r['extra_headers'] as String?),
    modernParams: (r['modern_params'] as int? ?? 0) != 0,
    compat: EndpointCompat.fromWire(r['compat_flags'] as String?),
  );

  LlmModelEntry _modelFromRow(Map<String, Object?> r) => LlmModelEntry(
    id: r['id'] as int,
    providerId: r['provider_id'] as int,
    modelId: r['model_id'] as String,
    displayName: r['display_name'] as String,
    contextCapacity: (r['context_capacity'] as int?) ?? 0,
    maxOutput: r['max_output'] as int?,
    // sqflite 对 REAL 列在整值时可能回传 int,统一按 num 兜底再转 double。
    temperature: (r['temperature'] as num?)?.toDouble(),
    isActive: (r['is_active'] as int) != 0,
    position: (r['position'] as int?) ?? 0,
  );
}
