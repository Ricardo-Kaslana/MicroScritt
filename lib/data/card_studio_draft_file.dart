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
import 'image_asset_store.dart';

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

  /// 读取草稿负载;先等待在队写入与写后对账完成,保证调用方看到一致快照。
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

  /// 原子写(临时文件 + 替换),按调用顺序串行执行;失败只打日志并返回 false。
  ///
  /// [afterWrite] 在文件成功后、下一项写/删操作前执行,供控制器把文件里的
  /// 资产持有清单与数据库引用计数对账;对账失败同样返回 false,调用方可重试。
  Future<bool> write(
    int? characterId,
    Map<String, dynamic> payload, {
    Future<void> Function()? afterWrite,
  }) {
    final result = _writes.then(
      (_) => _writeNow(characterId, payload, afterWrite: afterWrite),
    );
    _writes = result.then<void>((_) {});
    return result;
  }

  Future<bool> _writeNow(
    int? characterId,
    Map<String, dynamic> payload, {
    Future<void> Function()? afterWrite,
  }) async {
    try {
      final text = jsonEncode({
        'version': formatVersion,
        'savedAt': DateTime.now().toIso8601String(),
        'target': characterId,
        'payload': payload,
      });
      if (text.length > maxPayloadChars) {
        debugPrint('制卡草稿超过 $maxPayloadChars 字符上限,已跳过保存');
        return false;
      }
      final target = File(pathFor(characterId));
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      if (afterWrite != null) await afterWrite();
      return true;
    } catch (e) {
      debugPrint('制卡草稿写入或引用对账失败(已忽略):$e');
      return false;
    }
  }

  /// 扫描目录内全部 v1 草稿并报告单文件失败。
  ///
  /// 返回值同时携带「是否有单文件扫描失败」:实现
  /// `ImageAssetExternalReferences`,启动维护在失败时跳过零引用回收。
  ///
  /// 先等待在队写入,保证读到落定快照;`*.json.tmp` 与版本不符的文件跳过。
  /// 坏文件不再静默丢弃:从原始文本宽松提取 64 位十六进制哈希(宁可多保护
  /// 也不能让恢复后的草稿缺图),同时记入 [CardStudioDraftScan.failedFiles]。
  /// 返回的原始字符串由资产库侧再过滤非法哈希,这里只去首尾空白并丢弃空串。
  Future<CardStudioDraftScan> scanHeldAssetHashSets() async {
    await _writes;
    final sets = <Set<String>>[];
    final failed = <String>[];
    final directory = Directory(dir);
    if (!await directory.exists()) {
      return CardStudioDraftScan(sets: sets, failedFiles: failed);
    }
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(_prefix) || !name.endsWith('.json')) continue;
        String rawText;
        try {
          rawText = await entity.readAsString();
        } catch (e) {
          debugPrint('制卡草稿资产扫描失败(已跳过 $name):$e');
          failed.add(name);
          continue;
        }
        try {
          final decoded = jsonDecode(rawText);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('草稿根节点不是对象');
          }
          if (decoded['version'] != formatVersion) continue;
          final payload = decoded['payload'];
          if (payload is! Map<String, dynamic>) {
            throw const FormatException('草稿 payload 不是对象');
          }
          final held = <String>{};
          final raw = payload['heldAssetHashes'];
          if (raw is List) {
            for (final item in raw) {
              if (item is! String) continue;
              final hash = item.trim();
              if (hash.isNotEmpty) held.add(hash);
            }
          }
          sets.add(held);
        } catch (e) {
          debugPrint('制卡草稿资产扫描失败(已降级提取 $name):$e');
          failed.add(name);
          final salvaged = _salvageHeldHashes(rawText);
          if (salvaged.isNotEmpty) sets.add(salvaged);
        }
      }
    } catch (e) {
      debugPrint('制卡草稿目录扫描失败(已中止):$e');
      rethrow;
    }
    return CardStudioDraftScan(sets: sets, failedFiles: failed);
  }

  /// 从坏草稿文本里尽量捞回被持有的资产哈希,避免对账把它们当零引用回收。
  static Set<String> _salvageHeldHashes(String text) {
    final hashes = <String>{};
    final anyHash = RegExp(r'"([0-9a-f]{64})"');
    for (final match in anyHash.allMatches(text)) {
      final hash = match.group(1);
      if (hash != null) hashes.add(hash);
    }
    return hashes;
  }

  /// 删除草稿;同样排队,确保不会早于已入队的写入执行。失败返回 false。
  Future<bool> clear(int? characterId) {
    final result = _writes.then((_) => _clearNow(characterId));
    _writes = result.then<void>((_) {});
    return result;
  }

  Future<bool> _clearNow(int? characterId) async {
    try {
      final file = File(pathFor(characterId));
      if (await file.exists()) await file.delete();
      return true;
    } catch (e) {
      debugPrint('制卡草稿清理失败(已忽略):$e');
      return false;
    }
  }
}

/// 一次制卡草稿资产扫描的结果。
///
/// 实现 [ImageAssetExternalReferences]:`complete` 为 false 表示至少有一个
/// 草稿文件读取/解析失败,启动维护必须跳过本轮零引用回收(失败文件里可能
/// 还持有未被宽限提取到的哈希)。
class CardStudioDraftScan implements ImageAssetExternalReferences {
  @override
  final List<Set<String>> sets;

  /// 读取或解析失败的文件名。
  final List<String> failedFiles;

  const CardStudioDraftScan({required this.sets, this.failedFiles = const []});

  /// 是否有文件读取/解析失败。
  bool get hadFailures => failedFiles.isNotEmpty;

  @override
  bool get complete => failedFiles.isEmpty;
}
