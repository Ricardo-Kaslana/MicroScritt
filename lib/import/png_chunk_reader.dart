/// PNG 文本块读取:从 tEXt / iTXt / zTXt 中抽取角色卡 JSON 载荷。
///
/// zTXt 与压缩 iTXt 的单次解压输出设 64MB 上限,超限按坏块跳过;CRC 不
/// 校验,解码优先 UTF-8、非法序列回落 Latin-1,不让单个坏块炸掉整卡导入。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一个 PNG 文本块:关键字 + 已解码/解压后的文本。
class PngTextChunk {
  /// 块关键字(如 `chara` / `ccv3`);大小写由调用方归一。
  final String keyword;

  /// 块文本;压缩块已解压,失败时该块不会出现在结果里。
  final String text;

  const PngTextChunk(this.keyword, this.text);
}

/// zTXt / iTXt 单次解压输出的总量上限:几十 KB 的 PNG 就能携带高压缩比
/// 载荷,不设上限的解压是移动端 OOM 的直接路径(角色卡 JSON 合理上限几
/// MB,64MB 拦截零成本)。超限按坏块跳过,不炸整卡导入。
const int _maxInflateOutputBytes = 64 * 1024 * 1024;

/// 带输出上限的逐块接收 sink:解压流式进行,超限即抛 —— 压缩炸弹永远不会
/// 完整物化成字节数组。(`ZLibDecoder.startChunkedConversion` 接受任意
/// `Sink<List<int>>`,不必用 dart:convert 的接口类 ChunkedConversionSink。)
class _CappedInflateSink implements Sink<List<int>> {
  final builder = BytesBuilder(copy: false);
  int _total = 0;

  @override
  void add(List<int> chunk) {
    _total += chunk.length;
    if (_total > _maxInflateOutputBytes) {
      throw const FormatException('zlib 解压输出超过上限(疑似压缩炸弹)');
    }
    builder.add(chunk);
  }

  @override
  void close() {}
}

/// 解压 zlib 载荷(zTXt 文本或带压缩标志的 iTXt 文本字段)。
///
/// 流式解码且输出超过上限时返回 null(压缩炸弹不会完整物化成字节数组),
/// 非法 zlib 数据同样返回 null,由调用方按坏块跳过。
Uint8List? _inflateZlib(Uint8List data) {
  try {
    final sink = _CappedInflateSink();
    final decoder = ZLibDecoder().startChunkedConversion(sink);
    decoder.add(data);
    decoder.close();
    return sink.builder.takeBytes();
  } on FormatException {
    return null;
  }
}

/// 解码优先 UTF-8(生态里常把 UTF-8 字节写进规范上是 Latin-1 的字段,
/// 严格按规范解码反而丢数据);非法 UTF-8 序列回退 Latin-1(每个字节都
/// 合法,绝不抛)—— 严格 UTF-8 一个坏块就会炸掉整卡导入,连文件后部
/// 完好的 chara 块都救不回。
String _utf8ElseLatin1(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// 从 PNG 字节缓冲读取 tEXt / iTXt / zTXt 块(仅这三类会携带角色卡 JSON)。
///
/// zTXt 与带压缩标志的 iTXt 会被解压;解压失败的块跳过。CRC 不校验(与
/// ST 生态的宽松读取一致),结构越界时提前停止并返回已读块。关键字按块
/// 类型解码(tEXt 按 Latin-1,iTXt/zTXt 优先 UTF-8 并回退 Latin-1),调用方
/// 按大小写不敏感匹配。非 PNG 抛 [FormatException]。
List<PngTextChunk> readPngTextChunks(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 8) throw const FormatException('Not a PNG file');
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != signature[i]) throw const FormatException('Not a PNG file');
  }
  final chunks = <PngTextChunk>[];
  var offset = 8;
  // PNG 块类型大小写敏感,精确匹配四种关注的类型(避免对每个块做 sublist)。
  bool typeIs(int o, String t) =>
      bytes[offset + 4] == t.codeUnitAt(0) &&
      bytes[offset + 5] == t.codeUnitAt(1) &&
      bytes[offset + 6] == t.codeUnitAt(2) &&
      bytes[offset + 7] == t.codeUnitAt(3);
  while (offset + 8 <= bytes.length) {
    final length = _readUint32(bytes, offset);
    if (_dataEndExceeds(bytes, offset, length)) break;
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    // 只对文本块做整块复制:IDAT 等占 PNG 绝对体积的大块不白白多拷一份
    //(20MB 卡 ≈ 额外 20MB 峰值分配)。
    if (typeIs(offset, 'tEXt')) {
      _addText(chunks, bytes.sublist(dataStart, dataEnd), latin1: true);
    } else if (typeIs(offset, 'iTXt')) {
      _addItxt(chunks, bytes.sublist(dataStart, dataEnd));
    } else if (typeIs(offset, 'zTXt')) {
      _addZtxt(chunks, bytes.sublist(dataStart, dataEnd));
    } else if (typeIs(offset, 'IEND')) {
      break;
    }
    offset = dataEnd + 4; // skip CRC
  }
  return chunks;
}

