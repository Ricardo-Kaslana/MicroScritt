import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 下载一张远程图片的字节。
///
/// 用于把云端生成的图(`image_url`)在**生成时立即本地化落库**,或
/// 在渲染时写入磁盘缓存 —— 否则消息只存远程 URL,气泡在对话中重建(内存缓存逐出)
/// /重启后都会重新拉取、重新解码 —— 表现为"已生成的图片反复重新加载"。
///
/// 移动网络下连接常被运营商 NAT 空闲掐断(连接建立后长时间无响应,AM 批已给
/// 生图请求加过连接级重试):**连接停滞(超时)自动重试一次** —— 生成时一旦把图
/// 落成本地 base64,重启就不再走网络(否则 URL-only 消息在重启后要重新联网拉取,
/// 画面转圈很久)。**连接拒绝/立即断开等确定性失败不重试** —— 重试只会把已知
/// 失败拖成两倍时长;HTTP 非 200 / 空 body 同样是确定性失败,不重试。
Future<Uint8List?> downloadImageBytes(String url, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final res = await c.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) return res.bodyBytes;
        return null; // 确定性失败(HTTP 非 200 / 空 body):重试无意义
      } on TimeoutException {
        // 连接停滞(移动 NAT 掐断的典型表现):再试一次。
      } catch (_) {
        return null; // 连接拒绝/立即断开:确定性失败,不重试。
      }
    }
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// 下载一张远程图片为 base64 字符串(字节的编码形式,便于直接落 `image_base64`)。
///
/// 3~5MB 的 base64 编码在主 isolate 会占掉一帧以上,而生成落库时每张图都会
/// 走这条路径;这里把编码移到短生命周期 isolate。字节用 TransferableTypedData
/// 转移,避免再往 isolate 复制一份输入。
Future<String?> downloadImageBase64(String url, {http.Client? client}) async {
  final bytes = await downloadImageBytes(url, client: client);
  if (bytes == null) return null;
  final transferred = TransferableTypedData.fromList([bytes]);
  try {
    return await Isolate.run(
      () => base64Encode(transferred.materialize().asUint8List()),
    );
  } catch (_) {
    // 极端环境(isolate 不可用)回退主线程:正确性优先。
    return base64Encode(bytes);
  }
}
