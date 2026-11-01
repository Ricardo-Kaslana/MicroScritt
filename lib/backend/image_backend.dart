/// 生图后端抽象与连接探测结果。
///
/// 运行链路只依赖 [ImageBackend.generateImage];插件专有的测试/模型列表
/// 能力不下沉到本接口。
library;

import '../models/image_result.dart';

/// 生图后端连接探测的回显(设置页「测试连接」用)。
class ImageProbe {
  /// 面向用户的连接结果摘要。
  final String summary;

  /// 服务端报告的默认模型;未提供时为 null。
  final String? defaultModel;

  const ImageProbe(this.summary, {this.defaultModel});
}

/// 生图抽象,平行于 LlmBackend。运行链路(编排器 / 后台引擎)只依赖
/// [generateImage];连接测试/模型列表是 [PluginImageBackend] 的带外能力,不进本接口。
abstract class ImageBackend {
  String get id;
  Future<ImageResult> generateImage(String prompt);
}

/// 测试用的固定图片后端;生产路径不得构造。
class FakeImageBackend implements ImageBackend {
  /// 每次生成的固定 base64 图片。
  final String base64;

  FakeImageBackend(this.base64);

  @override
  String get id => 'fake';

  @override
  Future<ImageResult> generateImage(String prompt) async =>
      ImageResult.single(base64: base64);
}
