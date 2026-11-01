import 'package:http/http.dart' as http;
import 'anthropic_backend.dart';
import 'backend_config.dart';
import 'llm_backend.dart';
import 'openai_backend.dart';

LlmBackend createBackend(BackendConfig config, {http.Client? client}) => switch (config.provider) {
      BackendProvider.openai => OpenAiBackend(config: config, client: client),
      BackendProvider.anthropic => AnthropicBackend(config: config, client: client),
    };
