/// 供设置页/UI 使用的单位换算与上下文用量估算工具。
library;

/// 把用户填写的容量/输出简写解析为整数 token 数。
///
/// 支持纯数字(128000)以及带后缀的写法:`k`/`K`(×1000)、`m`/`M`(×1,000,000)。
/// 例:"128000"→128000, "128k"/"128K"→128000, "1m"/"1M"→1000000,"256k"→256000。
/// 无法解析(空/非法)返回 null。
int? parseTokenShorthand(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  final match = RegExp(r'^(\d+(?:\.\d+)?)([km]?)$').firstMatch(s);
  if (match == null) return null;
  final number = double.parse(match.group(1)!);
  final suffix = match.group(2)!;
  final multiplier = switch (suffix) {
    'k' => 1000,
    'm' => 1000000,
    _ => 1,
  };
  return (number * multiplier).round();
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

/// 把字符数估算为 token 数(经验值:混合中英文文本约 3~4 字符/token)。
/// 用于对"当前已组装上下文"做上下文环的用量估算。
int estimateTokensFromChars(int chars) => (chars / 3.2).round();
