/// 全屏图片查看页:缩放平移、下载保存与可选的删除入口。
///
/// 展示用 provider 与保存用原始字节解耦:文件资产直接读原图,URL 来源先读
/// 磁盘缓存、再联网;删除由调用方落库,成功后关闭本页。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../backend/disk_image_cache.dart';
import '../../backend/image_downloader.dart';
import '../common/app_snack_bar.dart';
import '../common/confirm_dialog.dart';
import '../common/export_helper.dart';
import '../common/inline_spinner.dart';

/// 全屏查看一张聊天图片:黑底铺满、双指缩放/平移、点击任意处或右上角关闭
/// 按钮退出;右上角附**下载**按钮,可把原始字节存到用户选择的位置。
///
/// [file]、[bytes] 与 [url] 按此顺序择一。文件资产始终以原图 FileImage
/// 降采样展示;URL 与气泡共用磁盘缓存,未命中走网络并后台写盘。
///
/// [onDelete] 非空时右上角额外出现**删除**按钮:确认后执行回调,成功后关闭
/// 本页;聊天气泡传入「清空该消息图片字段」的落库动作,不传则不显示入口。
///
/// 返回的 Future 在全屏页关闭时完成。
Future<void> showImageFullscreen(
  BuildContext context, {
  File? file,
  Uint8List? bytes,
  String? url,
  Future<void> Function()? onDelete,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      // 淡入淡出,不让"切到下一屏"的横滑打断查看;整体遮住聊天页。
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, __, ___) => _ImageViewerPage(
        file: file,
        bytes: bytes,
        url: url,
        onDelete: onDelete,
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// 全屏查看页。StatefulWidget:URL 来源要先异步查磁盘缓存再定 provider。
class _ImageViewerPage extends StatefulWidget {
  final File? file;
  final Uint8List? bytes;
  final String? url;

  /// 确认后从消息中移除这张图的回调;null = 不显示删除入口。
  final Future<void> Function()? onDelete;
  const _ImageViewerPage({
    required this.file,
    required this.bytes,
    required this.url,
    this.onDelete,
  });

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  /// 当前展示用的 provider;null = URL 的磁盘缓存仍在读取(显示转圈)。
  ImageProvider? _provider;

  /// 下载用原始文件;本地资产与 URL 磁盘命中均优先从文件读取。
  File? _fullFile;

  /// 无文件时的原始字节(仅网络尚未落盘或直接内存来源)。
  Uint8List? _fullBytes;

  /// 保存对话框未关闭/正在重取网络字节时,禁止重复点下载。
  bool _downloading = false;

  /// 确认框/删除落库进行中:防止重复触发删除,也让按钮有"处理中"反馈。
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    final file = widget.file;
    final bytes = widget.bytes;
    if (file != null) {
      _provider = _viewSizeFile(file);
      _fullFile = file;
    } else if (bytes != null) {
      _provider = _viewSize(bytes);
      _fullBytes = bytes;
    } else {
      _loadNetwork();
    }
  }

  /// URL 来源:磁盘缓存命中 → FileImage;未命中 → 网络即时展示,同时后台
  /// 下载写盘,写盘成功后切换到稳定的缓存文件 provider。
  Future<void> _loadNetwork() async {
    final url = widget.url;
    if (url == null || !mounted) return;
    try {
      final cached = await DiskImageCache.existingFile(url);
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _provider = _viewSizeFile(cached);
          _fullFile = cached;
        });
        return;
      }
      setState(() => _provider = NetworkImage(url));
      _cacheToDisk(url);
    } catch (_) {
      // 读盘插件缺失/失败:直接走网络,不阻塞查看。
      if (mounted && _provider == null) {
        setState(() => _provider = NetworkImage(url));
      }
    }
  }

  /// 网络字节后台落盘;下载失败静默放弃(本页已用 [NetworkImage] 展示),
  /// 下次查看再重试。
  Future<void> _cacheToDisk(String url) async {
    final bytes = await downloadImageBytes(url);
    if (bytes == null || !mounted) return;
    await DiskImageCache.write(url, bytes);
    final cached = await DiskImageCache.existingFile(url);
    if (!mounted) return;
    setState(() {
      if (cached != null) {
        _provider = _viewSizeFile(cached);
        _fullFile = cached;
        _fullBytes = null;
      } else {
        _provider = _viewSize(bytes);
        _fullBytes = bytes;
      }
    });
  }

  /// 下载当前图片:优先用已有原始字节(本地来源/磁盘缓存/写盘回填);没有时按 URL
  /// 现场重取一次。保存动作交给 [saveChatImage] → [saveBytesFile]。
  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      await saveChatImage(
        context,
        file: _fullFile,
        bytes: _fullBytes,
        url: widget.url,
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// 删除当前图片:先弹确认对话框(复用全局 [showConfirmDialog]),确认后执行
  /// 调用方传入的落库动作,成功即退出全屏回到聊天页 —— 气泡已随列表刷新而
  /// 不再渲染这张图。回调为空时入口不出现,此方法不会被触发。
  Future<void> _delete() async {
    final onDelete = widget.onDelete;
    if (_deleting || onDelete == null) return;
    final confirmed = await showConfirmDialog(
      context,
      title: '删除图片',
      message: '这张图片将从消息中移除,且无法恢复。',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      await onDelete();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 点击图片任意处直接退出;InteractiveViewer 的双指缩放/平移不受影响
          // (它只认 scale/pan 手势,不吞点击)。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 6.0,
              child: _buildContent(),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 删除按钮:仅当调用方提供落库回调时出现(聊天气泡的图);
                    // 确认/执行期间转小圈并禁用,避免重复触发删除。
                    if (widget.onDelete != null)
                      _deleting
                          ? const Padding(
                              padding: EdgeInsets.all(8),
                              child: InlineSpinner(
                                size: 18,
                                color: Colors.white70,
                              ),
                            )
                          : IconButton(
                              tooltip: '删除图片',
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black38,
                              ),
                              color: Theme.of(context).colorScheme.error,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _delete,
                            ),
                    // 下载按钮:下载中显示小转圈并禁用,避免重复触发保存对话框。
                    _downloading
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: InlineSpinner(
                              size: 18,
                              color: Colors.white70,
                            ),
                          )
                        : IconButton(
                            tooltip: '下载图片',
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black38,
                            ),
                            color: Colors.white,
                            icon: const Icon(Icons.download_outlined),
                            onPressed: _download,
                          ),
                    IconButton(
                      tooltip: '关闭',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black38,
                      ),
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final provider = _provider;
    if (provider == null) {
      // 还没定到 provider(URL 磁盘缓存读取中):先转圈。
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    return Image(
      image: provider,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      frameBuilder: (_, child, frame, __) => frame == null
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            )
          : child,
      errorBuilder: (_, __, ___) => const _ViewFailure(),
    );
  }
}

