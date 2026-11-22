/// 供设置页/UI 使用的单位换算与上下文用量估算工具。
library;

/// 把用户填写的容量/输出简写解析为整数 token 数。
///
/// 支持纯数字(128000)以及带后缀的写法:`k`/`K`(×1000)、`m`/`M`(×1,000,000)。
/// 例:"128000"→128000, "128k"/"128K"→128000, "1m"/"1M"→1000000,"256k"→256000。
/// 无法解析(空/非法)返回 null。0、负值、非有限数与超出合理输入上限
/// (>10 亿,已足以覆盖任何真实模型)同样返回 null —— 调用方据此给出
/// 可见错误;绝不把 Infinity 传给 `round()`(会抛 UnsupportedError)。
int? parseTokenShorthand(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  final match = RegExp(r'^(\d+(?:\.\d+)?)([km]?)$').firstMatch(s);
  if (match == null) return null;
  final number = double.tryParse(match.group(1)!);
  if (number == null || !number.isFinite) return null;
  final suffix = match.group(2)!;
  final multiplier = switch (suffix) {
    'k' => 1000,
    'm' => 1000000,
    _ => 1,
  };
  final scaled = number * multiplier;
  if (!scaled.isFinite || scaled <= 0 || scaled > 1000000000) return null;
  final tokens = scaled.round();
  return tokens > 0 ? tokens : null;
}

/// 把 token 数格式化为简洁的 K / M 人类可读串(供 ring 数值、展示)。
/// 例:1234→"1.2K",1234567→"1.2M",999→"999"。
String formatTokenCount(int tokens) {
  if (tokens >= 1000000) {
    final m = tokens / 1000000;
    return '${m.toStringAsFixed(m % 1 == 0 ? 0 : 1)}M';
  }
  if (tokens >= 1000) {
    final k = tokens / 1000;
    return '${k.toStringAsFixed(k % 1 == 0 ? 0 : 1)}K';
  }
  return '$tokens';
}

/// 把 token 数格式化为中文万/亿单位的短串(上下文容量展示)。
/// 例:237000→"23.7万",1000000→"100万",123456789→"1.2亿"。
String formatTokenCountZh(int tokens) {
  if (tokens >= 100000000) {
    return '${_trimUnit(tokens / 100000000)}亿';
  }
  if (tokens >= 10000) {
    return '${_trimUnit(tokens / 10000)}万';
  }
  return '$tokens';
}

String _trimUnit(double value) => value.toStringAsFixed(value % 1 == 0 ? 0 : 1);

/// 把字符数估算为 token 数(经验值:混合中英文文本约 3~4 字符/token)。
/// 用于对"当前已组装上下文"做上下文环的用量估算。
int estimateTokensFromChars(int chars) => (chars / 3.2).round();
