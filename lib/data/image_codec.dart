import 'dart:convert';
import 'dart:typed_data';

/// 安全地把"可能是 data URI"的 base64 串解码为图片字节。
///
/// 很多角色卡把头像存成 `data:image/png;base64,....` 或 `data:image/jpeg;base64,...`
/// 的完整 data URI;`base64Decode` 不能直接吃带前缀的串,会抛 [FormatException]。
/// 这里先剥掉 data URI 前缀(若有),再解码;损坏数据返回 null,不抛异常。
Uint8List? safeBase64Decode(String? base64) {
  if (base64 == null) return null;
  var s = base64.trim();
  final comma = s.indexOf(',');
  if (s.startsWith('data:') && comma != -1) {
    // 形如 data:image/png;base64,<payload> —— 只取逗号之后的部分。
    s = s.substring(comma + 1);
  }
  try {
    return base64Decode(s);
  } on FormatException {
    return null;
  }
}
