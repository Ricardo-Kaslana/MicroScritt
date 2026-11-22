/// 数据库打开与生命周期入口:`AppDatabase` 及同库的 schema/seeds 两个 part。
///
/// 单一基线:旧版本库归档后按基线重建,不保留增量迁移链;桌面端数据根固定
/// 在 `~/.microscritt`,移动端沿用应用私有 Documents 目录。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/data_root.dart';
import '../models/hook_seeds.dart';
import '../models/image_plugin_seeds.dart';
import '../models/prompt_seeds.dart';
import '../models/regex_script_seeds.dart';
import 'image_asset_store.dart';

part 'database_schema.dart';
part 'database_seeds.dart';

/// 应用数据库句柄:持有 sqflite 连接、基线版本与跨仓库事务入口。
///
/// schema(建表)与 seeds(默认数据)拆在同库 part 文件中,共享本库导入与
/// 库私有作用域。
class AppDatabase {
  final Database db;
  final String imageRootPath;
  late final ImageAssetStore images = ImageAssetStore(db, imageRootPath);

  AppDatabase(this.db, {String? imageRootPath})
    : imageRootPath =
          imageRootPath ??
          (db.path == inMemoryDatabasePath
              ? p.join(
                  Directory.systemTemp.path,
                  'microscritt-images-${identityHashCode(db)}',
                )
              : p.join(p.dirname(db.path), 'images'));

  /// 当前基线 schema 版本。历史版本(v1–v60)的增量迁移链已随 2.0 重置移除:
  /// 检测到旧版本库时不再逐级升级,而是归档原文件后按本基线重建(见 [open])。
  /// v63 起新增生图插件表及 provider 的插件关联/动态设置列。
  /// v64 起把两个内置生图协议(对话式网关 / Nai2API)改写为仓库自带插件,
  /// 全新建库幂等种入 `image_plugins` 两行;旧库按既定规则归档重建。
  /// v65 起 messages 保存生图原始描述(`image_prompt`),供图片重新生成。
  /// v66 起变量支持三档后台权限、回收站与待确认删除;新增
  /// `variable_trash` / `variable_deletion_proposals` 两张表。
  /// v67 起会话支持置顶(`pinned_at` 记录置顶时间,空值表示未置顶)。
  /// v68 起自动压缩触发线可配置(`app_settings.auto_compact_threshold`,
  /// 默认 0.6,范围 30%–90%)。
  /// v69 起新增逐请求用量明细表 `usage_records`(全量统计面板与导出)。
  /// v70 起移除历史遗留端点兼容选项(`llm_providers.compat_flags` 列删除)。
  /// v71 起后台运行模式可配置(`app_settings.background_mode`:
  /// legacy/agentic/hybrid,坏值回落 legacy,默认零行为变化)。
  /// v72 起图片字节迁入内容寻址文件资产库,业务表只保存 SHA-256 哈希。
  /// v73 起新入库图片可选择在写入前压缩(`app_settings.compress_images`,
  /// 默认关;长边上限 2048,GIF 与透明图保留格式)。
  /// v74 起 Agentic 后台可选两增强(`app_settings.background_variable_injection`
  /// / `background_next_suggestions`,默认关):变量注入主写附件、下一步建议。
  /// v75 起为高频筛选列补索引(`sessions.character_id` /
  /// `worldbook_entries.character_id` / `llm_models.provider_id` /
  /// `image_providers.plugin_id`),角色会话、世界书、模型与插件引用查询
  /// 不再全表扫描。
  static const int schemaVersion = 75;

