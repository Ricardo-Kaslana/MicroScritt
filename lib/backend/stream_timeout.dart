/// LLM 流式请求的连接与空闲超时护栏。
///
/// 不设防的流式读取在半开连接/服务端挂起时会永久挂起,必须在传输层统一
/// 设防;取消订阅会向上游传播并断开连接。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// LLM 流式请求的超时护栏(http 包本身没有默认超时,不设防的 `await for`
/// 在半开连接/服务端挂起时会永久挂起,主写有停止按钮兜底,后台/压缩路径
/// 则完全无人盯 —— 必须在传输层统一设防)。
///
/// - [kLlmConnectTimeout]:发起请求到收到**响应头**的时限。SSE 一旦开始
///   流式输出,响应头立即到达,这一段只覆盖连接建立/网关排队;
/// - [kLlmIdleTimeout]:两条流数据之间的最大间隔。覆盖流中途停滞(NAT 掐断
///   的半开连接、网关挂起);LLM 正常生成时 token/keepalive 持续到达,
///   思考型模型的首 token 前也有 ping/事件维持。
const Duration kLlmConnectTimeout = Duration(seconds: 60);
const Duration kLlmIdleTimeout = Duration(seconds: 120);

/// 逐事件空闲超时:[source] 相邻两个事件之间超过 [idle] 未产出,即以
/// `TimeoutException` 终止下游并**取消上游订阅**(取消沿流链条向上传播,
/// http 层随即断开底层连接,不会留下一条还在跑的僵尸请求)。
///
/// 与 `Future.timeout` 的关键区别:那是"放弃等待但请求继续跑",这里是
/// 真正掐断。
Stream<T> withIdleTimeout<T>(Stream<T> source, Duration idle) {
  late final StreamController<T> controller;
  Timer? timer;
  StreamSubscription<T>? sub;
  void arm() {
    timer?.cancel();
    timer = Timer(idle, () {
      sub?.cancel();
      controller.addError(TimeoutException('流空闲超过 ${idle.inSeconds}s 无数据(连接疑似已断)', idle));
      controller.close();
    });
  }

  controller = StreamController<T>(
    onListen: () {
      arm();
      sub = source.listen(
        (event) {
          arm();
          controller.add(event);
        },
        onError: (Object e, StackTrace s) {
          arm();
          controller.addError(e, s);
        },
        onDone: () {
          timer?.cancel();
          controller.close();
        },
      );
    },
    onCancel: () async {
      timer?.cancel();
      await sub?.cancel();
    },
  );
  return controller.stream;
}

/// 非 2xx 错误体的读取上限:错误体只用来诊断,不需要全文;部分网关在错误
/// 路径上仍挂着长连接或回传整页 HTML,不设上限会把内存与等待时间交给上游。
const int kUpstreamErrorBodyLimit = 64 * 1024;

/// 带空闲超时与字节上限地读取非 2xx 错误体。
///
/// 超限即停止读取(取消底层订阅,不等服务端关流)并在末尾标注截断;
/// 读取阶段的空闲超时归一为占位文本 —— 错误分类仍以状态码为准,不能因为
/// 错误体读不动就再次挂起或把整次请求升级成未分类异常。
Future<String> readUpstreamErrorBody(
  Stream<List<int>> stream,
  Duration idle, {
  int limit = kUpstreamErrorBodyLimit,
}) async {
  final bytes = BytesBuilder(copy: false);
  var truncated = false;
  try {
    await for (final chunk in withIdleTimeout(stream, idle)) {
      final remaining = limit - bytes.length;
      if (chunk.length > remaining) {
        bytes.add(chunk.sublist(0, remaining));
        truncated = true;
        break;
      }
      bytes.add(chunk);
      if (bytes.length >= limit) break;
    }
  } on TimeoutException {
    truncated = true;
  }
  // 截断可能切在多字节字符中间:allowMalformed 让诊断文本仍是合法字符串。
  final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
  return truncated ? '$text…(truncated)' : text;
}
