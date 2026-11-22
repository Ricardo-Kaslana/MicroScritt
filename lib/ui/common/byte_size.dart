/// 字节数的紧凑显示:按 1024 进制,最多保留一位小数。
library;

/// 把字节数格式化为 `B` / `KiB` / `MiB` / `GiB` / `TiB`。
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = -1;
  do {
    value /= 1024;
    unit++;
  } while (value >= 1024 && unit < units.length - 1);
  return '${value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} '
      '${units[unit]}';
}