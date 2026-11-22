/// 内容寻址图片资产的中立引用。
///
/// 只描述资产身份与元数据,不携带文件路径或图片字节,供持久化层与上层对接。
library;

/// 一张已落盘图片的不可变元数据。
class ImageRef {
  final String hash;
  final int byteSize;
  final String mime;
  final int width;
  final int height;

  const ImageRef({
    required this.hash,
    required this.byteSize,
    required this.mime,
    required this.width,
    required this.height,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageRef &&
          hash == other.hash &&
          byteSize == other.byteSize &&
          mime == other.mime &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(hash, byteSize, mime, width, height);

  @override
  String toString() =>
      'ImageRef(hash: $hash, byteSize: $byteSize, mime: $mime, '
      'width: $width, height: $height)';
}
