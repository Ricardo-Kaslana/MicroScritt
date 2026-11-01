import 'dart:async';
import 'package:http/http.dart' as http;
import '../models/chat_message.dart';
import 'anthropic_backend.dart';
import 'backend_config.dart';
import 'llm_backend.dart';
import 'openai_backend.dart';
import 'upstream_error.dart';

/// 「测试连接」探测:按当前表单配置发一次最小请求(system + ping + 流式),
/// 把「端点为什么不通」归因为稳定的错误分类,而不是让用户对着状态码猜。
class LlmProbeStage {
  final bool ok;

  /// 失败时的稳定分类;ok 时不承载信息。
  final UpstreamErrorKind? kind;
  final int? statusCode;

  /// 失败原因的原文摘要(已脱敏密钥)。
  final String detail;

  /// 成功时记录的服务端用量输入侧(部分网关不报 usage,为 null)。
  final int? inputTokens;

  const LlmProbeStage._({
    required this.ok,
    this.kind,
    this.statusCode,
    this.detail = '',
    this.inputTokens,
  });

  const LlmProbeStage.ok({int? inputTokens})
      : this._(ok: true, inputTokens: inputTokens);

  const LlmProbeStage.failure({
    UpstreamErrorKind? kind,
    int? statusCode,
    String detail = '',
  }) : this._(ok: false, kind: kind, statusCode: statusCode, detail: detail);

  String get kindLabel => kind?.label ?? '未知错误';
}

class LlmProbeReport {
  final LlmProbeStage stage;

  const LlmProbeReport({required this.stage});

  bool get ok => stage.ok;

  /// 面向 UI 的诊断摘要:给出归因结论与建议,而不是一个裸状态码。
  String get summary {
    if (stage.ok) return '连接正常:端点已受理请求。';
    return '连接失败:[${stage.kindLabel}] ${stage.detail}\n建议:${stage.kind?.hint ?? '检查配置后重试'}';
  }
}

class LlmProbe {
  final BackendConfig config;

  /// 探测独享一个 client 的工厂(生产为 null 时自建 http.Client);探测可能
  /// 中途断链(取消即 close),不能与运行链路共用实例。
  final http.Client Function()? clientFactory;

  /// 单级护栏:探测是设置页按钮,网络黑洞时不设防 UI 永远转圈(Nai2Probe
  /// 同款教训)。默认值覆盖"连接超时 + 短回复";测试注入毫秒级。
  final Duration stageTimeout;

  /// 后端的连接/流空闲护栏(透传,测试可注入短时限)。
  final Duration connectTimeout;
  final Duration idleTimeout;

  const LlmProbe({
    required this.config,
    this.clientFactory,
    this.stageTimeout = const Duration(seconds: 45),
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  });

  Future<LlmProbeReport> run() async {
    return LlmProbeReport(stage: await _stage());
  }

  Future<LlmProbeStage> _stage() async {
    // 工厂绕不过 createBackend 的固定签名(探测要注入短时限),按协议直构。
    final client = (clientFactory ?? http.Client.new)();
    final LlmBackend backend;
    switch (config.provider) {
      case BackendProvider.openai:
        backend = OpenAiBackend(
          config: config,
          client: client,
          connectTimeout: connectTimeout,
          idleTimeout: idleTimeout,
        );
      case BackendProvider.anthropic:
        backend = AnthropicBackend(
          config: config,
          client: client,
          connectTimeout: connectTimeout,
          idleTimeout: idleTimeout,
        );
    }
    final completer = Completer<LlmProbeStage>();
    int? inputTokens;
    late final StreamSubscription<LlmEvent> sub;
    sub = backend
        .generate(LlmRequest(
          model: config.model,
          systemPrompt: '',
          messages: const [ChatMessage(ChatRole.user, 'ping')],
        ))
        .listen(
          (event) {
            switch (event) {
              case TextDelta(:final text):
                if (text.isNotEmpty && !completer.isCompleted) {
                  completer.complete(LlmProbeStage.ok(inputTokens: inputTokens));
                }
              case UsageEvent(:final usage):
                inputTokens = usage.inputTokens;
              case ErrorEvent(:final message, :final kind, :final statusCode):
                if (!completer.isCompleted) {
                  completer.complete(LlmProbeStage.failure(
                    kind: kind ?? UpstreamErrorKind.transient,
                    statusCode: statusCode,
                    detail: _redact(message),
                  ));
                }
              case DoneEvent():
                // 收到 [DONE] 但零正文:契约层面算通(端点受理了请求)。
                if (!completer.isCompleted) {
                  completer.complete(LlmProbeStage.ok(inputTokens: inputTokens));
                }
            }
          },
          onError: (Object e) {
            if (!completer.isCompleted) {
              completer.complete(LlmProbeStage.failure(
                kind: UpstreamErrorKind.transient,
                detail: _redact('网络错误:$e'),
              ));
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.complete(const LlmProbeStage.ok());
            }
          },
        );
    LlmProbeStage stage;
    try {
      stage = await completer.future.timeout(
        stageTimeout,
        onTimeout: () => const LlmProbeStage.failure(
          kind: UpstreamErrorKind.transient,
          detail: '探测超时:服务器长时间未响应',
        ),
      );
    } finally {
      // 断链中止:无论哪条路径出栈,订阅都要收掉;后端 onCancel 会同步 close
      // 尚未收尾的连接,独享 client 随后由 finally 兜底释放。
      await sub.cancel();
    }
    return stage;
  }

  /// 服务端报错有时回显请求里的密钥(nai2 /api/me 教训):凡展示的摘要一律
  /// 先脱敏。
  String _redact(String text) {
    final key = config.apiKey;
    if (key.length < 4) return text;
    return text.replaceAll(key, '***');
  }
}
