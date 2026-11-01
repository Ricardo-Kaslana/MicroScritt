// 图片头解析:PNG/JPEG/GIF/WebP/BMP 的宽高读取、宽高比换算、截断/未知
// 数据回退 null,以及只读文件头解宽高比的磁盘路径。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/image_header.dart';

/// 各种格式的最小样本(PIL 生成),宽高刻意各不相同 —— 误判成别的格式或
/// 读错偏移时不会碰巧通过。
const _png3x5 =
    'iVBORw0KGgoAAAANSUhEUgAAAAMAAAAFCAIAAAAPE8H1AAAAE0lEQVR4nGPkEpFjAAMmCEWQBQAMWABG2N9HMQAAAABJRU5ErkJggg==';
const _jpeg7x2 =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAACAAcDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD82qKKK9M88//Z';
const _gif4x6 =
    'R0lGODdhBAAGAIAAAAAAAAAAACwAAAAABAAGAAAICwABCBxIsKDBgQEBADs=';
const _webpLossless9x3 =
    'UklGRiIAAABXRUJQVlA4TBYAAAAvCIAAAAdQiirUo/8BgCD8b5uI6H8K';
const _webpLossy11x4 =
    'UklGRjIAAABXRUJQVlA4ICYAAABwAQCdASoLAAQAAMASJZQCdAFAAAD+/qV09a8/ciVHBskU12AAAA==';
const _webpVp8x13x6 =
    'UklGRlYAAABXRUJQVlA4WAoAAAAQAAAADAAABQAAQUxQSAoAAAABB1DAiAhERP8DVlA4ICYAAABwAQCdASoNAAYAAMASJZQCdAFAAAD+/qV09a8/ciVHBskU12AAAA==';
const _bmp5x8 =
    'Qk22AAAAAAAAADYAAAAoAAAABQAAAAgAAAABABgAAAAAAIAAAADEDgAAxA4AAAAAAAAAAAAAHhQKHhQKHhQKHhQKHhQKAB4UCh4UCh4UCh4UCh4UCgAeFAoeFAoeFAoeFAoeFAoAHhQKHhQKHhQKHhQKHhQKAB4UCh4UCh4UCh4UCh4UCgAeFAoeFAoeFAoeFAoeFAoAHhQKHhQKHhQKHhQKHhQKAB4UCh4UCh4UCh4UCgAeFAoeFAoeFAoeFAoeFAoAHhQKHhQKHhQKHhQKHhQKAB4UCh4UCh4UCh4UCh4UCgA=';

void main() {
  test('reads dimensions from PNG/JPEG/GIF/WebP/BMP headers', () {
    expect(imageSizeFromBytes(base64Decode(_png3x5)), (3, 5));
    expect(imageSizeFromBytes(base64Decode(_jpeg7x2)), (7, 2));
    expect(imageSizeFromBytes(base64Decode(_gif4x6)), (4, 6));
    expect(imageSizeFromBytes(base64Decode(_webpLossless9x3)), (9, 3));
    expect(imageSizeFromBytes(base64Decode(_webpLossy11x4)), (11, 4));
    expect(imageSizeFromBytes(base64Decode(_webpVp8x13x6)), (13, 6));
    expect(imageSizeFromBytes(base64Decode(_bmp5x8)), (5, 8));
  });

  test('aspect ratio follows header dimensions', () {
    expect(imageAspectFromBytes(base64Decode(_png3x5)), closeTo(3 / 5, 1e-9));
    expect(
      imageAspectFromBytes(base64Decode(_webpVp8x13x6)),
      closeTo(13 / 6, 1e-9),
    );
  });

  test('truncated or unknown data falls back to null', () {
    final png = base64Decode(_png3x5);
    expect(imageSizeFromBytes(Uint8List.sublistView(png, 0, 20)), isNull);
    expect(imageSizeFromBytes(Uint8List.fromList([1, 2, 3, 4])), isNull);
    final jpeg = base64Decode(_jpeg7x2);
    expect(imageSizeFromBytes(Uint8List.sublistView(jpeg, 0, 10)), isNull);
  });

  test('reads only the header bytes from disk', () async {
    final dir = await Directory.systemTemp.createTemp('msc_img_header');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final png = File('${dir.path}/a.png');
    await png.writeAsBytes(base64Decode(_png3x5));
    expect(await imageAspectFromFile(png), closeTo(3 / 5, 1e-9));

    // 预读窗口不足以覆盖 SOF 段时应返回 null,而不是把整文件读进来。
    final jpeg = File('${dir.path}/a.jpg');
    await jpeg.writeAsBytes(base64Decode(_jpeg7x2));
    expect(await imageAspectFromFile(jpeg, headerBytes: 10), isNull);
  });
}
