// 上游故障分类测试:状态码/错误类型/文案判定表与错误形态提取。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/upstream_error.dart';

void main() {
  group('classifyUpstreamFailure', () {
    // 签名 → 期望分类的判定表:每条都来自常见上游实测形态
    // (免费档按客户端特征拒绝 / 内容风控标记 / 生图 402 额度不足)
    // 或高频兼容网关报错。
    final cases = <(String, int?, String?, String?, UpstreamErrorKind)>[
      (
        '免费档按客户端特征拒绝(403 + FreeTierError)',
        403,
        'FreeTierError',
        '{"type":"error","error":{"type":"FreeTierError","message":"free tier can only be used from within the provider"}}',
        UpstreamErrorKind.gatewayPolicy,
      ),
      ('401 鉴权失败', 401, null, '{"error":{"message":"Invalid API key"}}', UpstreamErrorKind.auth),
      (
        '402 额度不足(生图服务实测文案)',
        402,
        null,
        '{"error":{"message":"密钥额度不足,无法生成图片。"}}',
        UpstreamErrorKind.quota,
      ),
      ('429 限流', 429, null, 'rate limit exceeded', UpstreamErrorKind.rateLimit),
      ('5xx 瞬态', 500, null, '{"type":"error","error":{"message":"Internal server error"}}', UpstreamErrorKind.transient),
      (
        '400 内容风控标记文案',
        400,
        null,
        '{"error":{"message":"提示词已被标记,请修改后重试"}}',
        UpstreamErrorKind.contentFlag,
      ),
      ('400 普通坏请求 → 契约不符', 400, null, '{"error":{"message":"Invalid request"}}', UpstreamErrorKind.contractViolation),
      ('404 路由不存在 → 契约不符', 404, null, 'not found', UpstreamErrorKind.contractViolation),
      (
        '流中途错误负载(无状态码)限流文案',
        null,
        'server_error',
        'rate limited upstream',
        UpstreamErrorKind.rateLimit,
      ),
      ('流中途未知错误负载默认瞬态', null, 'server_error', 'upstream exploded', UpstreamErrorKind.transient),
      (
        '流中途 invalid_request_error 归非瞬态(避免 agent 盲目重试)',
        null,
        'invalid_request_error',
        'invalid request: missing field',
        UpstreamErrorKind.contractViolation,
      ),
      (
        '400 上下文超长(OpenAI)',
        400,
        'invalid_request_error',
        '{"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"This model\'s maximum context length is 8192 tokens"}}',
        UpstreamErrorKind.contextLength,
      ),
      (
        'Anthropic prompt is too long',
        400,
        'invalid_request_error',
        '{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}',
        UpstreamErrorKind.contextLength,
      ),
      ('密钥签名覆盖状态码(403 也报鉴权)', 403, null, 'API key not valid, please check', UpstreamErrorKind.auth),
      (
        '地区封锁 → 网关策略',
        400,
        null,
        'User location is not supported for the API use',
        UpstreamErrorKind.gatewayPolicy,
      ),
      ('全空输入按可重试对待', null, null, null, UpstreamErrorKind.transient),
    ];
    for (final (name, status, type, body, expected) in cases) {
      test(name, () {
        expect(
          classifyUpstreamFailure(statusCode: status, errorType: type, body: body),
          expected,
        );
      });
    }
  });

  test('every kind has non-empty label and hint (UI 依赖)', () {
    for (final kind in UpstreamErrorKind.values) {
      expect(kind.label, isNotEmpty);
      expect(kind.hint, isNotEmpty);
    }
  });

  group('extractUpstreamErrorShape', () {
    test('OpenAI 扁平形态', () {
      final shape = extractUpstreamErrorShape('{"error":{"type":"invalid_request_error","message":"bad"}}');
      expect(shape.type, 'invalid_request_error');
      expect(shape.message, 'bad');
    });

    test('嵌套形态(type=error + error 对象)', () {
      final shape = extractUpstreamErrorShape(
        '{"type":"error","error":{"type":"FreeTierError","message":"free tier only"}}',
      );
      expect(shape.type, 'FreeTierError');
      expect(shape.message, 'free tier only');
    });

    test('error 为字符串', () {
      final shape = extractUpstreamErrorShape('{"error":"无可用渠道"}');
      expect(shape.type, isNull);
      expect(shape.message, '无可用渠道');
    });

    test('纯文本/坏 JSON 返回全 null,分类退回状态码', () {
      expect(extractUpstreamErrorShape('plain gateway text'), (type: null, message: null));
      expect(extractUpstreamErrorShape('{not json'), (type: null, message: null));
      expect(extractUpstreamErrorShape(''), (type: null, message: null));
    });
  });

  group('redactSecrets', () {
    test('遮蔽本次请求的 apiKey 精确值', () {
      const key = 'sk-live-abcdefghijklmnop';
      final out = redactSecrets('bad key $key for request', apiKey: key);
      expect(out, isNot(contains(key)));
      expect(out, contains('***'));
    });

    test('遮蔽 Bearer 令牌、sk- 前缀与 api_key 字段值', () {
      final out = redactSecrets(
        'Authorization: Bearer abcdefgh12345678\n'
        'api_key: sk-test-1234567890\n'
        'X-Api-Key: "verysecretvalue123"',
      );
      expect(out, isNot(contains('abcdefgh12345678')));
      expect(out, isNot(contains('sk-test-1234567890')));
      expect(out, isNot(contains('verysecretvalue123')));
    });

    test('遮蔽超长 token 串(即使没有已知前缀)', () {
      const token = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789ABCD';
      expect(redactSecrets('token=$token'), isNot(contains(token)));
    });

    test('不影响普通短文本', () {
      expect(redactSecrets('rate limited upstream'), 'rate limited upstream');
    });
  });
}
