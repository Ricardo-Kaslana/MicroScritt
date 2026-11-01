/// 生图插件包模型:manifest、动态设置字段、权限与代码。
///
/// 插件是单文件 JSON(`formatVersion: 1`):manifest 声明身份、设置表单、
/// 联网 origin 白名单与支持的操作,`code` 为同步 JS `step(ctx)`。宿主只
/// 执行受限动作(`http`/`sleep`/`done`/`error`),强制 origin 校验、超时、
/// 响应大小上限与禁重定向;解析失败一律抛 [FormatException],不进入
/// 数据库。
///
/// 内置协议插件同样经此模型解析,但代码由仓库维护、用户不可编辑。
library;

import 'dart:convert';

/// 当前支持的插件包格式版本;不匹配的包一律拒绝导入。
const int kImagePluginFormatVersion = 1;

/// 插件包(manifest + code)的最大字节数。
const int kMaxImagePluginPackageBytes = 1024 * 1024;

/// 插件 JS 代码的最大字节数;与包上限分开校验,防止 manifest 挤占额度。
const int kMaxImagePluginCodeBytes = 512 * 1024;

/// 动态设置字段的类型,决定设置页控件与默认值校验规则。
enum ImagePluginFieldType {
  /// 单行文本。
  text,

  /// 密码文本(界面默认遮蔽)。
  password,

  /// HTTP(S) 地址;可被 [ImagePluginPermissions.endpointSetting] 引用。
  url,

  /// 整数。
  integer,

  /// 数值(整数或小数)。
  number,

  /// 布尔开关。
  boolean,

  /// 枚举选择,必须提供非空 options 且默认值在选项内。
  select,
}

/// 插件声明的一项动态设置(渲染为设置页表单字段)。
class ImagePluginField {
  /// 设置键;写入 `pluginSettings`,须匹配 `^[A-Za-z][A-Za-z0-9_]{0,63}$`。
  final String key;

  /// 表单标签。
  final String label;

  /// 控件类型与默认值校验规则。
  final ImagePluginFieldType type;

  /// 是否必填;仅为界面提示,宿主不代插件做业务校验。
  final bool required;

  /// 默认值;null 表示无默认值,[type] 必须与之匹配。
  final Object? defaultValue;

  /// 输入提示文本,可为空。
  final String hint;

  /// [ImagePluginFieldType.select] 的可选值;其他类型恒为空。
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

/// [ImagePluginFieldType.select] 的一个选项。
class ImagePluginOption {
  /// 写入 `pluginSettings` 的值;允许空串。
  final String value;

  /// 下拉框展示文本。
  final String label;

  const ImagePluginOption({required this.value, required this.label});

  Map<String, Object?> toJson() => {'value': value, 'label': label};
}

/// 插件联网权限声明。
///
/// 宿主只允许请求 [allowedOrigins] 中的精确 origin(不匹配子域、不支持
/// 通配符),这是插件沙箱的边界;`http` 动作的相对路径会拼到 endpoint
/// 所在 origin 上。
class ImagePluginPermissions {
  /// 允许访问的精确 origin(如 `https://api.example.com`),不含路径。
  final List<String> allowedOrigins;

  /// 指定哪个设置字段提供端点 origin:`baseUrl` 表示核心配置的 API 地址,
  /// 其余值必须是本插件声明的 url 类型设置键。
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

/// 一个已解析的生图插件(manifest + 代码 + 启用状态)。
class ImagePlugin {
  /// 插件 id,须匹配 `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`。
  final String id;

  /// 显示名。
  final String name;

  /// 插件自报版本;仅用于展示与排障。
  final String version;

  /// 动态设置字段(有序,键唯一)。
  final List<ImagePluginField> fields;

  /// 联网权限声明。
  final ImagePluginPermissions permissions;

  /// 同步 JS `step(ctx)` 源码。
  final String code;

  /// 是否启用;停用后引用它的配置不可发起生图。
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

  /// 从单文件插件包解析;先校验总大小,再解析 JSON 与全部字段。
  ///
  /// 体积/格式/字段非法时抛 [FormatException],调用方据此提示导入失败。
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

  /// 从数据库行重建:manifest 与 code 分列存储,`enabled` 为当前启停状态。
  ///
  /// manifest 损坏时抛 [FormatException];调用方需 fail-safe 跳过坏行,
  /// 不能让单条插件记录阻断设置页加载。
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

  /// 编码 manifest(不含 code;code 在库中单独一列,避免重复存储)。
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

/// 归一化并校验联网 origin。
///
/// 只接受无用户信息、无通配符、无路径/查询/片段的 http(s) 地址;非法值抛
/// [FormatException]。返回 [Uri.origin] 形式,供严格相等匹配。
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
