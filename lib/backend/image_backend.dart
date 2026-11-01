import '../models/image_result.dart';

/// 生图后端连接探测的回显(设置页「测试连接」用)。
class ImageProbe {
  final String summary;
  final String? defaultModel;

  const ImageProbe(this.summary, {this.defaultModel});
}

/// 生图抽象,平行于 LlmBackend。运行链路(编排器 / 后台引擎)只依赖
/// [generateImage];连接测试/模型列表是 [PluginImageBackend] 的带外能力,不进本接口。
abstract class ImageBackend {
  String get id;
  Future<ImageResult> generateImage(String prompt);
}

class FakeImageBackend implements ImageBackend {
  final String base64;
  FakeImageBackend(this.base64);

  @override
  String get id => 'fake';

  @override
  Future<ImageResult> generateImage(String prompt) async =>
      ImageResult.single(base64: base64);
}
