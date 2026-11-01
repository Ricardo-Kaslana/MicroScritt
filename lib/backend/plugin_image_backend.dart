/// 生图插件宿主:执行同步 JS `step(ctx)` 状态机并提供受限网络能力。
///
/// 宿主只执行 `http`/`sleep`/`done`/`error` 四种动作,强制 origin 白名单、
/// 请求/响应大小上限、总预算与禁重定向;插件抛出的业务错误转成
/// [ImagePluginException] 透给 UI。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/image_config.dart';
import '../models/image_plugin.dart';
import '../models/image_result.dart';
import 'image_backend.dart';

/// 单步 JS 求值器:输入完整脚本,返回 `step` 结果的 JSON 字符串;
/// null 表示引擎不可用、执行失败或单步超时。
typedef ImagePluginEvaluator = Future<String?> Function(String js);

/// 插件执行失败(校验不通过、JS 报错、超时或上游返回错误)。
///
/// [message] 面向用户展示,插件作者写的错误文案通常可直接使用。
class ImagePluginException implements Exception {
  /// 面向用户的失败原因。
  final String message;

  const ImagePluginException(this.message);

  @override
  String toString() => message;
}

/// 响应体超限时在流读取里抛出、被网络层就地转成失败响应的内部信号。
class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}

/// 生图 JS 插件宿主:用同步 `step(ctx)` 状态机 + Dart 受限 HTTP/sleep 执行,
/// 统一承载 generate / test / listModels 三种操作。内置协议(对话式网关、
/// Nai2API)亦以仓库自带插件走这条路径。
class PluginImageBackend implements ImageBackend {
  /// 单次操作允许的状态机步数上限。存在的意义是拦住不消耗时间的 JS 死循环
  /// (每步都要一次 JS 求值);带节奏的轮询不在此列 —— 内置 Nai2API 插件按
  /// 旧后端节奏(排队 1s / 生成中 500ms)轮询,一轮占 2 步(sleep + http),
  /// 5 分钟预算下最多约 1200 步,故上限必须显著高于轮询需求量,否则长排队
  /// 会被误报成「步数超过上限」而不是正常等到出图。真正的耗时兜底是总预算。
  static const int _maxSteps = 2048;

  /// 插件状态/设置序列化后的上限,防止单步上下文无限膨胀。
  static const int _maxStateBytes = 256 * 1024;

  /// 单次 HTTP 请求体与响应体的字节上限。
  static const int _maxBodyBytes = 8 * 1024 * 1024;

  /// 单幅图片解码后的字节上限。
  static const int _maxImageBytes = 8 * 1024 * 1024;

  /// 单次生成允许返回的图片数上限(与配置的每次生图数量一致)。
  static const int _maxImages = 6;

  /// 插件可请求的单请求超时上限(下限是 [requestTimeout] 之外的 `timeoutMs`)。
  /// 对话式生图网关排队可达数分钟,旧后端给该请求 5 分钟;不给插件放大空间
  /// 就会把「正在出的图」在 30s 掐断。总预算 [timeout] 仍然是硬上界。
  static const Duration _maxRequestTimeout = Duration(minutes: 10);
  static const Set<String> _methods = {
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
  };

  /// 本次生图使用的参数与凭据。
  final ImageConfig config;

  /// 当前插件定义;null 或 id 不匹配时拒绝执行。
  final ImagePlugin? plugin;

  /// JS 求值器;null 表示当前平台不支持插件。
  final ImagePluginEvaluator? evaluator;

  /// 测试注入的 HTTP client;生产为 null,每次操作独享新建。
  final http.Client? client;

  /// 单次操作(含全部轮询与重试)的总预算。
  final Duration timeout;

  /// 未声明 `timeoutMs` 的单次 HTTP 请求默认超时。
  final Duration requestTimeout;

  const PluginImageBackend({
    required this.config,
    required this.plugin,
    required this.evaluator,
    this.client,
    this.timeout = const Duration(minutes: 5),
    this.requestTimeout = const Duration(seconds: 30),
  });

