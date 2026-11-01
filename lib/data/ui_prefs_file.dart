/// 轻量 UI 偏好文件 `ui-prefs.json` 的读写。
///
/// 与数据库、配置文件同目录:独立成文件,避免被配置快照覆盖,也避免为
/// 布局开关升级 schema。解析与写入一律 fail-safe。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/data_root.dart';
import '../models/ui_prefs.dart';

/// UI 偏好文件的访问入口;内存表示为 [UiPrefs]。
///
/// 单独成文件的原因:`microscritt-config.json` 每次保存都按库重建,UI 偏好
/// 混进去会被反复覆盖;而给 `app_settings` 加列意味着改 schema,本项目
/// 的升级路径是归档重建整个库,不值得为一个布局开关丢聊天数据。
class UiPrefsFile {
  static const String fileName = 'ui-prefs.json';
  static const int formatVersion = 1;

  final String path;
  const UiPrefsFile(this.path);

  /// 与数据库同目录:桌面端固定数据根优先,移动端回退应用私有 Documents。
  static Future<UiPrefsFile> openDefault() async {
    final fixed = DataRoot.desktopDir();
    final dir = fixed ?? (await getApplicationDocumentsDirectory()).path;
    return UiPrefsFile(p.join(dir, fileName));
  }

  /// 读取偏好;文件缺失或解析失败回落默认值并打日志,启动不因此中断。
  Future<UiPrefs> read() async {
    try {
      final file = File(path);
      if (!await file.exists()) return const UiPrefs();
      return UiPrefs.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      debugPrint('UI 偏好读取失败(已回落默认):$e');
      return const UiPrefs();
    }
  }

  /// 原子写(临时文件 + 替换);写失败只打日志,绝不影响 UI 操作。
  Future<void> write(UiPrefs prefs) async {
    try {
      final text = const JsonEncoder.withIndent('  ').convert({
        'version': formatVersion,
        'characterLayout': prefs.characterLayout.wire,
      });
      final target = File(path);
      await target.parent.create(recursive: true);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(text, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(path);
    } catch (e) {
      debugPrint('UI 偏好写入失败(已忽略):$e');
    }
  }
}
