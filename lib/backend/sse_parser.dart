/// Server-Sent Events 解析:把按行输入的 SSE 流聚合为事件。
///
/// 空行分隔事件;同一事件的多个 `data:` 行以换行拼接;流结束时不带空行
/// 的尾部事件也会发出。注释行与其他字段(如 `id:`、`retry:`)忽略。
library;

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
      data.add(line.substring('data:'.length).trim());
    }
  }
  final joined = data.join('\n');
  if (joined.isNotEmpty) yield SseEvent(event, joined);
}
