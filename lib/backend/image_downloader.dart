/// 远程图片下载与可选的 base64 协议边界转换。
///
/// 生图结果若为 URL,上层在下游资产化前调用这里取回字节;下载失败返回
/// null,由调用方决定是否回退到远程 URL 渲染。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'image_magic.dart';

/// 单张下载的累计字节上限。整包缓冲时代没有任何上限,恶意/异常大图可直接
/// 打穿移动端内存;流式读取超过这里立即中止并返回 null。
const int maxDownloadImageBytes = 16 * 1024 * 1024;

/// 单次尝试的连接 + 正文读取总预算。超时视为连接停滞,允许再试一次。
const Duration downloadImageTimeout = Duration(seconds: 30);

/// 下载一张远程图片的字节。
///
/// 用于把云端生成的图(`image_url`)在**生成时立即本地化落库**,或
/// 在渲染时写入磁盘缓存 —— 否则消息只存远程 URL,气泡在对话中重建(内存缓存逐出)
/// /重启后都会重新拉取、重新解码 —— 表现为"已生成的图片反复重新加载"。
///
/// 移动网络下连接常被运营商 NAT 空闲掐断(连接建立后长时间无响应):
/// **连接停滞(超时)自动重试一次** —— 生成时一旦把图
/// 落成本地资产,重启就不再走网络(否则 URL-only 消息在重启后要重新联网拉取,
/// 画面转圈很久)。**连接拒绝/立即断开等确定性失败不重试** —— 重试只会把已知
/// 失败拖成两倍时长;HTTP 非 200 / 空 body / 超限 / 非图片同样是确定性失败。
///
/// 安全边界:只接受 http(s)、无用户信息的绝对 URL;不跟随重定向;拒绝
/// 环回/私网/链路本地等字面量 IP 目标;正文流式读取且累计不超过
/// [maxDownloadImageBytes]。重试只重放完全相同的受限请求,不会绕过上述限制。
Future<Uint8List?> downloadImageBytes(String url, {http.Client? client}) async {
  final uri = _parseDownloadUri(url);
  if (uri == null) return null;
  final c = client ?? http.Client();
  try {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final bytes = await _downloadOnce(uri, c);
        return bytes.isEmpty ? null : bytes;
      } on TimeoutException {
        // 连接停滞(移动 NAT 掐断的典型表现):再试一次。
      } on _DownloadRejected {
        return null;
      } catch (_) {
        // 连接拒绝/立即断开/响应流错误:确定性失败,不重试。
        return null;
      }
    }
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// 下载一张远程图片为 base64 字符串,供仍以此外部协议格式交换数据的调用方使用。
///
/// 消息落库主路径直接使用 [downloadImageBytes] 的字节结果。这里的编码移到短
/// 生命周期 isolate,字节用 TransferableTypedData 转移,避免额外复制输入。
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

/// 确定性拒绝(受限 URL/非 200/重定向/非图片):不重试。
class _DownloadRejected implements Exception {
  const _DownloadRejected();
}

/// 正文超过 [maxDownloadImageBytes]:立即中止,不重试。
class _DownloadTooLarge implements Exception {
  const _DownloadTooLarge();
}

Uri? _parseDownloadUri(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !(uri.isScheme('http') || uri.isScheme('https')) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  if (_isBlockedHost(uri.host)) return null;
  return uri;
}

/// 字面量 IP/本机名的 SSRF 防护。
///
/// 只检查 URL host 本身(不做 DNS 解析):环回、私网、链路本地、CGNAT、
/// 组播/保留网段与 localhost 一律拒绝。DNS 解析到私网地址的域名不在本函数
/// 能覆盖的范围内,由调用方的来源信任边界负责。
bool _isBlockedHost(String rawHost) {
  var host = rawHost.trim().toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty) return true;
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  final ipv4 = _parseIpv4(host);
  if (ipv4 != null) return _isBlockedIpv4(ipv4);
  if (host.contains(':')) return _isBlockedIpv6(host);
  return false;
}

List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return null;
    if (!part.codeUnits.every((c) => c >= 0x30 && c <= 0x39)) return null;
    final value = int.parse(part);
    if (value > 255) return null;
    octets.add(value);
  }
  return octets;
}

