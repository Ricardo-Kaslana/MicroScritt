// `imageBackendProvider` 恒路由到 PluginImageBackend(内置协议也是仓库自带
// 插件),这是"新增生图服务不改调用方"的唯一接缝,单独钉住。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/image_backend.dart';
import 'package:microscritt/backend/plugin_image_backend.dart';
import 'package:microscritt/models/image_config.dart';
import 'package:microscritt/models/image_plugin.dart';
import 'package:microscritt/state/providers.dart';

void main() {
  const catalog = [
    ImagePlugin(
      id: 'microscritt.chat-completions',
      name: '网关',
      version: '1',
      code: 'function step(){}',
    ),
    ImagePlugin(
      id: 'microscritt.nai2',
      name: 'Nai2',
      version: '1',
      code: 'function step(){}',
    ),
  ];

  ImageBackend? resolve({String? pluginId}) {
    final container = ProviderContainer(
      overrides: [imagePluginsProvider.overrideWith((ref) => catalog)],
    );
    addTearDown(container.dispose);
    container.read(imageConfigProvider.notifier).state = ImageConfig(
      kind: ImageBackendKind.plugin,
      apiKey: '',
      model: '',
      pluginId: pluginId,
    );
    return container.read(imageBackendProvider);
  }

  test('config 为 null 时无后端(生图整轮跳过)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(imageBackendProvider), isNull);
  });

  test('按 pluginId 解析到插件目录里的插件', () {
    final backend = resolve(pluginId: 'microscritt.nai2')!;
    expect(backend, isA<PluginImageBackend>());
    expect(backend.id, 'plugin:microscritt.nai2');
    expect((backend as PluginImageBackend).plugin?.name, 'Nai2');
  });

  test('插件缺失时仍返回后端,由生成时抛出明确错误(不静默掉轮)', () {
    final backend = resolve(pluginId: 'gone.example')!;
    expect((backend as PluginImageBackend).plugin, isNull);
  });

  test('kind 收敛为单一 plugin,wire/fromWire 闭环且脏值安全回落', () {
    expect(ImageBackendKind.values, [ImageBackendKind.plugin]);
    expect(ImageBackendKind.plugin.wire, 'plugin');
    expect(ImageBackendKind.fromWire('plugin'), ImageBackendKind.plugin);
    expect(
      ImageBackendKind.fromWire('chat_completions'),
      ImageBackendKind.plugin,
    );
    expect(ImageBackendKind.fromWire(null), ImageBackendKind.plugin);
  });

  test('ImageConfig 默认值:kind 恒 plugin、无预置端点/模型', () {
    const config = ImageConfig(apiKey: 'sk-x', model: 'm');
    expect(config.kind, ImageBackendKind.plugin);
    expect(config.baseUrl, isEmpty);
    expect(defaultImageModel(ImageBackendKind.plugin), isEmpty);
    expect(defaultImageBaseUrl(ImageBackendKind.plugin), isEmpty);
    expect(imageModelCandidates(ImageBackendKind.plugin), isEmpty);
  });
}