  @override
  String get id => 'plugin:${config.pluginId ?? 'unknown'}';

  @override
  Future<ImageResult> generateImage(String prompt) async {
    final done = await _run('generate', prompt: prompt, budget: timeout);
    return _parseImages(done['images']);
  }

  /// 执行插件的 `test` 操作;插件不支持时返回 null。
  Future<ImageProbe?> probe() async {
    if (plugin?.supportsTest != true) return null;
    final done = await _run('test', budget: const Duration(seconds: 30));
    final message = done['message'];
    final model = done['defaultModel'];
    return ImageProbe(
      message is String && message.isNotEmpty ? message : '连接成功',
      defaultModel: model is String ? model : null,
    );
  }

  /// 执行插件的 `listModels` 操作;插件不支持或结果非法时返回空列表。
  Future<List<String>> listModels() async {
    if (plugin?.supportsListModels != true) return const [];
    final done = await _run('listModels', budget: const Duration(seconds: 30));
    final models = done['models'];
    if (models is! List) return const [];
    return [
      for (final m in models)
        if (m is String) m,
    ];
  }

  /// 跑一遍状态机直到插件返回 done;error 动作与失信(非法动作/origin 越权/
  /// 非法结果)抛 [ImagePluginException]。网络传输失败不抛,而是回传给 JS。
  Future<Map<String, dynamic>> _run(
    String operation, {
    String? prompt,
    required Duration budget,
  }) async {
    final activePlugin = plugin;
    if (activePlugin == null || activePlugin.id != config.pluginId) {
      throw const ImagePluginException('生图插件不存在，请重新导入或更改配置');
    }
    if (!activePlugin.enabled) {
      throw ImagePluginException('生图插件「${activePlugin.name}」已停用');
    }
    final evaluate = evaluator;
    if (evaluate == null) {
      throw const ImagePluginException('当前平台无法使用 JS 生图插件');
    }
    final settings = _effectiveSettings(activePlugin);
    final params = _standardParams();

    final owned = client == null ? http.Client() : null;
    final httpClient = owned ?? client!;
    final stopwatch = Stopwatch()..start();
    Object? state;
    Map<String, dynamic>? response;
    var phase = 'start';
    var steps = 0;
    try {
      while (true) {
        final remaining = budget - stopwatch.elapsed;
        if (remaining <= Duration.zero) {
          throw ImagePluginException(
            '插件${_operationLabel(operation)}超时(超过 ${_formatBudget(budget)})',
          );
        }
        if (++steps > _maxSteps) {
          throw const ImagePluginException('插件执行步数超过上限');
        }
        final context = <String, dynamic>{
          'operation': operation,
          'phase': phase,
          'prompt': prompt,
          'negativePrompt': _negativePrompt,
          'params': params,
          'settings': settings,
          'state': state,
          if (response != null) 'response': response,
        };
        final action = await _evaluate(
          activePlugin,
          evaluate,
          context,
        ).timeout(remaining);
        final type = action['action'];
        if (type == 'error') {
          final message = action['message'];
          throw ImagePluginException(
            message is String && message.trim().isNotEmpty
                ? message.trim()
                : '插件报告${_operationLabel(operation)}失败',
          );
        }
        if (type == 'done') return action;
        if (type == 'sleep') {
          state = _parseState(action);
          final milliseconds = action['milliseconds'];
          if (milliseconds is! int ||
              milliseconds < 0 ||
              milliseconds > 60000) {
            throw const ImagePluginException('插件 sleep 毫秒数无效(允许 0–60000)');
          }
          final afterSleep = budget - stopwatch.elapsed;
          final delay = Duration(
            milliseconds: math.min(
              milliseconds,
              math.max(0, afterSleep.inMilliseconds),
            ),
          );
          await Future.delayed(delay);
          if (stopwatch.elapsed >= budget) {
            throw ImagePluginException(
              '插件${_operationLabel(operation)}超时(超过 ${_formatBudget(budget)})',
            );
          }
          phase = 'sleep';
          response = null;
          continue;
        }
        if (type == 'http') {
          state = _parseState(action);
          final request = action['request'];
          if (request is! Map<String, dynamic>) {
            throw const ImagePluginException('插件 http 动作缺少 request');
          }
          response = await _executeRequest(
            httpClient,
            activePlugin,
            settings,
            request,
            budget - stopwatch.elapsed,
          );
          phase = 'http';
          continue;
        }
        throw const ImagePluginException('插件返回了未知动作');
      }
    } on TimeoutException {
      throw ImagePluginException('插件${_operationLabel(operation)}超时');
    } finally {
      owned?.close();
    }
  }

