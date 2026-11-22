// SSE 解析测试:事件/数据行聚合、单前导空格剥离与多行 data 兼容。
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

  test('removes only one leading space and keeps trailing whitespace', () async {
    // 只去掉冒号后的一个空格;尾部空白可能属于 JSON 字符串值,不能被 trim。
    final lines = Stream.fromIterable([
      'data:  {"a":1} ',
      '',
    ]);
    final events = await parseSse(lines).toList();
    expect(events.single.data, ' {"a":1} ');
  });

  test('joins multiple data lines with newlines', () async {
    final lines = Stream.fromIterable([
      'data: line1',
      'data: line2',
      '',
    ]);
    final events = await parseSse(lines).toList();
    expect(events.single.data, 'line1\nline2');
  });

  test('decodeSseJsonObject handles multi-line and non-object payloads', () {
    // 多行 data 按换行拼接后能解析。
    expect(decodeSseJsonObject('{\n"a": 1\n}'), {'a': 1});
    // 网关把字符串值拆到两条 data 行(换行落进 JSON 字符串):去换行重试。
    expect(decodeSseJsonObject('{"text": "hello\nworld"}'), {
      'text': 'helloworld',
    });
    // 非对象 JSON 与坏 JSON 都返回 null(调用方归契约错误)。
    expect(decodeSseJsonObject('null'), isNull);
    expect(decodeSseJsonObject('[1,2]'), isNull);
    expect(decodeSseJsonObject('"text"'), isNull);
    expect(decodeSseJsonObject('42'), isNull);
    expect(decodeSseJsonObject('{not json}'), isNull);
  });
}
