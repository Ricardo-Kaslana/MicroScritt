/// 图片字节的容器魔数识别(不解析尺寸,只判断「像不像图片」)。
///
/// URL 下载校验与磁盘缓存共用同一张接受清单:两处各自维护副本时,
/// 新增/收窄容器格式会让下载通过而缓存拒绝(或相反)。
library;

/// 仅识别常见位图容器;非图片字节不得当作图片缓存或资产化。
bool looksLikeImageBytes(List<int> b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return true; // PNG
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return true; // JPEG
  }
  if (b.length >= 6 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x38 &&
      (b[4] == 0x37 || b[4] == 0x39) &&
      b[5] == 0x61) {
    return true; // GIF87a / GIF89a
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true; // WebP
  }
  if (b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D) {
    return true; // BMP
  }
  if (b.length >= 12 &&
      b[4] == 0x66 &&
      b[5] == 0x74 &&
      b[6] == 0x79 &&
      b[7] == 0x70) {
    // ISO BMFF(avif/avis/heic/heix/mif1);排除常见视频 brand。
    final brand = String.fromCharCodes(b.sublist(8, 12)).toLowerCase();
    return brand == 'avif' ||
        brand == 'avis' ||
        brand == 'heic' ||
        brand == 'heix' ||
        brand == 'mif1';
  }
  return false;
}
