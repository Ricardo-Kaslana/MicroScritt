import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/backend/openai_backend.dart';
import 'package:microscritt/backend/upstream_error.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/endpoint_compat.dart';

/// 端点兼容选项 replyViaTool 的后端测试:回复经 output_reply 工具参数的
/// JSON content 字符串输出 —— 增量解码、代理对跨块、截断容忍、空回自动
/// 重试。SSE 线一律经 jsonEncode 构造,内嵌转义不再手工拼写。
void main() {
  const replyConfig = BackendConfig(
    provider: BackendProvider.openai,
    baseUrl: 'https://x',
    apiKey: 'k',
    model: 'm',
    compat: EndpointCompat(replyViaTool: true),
  );
  const plainConfig = BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm');
  const request = LlmRequest(model: 'm', systemPrompt: 'sys', messages: [ChatMessage(ChatRole.user, 'hi')]);

  // ── SSE 构造助手:arguments 的值是"原始字符串",转义交 jsonEncode ──
  String toolEvent({String? id, String? name, String? arguments}) => 'data: ${jsonEncode({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  if (id != null) 'id': id,
                  'type': 'function',
                  'function': {
                    if (name != null) 'name': name,
                    if (arguments != null) 'arguments': arguments,
                  },
                },
              ],
            },
          },
        ],
      })}';
  String finishEvent(String reason) => 'data: ${jsonEncode({
        'choices': [
          {'delta': {}, 'finish_reason': reason},
        ],
      })}';
  String contentEvent(String text) => 'data: ${jsonEncode({
        'choices': [
          {'delta': {'content': text}},
        ],
      })}';
  const doneEvent = 'data: [DONE]';
  String sse(List<String> events) => '${events.join('\n\n')}\n\n';

  test('replyViaTool wires the output_reply channel into the request body', () async {
    late Map<String, dynamic> captured;
    final client = MockClient((req) async {
      captured = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response.bytes(utf8.encode(sse([doneEvent])), 200);
    });
    await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    final tools = captured['tools'] as List;
    expect(tools, hasLength(1));
    expect((tools.single as Map)['function']['name'], 'output_reply');
    expect(captured['tool_choice'], {
      'type': 'function',
      'function': {'name': 'output_reply'},
    });
    expect(captured['parallel_tool_calls'], false);
  });

  test('reply content is decoded incrementally from tool arguments', () async {
    // arguments 分两块到达:块尾截在字符串字面量中间(含 \n 转义)。
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(sse([
          toolEvent(id: 'c1', name: 'output_reply', arguments: '{"content": "你好'),
          toolEvent(arguments: '\\n世界'),
          finishEvent('stop'),
          doneEvent,
        ])), 200));

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '你好\n世界');
    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('surrogate pair split across chunks stays intact (无孤立代理)', () async {
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(sse([
          toolEvent(id: 'c1', name: 'output_reply', arguments: '{"content": "维'),
          toolEvent(arguments: '\\ud83d\\ude00'),
          toolEvent(arguments: '"}'),
          finishEvent('stop'),
          doneEvent,
        ])), 200));

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '维😀');
  });

  test('truncated reply (no closing quote) keeps the decoded prefix', () async {
    // 风控/长度中途掐断:JSON 残缺但已开始解码 —— 容忍,保留前缀。
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(sse([
          toolEvent(id: 'c1', name: 'output_reply', arguments: '{"content": "被截断的正文'),
          finishEvent('stop'),
          doneEvent,
        ])), 200));

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '被截断的正文');
    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('junk after the closing quote is a structural error', () async {
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(sse([
          toolEvent(id: 'c1', name: 'output_reply', arguments: '{"content": "ok"}extra'),
          finishEvent('stop'),
          doneEvent,
        ])), 200));

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors.single.kind, UpstreamErrorKind.contractViolation);
    expect(errors.single.message, contains('参数格式错误'));
  });

  test('invalid escape inside content is reported once (流内报错不重复)', () async {
    final client = MockClient((req) async => http.Response.bytes(utf8.encode(sse([
          toolEvent(id: 'c1', name: 'output_reply', arguments: '{"content": "bad\\x"}'),
          finishEvent('stop'),
          doneEvent,
        ])), 200));

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors, hasLength(1));
    expect(errors.single.message, contains('参数格式错误'));
  });

  test('output_reply with empty content errors without retry (有调用即有响应)', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response.bytes(utf8.encode(sse([
        toolEvent(id: 'c1', name: 'output_reply', arguments: '{"content": ""}'),
        finishEvent('stop'),
        doneEvent,
      ])), 200);
    });

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(calls, 1); // 有调用即有响应,不重试
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors.single.kind, UpstreamErrorKind.contentFlag);
    expect(errors.single.message, contains('工具通道输出'));
  });

  test('empty round with replyViaTool retries twice then surfaces the error', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response.bytes(utf8.encode(sse([doneEvent])), 200);
    });

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(calls, 3); // 首次 + 2 次空回重试(共 3 次尝试)
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors.single.kind, UpstreamErrorKind.contentFlag);
    expect(errors.single.message, contains('空回复'));
  });

  test('empty round retry succeeds on a later attempt', () async {
    var calls = 0;
    final client = MockClient((req) async {
      final n = calls++;
      if (n == 0) return http.Response.bytes(utf8.encode(sse([doneEvent])), 200);
      return http.Response.bytes(utf8.encode(sse([
        toolEvent(id: 'c1', name: 'output_reply', arguments: '{"content": "恢复输出"}'),
        finishEvent('stop'),
        doneEvent,
      ])), 200);
    });

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(calls, 2);
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '恢复输出');
    expect(events.whereType<ErrorEvent>(), isEmpty);
  });

  test('plain mode keeps the historical silent empty (无重试)', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      return http.Response.bytes(utf8.encode(sse([doneEvent])), 200);
    });

    final events = await OpenAiBackend(config: plainConfig, client: client).generate(request).toList();

    expect(calls, 1);
    expect(events.whereType<ErrorEvent>(), isEmpty);
    expect(events.whereType<DoneEvent>(), isNotEmpty);
  });

  test('transient HTTP failure with zero content is retried once transparently', () async {
    var calls = 0;
    final client = MockClient((req) async {
      final n = calls++;
      if (n == 0) return http.Response('Internal server error', 500);
      return http.Response.bytes(utf8.encode(sse([contentEvent('恢复'), doneEvent])), 200);
    });

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(calls, 2);
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '恢复');
    expect(events.whereType<ErrorEvent>(), isEmpty);
  });

  test('transient failure after content streamed is NOT retried (部分正文不重来)', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      // 正文已流式透出,流却被提前掐断(无 [DONE])—— 不重试,错误照旧透出。
      return http.Response.bytes(utf8.encode('data: {"choices":[{"delta":{"content":"部分"}}]}\n\n'), 200);
    });

    final events = await OpenAiBackend(config: replyConfig, client: client).generate(request).toList();

    expect(calls, 1);
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '部分');
    final errors = events.whereType<ErrorEvent>().toList();
    expect(errors.single.kind, UpstreamErrorKind.transient);
    expect(errors.single.message, contains('[DONE]'));
  });
}
