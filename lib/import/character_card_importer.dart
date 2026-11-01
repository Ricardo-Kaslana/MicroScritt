import 'dart:convert';
import 'dart:typed_data';
import '../models/character_card.dart';
import 'png_chunk_reader.dart';

class CharacterCardImporter {
  /// PNG 文件签名;导入 UI 据此决定"头像源是否就是原始文件字节"。
  static bool isPng(Uint8List bytes) {
    if (bytes.length < 8) return false;
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  /// [includePngImageAsAvatar] 为 false 时不把整张 PNG base64 成头像 —— 导入
  /// UI 手里已有原始字节,直接走 `shrinkImageBytes` 能省掉一次 20MB 级
  /// base64 编码与随后的 base64 解码(两次大拷贝)。
  static CharacterCard fromBytes(
    Uint8List bytes, {
    String filename = '',
    bool includePngImageAsAvatar = true,
  }) {
    if (isPng(bytes)) {
      return fromPng(bytes, includeImageAsAvatar: includePngImageAsAvatar);
    }
    return fromJsonString(utf8.decode(bytes));
  }

  /// 解析一张 PNG 角色卡。角色的头像就是这张 PNG 图片本身(ST/V3 卡片把图片
  /// 内嵌进 PNG,JSON 里通常没有 avatar 字段)——默认把原始 PNG 字节作为头像。
  static CharacterCard fromPng(
    Uint8List png, {
    bool includeImageAsAvatar = true,
  }) {
    final chunks = readPngTextChunks(png);
    final b64 = _find(chunks, 'ccv3') ?? _find(chunks, 'chara') ?? _findFallback(chunks);
    if (b64 == null) throw const FormatException('PNG has no character card data (chara/ccv3)');
    final jsonStr = decodeCharaPayload(b64);
    final card = fromJsonString(jsonStr);
    // 头像 = 这张卡本身的图片(仅当 JSON 里没有内嵌头像时)。
    return card.avatarBase64 == null && includeImageAsAvatar
        ? card.withAvatar(base64Encode(png))
        : card;
  }

  static CharacterCard fromJsonString(String jsonStr) {
    final text = jsonStr.startsWith('\uFEFF') ? jsonStr.substring(1) : jsonStr;
    final json = jsonDecode(text) as Map<String, dynamic>;
    return CharacterCard.fromJson(json);
  }

  /// 角色卡文本块解码为 JSON 字符串:剥 data URI 前缀(若有)→ base64(标准或
  /// URL 安全、去空白)解码为 JSON,失败时直接当 JSON 文本解析;剥离 UTF-8 BOM。
  static String decodeCharaPayload(String text) {
    var cleaned = text.trim();
    final comma = cleaned.indexOf(',');
    if (cleaned.startsWith('data:') && comma != -1) cleaned = cleaned.substring(comma + 1);
    // base64:先去空白(换行/空格),standard 失败回退 url-safe。
    final compact = cleaned.replaceAll(RegExp(r'\s'), '');
    String? jsonText;
    try {
      jsonText = utf8.decode(base64Decode(compact));
    } on FormatException {
      jsonText = null;
    }
    jsonText ??= _tryUrlSafeDecode(compact);
    if (jsonText != null) {
      jsonText = jsonText.startsWith('\uFEFF') ? jsonText.substring(1) : jsonText;
      return jsonText;
    }
    // 兜底直连 JSON:基于剥过 data URI 前缀、trim 过的 cleaned —— 此前回退
    // 原始 text,带前缀时 jsonDecode 必失败,把真实错误掩盖成无意义的
    // "Unexpected character"。Dart 的 trim() 会连 BOM 一起剥,无需再处理。
    return cleaned;
  }

  static String? _tryUrlSafeDecode(String s) {
    final padded = s.replaceAll('-', '+').replaceAll('_', '/');
    final mod = padded.length % 4;
    final withPad = mod == 0 ? padded : padded + '=' * (4 - mod);
    try {
      return utf8.decode(base64Decode(withPad));
    } on FormatException {
      return null;
    }
  }

  /// RP-Hub 兜底:`chara`/`ccv3` 之外,任意块值 trim 后 >50 字符且以 `{`(直接
  /// JSON)或 `ey`(base64 编码的 `{"`)开头,即视为卡片数据。
  static String? _findFallback(List<PngTextChunk> chunks) {
    for (final c in chunks) {
      final t = c.text.trim();
      if (t.length > 50 && (t.startsWith('{') || t.startsWith('ey'))) return t;
    }
    return null;
  }

  static String? _find(List<PngTextChunk> chunks, String keyword) {
    // V3 规范允许把超大 base64 载荷拆进多个同名块(按文件顺序拼接续块);
    // 单块卡(绝大多数)只有一个同名块,拼接与旧"取首个"等价。
    final parts = [
      for (final c in chunks)
        if (c.keyword.toLowerCase() == keyword.toLowerCase()) c.text,
    ];
    return parts.isEmpty ? null : parts.join();
  }
}
