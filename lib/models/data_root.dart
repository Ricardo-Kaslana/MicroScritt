/// 应用数据根目录的统一解析。
///
/// data 层与 backend 层共用;按分层约定放在 `lib/models/`,两侧互不 import。
library;

import 'dart:io';
import 'package:path/path.dart' as p;

/// 应用数据根目录的统一解析(data 层与 backend 层共用;按分层家规经
/// `lib/models/` 对接,两侧互不 import)。
///
/// 桌面端(Windows/Linux/macOS)固定为用户主目录下的 `.microscritt`:
/// 数据库与图片缓存集中在一个用户可见、可整体备份/删除的位置,且不受
/// Windows「文档」库重定向(OneDrive 等)与 AppData 漫游策略影响。
/// 移动端没有用户可自由选择的目录概念,返回 null —— 调用方回退到各自
/// 的 path_provider 目录(应用私有),行为与历史一致。
class DataRoot {
  DataRoot._();

  /// 固定目录名(位于用户主目录下)。
  static const String dirName = '.microscritt';

  /// 测试注入;非 null 时 [desktopDir] 原样返回(平台判定一并跳过)。
  static String? overrideDir;

  /// 桌面端的固定数据根目录;移动端或解析不到主目录时返回 null。
  static String? desktopDir() {
    final o = overrideDir;
    if (o != null) return o;
    if (Platform.isAndroid || Platform.isIOS) return null;
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return p.join(home, dirName);
  }
}
