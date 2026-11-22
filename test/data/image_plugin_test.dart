// 生图插件单文件包:toPackageJson 往返、manifest 不含 code、体积上限。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/image_plugin.dart';

void main() {
  const plugin = ImagePlugin(
    id: 'example.image',
    name: 'Example',
    version: '1.1.0',
    code: 'function step(ctx) { return {action: "error", message: "x"}; }',
    fields: [
      ImagePluginField(
        key: 'endpoint',
        label: 'Endpoint',
        type: ImagePluginFieldType.url,
        required: true,
      ),
      ImagePluginField(
        key: 'mode',
        label: 'Mode',
        type: ImagePluginFieldType.select,
        options: [
          ImagePluginOption(value: 'a', label: 'A'),
          ImagePluginOption(value: 'b', label: 'B'),
        ],
      ),
      ImagePluginField(
        key: 'retries',
        label: 'Retries',
        type: ImagePluginFieldType.integer,
        defaultValue: 1,
      ),
    ],
    permissions: ImagePluginPermissions(
      allowedOrigins: ['https://api.example.com'],
      endpointSetting: 'endpoint',
    ),
    usesStandardParams: true,
    supportsTest: true,
    supportsListModels: true,
  );

  test('toPackageJson round-trips through fromPackageJson with code intact', () {
    final source = plugin.toPackageJson();
    expect(source, contains('function step'));
    final parsed = ImagePlugin.fromPackageJson(source);
    expect(parsed.id, plugin.id);
    expect(parsed.name, plugin.name);
    expect(parsed.version, plugin.version);
    expect(parsed.code, plugin.code);
    expect(parsed.usesStandardParams, isTrue);
    expect(parsed.supportsTest, isTrue);
    expect(parsed.supportsListModels, isTrue);
    expect(parsed.permissions.endpointSetting, 'endpoint');
    expect(parsed.permissions.allowedOrigins, ['https://api.example.com']);
    expect(parsed.fields.map((field) => field.key), ['endpoint', 'mode', 'retries']);
    expect(parsed.fields.last.defaultValue, 1);
  });

  test('toManifestJson omits code; toPackageJson adds it', () {
    expect(plugin.toManifestJson(), isNot(contains('"code"')));
    expect(plugin.toPackageJson(), contains('"code"'));
    expect(plugin.toPackageJson(), startsWith('{"formatVersion":1,'));
  });

  test('packages larger than 1MB are rejected', () {
    final huge = '{"formatVersion":1,"id":"x","name":"X","version":"1","code":"'
        '${'a' * (kMaxImagePluginPackageBytes + 1)}"}';
    expect(
      () => ImagePlugin.fromPackageJson(huge),
      throwsA(isA<FormatException>()),
    );
  });
}