import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../models/character_card.dart';
import '../models/worldbook_entry.dart';
import 'character_card_exporter.dart';

/// 把角色卡导出为 ST 生态通用的 PNG 卡:图片本体即头像(无头像/解码失败时
/// 生成占位图),卡数据以 base64 JSON 写入 PNG 的 `chara` 文本块;V3 卡按
/// 生态惯例另写一份 `ccv3`。
///
/// 写入的是**去掉 avatar 字段**的导出 JSON —— PNG 自己就是头像,再内嵌一份
/// base64 只会让文件近乎翻倍;导入方(含本应用)会以这张 PNG 作为头像。
class CharacterCardPngExporter {
  static Future<Uint8List> export(
    CharacterCard card, {
    List<WorldbookEntry>? worldbook,
  }) async {
    final payload = _stripAvatar(
      CharacterCardExporter.exportJson(card, worldbook: worldbook),
    );
    final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
    final image =
        await _normalizeToPng(_decodeAvatar(card.avatarBase64)) ??
        await _placeholderPng(card.name);
    return _insertTextChunks(image, [
      ('chara', encoded),
      if (payload['spec'] == 'chara_card_v3') ('ccv3', encoded),
    ]);
  }

  /// 顶层与 `data` 信封里的 avatar 都剥掉(data_json 落库已有同样语义)。
  static Map<String, dynamic> _stripAvatar(Map<String, dynamic> json) {
    final copy = <String, dynamic>{...json}..remove('avatar');
    if (copy['data'] is Map<String, dynamic>) {
      copy['data'] = <String, dynamic>{
        ...(copy['data'] as Map<String, dynamic>),
      }..remove('avatar');
    }
    return copy;
  }

  /// 头像列可能带 `data:image/...;base64,` 前缀;坏值返回 null 走占位图。
  static Uint8List? _decodeAvatar(String? base64Text) {
    if (base64Text == null || base64Text.isEmpty) return null;
    var text = base64Text.trim();
    final comma = text.indexOf(',');
    if (text.startsWith('data:') && comma != -1) {
      text = text.substring(comma + 1);
    }
    try {
      return base64Decode(text);
    } on FormatException {
      return null;
    }
  }

  /// PNG 原样复用(只追加文本块,不重编码);其他格式/损坏 PNG 经平台解码器
  /// 重编码为 PNG;不可解码返回 null。
  static Future<Uint8List?> _normalizeToPng(Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) return null;
    if (_isPng(bytes) && _findIend(bytes) != null) return bytes;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// 无头像时的占位图:按名字取色的渐变 + 首字,512×512。
  static Future<Uint8List> _placeholderPng(String name) async {
    const size = 512.0;
    final hue = _nameHash(name) % 360;
    final top = HSLColor.fromAHSL(1, hue.toDouble(), 0.42, 0.55).toColor();
    final bottom = HSLColor.fromAHSL(1, hue.toDouble(), 0.45, 0.35).toColor();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, size, size),
      ui.Paint()
        ..shader = ui.Gradient.linear(
          const ui.Offset(0, 0),
          const ui.Offset(size, size),
          [top, bottom],
        ),
    );
    canvas.drawCircle(
      const ui.Offset(size / 2, size / 2),
      150,
      ui.Paint()..color = const ui.Color(0x33FFFFFF),
    );
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? '?'
        : String.fromCharCode(trimmed.runes.first);
    final painter = TextPainter(
      text: TextSpan(
        text: initial,
        style: const TextStyle(
          color: ui.Color(0xF2FFFFFF),
          fontSize: 200,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      ui.Offset((size - painter.width) / 2, (size - painter.height) / 2),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  static int _nameHash(String name) {
    var hash = 0;
    for (final rune in name.runes) {
      hash = (hash * 31 + rune) & 0x7fffffff;
    }
    return hash;
  }

  static bool _isPng(Uint8List bytes) {
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  /// 返回 IEND 块起始偏移;结构越界/缺 IEND 返回 null。
  static int? _findIend(Uint8List png) {
    var offset = 8;
    while (offset + 8 <= png.length) {
      final length = _readUint32(png, offset);
      final dataEnd = offset + 8 + length;
      if (dataEnd + 4 > png.length) return null;
      if (png[offset + 4] == 0x49 && // 'I'
          png[offset + 5] == 0x45 && // 'E'
          png[offset + 6] == 0x4E && // 'N'
          png[offset + 7] == 0x44) {
        return offset;
      }
      offset = dataEnd + 4;
    }
    return null;
  }

  /// 在 IEND 前插入文本块(必须位于 IDAT 之后,IEND 之前)。
  static Uint8List _insertTextChunks(
    Uint8List png,
    List<(String, String)> chunks,
  ) {
    final insertAt = _findIend(png);
    if (insertAt == null) throw const FormatException('PNG 缺少 IEND 块');
    // 用视图代替 sublist 的大块复制:20MB 头像整图导出时避免再翻倍一次峰值。
    final builder = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(png, 0, insertAt));
    for (final (keyword, text) in chunks) {
      builder.add(_textChunk(keyword, text));
    }
    builder.add(Uint8List.sublistView(png, insertAt));
    return builder.takeBytes();
  }

  /// tEXt 块直接写进目标缓冲区。旧实现把 27MB 级 base64 展开成 `List<int>`
  /// 再多次 spread/复制(每份元素约 8 字节),大卡 PNG 导出会瞬时吃掉数百 MB;
  /// 现在只有最终块这一份字节,CRC 原地遍历。
  static Uint8List _textChunk(String keyword, String text) {
    final type = ascii.encode('tEXt');
    final keywordBytes = ascii.encode(keyword);
    final textBytes = ascii.encode(text);
    final dataLen = keywordBytes.length + 1 + textBytes.length;
    final out = Uint8List(4 + 4 + dataLen + 4);
    _writeUint32(out, 0, dataLen);
    out.setRange(4, 8, type);
    out.setRange(8, 8 + keywordBytes.length, keywordBytes);
    out[8 + keywordBytes.length] = 0;
    out.setRange(8 + keywordBytes.length + 1, 8 + dataLen, textBytes);
    var crc = 0xFFFFFFFF;
    for (var i = 4; i < 8 + dataLen; i++) {
      crc = _crcTable[(crc ^ out[i]) & 0xFF] ^ (crc >> 8);
    }
    _writeUint32(out, 8 + dataLen, crc ^ 0xFFFFFFFF);
    return out;
  }

  static void _writeUint32(Uint8List out, int offset, int value) {
    out[offset] = (value >> 24) & 0xFF;
    out[offset + 1] = (value >> 16) & 0xFF;
    out[offset + 2] = (value >> 8) & 0xFF;
    out[offset + 3] = value & 0xFF;
  }

  static int _readUint32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static final List<int> _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
}
