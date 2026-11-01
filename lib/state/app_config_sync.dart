/// 配置文件回写:把用户名与 LLM provider 快照同步到 `microscritt-config.json`。
///
/// 文件是启动时权威、运行期由 UI 写回;provider 为空(测试/未注入)时跳过,
/// 写失败只打日志,绝不让配置文件问题影响数据库保存流程。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// 把当前用户名与 LLM provider 快照写回固定配置文件。
///
/// 文件 provider 为空(测试/未注入)时直接返回;写失败只打日志 —— 配置文件
/// 是备份/可编辑副本,绝不让它影响正常保存流程。
Future<void> syncAppConfigFile(WidgetRef ref) async {
  final file = ref.read(appConfigFileProvider);
  if (file == null) return;
  try {
    await file.writeSnapshot(ref.read(databaseProvider));
  } catch (e) {
    debugPrint('配置文件同步失败:$e');
  }
}
