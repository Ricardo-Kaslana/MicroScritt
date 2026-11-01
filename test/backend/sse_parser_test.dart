// SSE 解析测试:事件/数据行聚合与空 data 行的跳过。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/sse_parser.dart';

void main() {
  test('parses event/data lines into SseEvents', () async {
    final lines = Stream.fromIterable([
      'event: content_block_delta',
      'data: {"type":"content_block_delta"}',
      '',
      'data: {"type":"message_stop"}',
      '',
    ]);
    final events = await parseSse(lines).toList();
    expect(events.length, 2);
    expect(events[0].event, 'content_block_delta');
    expect(events[0].data, '{"type":"content_block_delta"}');
    expect(events[1].event, isNull);
    expect(events[1].data, '{"type":"message_stop"}');
  });

  test('skips empty data (bare data: line)', () async {
    final lines = Stream.fromIterable(['data:', '']);
    final events = await parseSse(lines).toList();
    expect(events, isEmpty);
  });
}
