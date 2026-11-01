// 测试用 SSE 服务:分片即时交付、写完继续保活,用于验证插件的提前截断。
import 'dart:convert';
import 'dart:io';

/// 起一个「分片写完就保活、迟迟不关流」的 SSE 服务 —— 真实对话式生图网关出图后
/// 就是这个行为(连接 keepalive 数十秒才关),插件宿主的提前截断必须能在这种
/// 服务端上验证。
///
/// 为什么用裸 socket 而不是 `request.response.write(...)+flush()`:同 isolate 里
/// 的 `HttpResponse.flush()` 实测不把分片推给客户端,要等 `close()` 才一次到达,
/// 于是「读到就断」的用例无论实现对错都会慢整整一个 hold —— 用它测截断会得到
/// 假结论。裸 socket + chunked 帧 + `socket.flush()` 才是即时交付。
Future<HttpServer> serveHeldEventStream(
  List<String> chunks, {
  Duration hold = const Duration(seconds: 2),
  int statusCode = HttpStatus.ok,
}) => serveHeldByteStream(
  [for (final chunk in chunks) utf8.encode(chunk)],
  hold: hold,
  statusCode: statusCode,
);

/// [serveHeldEventStream] 的字节分片版本:截断点可以落在多字节 UTF-8 字符中间,
/// String 版本做不到(按字符编码后总是合法 UTF-8)。
Future<HttpServer> serveHeldByteStream(
  List<List<int>> chunks, {
  Duration hold = const Duration(seconds: 2),
  int statusCode = HttpStatus.ok,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      await utf8.decoder.bind(request).join(); // 先消费完请求体
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 $statusCode Event Stream\r\n'
        'content-type: text/event-stream\r\n'
        'transfer-encoding: chunked\r\n\r\n',
      );
      for (final bytes in chunks) {
        socket.write('${bytes.length.toRadixString(16)}\r\n');
        socket.add(bytes);
        socket.write('\r\n');
        await socket.flush();
      }
      await Future<void>.delayed(hold);
      socket.write('0\r\n\r\n');
      await socket.flush();
      socket.destroy();
    } catch (_) {
      // 客户端提前断开(正是被测行为)会让写入抛错:忽略即可。
    }
  });
  return server;
}
