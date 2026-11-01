/// 图片 base64 的容错解码:把可能带 data URI 前缀的串还原为字节。
///
/// 角色卡头像/背景等导入数据常见 `data:image/png;base64,...` 形态;
/// 解码失败返回 null 而不是抛异常,调用方据此跳过坏图。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 剥掉可选的 data URI 前缀后解码 base64;损坏数据返回 null,不抛异常。
///
/// `base64Decode` 不能直接处理带 `data:` 前缀的串(会抛 [FormatException]),
/// 而不少导入源把图片存成完整 data URI,因此这里统一兜底。
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