  /// 在单个事务里执行 [action](供编排器等跨多个 repository 的原子写入用)。
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) =>
      db.transaction(action);

  /// 测试注入「文档目录」(2.1 及以前桌面端的默认数据位置);null 时走
  /// path_provider。旧位置自动搬迁的测试依赖此钩子注入假想的旧目录。
  static Future<Directory> Function()? documentsDirOverride;

  static Future<Directory> _documentsDir() async {
    final o = documentsDirOverride;
    if (o != null) return o();
    return getApplicationDocumentsDirectory();
  }

  /// 默认数据库文件路径:桌面端固定在 `~/.microscritt`,移动端沿用应用
  /// 私有 Documents 目录(见 [DataRoot])。
  static Future<String> _defaultDbPath() async {
    final fixed = DataRoot.desktopDir();
    if (fixed != null) return p.join(fixed, 'microscritt.db');
    return p.join((await _documentsDir()).path, 'microscritt.db');
  }

  /// 旧位置一次性搬迁(2.2:桌面端数据位置固定到 `~/.microscritt`):新
  /// 位置还没有主库文件、而旧默认位置(Documents)有时,把主库与 SQLite
  /// 伴生文件一并**移动**过去 —— 移动而非复制,避免两份数据各自演化。
  /// 旧图片缓存不迁移(可再生的缓存,留在原处可手动删除)。
  ///
  /// 仅在桌面默认路径下触发(显式传 [open] 的 `path` 参数的调用方自管其
  /// 位置);搬迁失败静默跳过,回退「新位置从零开始」—— 旧文件原样保留,
  /// 任何情况下不丢数据。
  static Future<void> _migrateFromLegacyLocation(String dbPath) async {
    try {
      if (DataRoot.desktopDir() == null) return;
      if (await File(dbPath).exists()) return;
      final legacyBase = p.join((await _documentsDir()).path, 'microscritt.db');
      if (!await File(legacyBase).exists()) return;
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final src = File('$legacyBase$suffix');
        if (!await src.exists()) continue;
        final dst = File('$dbPath$suffix');
        try {
          await src.rename(dst.path);
        } on FileSystemException {
          // 跨卷 rename 失败(理论上同在用户主目录下不会发生):退回复制+删除。
          await src.copy(dst.path);
          await src.delete();
        }
      }
    } catch (_) {
      // 迁移是尽力而为:任何失败都回到「新位置空库」路径,旧文件不动。
    }
  }

  /// 打开(必要时创建)数据库。顺序:建父目录 → 桌面默认路径下从旧位置
  /// 搬迁 → 检测旧版本库并归档 → 按 [schemaVersion] 打开 → 回灌旧归档的
  /// 用量明细(统计面板不随升级归零)。
  ///
  /// [factory] 供测试注入内存库;显式传 [path] 的调用方自管位置(跳过搬迁)。
  /// 降级打开是空操作 —— 旧版本库已在打开前归档重建,正常流程不会走到这里。
  static Future<AppDatabase> open({
    DatabaseFactory? factory,
    String? path,
    String? imageRootPath,
  }) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? await _defaultDbPath();
    if (dbPath != inMemoryDatabasePath) {
      // 固定数据根(~/.microscritt)首启时不存在:幂等建目录。
      final dir = Directory(p.dirname(dbPath));
      if (!dir.existsSync()) await dir.create(recursive: true);
    }
    if (path == null) {
      await _migrateFromLegacyLocation(dbPath);
    }
    await _archiveIfLegacy(f, dbPath);
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onDowngrade: (db, oldVersion, newVersion) {},
      ),
    );
    await _salvageUsageRecords(db, dbPath);
    return AppDatabase(db, imageRootPath: imageRootPath);
  }

  /// 旧版本库检测与归档:用不带版本管理的裸连接读
  /// `PRAGMA user_version`,版本在 (0, schemaVersion) 区间即旧库 —— 把主
  /// 文件与 journal 伴生文件一并改名归档(数据不删,用户可另行处理),随后的
  /// 正常打开按基线 onCreate 重建全新库。内存库与不存在的文件无可归档。
  static Future<void> _archiveIfLegacy(DatabaseFactory f, String dbPath) async {
    if (dbPath == inMemoryDatabasePath || !File(dbPath).existsSync()) return;
    final probe = await f.openDatabase(dbPath);
    final rows = await probe.rawQuery('PRAGMA user_version');
    final oldVersion = rows.isEmpty
        ? 0
        : (rows.first.values.first as int? ?? 0);
    await probe.close();
    if (oldVersion > schemaVersion) {
      // 旧版应用打开更高版本库会按自认的基线写入,可能破坏未知 schema。
      throw StateError(
        '数据库版本 v$oldVersion 高于当前应用支持的 v$schemaVersion,请升级应用后再打开',
      );
    }
    if (oldVersion <= 0 || oldVersion >= schemaVersion) return;

    final dir = p.dirname(dbPath);
    final base = p.basenameWithoutExtension(dbPath);
    final ext = p.extension(dbPath);
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final archived = p.join(dir, '$base-legacy-v$oldVersion-$stamp$ext');
    await File(dbPath).rename(archived);
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final side = p.join(dir, '$base$ext$suffix');
      if (File(side).existsSync()) {
        await File(side).rename('$archived$suffix');
      }
    }
    // ignore: avoid_print
    print(
      '[db] 检测到旧版本数据库(v$oldVersion,当前基线 v$schemaVersion),'
      '已归档到 $archived,已按基线重建新库',
    );
  }

  /// `usage_records` 的列集合。回灌只拷贝新旧库共有的列:旧归档缺列时让新库
  /// 默认值兜底,未来新增列也不会中断拷贝。
  static const List<String> _usageRecordColumns = [
    'id',
    'session_id',
    'kind',
    'provider_id',
    'provider_name',
    'model',
    'model_name',
    'input_tokens',
    'output_tokens',
    'cached_input_tokens',
    'reported',
    'created_at',
  ];

  /// 归档文件旁的一次性回灌标记后缀。
  static const String _usageSalvageMarkerSuffix = '.usage-salvaged';

  /// 从同目录的旧库归档回灌逐请求用量明细。
  ///
  /// 版本升级会按基线整库重建,`usage_records` 若随旧库一起留在归档里,统计
  /// 面板就会从零开始。逐请求用量是纯历史账,不与业务表耦合,可以安全地搬进
  /// 新库;这里扫描所有尚未处理的 `*-legacy-v*.db` 归档(含本特性上线之前
  /// 遗留的),把其中存在的 `usage_records` 按 id 幂等并入当前库,再用同名
  /// `.usage-salvaged` 标记保证每份归档只回灌一次。
  ///
  /// 统计是附加信息:任何失败只打日志、不写标记,下次启动重试,绝不阻塞启动。
  static Future<void> _salvageUsageRecords(Database db, String dbPath) async {
    if (dbPath == inMemoryDatabasePath) return;
    final dir = Directory(p.dirname(dbPath));
    final base = p.basenameWithoutExtension(dbPath);
    final ext = p.extension(dbPath);
    if (ext.isEmpty || !dir.existsSync()) return;
    final List<String> archives;
    try {
      archives = [
        for (final entity in dir.listSync())
          if (entity is File &&
              p.basename(entity.path).startsWith('$base-legacy-v') &&
              entity.path.endsWith(ext))
            entity.path,
      ]..sort();
    } catch (_) {
      return;
    }
    for (final archive in archives) {
      final marker = File('$archive$_usageSalvageMarkerSuffix');
      if (marker.existsSync()) continue;
      if (!await _salvageUsageArchive(db, archive)) continue;
      try {
        await marker.writeAsString('', flush: true);
      } catch (_) {
        // 标记写入失败只会导致下次重复回灌:INSERT OR IGNORE 按 id 幂等。
      }
    }
  }

  /// 回灌单个归档。返回 true 表示已处理完毕(成功,或确认没有可回灌的用量
  /// 表),可以写一次性标记;false 表示暂时失败,下次启动重试。
  static Future<bool> _salvageUsageArchive(
    Database db,
    String archivePath,
  ) async {
    const alias = 'legacy_usage';
    try {
      await db.execute('ATTACH DATABASE ? AS $alias', [archivePath]);
    } catch (_) {
      return false;
    }
    try {
      final exists = await db.rawQuery(
        "SELECT name FROM $alias.sqlite_master "
        "WHERE type = 'table' AND name = 'usage_records'",
      );
      if (exists.isEmpty) return true;
      final available = (await db.rawQuery(
        'PRAGMA $alias.table_info(usage_records)',
      )).map((row) => row['name'] as String? ?? '').toSet();
      final columns = [
        for (final column in _usageRecordColumns)
          if (available.contains(column)) column,
      ];
      // 没有时间列的账无法参与按日/按模型统计,视为无可回灌。
      if (!columns.contains('created_at')) return true;
      // 不复制归档 id:此前保 id + INSERT OR IGNORE 在「回灌失败后主库又写入
      // 新行」时会让冲突的历史记录被静默丢弃。按整行自然键去重,id 由新库
      // 自增分配,重复启动仍幂等。
      final dataColumns = [
        for (final column in columns)
          if (column != 'id') column,
      ];
      final list = dataColumns.join(', ');
      final sameRow = dataColumns
          .map((column) => 'dst.$column IS src.$column')
          .join(' AND ');
      await db.execute(
        'INSERT INTO main.usage_records ($list) '
        'SELECT $list FROM $alias.usage_records AS src '
        'WHERE NOT EXISTS ('
        'SELECT 1 FROM main.usage_records AS dst WHERE $sameRow)',
      );
      final changed = (await db.rawQuery(
        'SELECT changes() AS changed',
      )).first['changed'];
      // ignore: avoid_print
      print('[db] 已从归档 ${p.basename(archivePath)} 回灌 ${changed ?? 0} 条用量记录');
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await db.execute('DETACH DATABASE $alias');
      } catch (_) {
        // 连接即将继续使用,残留附件不影响主库;最坏情况下次启动重试。
      }
    }
  }

  static Future<void> _onCreate(Database db, int version) => _createSchema(db);
}
