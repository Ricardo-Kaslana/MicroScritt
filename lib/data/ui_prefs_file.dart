import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/data_root.dart';
import '../models/ui_prefs.dart';

/// 轻量 UI 偏好文件(与数据库、`microscritt-config.json` 同目录):目前只存
/// 角色列表布局。
///
/// 单独成文件的原因:`microscritt-config.json` 是用户名/LLM provider 的权威
/// 快照,每次保存都按库重建,UI 偏好混进去会被反复覆盖;而 `app_settings`
/// 加列会触发 schema 升级 —— 本项目升级会归档重建整个库,不值得为一个
/// 布局开关丢聊天数据。
///
/// 解析一律 fail-safe:坏文件/未知值回落默认,启动不因偏好文件失败。
class UiPrefsFile {
  static const String fileName = 'ui-prefs.json';
  static const int formatVersion = 1;

  final String path;
  const UiPrefsFile(this.path);

  static Future<UiPrefsFile> openDefault() async {
    final fixed = DataRoot.desktopDir();
    final dir = fixed ?? (await getApplicationDocumentsDirectory()).path;
    return UiPrefsFile(p.join(dir, fileName));
  }

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
