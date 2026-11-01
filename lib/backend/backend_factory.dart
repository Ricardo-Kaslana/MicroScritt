/// 按协议创建 LLM 后端实例的工厂。
///
/// 调用方只依赖 `LlmBackend`,新增协议时在 `BackendProvider` 与这里同步
/// 增加分支;测试可注入自定义 `http.Client`。
library;

import 'package:http/http.dart' as http;
import 'anthropic_backend.dart';
import 'backend_config.dart';
import 'llm_backend.dart';
import 'openai_backend.dart';

/// 按 [BackendConfig.provider] 创建对应后端。
LlmBackend createBackend(BackendConfig config, {http.Client? client}) => switch (config.provider) {
      BackendProvider.openai => OpenAiBackend(config: config, client: client),
      BackendProvider.anthropic => AnthropicBackend(config: config, client: client),
    };