  static String _operationLabel(String operation) => switch (operation) {
    'test' => '连接测试',
    'listModels' => '模型列表',
    _ => '生图',
  };

  /// 超时文案里的预算时长:生图是分钟级,连接测试/模型列表是 30 秒级 ——
  /// 用 `inMinutes` 后者会显示成「超过 0 分钟」。
  static String _formatBudget(Duration budget) => budget.inSeconds >= 60
      ? '${budget.inMinutes} 分钟'
      : '${budget.inSeconds} 秒';

  String get _negativePrompt {
    final configured = config.negative;
    return configured == null || configured.trim().isEmpty
        ? kDefaultNegativePrompt
        : configured.trim();
  }

  /// 标准生图参数(来自 ImageConfig 并集列),供内置协议插件与画面风格预设复用。
  ///
  /// `negative` 是**用户原始值**(未填为 null),与已兜底注入默认负面词的
  /// `ctx.negativePrompt` 并存:旧对话式网关只在用户显式配置负面词时才把
  /// `negative` 放进 `nai` 覆盖对象,只给一个合并值就复刻不出该语义。
  Map<String, dynamic> _standardParams() => {
    'size': config.size,
    'scale': config.scale,
    'cfg': config.cfg,
    'sampler': config.sampler,
    'artist': config.artist,
    'noiseSchedule': config.noiseSchedule,
    'steps': config.steps,
    'nocache': config.nocache,
    'count': config.count,
    'negative': config.negative,
  };

  Map<String, dynamic> _effectiveSettings(ImagePlugin activePlugin) {
    // 核心 baseUrl/apiKey/model 恒由列提供(内置协议插件直接读它们),
    // 覆盖同名 pluginSettings,保证单一来源。
    final settings = <String, dynamic>{
      ...config.pluginSettings,
      'baseUrl': config.baseUrl,
      'apiKey': config.apiKey,
      'model': config.model,
    };
    for (final field in activePlugin.fields) {
      if (field.required) {
        final value = settings[field.key];
        if (value == null || (value is String && value.trim().isEmpty)) {
          throw ImagePluginException('请填写插件设置「${field.label}」');
        }
      }
      final value = settings[field.key];
      if (value == null) continue;
      final valid = switch (field.type) {
        ImagePluginFieldType.text ||
        ImagePluginFieldType.password ||
        ImagePluginFieldType.url => value is String,
        ImagePluginFieldType.integer => value is int,
        ImagePluginFieldType.number => value is num,
        ImagePluginFieldType.boolean => value is bool,
        ImagePluginFieldType.select =>
          value is String &&
              field.options.any((option) => option.value == value),
      };
      if (!valid) {
        throw ImagePluginException('插件设置「${field.label}」的值或类型无效');
      }
    }
    if (utf8.encode(jsonEncode(settings)).length > _maxStateBytes) {
      throw const ImagePluginException('插件设置数据过大');
    }
    return settings;
  }

