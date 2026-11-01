/// 一幅生成图:base64 内嵌数据 与 远程 URL 二选一。
/// 本地/模拟 provider 产 base64;云端 provider 产 URL。
class ImageEntry {
  final String? base64;
  final String? url;
  const ImageEntry({this.base64, this.url})
    : assert((base64 == null) != (url == null), 'exactly one of base64/url must be set');
}

/// 一次生图请求的结果:可含 1..N 幅图(数量由配置的「每次生图数量」决定)。
/// 云端 provider 一次返回多张时,编排器逐张下载落库、各成一条图片消息。
class ImageResult {
  final List<ImageEntry> images;
  const ImageResult(this.images);

  /// 单图结果(本地/模拟 provider 恒为单图)。
  factory ImageResult.single({String? base64, String? url}) =>
      ImageResult([ImageEntry(base64: base64, url: url)]);
}