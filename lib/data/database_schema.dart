part of 'database.dart';

// 基线建表 DDL:全新安装(及旧版本库归档重建)的唯一 schema 来源。
//
// 表结构就是当前 `schemaVersion` 的完整形态,不存在增量迁移链;建表后调用
// database_seeds.dart 的种子函数预填默认数据。改 schema = 改这里的 DDL +
// 递增 `AppDatabase.schemaVersion`,并补 test/data/database_open_test.dart 断言。

/// 全新安装的建表 DDL(`AppDatabase._onCreate` 委托至此)。
/// 建表后调用 database_seeds.dart 的幂等种子函数预填默认数据。
Future<void> _createSchema(Database db) async {
  await db.execute('''
      CREATE TABLE characters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        avatar_base64 TEXT,
        background_base64 TEXT,
        data_json TEXT NOT NULL
      )
    ''');
  await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
        title TEXT,
        created_at INTEGER NOT NULL,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cached_input_tokens INTEGER NOT NULL DEFAULT 0,
        background_input_tokens INTEGER NOT NULL DEFAULT 0,
        background_output_tokens INTEGER NOT NULL DEFAULT 0,
        background_cached_input_tokens INTEGER NOT NULL DEFAULT 0,
        compact_input_tokens INTEGER NOT NULL DEFAULT 0,
        compact_output_tokens INTEGER NOT NULL DEFAULT 0,
        compact_cached_input_tokens INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        seq INTEGER NOT NULL,
        is_compacted INTEGER NOT NULL DEFAULT 0,
        compact_of INTEGER,
        image_base64 TEXT,
        image_url TEXT,
        image_prompt TEXT,
        kind TEXT NOT NULL DEFAULT 'chat',
        ref_id TEXT
      )
    ''');
  await db.execute('''
      CREATE TABLE image_plugins (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        version TEXT NOT NULL,
        manifest_json TEXT NOT NULL,
        js_code TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');
  // 生图配置多行:一行一套完整配置(自带 api_key 与 is_active),
  // 运行链路只消费"活跃那一套"。
  await db.execute('''
      CREATE TABLE image_providers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        display_name TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL DEFAULT 'chat_completions',
        base_url TEXT NOT NULL,
        api_key TEXT NOT NULL,
        model TEXT NOT NULL,
        size TEXT,
        scale INTEGER,
        cfg INTEGER,
        negative TEXT,
        sampler TEXT,
        artist TEXT,
        noise_schedule TEXT,
        steps INTEGER,
        count INTEGER NOT NULL DEFAULT 1,
        plugin_id TEXT,
        settings_json TEXT NOT NULL DEFAULT '{}',
        is_active INTEGER NOT NULL DEFAULT 0,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE prompt_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        text TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE llm_providers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provider_id TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        base_url TEXT NOT NULL,
        protocol TEXT NOT NULL,
        api_key TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 0,
        position INTEGER NOT NULL DEFAULT 0,
        extra_headers TEXT NOT NULL DEFAULT '',
        modern_params INTEGER NOT NULL DEFAULT 0,
        compat_flags TEXT NOT NULL DEFAULT ''
      )
    ''');
  await db.execute('''
      CREATE TABLE llm_models (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provider_id INTEGER NOT NULL REFERENCES llm_providers(id) ON DELETE CASCADE,
        model_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        context_capacity INTEGER NOT NULL DEFAULT 0,
        max_output INTEGER,
        temperature REAL,
        is_active INTEGER NOT NULL DEFAULT 0,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE worldbook_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        key TEXT NOT NULL,
        use_regex INTEGER NOT NULL DEFAULT 0,
        case_sensitive INTEGER NOT NULL DEFAULT 0,
        match_whole_words INTEGER NOT NULL DEFAULT 0,
        selective INTEGER NOT NULL DEFAULT 0,
        secondary_key TEXT NOT NULL DEFAULT '[]',
        constant INTEGER NOT NULL DEFAULT 0,
        content TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        background INTEGER NOT NULL DEFAULT 0,
        extra TEXT NOT NULL DEFAULT ''
      )
    ''');
  await db.execute('''
      CREATE TABLE skills (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');
  await db.execute('''
      CREATE TABLE variables (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        agent_access TEXT NOT NULL DEFAULT 'protected',
        UNIQUE(session_id, key)
      )
    ''');
  await db.execute('''
      CREATE TABLE variable_trash (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        agent_access TEXT NOT NULL DEFAULT 'protected',
        deleted_at INTEGER NOT NULL,
        deleted_by TEXT NOT NULL DEFAULT 'user',
        UNIQUE(session_id, key)
      )
    ''');
  await db.execute('''
      CREATE TABLE variable_deletion_proposals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(session_id, key)
      )
    ''');
  await db.execute('''
      CREATE TABLE memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        content TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE(session_id)
      )
    ''');
  await db.execute('''
      CREATE TABLE image_guides (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        content TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE(session_id)
      )
    ''');
  await db.execute('''
      CREATE TABLE hooks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        trigger_point TEXT NOT NULL,
        js_code TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');
  await db.execute('''
      CREATE TABLE app_settings (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        theme_mode TEXT NOT NULL DEFAULT 'system',
        background_enabled INTEGER NOT NULL DEFAULT 1,
        background_features INTEGER NOT NULL DEFAULT 31,
        reasoning_level TEXT NOT NULL DEFAULT 'off',
        chat_background_enabled INTEGER NOT NULL DEFAULT 0,
        chat_background_blur REAL NOT NULL DEFAULT 18,
        dialogue_highlight_enabled INTEGER NOT NULL DEFAULT 1,
        background_model_id INTEGER,
        background_reasoning_level TEXT NOT NULL DEFAULT 'off',
        background_output_tier TEXT NOT NULL DEFAULT 'standard',
        auto_compact_chunk INTEGER NOT NULL DEFAULT 10,
        auto_compact_enabled INTEGER NOT NULL DEFAULT 1,
        slow_state_interval INTEGER NOT NULL DEFAULT 3,
        image_interval INTEGER NOT NULL DEFAULT 1,
        max_auto_attachments INTEGER NOT NULL DEFAULT 5,
        background_character_anchor INTEGER NOT NULL DEFAULT 1,
        background_memory_anchor INTEGER NOT NULL DEFAULT 1,
        background_deletion_confirm INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE user_profile (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        name TEXT NOT NULL DEFAULT '',
        avatar_base64 TEXT
      )
    ''');
  await db.execute('''
      CREATE TABLE regex_scripts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        find_regex TEXT NOT NULL,
        replace TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''');
  await db.execute('''
      CREATE TABLE image_styles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        artist TEXT,
        sampler TEXT,
        noise_schedule TEXT,
        scale INTEGER,
        cfg INTEGER,
        negative TEXT
      )
    ''');

  // 全新安装:种入内置默认预设提示词(全部启用)。
  await _seedDefaultPresets(db);
  // 全新安装:种入默认 Hook(main/jump 输入改写)。
  await _seedDefaultHooks(db);
  // 全新安装:种入默认 LLM provider(deepseek 官网 + deepseek-flash,1M 上下文)。
  await _seedDefaultLlmProvider(db);
  // 全新安装:种入默认正则脚本(斜体动作/时间戳胶囊,管理页可见可关)。
  await _seedDefaultRegexScripts(db);
  // 全新安装:种入两个内置生图协议插件(对话式网关 / Nai2API,取代旧 Dart 后端)。
  await _seedImagePlugins(db);
  // 消息窗口查询索引:messages 按 session_id + seq 倒序取页。
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_messages_session_seq ON messages(session_id, seq DESC)',
  );
}
