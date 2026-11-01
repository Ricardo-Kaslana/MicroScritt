import 'dart:convert';

const int kImagePluginFormatVersion = 1;
const int kMaxImagePluginPackageBytes = 1024 * 1024;
const int kMaxImagePluginCodeBytes = 512 * 1024;

enum ImagePluginFieldType {
  text,
  password,
  url,
  integer,
  number,
  boolean,
  select,
}

class ImagePluginField {
  final String key;
  final String label;
  final ImagePluginFieldType type;
  final bool required;
  final Object? defaultValue;
  final String hint;
  final List<ImagePluginOption> options;

  const ImagePluginField({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
    this.defaultValue,
    this.hint = '',
    this.options = const [],
  });

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'type': type.name,
    if (required) 'required': true,
    if (defaultValue != null) 'default': defaultValue,
    if (hint.isNotEmpty) 'hint': hint,
    if (options.isNotEmpty)
      'options': [for (final option in options) option.toJson()],
  };
}

class ImagePluginOption {
  final String value;
  final String label;

  const ImagePluginOption({required this.value, required this.label});

  Map<String, Object?> toJson() => {'value': value, 'label': label};
}

class ImagePluginPermissions {
  final List<String> allowedOrigins;
  final String? endpointSetting;

  const ImagePluginPermissions({
    this.allowedOrigins = const [],
    this.endpointSetting,
  });

  Map<String, Object?> toJson() => {
    if (allowedOrigins.isNotEmpty) 'allowedOrigins': allowedOrigins,
    if (endpointSetting != null) 'endpointSetting': endpointSetting,
  };
}

class ImagePlugin {
  final String id;
  final String name;
  final String version;
  final List<ImagePluginField> fields;
  final ImagePluginPermissions permissions;
  final String code;
  final bool enabled;

  /// 该插件是否使用宿主的标准生图参数(size/scale/cfg/sampler/artist/噪声/步数/
  /// 负面词)与画面风格预设 —— 决定设置页是否渲染这些通用区块。
  final bool usesStandardParams;

  /// 是否支持设置页「测试连接」/「刷新模型列表」带外操作(经 step 的 test/listModels)。
  final bool supportsTest;
  final bool supportsListModels;

