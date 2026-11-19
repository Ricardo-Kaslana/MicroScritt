/// 制卡草稿文件:按目标角色存放未完成的审阅提案。
///
/// 不进数据库(改 schema 会触发整库归档重建);与配置/UI 偏好同目录,
/// 独立 JSON 文件 + 原子替换。解析/写入一律 fail-safe,草稿损坏只影响恢复。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/data_root.dart';

/// `card-studio-draft-<id|new>.json` 的读写入口。
class CardStudioDraftFile {
  static const int formatVersion = 1;
  static const String _prefix = 'card-studio-draft-';

  /// 编码后上限:超过则放弃草稿持久化(大卡 raw 已排除,这里兜底病态数据),
  /// 避免每次编辑都重复写超大文件。
  static const int maxPayloadChars = 8 * 1024 * 1024;

  final String dir;

  /// 串行写队列:决策连续变化会排队落盘;删除也走同一队列,保证
  /// 「先写后删」的最终状态是删除,不会被迟到写复活。
  Future<void> _writes = Future<void>.value();

  CardStudioDraftFile(this.dir);

  /// 与数据库同目录:桌面端固定数据根优先,移动端回退应用私有 Documents。
  static Future<CardStudioDraftFile> openDefault() async {
    final fixed = DataRoot.desktopDir();
    final dir = fixed ?? (await getApplicationDocumentsDirectory()).path;
    return CardStudioDraftFile(dir);
  }

  String pathFor(int? characterId) =>
      p.join(dir, '$_prefix${characterId?.toString() ?? 'new'}.json');

  /// 读取草稿负载;先等待在队写入完成,保证退出后立刻重进读到最新快照。
  Future<Map<String, dynamic>?> read(int? characterId) async {
    await _writes;
    try {
      final file = File(pathFor(characterId));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != formatVersion) return null;
      final payload = decoded['payload'];
      if (payload is! Map<String, dynamic>) return null;
      return payload;
    } catch (e) {
      debugPrint('制卡草稿读取失败(已忽略):$e');
      return null;
    }
  }

  /// 原子写(临时文件 + 替换),按调用顺序串行执行;失败只打日志。
  Future<void> write(int? characterId, Map<String, dynamic> payload) {
    final result = _writes.then((_) => _writeNow(characterId, payload));
    _writes = result;
    return result;
  }

  Future<void> _writeNow(int? characterId, Map<String, dynamic> payload) async {
    try {
      final text = jsonEncode({
        'version': formatVersion,
        'savedAt': DateTime.now().toIso8601String(),
        'target': characterId,
        'payload': payload,
      });
      if (text.length > maxPayloadChars) {
        debugPrint('制卡草稿超过 $maxPayloadChars 字符上限，已跳过保存');
        return;
      }
      final target = File(pathFor(characterId));
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } catch (e) {
      debugPrint('制卡草稿写入失败(已忽略):$e');
    }
  }

  /// 删除草稿;同样排队,确保不会早于已入队的写入执行。
  Future<void> clear(int? characterId) {
    final result = _writes.then((_) => _clearNow(characterId));
    _writes = result;
    return result;
  }

  Future<void> _clearNow(int? characterId) async {
    try {
      final file = File(pathFor(characterId));
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('制卡草稿清理失败(已忽略):$e');
    }
  }
}