  Future<Map<String, dynamic>> _evaluate(
    ImagePlugin activePlugin,
    ImagePluginEvaluator evaluate,
    Map<String, dynamic> context,
  ) async {
    final script =
        '''
(function() {
  "use strict";
  var __pluginContext = JSON.parse(${jsonEncode(jsonEncode(context))});
${activePlugin.code}
  if (typeof step !== "function") throw new Error("step is not defined");
  return JSON.stringify(step(__pluginContext));
})()
''';
    final result = await evaluate(script);
    if (result == null) {
      throw const ImagePluginException('插件 JS 执行失败或单步超时');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(result);
    } on FormatException {
      throw const ImagePluginException('插件 step 未返回有效 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ImagePluginException('插件 step 必须返回对象');
    }
    return decoded;
  }

  Object? _parseState(Map<String, dynamic> action) {
    if (!action.containsKey('state')) {
      throw const ImagePluginException('插件 http/sleep 动作缺少 state');
    }
    final state = action['state'];
    final String encoded;
    try {
      encoded = jsonEncode(state);
    } on JsonUnsupportedObjectError {
      throw const ImagePluginException('插件 state 不是可序列化 JSON');
    }
    if (utf8.encode(encoded).length > _maxStateBytes) {
      throw const ImagePluginException('插件 state 超过 256KB 上限');
    }
    return state;
  }

  /// done.images 每项 `{base64}` 或 `{url}`;URL 原样进 ImageResult,由上层
  /// `downloadImageBase64` 本地化(与旧内置后端行为一致)。
  ImageResult _parseImages(Object? rawImages) {
    if (rawImages is! List ||
        rawImages.isEmpty ||
        rawImages.length > _maxImages) {
      throw const ImagePluginException('插件 done 必须返回 1–6 幅图片');
    }
    final images = <ImageEntry>[];
    for (final raw in rawImages) {
      if (raw is! Map<String, dynamic>) {
        throw const ImagePluginException('插件图片项必须是对象');
      }
      final base64 = raw['base64'];
      final url = raw['url'];
      if (base64 is String && base64.isNotEmpty) {
        // 只做无分配的语法/体积校验,原串直接进 ImageEntry —— 旧实现
        // base64Decode + base64Encode 往返,每张图白白多一次解码与重新编码,
        // 并让 Dart 堆同时驻留原串和一份解码字节。
        final decodedLength = _decodedBase64Length(base64);
        if (decodedLength == null) {
          throw const ImagePluginException('插件返回了无效 base64 图片');
        }
        if (decodedLength <= 0 || decodedLength > _maxImageBytes) {
          throw const ImagePluginException('插件图片为空或超过 8MB 上限');
        }
        images.add(ImageEntry(base64: base64));
      } else if (url is String && url.trim().isNotEmpty) {
        final uri = Uri.tryParse(url.trim());
        if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
          throw const ImagePluginException('插件图片 URL 必须是 http(s) 绝对地址');
        }
        images.add(ImageEntry(url: url.trim()));
      } else {
        throw const ImagePluginException('插件图片项必须含 base64 或 url');
      }
    }
    return ImageResult(images);
  }

  /// 校验标准 base64(Dart `base64Decode` 的口径:长度是 4 的倍数、仅末尾
  /// 0–2 个 `=`)并返回解码后的字节数;非法返回 null。逐字符扫描不分配
  /// 解码缓冲区 —— 8MB 图片的 base64 约 11M 字符,比完整解码便宜得多。
  static int? _decodedBase64Length(String text) {
    final len = text.length;
    if (len == 0 || len % 4 != 0) return null;
    var padding = 0;
    if (text.codeUnitAt(len - 1) == 0x3D) {
      padding = 1;
      if (len > 1 && text.codeUnitAt(len - 2) == 0x3D) padding = 2;
    }
    for (var i = 0; i < len - padding; i++) {
      final c = text.codeUnitAt(i);
      final ok =
          (c >= 0x41 && c <= 0x5A) || // A-Z
          (c >= 0x61 && c <= 0x7A) || // a-z
          (c >= 0x30 && c <= 0x39) || // 0-9
          c == 0x2B || // +
          c == 0x2F; // /
      if (!ok) return null;
    }
    return len ~/ 4 * 3 - padding;
  }

