/// 生图结果模型:插件返回的图片载体与聚合结果。
///
/// URL 结果由上层下载为字节并资产化后落库,`ImageResult` 本身不触网。
library;

/// 一幅生成图的外部协议载体:base64 内嵌数据与远程 URL 二选一。
/// 编排器在写消息前把它转换为文件资产哈希;云端插件也可产 URL。
class ImageEntry {
  final String? base64;
  final String? url;
  const ImageEntry({this.base64, this.url})
    : assert(
        (base64 == null) != (url == null),
        'exactly one of base64/url must be set',
      );
}

/// 一次生图请求的结果:可含 1..N 幅图(数量由配置的「每次生图数量」决定)。
/// 云端 provider 一次返回多张时,编排器逐张下载落库、各成一条图片消息。
class ImageResult {
  final List<ImageEntry> images;
  const ImageResult(this.images);

  /// 单图结果(本地/模拟 provider 通常为单图)。
  factory ImageResult.single({String? base64, String? url}) =>
      ImageResult([ImageEntry(base64: base64, url: url)]);
}
