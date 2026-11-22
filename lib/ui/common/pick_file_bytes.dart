/// 文件选择的字节/路径读取与单文件大小上限。
///
/// `file_picker` 的 bytes 通道在 Android 走原生一次性整读,大文件会 OOM 或
/// 静默失败;因此调用方关掉 `withData` 只给路径,这里读 path 并统一执行
/// [kMaxPickedFileBytes] 上限。会话归档等超大文件另走 [pickedFilePath]。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 单次导入/选图可接受的文件大小上限:整个文件要读进 Dart 堆再解析,不设
/// 上限时误选/恶意超大文件直接 OOM。50MB 对角色卡(几百 KB~几 MB)、世界书、
/// 生图插件与照片头像都绰绰有余;超限抛 [FormatException],调用方的导入
/// try/catch 会把提示原样吐给用户。会话归档不受此限,另走 [pickedFilePath]。
const int kMaxPickedFileBytes = 50 * 1024 * 1024;

/// 从一次文件选择结果中拿到完整字节。
///
/// 移动端必须走 `withData: false` + 读 [PlatformFile.path]:file_picker 的
/// Android 实现(`FileUtils.loadData`)会用原生 `ByteArray(file.length())`
/// 一次性把整个文件装进内存 —— 大文件会 OOM(或负数长度截断),并且在 catch
/// 里**静默丢弃字节**(`bytes` 返回 null,调用方毫不知情地失败);桌面读文件
/// 不经过这段原生代码,所以同样的"大文件"只有移动端导入失败。插件在 Android
/// 会把选中的文件复制进应用缓存并返回该 path,直接读 path 即可(字节流进
/// Dart 堆,可被 GC 管理,不占原生堆配额,大文件也稳)。
///
/// 选择结果里已有 `bytes`(少数平台/调用方显式要了 withData)时直接使用。
Future<Uint8List?> pickedFileBytes(
  PlatformFile? file, {
  void Function(int read, int total)? onProgress,
}) async {
  if (file == null) return null;
  final bytes = file.bytes;
  if (bytes != null) {
    if (bytes.length > kMaxPickedFileBytes) {
      throw const FormatException('文件过大(超过 50MB),已取消读取');
    }
    onProgress?.call(bytes.length, bytes.length);
    return Uint8List.fromList(bytes);
  }
  final path = file.path;
  if (path == null) return null;
  try {
    final f = File(path);
    final total = await f.length();
    if (total > kMaxPickedFileBytes) {
      throw const FormatException('文件过大(超过 50MB),已取消读取');
    }
    if (onProgress == null) return await f.readAsBytes();
    // 20MB 级大卡整读也要几百毫秒;分块读顺便把进度喂给导入对话框。
    final builder = BytesBuilder(copy: false);
    await for (final chunk in f.openRead()) {
      builder.add(chunk);
      onProgress(builder.length, total);
    }
    return builder.takeBytes();
  } on FileSystemException {
    return null;
  }
}

/// 会话归档专用:只拿文件**路径**,不整读字节、也不设 50MB 上限 ——
/// 归档可能几百 MB,读取端必须边扫边解析(见 SessionArchiveReader)。
///
/// 极少数平台只给内联 bytes 时,落到应用临时目录下的 `imports/` 受管理文件;
/// 调用方导入结束后必须调用 [PickedSessionFile.deleteIfTemporary] 清理
/// (异常路径同样要清理),崩溃残留由一天后的清扫兜底。
Future<PickedSessionFile?> pickedFilePath(PlatformFile? file) async {
  if (file == null) return null;
  final path = file.path;
  if (path != null && path.isNotEmpty) return PickedSessionFile(path);
  final bytes = file.bytes;
  if (bytes == null) return null;
  final dir = Directory(
    p.join((await getTemporaryDirectory()).path, 'imports'),
  );
  await dir.create(recursive: true);
  await _purgeOldImports(dir);
  final isZip = bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4b;
  final target = File(
    p.join(
      dir.path,
      'picked-${DateTime.now().microsecondsSinceEpoch}.'
      '${isZip ? 'msarc' : 'json'}',
    ),
  );
  try {
    await target.writeAsBytes(bytes, flush: true);
  } catch (_) {
    // 写一半失败时不留半截临时档。
    try {
      if (await target.exists()) await target.delete();
    } catch (_) {}
    rethrow;
  }
  return PickedSessionFile(target.path, temporary: true);
}

/// 会话导入选中的文件:实际路径 + 是否需要导入后清理。
class PickedSessionFile {
  /// 本地文件路径。
  final String path;

  /// true 表示该文件是 [pickedFilePath] 为内联 bytes 写出的临时归档。
  final bool temporary;

  const PickedSessionFile(this.path, {this.temporary = false});

  /// 删除本次导入创建的临时归档(用户自己的文件绝不删除)。
  Future<void> deleteIfTemporary() async {
    if (!temporary) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理失败只留下临时档,一天后的清扫会回收。
    }
  }
}

/// 清理一天前异常退出遗留的内联字节临时档。
Future<void> _purgeOldImports(Directory dir) async {
  final now = DateTime.now();
  try {
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      if (now.difference(stat.modified) > const Duration(hours: 24)) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  } catch (_) {}
}