  /// 执行一次 HTTP:成功返回 status/headers/text|base64/isRedirect;传输层失败
  /// (超时/连接/握手/超限)返回 `{error, receivedBytes}` 交 JS 决策(宿主不重试)。
  Future<Map<String, dynamic>> _executeRequest(
    http.Client httpClient,
    ImagePlugin activePlugin,
    Map<String, dynamic> settings,
    Map<String, dynamic> request,
    Duration remaining,
  ) async {
    if (remaining <= Duration.zero) {
      throw const ImagePluginException('插件生图超时');
    }
    final method = request['method'] is String
        ? (request['method'] as String).toUpperCase()
        : '';
    if (!_methods.contains(method)) {
      throw const ImagePluginException('插件 HTTP method 无效');
    }
    final uri = _requestUri(activePlugin, settings, request['url']);
    final headers = _requestHeaders(request['headers']);
    final body = _requestBody(method, request, headers);
    final outgoing = http.Request(method, uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll(headers);
    if (body != null) outgoing.bodyBytes = body;

    // 插件可用 `timeoutMs` 请求更长(排队数分钟的生成 POST),上限为本次操作的
    // 剩余预算与 [_maxRequestTimeout];缺省走 [requestTimeout]。
    // **绝不能把插件请求的值再夹到 requestTimeout** —— 那等于「放大超时」这个
    // 能力根本不存在:对话式生图网关的生成 POST 要 5 分钟,夹成 30s 会把正在
    // 排队出图的请求稳定掐死,表现为整轮生图失败。
    final requested = request['timeoutMs'] is int && request['timeoutMs'] as int > 0
        ? request['timeoutMs'] as int
        : requestTimeout.inMilliseconds;
    final ceiling = math.min(remaining.inMilliseconds, _maxRequestTimeout.inMilliseconds);
    final budget = Duration(milliseconds: math.max(1, math.min(requested, ceiling)));

    var receivedBytes = false;
    final requestWatch = Stopwatch()..start();
    try {
      final response = await httpClient.send(outgoing).timeout(budget);
      final bodyBudget = budget - requestWatch.elapsed;
      if (bodyBudget <= Duration.zero) {
        return {'error': 'timeout', 'receivedBytes': receivedBytes};
      }
      final contentType = response.headers['content-type'] ?? '';
      final asText = !contentType.toLowerCase().startsWith('image/');
      final stop = asText ? _parseStopWhen(request) : null;
      final builder = BytesBuilder(copy: false);
      var length = 0;
      var stoppedEarly = false;
      final finished = Completer<void>();
      void finishError(Object error) {
        if (!finished.isCompleted) finished.completeError(error);
      }

      // 显式订阅而非 for-await:提前截断/超时都要 cancel 底层订阅,否则被放弃的
      // 响应还在后台继续往内存里灌字节。但**截断路径不能 await 这个 cancel**:
      // HttpClientResponse 的取消为复用保活连接会把剩余正文读完才回 —— 服务端
      // 出图后仍保活数十秒时,等待取消就等于把「链接早到手」硬拖成超时,正好
      // 丢掉提前截断要省的时间。连接最终由 `_run` 结束时 close 的 client 收掉。
      final sub = response.stream.listen(
        (chunk) {
          receivedBytes = true;
          length += chunk.length;
          if (length > _maxBodyBytes) {
            finishError(const _ResponseTooLarge());
            return;
          }
          builder.add(chunk);
          if (stop != null && !stoppedEarly) {
            // 先用新到分片做一次廉价子串门控(UTF-8 后续字节恒 ≥0x80,不会
            // 误撞 ASCII needle),命中才对整段缓冲跑正则 —— 与旧后端逐分片
            // 检查 `](` 同款省算,避免每分片 O(缓冲长度) 全量匹配。
            // 链接的 `](` 恰被拆到两个分片时门控落空,退回读完整流,由 JS 的
            // SSE 重组兜底提取(与旧后端的兜底路径一致)。
            if (String.fromCharCodes(chunk).contains(stop.contains) &&
                stop.regex.hasMatch(utf8.decode(builder.toBytes(), allowMalformed: true))) {
              stoppedEarly = true;
              if (!finished.isCompleted) finished.complete();
            }
          }
        },
        onError: finishError,
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: true,
      );
      var timedOut = false;
      try {
        await finished.future.timeout(bodyBudget, onTimeout: () => timedOut = true);
      } on TimeoutException {
        timedOut = true;
      } finally {
        if (stoppedEarly || timedOut) {
          sub.cancel().ignore();
        } else {
          await sub.cancel();
        }
      }
      if (timedOut) {
        return {'error': 'timeout', 'receivedBytes': receivedBytes};
      }
      return _decodeResponse(response, builder.takeBytes(), partial: stoppedEarly);
    } on _ResponseTooLarge {
      return {'error': 'tooLarge', 'receivedBytes': true};
    } on TimeoutException {
      return {'error': 'timeout', 'receivedBytes': receivedBytes};
    } on http.ClientException {
      return {'error': 'network', 'receivedBytes': receivedBytes};
    } on SocketException {
      return {'error': 'network', 'receivedBytes': receivedBytes};
    } on HandshakeException {
      return {'error': 'network', 'receivedBytes': receivedBytes};
    }
  }

  /// 解析 `request.stopWhen`(`{contains, regex}`):流式响应里目标内容一到位就
  /// 断开读取。旧对话式生图后端靠它把「链接已到、服务端还保活数十秒」的等待
  /// 砍掉 —— 没有等价机制,内置插件会把已经出好的图硬拖成请求超时。
  ({String contains, RegExp regex})? _parseStopWhen(Map<String, dynamic> request) {
    final raw = request['stopWhen'];
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw const ImagePluginException('插件 stopWhen 必须是对象');
    }
    final contains = raw['contains'];
    final pattern = raw['regex'];
    if (contains is! String || contains.isEmpty || contains.length > 64) {
      throw const ImagePluginException('插件 stopWhen.contains 无效(需 1–64 字符)');
    }
    if (pattern is! String || pattern.isEmpty || pattern.length > 500) {
      throw const ImagePluginException('插件 stopWhen.regex 无效(需 1–500 字符)');
    }
    try {
      return (contains: contains, regex: RegExp(pattern));
    } on FormatException {
      throw const ImagePluginException('插件 stopWhen.regex 不是合法正则');
    }
  }

