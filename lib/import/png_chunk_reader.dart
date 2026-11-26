/// PNG 文本块读取:从 tEXt / iTXt / zTXt 中抽取角色卡 JSON 载荷。
///
/// 除单块解压上限外还有**全局预算**:文本块数量、解压输出总量与文本总量
/// 任一超限都按坏卡失败 —— 几十 KB 的 PNG 可以塞进大量高压缩比块,逐块
/// 限额挡不住把全部解压结果累加进内存的压缩炸弹。文本块 CRC 不符时只跳过
/// 该块,不让单个坏块炸掉整卡导入。
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

/// 全局文本预算:块数量、解压输出总量与文本总量。超限按坏卡失败,不能把
/// 所有块无限保留在内存里。
const int _maxTextChunkCount = 256;

/// PNG 文本预算的两级上限:标准档是安全线,放宽档只在用户确认风险后使用。
///
/// 正常角色卡远低于标准线;超过它的卡多半是内嵌了 base64 头像/超长世界书,
/// 或是 V3 卡把同一载荷同时写进 chara 与 ccv3。放宽档仍设硬顶,避免把
/// 压缩炸弹真正解压进内存。
class PngTextLimits {
  /// 解压输出总量上限(字节)。
  final int maxInflateBytes;

  /// 全部文本块解码后的长度上限(UTF-16 码元数,base64/ASCII 近似字节)。
  final int maxTextLength;

  const PngTextLimits({
    required this.maxInflateBytes,
    required this.maxTextLength,
  });

  /// 默认安全线:8MiB。
  static const standard = PngTextLimits(
    maxInflateBytes: 8 * 1024 * 1024,
    maxTextLength: 8 * 1024 * 1024,
  );

  /// 用户在警告框确认风险后的放宽线:32MiB。
  static const relaxed = PngTextLimits(
    maxInflateBytes: 32 * 1024 * 1024,
    maxTextLength: 32 * 1024 * 1024,
  );
}

/// 文本/解压体积预算超限(不含块数量)。继承 [FormatException] 以兼容既有
/// 导入错误处理;调用方可据此在标准档超限时先询问用户,再用
/// [PngTextLimits.relaxed] 重试。
class PngTextBudgetExceeded extends FormatException {
  const PngTextBudgetExceeded(super.message);
}

String _mibLabel(int bytes) => '${bytes ~/ (1024 * 1024)}MiB';

/// 一次读取内共享的累计预算。
class _TextBudget {
  final PngTextLimits _limits;
  int _chunks = 0;
  int _inflated = 0;
  int _textLength = 0;

  _TextBudget(this._limits);

  PngTextLimits get limits => _limits;

  void startChunk() {
    _chunks++;
    if (_chunks > _maxTextChunkCount) {
      // 块数量与体积无关,放宽档也不放行:直接按坏卡失败,不触发大卡确认。
      throw const FormatException(
        'PNG 文本块数量超过 $_maxTextChunkCount 上限(疑似恶意文件)',
      );
    }
  }

  int get remainingInflate => _limits.maxInflateBytes - _inflated;

  void addInflated(int bytes) {
    _inflated += bytes;
    if (_inflated > _limits.maxInflateBytes) {
      throw PngTextBudgetExceeded(
        'PNG 解压输出总量超过 ${_mibLabel(_limits.maxInflateBytes)} 上限(疑似压缩炸弹)',
      );
    }
  }

  void addText(int length) {
    _textLength += length;
    if (_textLength > _limits.maxTextLength) {
      throw PngTextBudgetExceeded(
        'PNG 文本总量超过 ${_mibLabel(_limits.maxTextLength)} 上限(疑似恶意文件)',
      );
    }
  }
}

/// 带全局预算的逐块接收 sink:解压流式进行,累计超限即抛 —— 压缩炸弹永远
/// 不会完整物化成字节数组。(`ZLibDecoder.startChunkedConversion` 接受任意
/// `Sink<List<int>>`,不必用 dart:convert 的接口类 ChunkedConversionSink。)
class _CappedInflateSink implements Sink<List<int>> {
  final _TextBudget _budget;
  final builder = BytesBuilder(copy: false);

  _CappedInflateSink(this._budget);

  PngTextLimits get limits => _budget.limits;

  @override
  void add(List<int> chunk) {
    if (chunk.length > _budget.remainingInflate) {
      throw PngTextBudgetExceeded(
        'PNG 解压输出总量超过 ${_mibLabel(_budget.limits.maxInflateBytes)} 上限(疑似压缩炸弹)',
      );
    }
    _budget.addInflated(chunk.length);
    builder.add(chunk);
  }

  @override
  void close() {}
}

/// 解压 zlib 载荷(zTXt 文本或带压缩标志的 iTXt 文本字段)。
///
/// 流式解码且全局解压预算超限时抛 [PngTextBudgetExceeded](直接判坏卡);非法
/// zlib 数据返回 null,由调用方按坏块跳过。
Uint8List? _inflateZlib(Uint8List data, _TextBudget budget) {
  try {
    final sink = _CappedInflateSink(budget);
    final decoder = ZLibDecoder().startChunkedConversion(sink);
    decoder.add(data);
    decoder.close();
    return sink.builder.takeBytes();
  } on PngTextBudgetExceeded {
    rethrow;
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
  } catch (_) {
    return latin1.decode(bytes);
  }
}

