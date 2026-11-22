/// 外部图片字节进入文件资产库的统一入口:先缩图,再内容寻址落盘。
library;

import 'dart:typed_data';

import 'database.dart';
import 'image_codec.dart';
import 'shrink_image.dart';

/// 缩图并写入零引用资产,返回 SHA-256;业务仓储随后在事务内 acquire。
/// 坏图/空输入返回 null,格式与大小约束由 ImageAssetStore 继续校验。
Future<String?> assetizeImageBytes(
  AppDatabase db,
  Uint8List? bytes, {
  int maxDim = 1024,
}) async {
  final shrunk = await shrinkImageBytesToBytes(bytes, maxDim: maxDim);
  if (shrunk == null) return null;
  return (await db.images.putBytes(shrunk)).hash;
}

/// 外部协议 base64 的边界适配;解码后立即进入字节主链路。
Future<String?> assetizeBase64Image(
  AppDatabase db,
  String? base64, {
  int maxDim = 1024,
}) async {
  final bytes = safeBase64Decode(base64);
  if (bytes == null) return null;
  return assetizeImageBytes(db, bytes, maxDim: maxDim);
}
