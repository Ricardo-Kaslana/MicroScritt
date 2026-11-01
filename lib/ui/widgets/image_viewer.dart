import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../backend/disk_image_cache.dart';
import '../../backend/image_downloader.dart';
import '../common/confirm_dialog.dart';
import '../common/export_helper.dart';

/// 全屏查看一张聊天图片:黑底铺满、双指缩放/平移、点击任意处或右上角关闭按钮退出;
/// 右上角附**下载**按钮,可把当前图片原始字节存到用户选择的位置。
///
/// [bytes] 与 [url] 二选一(同时给时优先字节):
/// - 本地字节(气泡里 base64 解码的结果):直接以内存图解码,不重复读库。
/// - 远程 URL:与气泡内网络图同一策略 —— 先读 [DiskImageCache],命中则本地解码;
///   未命中走网络即时展示,并把字节后台写盘,供下一次全屏查看直接读盘。
///
/// [onDelete] 非空时右上角额外出现**删除**按钮:确认后执行回调并把图片从
/// 消息里移除;聊天气泡调用方传入"清空该消息图片字段"的落库动作,其他
/// 入口(角色头像预览等)不传则不显示。
Future<void> showImageFullscreen(
  BuildContext context, {
  Uint8List? bytes,
  String? url,
  Future<void> Function()? onDelete,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      // 淡入淡出,不让"切到下一屏"的横滑打断查看;整体遮住聊天页。
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, __, ___) =>
          _ImageViewerPage(bytes: bytes, url: url, onDelete: onDelete),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// 全屏查看页。StatefulWidget:URL 来源要先异步查磁盘缓存再定 provider;
/// 字节来源在 initState 直接定,一整页无需在解码期间重建。
class _ImageViewerPage extends StatefulWidget {
  final Uint8List? bytes;
  final String? url;

  /// 确认后从消息中移除这张图的回调;null = 不显示删除入口。
  final Future<void> Function()? onDelete;
  const _ImageViewerPage({required this.bytes, required this.url, this.onDelete});

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  ImageProvider? _provider;

  /// 图片的**原始字节**(下载用,与展示用的 provider 解耦):字节来源立即可用;
  /// URL 来源在磁盘缓存命中/网络写盘成功后填充,否则为 null(下载时现取)。
  Uint8List? _fullBytes;

  /// 保存对话框未关闭/正在重取网络字节时,禁止重复点下载。
  bool _downloading = false;

  /// 确认框/删除落库进行中:防止重复触发删除,也让按钮有"处理中"反馈。
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    final bytes = widget.bytes;
    if (bytes != null) {
      _provider = _viewSize(bytes);
      _fullBytes = bytes;
    } else {
      _loadNetwork();
    }
  }

  /// URL 来源:磁盘缓存命中 → 本地解码;未命中 → 网络即时展示,同时后台下载
  /// 写盘,写盘成功后再把 provider 换成内存图(之后不再依赖网络)。
  Future<void> _loadNetwork() async {
    final url = widget.url;
    if (url == null || !mounted) return;
    try {
      final cached = await DiskImageCache.read(url);
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _provider = _viewSize(cached);
          _fullBytes = cached;
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

  Future<void> _cacheToDisk(String url) async {
    final bytes = await downloadImageBytes(url);
    if (bytes == null || !mounted) return;
    await DiskImageCache.write(url, bytes);
    if (!mounted) return;
    setState(() {
      _provider = _viewSize(bytes);
      _fullBytes = bytes;
    });
  }

  /// 下载当前图片:优先用已有原始字节(本地来源/磁盘缓存/写盘回填);没有时按 URL
  /// 现场重取一次。保存动作交给 [saveBytesFile](file_picker,成功/失败自带反馈)。
  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      var bytes = _fullBytes;
      if (bytes == null) {
        final url = widget.url;
        if (url == null) {
          _toast('下载失败:图片数据不可用');
          return;
        }
        bytes = await downloadImageBytes(url);
        if (!mounted) return; // 重取网络字节期间全屏页已被关闭
        if (bytes == null) {
          _toast('下载失败:无法获取图片');
          return;
        }
      }
      await saveBytesFile(
        context,
        fileName: 'chat-image_${_timestamp()}.${_imageExtension(bytes)}',
        bytes: bytes,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white70,
                                ),
                              ),
                            )
                          : IconButton(
                              tooltip: '删除图片',
                              style: IconButton.styleFrom(backgroundColor: Colors.black38),
                              color: Theme.of(context).colorScheme.error,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _delete,
                            ),
                    // 下载按钮:下载中显示小转圈并禁用,避免重复触发保存对话框。
                    _downloading
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            ),
                          )
                        : IconButton(
                            tooltip: '下载图片',
                            style: IconButton.styleFrom(backgroundColor: Colors.black38),
                            color: Colors.white,
                            icon: const Icon(Icons.download_outlined),
                            onPressed: _download,
                          ),
                    IconButton(
                      tooltip: '关闭',
                      style: IconButton.styleFrom(backgroundColor: Colors.black38),
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

/// 按图片魔数推断扩展名(下载保存用;识别不出回退 png)。
String _imageExtension(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'jpg';
  }
  // RIFF....WEBP(WebP 头为 "RIFF" + 大小 + "WEBP")。
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
      bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
    return 'webp';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
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