  const ImagePlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.code,
    this.fields = const [],
    this.permissions = const ImagePluginPermissions(),
    this.enabled = true,
    this.usesStandardParams = false,
    this.supportsTest = false,
    this.supportsListModels = false,
  });

  ImagePlugin copyWith({bool? enabled}) => ImagePlugin(
    id: id,
    name: name,
    version: version,
    fields: fields,
    permissions: permissions,
    code: code,
    enabled: enabled ?? this.enabled,
    usesStandardParams: usesStandardParams,
    supportsTest: supportsTest,
    supportsListModels: supportsListModels,
  );

  factory ImagePlugin.fromPackageJson(String source) {
    if (utf8.encode(source).length > kMaxImagePluginPackageBytes) {
      throw const FormatException('插件文件过大(上限 1MB)');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw FormatException('插件 JSON 无效:${e.message}');
    }
    return _parse(_object(decoded, '插件根节点'), null, true);
  }

  factory ImagePlugin.fromStorageJson(
    String manifest,
    String code,
    bool enabled,
  ) {
    return _parse(_object(jsonDecode(manifest), '插件 manifest'), code, enabled);
  }

  static ImagePlugin _parse(
    Map<String, dynamic> json,
    String? storedCode,
    bool enabled,
  ) {
    if (json['formatVersion'] != kImagePluginFormatVersion) {
      throw const FormatException('不支持的插件 formatVersion(当前仅支持 1)');
    }
    final id = _string(json['id'], 'id', 128);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
      throw const FormatException('插件 id 只能包含字母、数字、点、下划线和连字符');
    }
    final name = _string(json['name'], 'name', 100);
    final version = _string(json['version'], 'version', 40);
    final code =
        storedCode ?? _string(json['code'], 'code', kMaxImagePluginCodeBytes);
    if (code.trim().isEmpty) throw const FormatException('插件 code 不能为空');
    if (utf8.encode(code).length > kMaxImagePluginCodeBytes) {
      throw const FormatException('插件代码过大(上限 512KB)');
    }

    final rawFields = json['settings'] ?? const [];
    if (rawFields is! List) throw const FormatException('settings 必须是数组');
    final fields = <ImagePluginField>[];
    final keys = <String>{};
    for (final raw in rawFields) {
      final field = _parseField(_object(raw, 'settings 字段'));
      if (!keys.add(field.key)) throw FormatException('设置字段重复:${field.key}');
      fields.add(field);
    }

    final permissionsJson = _object(
      json['permissions'] ?? const <String, dynamic>{},
      'permissions',
    );
    final rawOrigins = permissionsJson['allowedOrigins'] ?? const [];
    if (rawOrigins is! List) {
      throw const FormatException('allowedOrigins 必须是数组');
    }
    final origins = <String>[];
    for (final raw in rawOrigins) {
      final origin = normalizeImagePluginOrigin(
        _string(raw, 'allowedOrigins 项', 2048),
      );
      if (!origins.contains(origin)) origins.add(origin);
    }
    final endpointSetting = permissionsJson['endpointSetting'] == null
        ? null
        : _string(permissionsJson['endpointSetting'], 'endpointSetting', 64);
    // endpointSetting 可指向核心 baseUrl(宿主恒把 config.baseUrl 注入 settings),
    // 或一个显式声明的 url 类型设置字段。
    if (endpointSetting != null &&
        endpointSetting != 'baseUrl' &&
        !fields.any(
          (field) =>
              field.key == endpointSetting &&
              field.type == ImagePluginFieldType.url,
        )) {
      throw const FormatException(
        'endpointSetting 必须是 baseUrl 或一个 url 类型的设置字段',
      );
    }

    final operations = _object(
      json['operations'] ?? const <String, dynamic>{},
      'operations',
    );

    return ImagePlugin(
      id: id,
      name: name,
      version: version,
      code: code,
      fields: List.unmodifiable(fields),
      permissions: ImagePluginPermissions(
        allowedOrigins: List.unmodifiable(origins),
        endpointSetting: endpointSetting,
      ),
      enabled: enabled,
      usesStandardParams: json['usesStandardParams'] == true,
      supportsTest: operations['test'] == true,
      supportsListModels: operations['listModels'] == true,
    );
  }

  static ImagePluginField _parseField(Map<String, dynamic> json) {
    final key = _string(json['key'], '设置 key', 64);
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(key)) {
      throw FormatException('设置 key 无效:$key');
    }
    final label = _string(json['label'], '设置 $key 的 label', 100);
    final typeName = _string(json['type'], '设置 $key 的 type', 20);
    final type = ImagePluginFieldType.values
        .where((value) => value.name == typeName)
        .firstOrNull;
    if (type == null) throw FormatException('设置 $key 的类型无效:$typeName');
    final required = json['required'] == true;
    final hint = json['hint'] == null
        ? ''
        : _string(json['hint'], '设置 $key 的 hint', 300, allowEmpty: true);
    final options = <ImagePluginOption>[];
    if (type == ImagePluginFieldType.select) {
      final rawOptions = json['options'];
      if (rawOptions is! List || rawOptions.isEmpty) {
        throw FormatException('select 设置 $key 必须提供 options');
      }
      final values = <String>{};
      for (final raw in rawOptions) {
        final option = _object(raw, '设置 $key 的选项');
        final value = _string(
          option['value'],
          '选项 value',
          300,
          allowEmpty: true,
        );
        final optionLabel = _string(option['label'], '选项 label', 100);
        if (!values.add(value)) throw FormatException('设置 $key 的选项值重复:$value');
        options.add(ImagePluginOption(value: value, label: optionLabel));
      }
    }
    final defaultValue = json['default'];
    _validateFieldValue(key, type, defaultValue, options, allowNull: true);
    return ImagePluginField(
      key: key,
      label: label,
      type: type,
      required: required,
      defaultValue: defaultValue,
      hint: hint,
      options: List.unmodifiable(options),
    );
  }

  static void _validateFieldValue(
    String key,
    ImagePluginFieldType type,
    Object? value,
    List<ImagePluginOption> options, {
    required bool allowNull,
  }) {
    if (value == null) {
      if (!allowNull) throw FormatException('设置 $key 缺少默认值');
      return;
    }
    final valid = switch (type) {
      ImagePluginFieldType.text ||
      ImagePluginFieldType.password ||
      ImagePluginFieldType.url => value is String,
      ImagePluginFieldType.integer => value is int,
      ImagePluginFieldType.number => value is num,
      ImagePluginFieldType.boolean => value is bool,
      ImagePluginFieldType.select =>
        value is String && options.any((option) => option.value == value),
    };
    if (!valid) throw FormatException('设置 $key 的默认值与类型不匹配');
  }

  String toManifestJson() => jsonEncode({
    'formatVersion': kImagePluginFormatVersion,
    'id': id,
    'name': name,
    'version': version,
    'settings': [for (final field in fields) field.toJson()],
    'permissions': permissions.toJson(),
    if (usesStandardParams) 'usesStandardParams': true,
    if (supportsTest || supportsListModels)
      'operations': {
        if (supportsTest) 'test': true,
        if (supportsListModels) 'listModels': true,
      },
  });

  static Map<String, dynamic> _object(Object? value, String name) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('$name 必须是 JSON 对象');
    }
    return value;
  }

  static String _string(
    Object? value,
    String name,
    int maxLength, {
    bool allowEmpty = false,
  }) {
    if (value is! String ||
        (!allowEmpty && value.trim().isEmpty) ||
        value.length > maxLength) {
      throw FormatException('$name 无效');
    }
    return value;
  }
}

String normalizeImagePluginOrigin(String value) {
  final uri = Uri.parse(value.trim());
  if (!(uri.isScheme('http') || uri.isScheme('https')) ||
      uri.host.isEmpty ||
      uri.host.contains('*') ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException('联网 origin 无效:$value');
  }
  return uri.origin;
}
