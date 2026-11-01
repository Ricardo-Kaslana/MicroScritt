part of 'database.dart';

// 默认数据种子(仅建库路径):默认提示词预设、默认 Hook、默认正则脚本、
// 默认 LLM provider 与两个内置生图协议插件。
//
// 内容须为本项目原创的中性创作辅助素材;除默认预设只在建库时一次性写入外,
// 其余均幂等(按 name/id 或空表判定),重复执行不重复、不覆盖用户改动。

/// 种入默认正则脚本。按 name 幂等:已存在同名脚本(含用户改过的)则跳过。
Future<void> _seedDefaultRegexScripts(Database db) async {
  final hasTable = (await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='regex_scripts'",
  )).isNotEmpty;
  if (!hasTable) return;

  for (final seed in kDefaultRegexScriptSeeds) {
    final existing = await db.query(
      'regex_scripts',
      where: 'name = ?',
      whereArgs: [seed.name],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('regex_scripts', seed.toMap());
    }
  }
}

/// 把内置默认预设提示词(全部启用)写入 prompt_items。
/// 仅建库路径调用一次:不做去重,重复执行会产生重复预设。
Future<void> _seedDefaultPresets(Database db) async {
  final insert = await db.transaction((txn) async {
    for (final seed in kDefaultPromptSeeds) {
      await txn.insert('prompt_items', seed.toMap());
    }
  });
  return insert;
}

/// 种入默认 Hook(main/jump 输入改写)。
/// 按 name 幂等:已存在同名 hook 则跳过,只补缺失的默认 hook。
Future<void> _seedDefaultHooks(Database db) async {
  for (final seed in kDefaultHookSeeds) {
    final existing = await db.query(
      'hooks',
      where: 'name = ?',
      whereArgs: [seed.name],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('hooks', seed.toMap());
    }
  }
}

/// 种入默认 LLM provider:deepseek 官网 + deepseek-flash(上下文 1M tokens)。
/// 让设置页首次打开就有可用的 provider/模型目录、聊天输入框预选该模型;
/// API 密钥留空,由用户在设置页编辑填入。仅当 `llm_providers` 表为空时
/// 种入,绝不覆盖/追加用户已有的 provider。
Future<void> _seedDefaultLlmProvider(Database db) async {
  final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM llm_providers');
  final count = rows.isNotEmpty ? (rows.first['c'] as int? ?? 0) : 0;
  if (count > 0) return;
  final pid = await db.insert('llm_providers', {
    'provider_id': 'deepseek',
    'display_name': 'DeepSeek 官网',
    'base_url': 'https://api.deepseek.com',
    'protocol': 'openai',
    'api_key': '',
    'is_active': 1,
    'position': 0,
  });
  await db.insert('llm_models', {
    'provider_id': pid,
    'model_id': 'deepseek-flash',
    'display_name': 'deepseek-flash',
    'context_capacity': 1000000,
    'max_output': null,
    'is_active': 1,
    'position': 0,
  });
}

/// 种入两个内置生图协议插件(对话式网关 / Nai2API)。按 id 幂等:已存在同 id
/// 则跳过(含用户改过/停用),只补缺失的默认插件。manifest 与 JS 分列存储,
/// 与用户导入插件走同一张 `image_plugins` 表、同一执行路径。
Future<void> _seedImagePlugins(Database db) async {
  for (final plugin in kDefaultImagePluginSeeds) {
    final existing = await db.query(
      'image_plugins',
      columns: const ['id'],
      where: 'id = ?',
      whereArgs: [plugin.id],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('image_plugins', {
        'id': plugin.id,
        'name': plugin.name,
        'version': plugin.version,
        'manifest_json': plugin.toManifestJson(),
        'js_code': plugin.code,
        'enabled': 1,
      });
    }
  }
}