/// 块数据是否越过缓冲区末尾(截断 PNG);调用方据此提前停止而不越界读取。
bool _dataEndExceeds(Uint8List bytes, int offset, int length) {
  final dataStart = offset + 8;
  final dataEnd = dataStart + length;
  return dataEnd > bytes.length;
}

/// tEXt 块:keyword\0text;按 [latin1] 选择 Latin-1 或 UTF-8 解码,无分隔符
/// 则跳过。
void _addText(List<PngTextChunk> chunks, Uint8List data, {required bool latin1}) {
  final nullIdx = data.indexOf(0);
  if (nullIdx == -1) return;
  final keyword = latin1 ? String.fromCharCodes(data.sublist(0, nullIdx)) : _utf8(data.sublist(0, nullIdx));
  final text = latin1 ? String.fromCharCodes(data.sublist(nullIdx + 1)) : _utf8(data.sublist(nullIdx + 1));
  chunks.add(PngTextChunk(keyword, text));
}

/// iTXt 布局:keyword\0 | compressionFlag(1 字节) | compressionMethod
/// (1 字节) | language\0 | translatedKeyword\0 | text。compressionFlag
/// 非 0 时 text 是 zlib 压缩数据。
void _addItxt(List<PngTextChunk> chunks, Uint8List data) {
  final nul = data.indexOf(0);
  if (nul == -1) return;
  final keyword = _utf8(data.sublist(0, nul));
  final rest = data.sublist(nul + 1);
  if (rest.length < 2) return;
  final compressed = rest[0] != 0;
  var after = rest.sublist(2);
  final n1 = after.indexOf(0); // end of language tag
  if (n1 == -1) return;
  after = after.sublist(n1 + 1);
  final n2 = after.indexOf(0); // end of translated keyword
  if (n2 == -1) return;
  final raw = after.sublist(n2 + 1);
  final text = compressed ? _inflateZlib(raw) : raw;
  if (text == null) return;
  chunks.add(PngTextChunk(keyword, _utf8(text)));
}

/// zTXt 布局:keyword\0 | compressionMethod(1 字节) | zlib(text)。
/// keyword 与解压后的 text 按规范是 Latin-1;生态里常见 UTF-8 字节写入,
/// 解码顺序:UTF-8 优先、非法序列回退 Latin-1(绝不为一个坏块炸掉整卡)。
void _addZtxt(List<PngTextChunk> chunks, Uint8List data) {
  final nul = data.indexOf(0);
  if (nul == -1) return;
  final keyword = _utf8ElseLatin1(data.sublist(0, nul));
  final rest = data.sublist(nul + 1);
  if (rest.isEmpty || rest[0] != 0) return; // compression method must be 0 (zlib)
  final inflated = _inflateZlib(rest.sublist(1));
  if (inflated == null) return;
  chunks.add(PngTextChunk(keyword, _utf8ElseLatin1(inflated)));
}

String _utf8(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);

int _readUint32(Uint8List b, int offset) =>
    (b[offset] << 24) | (b[offset + 1] << 16) | (b[offset + 2] << 8) | b[offset + 3];
