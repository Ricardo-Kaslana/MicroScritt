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
}
