// 测试数据库工厂:内存库 + 清空种子,让仓库/UI 测试从稳定空状态起步。
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/llm_provider_repository.dart';
import 'package:microscritt/data/regex_script_repository.dart';

Future<AppDatabase> openTestDb() async {
  sqfliteFfiInit();
  final db = await AppDatabase.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
  // 测试统一从"未配置任何 LLM provider"的干净状态起步:默认 provider
  // (deepseek 官网 + deepseek-flash)的种入是产品行为,由 database 的
  // 全新建库/迁移测试单独覆盖;这里清空,既有仓库/UI 测试的"空 provider"
  // 契约保持不变。
  final repo = LlmProviderRepository(db);
  for (final p in await repo.all()) {
    await repo.deleteProvider(p.id);
  }
  // 同理:v30 起种入的默认正则脚本(斜体动作/时间戳胶囊)也在此清空,
  // 仓库/气泡测试保持"无脚本"契约;种入本身由迁移测试覆盖。
  final scriptRepo = RegexScriptRepository(db);
  for (final s in await scriptRepo.all()) {
    await scriptRepo.delete(s.id!);
  }
  // v64 起种入的两个内置生图协议插件同样清空,让插件仓储/管理页测试从
  // "无插件"契约起步;种入本身由 database_open_test 覆盖。
  await db.db.delete('image_plugins');
  return db;
}
