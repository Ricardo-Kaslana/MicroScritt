/// 角色级气泡容器样式(仅助手气泡;存角色卡 `extensions.microscritt_bubble_style`,
/// 导入/导出随卡携带,ST 端忽略未知 extension 字段、互不干扰)。
///
/// 纯 Dart 模型:颜色用 0xAARRGGBB 整型存,不依赖 Flutter(models 层约定);
/// UI 侧再转 `Color`。全部字段可空,null = 沿用应用默认(iOS 风格白卡)。
class BubbleStyle {
  /// 气泡底色(0xAARRGGBB)。
  final int? bubbleColor;

  /// 正文文字颜色(0xAARRGGBB);null 时按底色亮度自动取深/浅。
  final int? textColor;

  /// 圆角半径(逻辑像素);null = 应用默认 18。
  final double? radius;

  /// 底色透明度(0–1);null = 不透明。
  final double? opacity;

  /// 正文字体族(null = 应用默认;如 `serif` 衬线/宋体风)。
  final String? fontFamily;

  const BubbleStyle({
    this.bubbleColor,
    this.textColor,
    this.radius,
    this.opacity,
    this.fontFamily,
  });

  /// 等同应用默认值(颜色未设 + 圆角为默认 18/未设 + 不透明度为 1/未设
  /// + 字体未设)= 未定制,走应用统一样式。
  bool get isDefault =>
      bubbleColor == null &&
      textColor == null &&
      (radius == null || radius == 18) &&
      (opacity == null || opacity == 1) &&
      (fontFamily == null || fontFamily!.isEmpty);

  BubbleStyle copyWith({
    int? bubbleColor,
    int? textColor,
    double? radius,
    double? opacity,
    String? fontFamily,
  }) =>
      BubbleStyle(
        bubbleColor: bubbleColor ?? this.bubbleColor,
        textColor: textColor ?? this.textColor,
        radius: radius ?? this.radius,
        opacity: opacity ?? this.opacity,
        fontFamily: fontFamily ?? this.fontFamily,
      );

  factory BubbleStyle.fromJson(Map<String, dynamic> json) => BubbleStyle(
        bubbleColor: (json['bubble_color'] as num?)?.toInt(),
        textColor: (json['text_color'] as num?)?.toInt(),
        radius: (json['radius'] as num?)?.toDouble(),
        opacity: (json['opacity'] as num?)?.toDouble(),
        fontFamily: json['font_family'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (bubbleColor != null) 'bubble_color': bubbleColor,
        if (textColor != null) 'text_color': textColor,
        if (radius != null) 'radius': radius,
        if (opacity != null) 'opacity': opacity,
        if (fontFamily != null && fontFamily!.isNotEmpty) 'font_family': fontFamily,
      };
}
