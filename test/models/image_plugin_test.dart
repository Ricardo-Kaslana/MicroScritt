// 生图插件包模型测试:manifest 校验、设置字段默认值与 origin 规范化。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/image_plugin.dart';

void main() {
  Map<String, dynamic> package() => {
    'formatVersion': 1,
    'id': 'example.image',
    'name': 'Example',
    'version': '1.2.3',
    'settings': [
      {'key': 'baseUrl', 'label': 'URL', 'type': 'url', 'required': true},
      {'key': 'token', 'label': 'Token', 'type': 'password'},
      {'key': 'steps', 'label': 'Steps', 'type': 'integer', 'default': 20},
      {
        'key': 'guidance',
        'label': 'Guidance',
        'type': 'number',
        'default': 6.5,
      },
      {
        'key': 'enabled',
        'label': 'Enabled',
        'type': 'boolean',
        'default': true,
      },
      {
        'key': 'size',
        'label': 'Size',
        'type': 'select',
        'default': 'square',
        'options': [
          {'value': 'square', 'label': 'Square'},
        ],
      },
    ],
    'permissions': {
      'endpointSetting': 'baseUrl',
      'allowedOrigins': ['https://cdn.example.com/'],
    },
    'code': 'function step(ctx) { return {action: "error", message: "test"}; }',
  };

  test(
    'valid package parses fields, defaults, permissions and storage round-trip',
    () {
      final plugin = ImagePlugin.fromPackageJson(jsonEncode(package()));

      expect(plugin.id, 'example.image');
      expect(plugin.fields, hasLength(6));
      expect(plugin.fields[2].defaultValue, 20);
      expect(plugin.fields[4].defaultValue, isTrue);
      expect(plugin.permissions.allowedOrigins, ['https://cdn.example.com']);

      final restored = ImagePlugin.fromStorageJson(
        plugin.toManifestJson(),
        plugin.code,
        false,
      );
      expect(restored.name, plugin.name);
      expect(
        restored.fields
            .singleWhere((field) => field.key == 'size')
            .options
            .single
            .value,
        'square',
      );
      expect(restored.enabled, isFalse);
    },
  );

  test('invalid manifests fail at import instead of reaching generation', () {
    final invalid = <Map<String, dynamic>>[];
    invalid.add({...package(), 'formatVersion': 99});
    invalid.add({...package(), 'id': 'bad id'});
    final duplicate = package();
    duplicate['settings'] = [
      {'key': 'same', 'label': 'A', 'type': 'text'},
      {'key': 'same', 'label': 'B', 'type': 'text'},
    ];
    invalid.add(duplicate);
    final wrongEndpoint = package();
    wrongEndpoint['permissions'] = {'endpointSetting': 'token'};
    invalid.add(wrongEndpoint);
    final wrongDefault = package();
    (wrongDefault['settings'] as List).removeAt(2);
    wrongDefault['settings'] = [
      {
        'key': 'steps',
        'label': 'Steps',
        'type': 'integer',
        'default': 'twenty',
      },
    ];
    wrongDefault['permissions'] = <String, dynamic>{};
    invalid.add(wrongDefault);

    for (final value in invalid) {
      expect(
        () => ImagePlugin.fromPackageJson(jsonEncode(value)),
        throwsFormatException,
      );
    }
  });

  test('origins are exact HTTP(S) origins, not paths or wildcard URLs', () {
    expect(
      normalizeImagePluginOrigin('http://127.0.0.1:8080/'),
      'http://127.0.0.1:8080',
    );
    for (final value in [
      'file:///tmp/a',
      'https://example.com/path',
      'https://*',
      'https://user@example.com',
    ]) {
      expect(() => normalizeImagePluginOrigin(value), throwsFormatException);
    }
  });
}