  Map<String, dynamic> _decodeResponse(
    http.StreamedResponse response,
    Uint8List bytes, {
    bool partial = false,
  }) {
    final contentType = response.headers['content-type'] ?? '';
    final result = <String, dynamic>{
      'status': response.statusCode,
      'headers': response.headers,
      'contentType': contentType,
      'isRedirect': response.isRedirect,
      if (partial) 'partial': true,
    };
    if (!contentType.toLowerCase().startsWith('image/')) {
      try {
        // stopWhen 的截断按字节分片边界发生,可能切在多字节字符中间。partial
        // 时允许畸形序列 —— 否则整段正文退成 base64,插件拿不到 text,把
        // 「链接已在截断前到达」误判成「响应中未找到图片链接」。
        result['text'] = utf8.decode(bytes, allowMalformed: partial);
        return result;
      } on FormatException {
        // 非 UTF-8 正文回落 base64。
      }
    }
    result['base64'] = base64Encode(bytes);
    return result;
  }

  Uri _requestUri(
    ImagePlugin activePlugin,
    Map<String, dynamic> settings,
    Object? rawUrl,
  ) {
    if (rawUrl is! String || rawUrl.trim().isEmpty) {
      throw const ImagePluginException('插件 HTTP URL 无效');
    }
    final value = rawUrl.trim();
    Uri uri;
    final endpointKey = activePlugin.permissions.endpointSetting;
    if (Uri.parse(value).isAbsolute) {
      uri = Uri.parse(value);
    } else {
      if (endpointKey == null) {
        throw const ImagePluginException('插件未声明 endpointSetting，不能使用相对 URL');
      }
      final endpoint = _endpoint(settings, endpointKey);
      final basePath = endpoint.path.endsWith('/')
          ? endpoint.path
          : '${endpoint.path}/';
      uri = endpoint.replace(path: basePath).resolve(value);
    }
    if (!(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const ImagePluginException('插件仅允许不含用户信息的 HTTP(S) URL');
    }
    final allowed = <String>{...activePlugin.permissions.allowedOrigins};
    if (endpointKey != null) {
      allowed.add(_endpoint(settings, endpointKey).origin);
    }
    if (!allowed.contains(uri.origin)) {
      throw ImagePluginException('插件请求 origin 未获授权:${uri.origin}');
    }
    return uri;
  }

  Uri _endpoint(Map<String, dynamic> settings, String key) {
    final raw = settings[key];
    if (raw is! String || raw.trim().isEmpty) {
      throw const ImagePluginException('插件服务地址未配置');
    }
    final uri = Uri.parse(raw.trim());
    if (!(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ImagePluginException('插件服务地址必须是有效的 HTTP(S) base URL');
    }
    return uri;
  }

  Map<String, String> _requestHeaders(Object? raw) {
    if (raw == null) return {};
    if (raw is! Map<String, dynamic>) {
      throw const ImagePluginException('插件 HTTP headers 必须是对象');
    }
    if (raw.length > 100) {
      throw const ImagePluginException('插件 HTTP headers 过多');
    }
    final headers = <String, String>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! String ||
          entry.key.contains(RegExp(r'[\r\n]')) ||
          value.contains(RegExp(r'[\r\n]'))) {
        throw const ImagePluginException('插件 HTTP header 名称或值无效');
      }
      headers[entry.key] = value;
    }
    return headers;
  }

