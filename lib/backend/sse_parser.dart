/// Server-Sent Events 解析:把按行输入的 SSE 流聚合为事件。
///
/// 空行分隔事件;同一事件的多个 `data:` 行以换行拼接;流结束时不带空行
/// 的尾部事件也会发出。注释行与其他字段(如 `id:`、`retry:`)忽略。
library;

import 'dart:convert';

/// 一个已聚合的 SSE 事件。
class SseEvent {
  /// `event:` 字段值;未声明时为 null。
  final String? event;

  /// 拼接后的 `data:` 载荷。
  final String data;

  const SseEvent(this.event, this.data);
}

/// 逐行解析 SSE 输入流;每遇到空行发出一个非空事件。
Stream<SseEvent> parseSse(Stream<String> lines) async* {
  String? event;
  final data = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      final joined = data.join('\n');
      if (joined.isNotEmpty) yield SseEvent(event, joined);
      event = null;
      data.clear();
    } else if (line.startsWith('event:')) {
      event = line.substring('event:'.length).trim();
    } else if (line.startsWith('data:')) {
      // 按 SSE 规范只去掉冒号后的**一个**前导空格:尾部空白可能属于
      // JSON 字符串值(如正文以空格结尾),trim 会静默改写上游内容。
      final value = line.substring('data:'.length);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
  final joined = data.join('\n');
  if (joined.isNotEmpty) yield SseEvent(event, joined);
}

/// 把一帧 SSE 载荷解码为 JSON 对象;非对象 JSON(null/数组/字符串/数字)
/// 与坏 JSON 都返回 null。
///
/// 同事件的多个 `data:` 行按协议以换行拼接,部分网关却把**一个** JSON
/// 对象拆到多行(未按规范用空行分隔事件),因此拼接后解析失败时再去掉
/// 换行重试一次。归类交给调用方:非对象载荷是契约不符,不是未分类异常。
Map<String, dynamic>? decodeSseJsonObject(String data) {
  Object? decoded;
  try {
    decoded = jsonDecode(data);
  } on FormatException {
    try {
      decoded = jsonDecode(data.replaceAll('\n', ''));
    } on FormatException {
      return null;
    }
  }
  return decoded is Map<String, dynamic> ? decoded : null;
}