/// 图片加载失败时全屏页的提示(网络 400/解码失败等,只影响查看,不影响气泡)。
class _ViewFailure extends StatelessWidget {
  const _ViewFailure();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
          SizedBox(height: 12),
          Text('图片加载失败', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

/// 全屏查看的解码上限:宽高都封顶 2560 —— 聊天图多为 1216px、2K 重导出图
/// 不损失肉眼细节;竖图/4K 巨图也不会只按宽度解出超高的帧(2160×3840 只按
/// 宽解码是 ~33MB,双向封顶后 ≤ 2560²)。policy=fit 保证比例不变、不放大小图。
ImageProvider _viewSize(Uint8List bytes) => ResizeImage(
  MemoryImage(bytes),
  width: 2560,
  height: 2560,
  policy: ResizeImagePolicy.fit,
);

/// 文件资产与 URL 磁盘命中共用原图文件路径,全屏不经过聊天预览。
ImageProvider _viewSizeFile(File file) => ResizeImage(
  FileImage(file),
  width: 2560,
  height: 2560,
  policy: ResizeImagePolicy.fit,
);

/// 按图片魔数推断扩展名(下载保存用;识别不出回退 png)。
/// 把一张聊天图片保存到用户选择的位置。
///
/// [file]、[bytes]、[url] 按顺序择一;本地文件优先,URL 先读磁盘缓存再联网。
/// 读取失败或检查到页面已卸载时给出 SnackBar,不抛给调用方。
Future<void> saveChatImage(
  BuildContext context, {
  File? file,
  Uint8List? bytes,
  String? url,
}) async {
  Uint8List? data = bytes;
  if (data == null && file != null) {
    try {
      data = await file.readAsBytes();
    } catch (_) {
      data = null;
    }
  }
  if (data == null && url != null && url.isNotEmpty) {
    try {
      final cached = await DiskImageCache.existingFile(url);
      if (cached != null) data = await cached.readAsBytes();
    } catch (_) {
      data = null;
    }
  }
  if (data == null && url != null && url.isNotEmpty) {
    try {
      data = await downloadImageBytes(url);
    } catch (_) {
      data = null;
    }
  }
  if (!context.mounted) return;
  if (data == null) {
    showAppSnack(context, '下载失败:无法获取图片');
    return;
  }
  await saveBytesFile(
    context,
    fileName: 'chat-image_${_timestamp()}.${_imageExtension(data)}',
    bytes: data,
    allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
  );
}

String _imageExtension(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'jpg';
  }
  // RIFF....WEBP(WebP 头为 "RIFF" + 大小 + "WEBP")。
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'gif';
  }
  return 'png';
}

/// 下载文件名的建议时间戳:chat-image_20260819_123456.png。
String _timestamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