/// 从 PNG 字节缓冲读取 tEXt / iTXt / zTXt 块(仅这三类会携带角色卡 JSON)。
///
/// zTXt 与带压缩标志的 iTXt 会被解压;解压失败或 CRC 不符的块跳过。块数量、
/// 解压总量或文本总量超过全局预算时抛 [FormatException](判坏卡,不返回
/// 部分结果)。结构越界时提前停止并返回已读块。关键字按块类型解码(tEXt
/// 按 Latin-1,iTXt/zTXt 优先 UTF-8 并回退 Latin-1),调用方按大小写不敏感
/// 匹配。非 PNG 抛 [FormatException]。
List<PngTextChunk> readPngTextChunks(
  Uint8List bytes, {
  PngTextLimits limits = PngTextLimits.standard,
}) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 8) throw const FormatException('Not a PNG file');
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != signature[i]) throw const FormatException('Not a PNG file');
  }
  final chunks = <PngTextChunk>[];
  final budget = _TextBudget(limits);
  var offset = 8;
  // PNG 块类型大小写敏感,精确匹配四种关注的类型(避免对每个块做 sublist)。
  bool typeIs(int o, String t) =>
      bytes[o + 4] == t.codeUnitAt(0) &&
      bytes[o + 5] == t.codeUnitAt(1) &&
      bytes[o + 6] == t.codeUnitAt(2) &&
      bytes[o + 7] == t.codeUnitAt(3);
  while (offset + 8 <= bytes.length) {
    final length = _readUint32(bytes, offset);
    if (_dataEndExceeds(bytes, offset, length)) break;
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    // CRC 也必须在缓冲区里,否则属于截断文件。
    if (dataEnd + 4 > bytes.length) break;
    final isText =
        typeIs(offset, 'tEXt') ||
        typeIs(offset, 'iTXt') ||
        typeIs(offset, 'zTXt');
    if (isText) {
      budget.startChunk();
      // 只对文本块校验 CRC;不符时跳过该块,不让一个坏块炸掉整卡。
      if (!_crcMatches(bytes, offset, dataEnd)) {
        offset = dataEnd + 4;
        continue;
      }
    }
    // 只对文本块做整块复制:IDAT 等占 PNG 绝对体积的大块不白白多拷一份
    //(20MB 卡 ≈ 额外 20MB 峰值分配)。
    if (typeIs(offset, 'tEXt')) {
      _addText(
        chunks,
        bytes.sublist(dataStart, dataEnd),
        latin1: true,
        budget: budget,
      );
    } else if (typeIs(offset, 'iTXt')) {
      _addItxt(chunks, bytes.sublist(dataStart, dataEnd), budget);
    } else if (typeIs(offset, 'zTXt')) {
      _addZtxt(chunks, bytes.sublist(dataStart, dataEnd), budget);
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

/// 校验文本块 CRC(type + data 的 CRC32);CRC 字段在 [dataEnd] 起 4 字节。
bool _crcMatches(Uint8List bytes, int typeOffset, int dataEnd) {
  var crc = 0xFFFFFFFF;
  for (var i = typeOffset + 4; i < dataEnd; i++) {
    crc = _crcTable[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) == _readUint32(bytes, dataEnd);
}

/// tEXt 块:keyword\0text;按 [latin1] 选择 Latin-1 或 UTF-8 解码,无分隔符
/// 则跳过。
void _addText(
  List<PngTextChunk> chunks,
  Uint8List data, {
  required bool latin1,
  required _TextBudget budget,
}) {
  final nullIdx = data.indexOf(0);
  if (nullIdx == -1) return;
  final keyword = latin1
      ? String.fromCharCodes(data.sublist(0, nullIdx))
      : _utf8(data.sublist(0, nullIdx));
  final text = latin1
      ? String.fromCharCodes(data.sublist(nullIdx + 1))
      : _utf8(data.sublist(nullIdx + 1));
  budget.addText(text.length);
  chunks.add(PngTextChunk(keyword, text));
}

/// iTXt 布局:keyword\0 | compressionFlag(1 字节) | compressionMethod
/// (1 字节) | language\0 | translatedKeyword\0 | text。compressionFlag
/// 非 0 时 text 是 zlib 压缩数据。
void _addItxt(
  List<PngTextChunk> chunks,
  Uint8List data,
  _TextBudget budget,
) {
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
  final text = compressed ? _inflateZlib(raw, budget) : raw;
  if (text == null) return;
  budget.addText(text.length);
  chunks.add(PngTextChunk(keyword, _utf8(text)));
}

/// zTXt 布局:keyword\0 | compressionMethod(1 字节) | zlib(text)。
/// keyword 与解压后的 text 按规范是 Latin-1;生态里常见 UTF-8 字节写入,
/// 解码顺序:UTF-8 优先、非法序列回退 Latin-1(绝不为一个坏块炸掉整卡)。
void _addZtxt(
  List<PngTextChunk> chunks,
  Uint8List data,
  _TextBudget budget,
) {
  final nul = data.indexOf(0);
  if (nul == -1) return;
  final keyword = _utf8ElseLatin1(data.sublist(0, nul));
  final rest = data.sublist(nul + 1);
  if (rest.isEmpty || rest[0] != 0) return; // compression method must be 0 (zlib)
  final inflated = _inflateZlib(rest.sublist(1), budget);
  if (inflated == null) return;
  budget.addText(inflated.length);
  chunks.add(PngTextChunk(keyword, _utf8ElseLatin1(inflated)));
}

String _utf8(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _readUint32(Uint8List b, int offset) =>
    (b[offset] << 24) |
    (b[offset + 1] << 16) |
    (b[offset + 2] << 8) |
    b[offset + 3];
