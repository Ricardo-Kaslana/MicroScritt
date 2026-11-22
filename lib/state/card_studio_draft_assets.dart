/// 制卡草稿图片引用的差集对账与清理。
///
/// 草稿文件记录自身持有的哈希,数据库只保存聚合计数;恢复时直接接管清单,
/// 不在每次启动或重写时重复 acquire。物理文件仍统一由资产库延迟回收。
library;

import 'package:flutter/foundation.dart';

import '../data/card_studio_draft_file.dart';
import '../data/database.dart';
import '../data/image_asset_store.dart';
import 'card_studio_draft_codec.dart';

/// 把一次成功落盘前后的持有集合对账到数据库,整个过程只使用一个事务。
Future<void> reconcileCardStudioDraftReferences(
  AppDatabase db, {
  required Set<String> previous,
  required Set<String> desired,
}) async {
  final before = previous.where(ImageAssetStore.isValidHash).toSet();
  final next = desired.where(ImageAssetStore.isValidHash).toSet();
  if (before.length == next.length && before.containsAll(next)) return;
  await db.transaction((txn) async {
    for (final hash in next.difference(before)) {
      await db.images.acquire(txn, hash);
    }
    for (final hash in before.difference(next)) {
      await db.images.release(txn, hash);
    }
  });
}

/// 删除目标草稿并释放它持有的引用;返回是否完成全部清理。
///
/// 文件删除失败时保留引用,避免仍可恢复的草稿失去图片。数据库释放失败时
/// 文件已经删除,返回 false 让仍存活的控制器保留内存账本并可再次尝试。
Future<bool> clearCardStudioDraftAndRelease(
  AppDatabase db,
  CardStudioDraftFile file,
  int? targetCharacterId, {
  Set<String>? trackedHashes,
}) async {
  final payload = await file.read(targetCharacterId);
  final snapshot = payload == null ? null : decodeCardStudioDraft(payload);
  final held = snapshot?.heldAssetHashes ?? trackedHashes;
  if (!await file.clear(targetCharacterId)) return false;
  if (held == null || held.isEmpty) return true;
  try {
    await db.transaction((txn) async {
      for (final hash in held.toSet()) {
        if (ImageAssetStore.isValidHash(hash)) {
          await db.images.release(txn, hash);
        }
      }
    });
    return true;
  } catch (e) {
    debugPrint('制卡草稿图片引用释放失败(已忽略):$e');
    return false;
  }
}