bool _isBlockedIpv4(List<int> o) {
  final a = o[0];
  final b = o[1];
  if (a == 0 || a == 10 || a == 127) return true; // 本网络 / 私网 / 环回
  if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64/10
  if (a == 169 && b == 254) return true; // 链路本地(云元数据端点常见)
  if (a == 172 && b >= 16 && b <= 31) return true; // 私网 172.16/12
  if (a == 192 && b == 168) return true; // 私网 192.168/16
  if (a == 192 && b == 0 && (o[2] == 0 || o[2] == 2)) return true;
  if (a == 198 && (b == 18 || b == 19)) return true; // 基准测试网段
  if (a == 198 && b == 51 && o[2] == 100) return true; // 文档网段
  if (a == 203 && b == 0 && o[2] == 113) return true; // 文档网段
  if (a >= 224) return true; // 组播/保留/广播
  return false;
}

bool _isBlockedIpv6(String host) {
  if (host == '::' || host == '::1' || host == '0:0:0:0:0:0:0:1') {
    return true;
  }
  // IPv4-mapped(::ffff:1.2.3.4 或 ::ffff:7f00:1 的常见点分形式)。
  if (host.startsWith('::ffff:')) {
    final tail = host.substring('::ffff:'.length);
    final ipv4 = _parseIpv4(tail);
    if (ipv4 != null) return _isBlockedIpv4(ipv4);
  }
  final head = host.length >= 4 ? host.substring(0, 4) : host;
  if (head.startsWith('fe8') ||
      head.startsWith('fe9') ||
      head.startsWith('fea') ||
      head.startsWith('feb')) {
    return true; // 链路本地 fe80::/10
  }
  if (host.startsWith('fc') || host.startsWith('fd')) {
    return true; // 唯一本地 fc00::/7
  }
  if (host.startsWith('ff')) return true; // 组播
  return false;
}

/// 执行一次受限请求:不跟随重定向、校验 content-type、流式限长读取。
///
/// 超时抛 [TimeoutException](允许外层重试一次);其它确定性失败抛
/// [_DownloadRejected]/[_DownloadTooLarge],外层直接返回 null。
Future<Uint8List> _downloadOnce(Uri uri, http.Client client) async {
  final request = http.Request('GET', uri)
    ..followRedirects = false
    ..maxRedirects = 0;
  final response = await client.send(request).timeout(downloadImageTimeout);
  if (response.statusCode != 200 || response.isRedirect) {
    _discard(response);
    throw const _DownloadRejected();
  }
  final contentType = _mediaType(response.headers['content-type']);
  if (contentType != null &&
      !contentType.startsWith('image/') &&
      contentType != 'application/octet-stream' &&
      contentType != 'binary/octet-stream') {
    _discard(response);
    throw const _DownloadRejected();
  }
  final bytes = await _readBody(response, downloadImageTimeout);
  // 无论 content-type 是否声称 image/*,最终都按真实魔数确认;服务端把
  // HTML 错误页标成 image/png 也不能进缓存/资产库。
  if (!looksLikeImageBytes(bytes)) throw const _DownloadRejected();
  return bytes;
}

/// 放弃一个不再需要的响应:取消订阅,不等待保活连接读完正文。
void _discard(http.StreamedResponse response) {
  unawaited(
    response.stream
        .listen((_) {}, onError: (_) {}, cancelOnError: true)
        .cancel()
        .then<void>((_) {}, onError: (_) {}),
  );
}

String? _mediaType(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  final semicolon = trimmed.indexOf(';');
  final type = semicolon < 0 ? trimmed : trimmed.substring(0, semicolon);
  final normalized = type.trim();
  return normalized.isEmpty ? null : normalized;
}

/// 流式收集正文;累计超过 [maxDownloadImageBytes] 立即取消订阅并中止。
///
/// 超时覆盖整个正文读取:连接建立后长时间无数据同样会取消底层订阅,
/// 交由外层按「连接停滞」重试一次。
Future<Uint8List> _readBody(
  http.StreamedResponse response,
  Duration budget,
) async {
  final builder = BytesBuilder(copy: false);
  final done = Completer<Uint8List>();
  late StreamSubscription<List<int>> subscription;
  void fail(Object error, [StackTrace? stackTrace]) {
    if (!done.isCompleted) done.completeError(error, stackTrace);
  }

  subscription = response.stream.listen(
    (chunk) {
      if (builder.length + chunk.length > maxDownloadImageBytes) {
        fail(const _DownloadTooLarge());
        subscription.cancel().ignore();
        return;
      }
      builder.add(chunk);
    },
    onError: fail,
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  try {
    return await done.future.timeout(budget);
  } catch (_) {
    // 不等待取消完成:保活连接上的 cancel 会等剩余正文读完,把「停滞重试」
    // 拖成又一个长超时;连接最终由调用方 close 或服务端断开收掉。
    unawaited(subscription.cancel().then<void>((_) {}, onError: (_) {}));
    rethrow;
  }
}
