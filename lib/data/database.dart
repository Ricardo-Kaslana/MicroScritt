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

part 'database_schema.dart';
part 'database_seeds.dart';

/// 应用数据库句柄:持有 sqflite 连接、基线版本与跨仓库事务入口。
///
/// schema(建表)与 seeds(默认数据)拆在同库 part 文件中,共享本库导入与
/// 库私有作用域。
class AppDatabase {
  final Database db;
  AppDatabase(this.db);

  /// 当前基线 schema 版本。历史版本(v1–v60)的增量迁移链已随 2.0 重置移除:
  /// 检测到旧版本库时不再逐级升级,而是归档原文件后按本基线重建(见 [open])。
  /// v63 起新增生图插件表及 provider 的插件关联/动态设置列。
  /// v64 起把两个内置生图协议(对话式网关 / Nai2API)改写为仓库自带插件,
  /// 全新建库幂等种入 `image_plugins` 两行;旧库按既定规则归档重建。
  /// v65 起 messages 保存生图原始描述(`image_prompt`),供图片重新生成。
  /// v66 起变量支持三档后台权限、回收站与待确认删除;新增
  /// `variable_trash` / `variable_deletion_proposals` 两张表。
  static const int schemaVersion = 66;

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
  /// 搬迁 → 检测旧版本库并归档 → 按 [schemaVersion] 打开。
  ///
  /// [factory] 供测试注入内存库;显式传 [path] 的调用方自管位置(跳过搬迁)。
  /// 降级打开是空操作 —— 旧版本库已在打开前归档重建,正常流程不会走到这里。
  static Future<AppDatabase> open({
    DatabaseFactory? factory,
    String? path,
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
    return AppDatabase(db);
  }

  /// 旧版本(2.0 之前)库检测与归档:用不带版本管理的裸连接读
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
      '[db] 检测到 2.0 之前的数据库(v$oldVersion),'
      '已归档到 $archived,已按 v$schemaVersion 重建新库',
    );
  }

  static Future<void> _onCreate(Database db, int version) => _createSchema(db);
}