  static void _setDefaultContentType(
    Map<String, String> headers,
    String value,
  ) {
    if (!headers.keys.any((key) => key.toLowerCase() == 'content-type')) {
      headers['content-type'] = value;
    }
  }

  Uint8List? _requestBody(
    String method,
    Map<String, dynamic> request,
    Map<String, String> headers,
  ) {
    final keys = ['json', 'text', 'base64'].where(request.containsKey).toList();
    if (keys.length > 1) {
      throw const ImagePluginException('插件 HTTP body 只能选择 json/text/base64 之一');
    }
    if (keys.isEmpty) return null;
    if (method == 'GET' || method == 'HEAD') {
      throw const ImagePluginException('GET/HEAD 请求不能携带 body');
    }
    final key = keys.single;
    final value = request[key];
    late final Uint8List bytes;
    if (key == 'json') {
      try {
        bytes = utf8.encode(jsonEncode(value));
      } on JsonUnsupportedObjectError {
        throw const ImagePluginException('插件 JSON body 无法序列化');
      }
      _setDefaultContentType(headers, 'application/json; charset=utf-8');
    } else if (key == 'text') {
      if (value is! String) {
        throw const ImagePluginException('插件 text body 必须是字符串');
      }
      bytes = utf8.encode(value);
      _setDefaultContentType(headers, 'text/plain; charset=utf-8');
    } else {
      if (value is! String) {
        throw const ImagePluginException('插件 base64 body 必须是字符串');
      }
      try {
        bytes = base64Decode(value);
      } on FormatException {
        throw const ImagePluginException('插件 base64 body 无效');
      }
      _setDefaultContentType(headers, 'application/octet-stream');
    }
    if (bytes.length > _maxBodyBytes) {
      throw const ImagePluginException('插件 HTTP 请求体超过 8MB 上限');
    }
    return bytes;
  }
}
