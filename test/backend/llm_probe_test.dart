// 「测试连接」探测测试:一次最小请求,失败时给出稳定分类与脱敏摘要。
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:microscritt/models/backend_config.dart';
import 'package:microscritt/backend/llm_probe.dart';

void main() {
  const ssePong = 'data: {"choices":[{"delta":{"content":"pong"}}]}\n\ndata: [DONE]\n\n';
  const gatewayPolicy403 =
      '{"type":"error","error":{"type":"FreeTierError","message":"endpoint policy violation"}}';

  test('测试连接透传模型配置的温度', () async {
    late Map<String, dynamic> body;
    final probe = LlmProbe(
      config: const BackendConfig(
        provider: BackendProvider.openai,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
        temperature: 0.4,
      ),
      clientFactory: () => MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(ssePong), 200);
      }),
    );

    await probe.run();

    expect(body['temperature'], 0.4);
  });

  test('端点受理请求(流式正文)→ 连接正常', () async {
    var clients = 0;
    final probe = LlmProbe(
      config: const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      clientFactory: () {
        clients++;
        return MockClient((req) async => http.Response.bytes(utf8.encode(ssePong), 200));
      },
    );

    final report = await probe.run();

    expect(clients, 1);
    expect(report.ok, isTrue);
    expect(report.summary, contains('连接正常'));
  });

  test('网关策略拦截(403)→ 归因与状态码透出', () async {
    final probe = LlmProbe(
      config: const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      clientFactory: () => MockClient(
        (req) async => http.Response.bytes(utf8.encode(gatewayPolicy403), 403),
      ),
    );

    final report = await probe.run();

    expect(report.ok, isFalse);
    expect(report.stage.kind?.label, '网关策略拦截');
    expect(report.stage.statusCode, 403);
    expect(report.summary, contains('网关策略拦截'));
  });

  test('[DONE] 零正文也算通(端点受理了请求)', () async {
    const sseDoneOnly = 'data: [DONE]\n\n';
    final probe = LlmProbe(
      config: const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: 'k', model: 'm'),
      clientFactory: () => MockClient((req) async => http.Response.bytes(utf8.encode(sseDoneOnly), 200)),
    );

    final report = await probe.run();

    expect(report.ok, isTrue);
  });

  test('失败摘要脱敏密钥(服务端回显 key 的网关不再泄露)', () async {
    const key = 'sk-secret-123456';
    final probe = LlmProbe(
      config: const BackendConfig(provider: BackendProvider.openai, baseUrl: 'https://x', apiKey: key, model: 'm'),
      clientFactory: () => MockClient((req) async => http.Response('bad key $key', 401)),
    );

    final report = await probe.run();

    expect(report.ok, isFalse);
    expect(report.stage.detail, contains('***'));
    expect(report.stage.detail, isNot(contains(key)));
    expect(report.stage.kind?.label, '鉴权失败');
  });

  test('Anthropic 探测透传 max_tokens 与非空 system,并关闭自建 client', () async {
    // Anthropic 的 max_tokens 必填、system 不接受空串:探测不带就会 100% 误报
    // 配置缺失。成功路径也必须关闭每次新建的 client,否则设置页反复探测会泄漏。
    late Map<String, dynamic> body;
    final client = _CloseTrackingClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      const sse = 'event: content_block_delta\n'
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"pong"}}\n\n'
          'event: message_stop\n'
          'data: {"type":"message_stop"}\n\n';
      return http.Response.bytes(utf8.encode(sse), 200);
    });
    final probe = LlmProbe(
      config: const BackendConfig(
        provider: BackendProvider.anthropic,
        baseUrl: 'https://x',
        apiKey: 'k',
        model: 'm',
        maxTokens: 4096,
      ),
      clientFactory: () => client,
    );

    final report = await probe.run();

    expect(report.ok, isTrue);
    expect(body['max_tokens'], 4096);
    expect(body['system'], isNotEmpty);
    // 自建 client 至少被关闭一次(探测自己负责成功路径,取消时的后端兜底
    // 可能先一步关过;真实 http.Client 的 close 幂等)。
    expect(client.closes, greaterThanOrEqualTo(1));
  });
}

/// 记录 close 次数的 MockClient:探测成功路径也必须释放自建 client。
class _CloseTrackingClient extends MockClient {
  int closes = 0;
  _CloseTrackingClient(super.fn);
  @override
  void close() {
    closes++;
    super.close();
  }
}
