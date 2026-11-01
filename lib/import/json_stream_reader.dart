/// 会话归档的流式 JSON 读取:按块增量扫描,不把整个文件解码成 String/Map。
///
/// 只有单个值会整体驻留内存(通常最坏是单条消息的图片);截断/坏结构在
/// 扫描时抛 [FormatException],调用方据此在写库前失败。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 会话归档的流式 JSON 读取:只做合法的词法切分(字符串/括号/标量),
/// 值本身仍交给 `jsonDecode` 解码 —— 不做第二套 JSON 语义实现。
///
/// 缓冲随读随丢:已消费位置超过 64KB 时截掉前缀,内存占用与已扫描长度
/// 无关,只与单个值的大小相关(通常最坏是单条消息的图片)。
class JsonStreamScanner {
  final StreamIterator<String> _source;
  String _buf = '';
  int _pos = 0;
  bool _eof = false;
  bool _firstKey = true;
  bool _arrayFirst = true;

  JsonStreamScanner(Stream<String> chars) : _source = StreamIterator(chars);

  static bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  Future<bool> _fill() async {
    if (_eof) return false;
    while (await _source.moveNext()) {
      final chunk = _source.current;
      if (chunk.isEmpty) continue;
      _buf += chunk;
      return true;
    }
    _eof = true;
    return false;
  }

  // 已消费前缀超过 64KB 时丢弃,否则缓冲区会随扫描进度无限增长。
  void _compactIfNeeded() {
    if (_pos > 64 * 1024) {
      _buf = _buf.substring(_pos);
      _pos = 0;
    }
  }

  Future<int?> _peek() async {
    if (_pos >= _buf.length) {
      _compactIfNeeded();
      if (!await _fill()) return null;
    }
    return _buf.codeUnitAt(_pos);
  }

  Future<int> _readOrThrow() async {
    final c = await _peek();
    if (c == null) throw const FormatException('文件被截断');
    _pos++;
    return c;
  }

  Future<void> _skipWhitespace() async {
    while (true) {
      final c = await _peek();
      if (c == null || !_isWhitespace(c)) return;
      _pos++;
    }
  }

  /// 校验并消费顶层 `{`;容忍 UTF-8 BOM。非对象抛 [FormatException]。
  Future<void> beginObject() async {
    await _skipWhitespace();
    // UTF-8 BOM 会被解码成 \uFEFF。
    if (await _peek() == 0xFEFF) _pos++;
    if (await _readOrThrow() != 0x7B) {
      throw const FormatException('不是会话导出文件(缺少顶层对象)');
    }
  }

  /// 读取下一个键;对象结束时返回 null。逗号由这里按严格 JSON 语义消费。
  Future<String?> nextKey() async {
    await _skipWhitespace();
    final c = await _peek();
    if (c == null) throw const FormatException('文件被截断');
    if (c == 0x7D) {
      _pos++;
      return null;
    }
    if (_firstKey) {
      if (c == 0x2C) throw const FormatException('JSON 结构错误(多余的逗号)');
      _firstKey = false;
    } else {
      if (c != 0x2C) throw const FormatException('JSON 结构错误(缺少逗号)');
      _pos++;
      await _skipWhitespace();
    }
    final rawKey = await _scanValue(collect: true);
    final dynamic key;
    try {
      key = jsonDecode(rawKey);
    } catch (e) {
      throw FormatException('JSON 结构错误(键名无效):$e');
    }
    if (key is! String) throw const FormatException('JSON 结构错误(键名必须是字符串)');
    await _skipWhitespace();
    if (await _readOrThrow() != 0x3A) throw const FormatException('JSON 结构错误(缺少冒号)');
    return key;
  }

  /// 校验并消费数组开头的 `[`(messages 数组)。缺失抛 [FormatException]。
  Future<void> beginArray() async {
    await _skipWhitespace();
    if (await _readOrThrow() != 0x5B) {
      throw const FormatException('不是会话导出文件(缺少 messages)');
    }
    _arrayFirst = true;
  }

  /// 读取数组下一个元素原文;数组结束时返回 null。[collect] 为 false 时
  /// 只验证/跳过元素,不把原文留在内存(用于第一遍计数)。
  Future<String?> nextArrayElement({bool collect = true}) async {
    await _skipWhitespace();
    final c = await _peek();
    if (c == null) throw const FormatException('文件被截断');
    if (c == 0x5D) {
      _pos++;
      return null;
    }
    if (!_arrayFirst) {
      if (c != 0x2C) throw const FormatException('JSON 结构错误(数组缺少逗号)');
      _pos++;
      await _skipWhitespace();
    }
    _arrayFirst = false;
    final raw = await _scanValue(collect: collect);
    return collect ? raw : '';
  }

  /// 读取并完整解码一个值(整体进内存);值语法错误抛 [FormatException]。
  /// 用于头部字段,不要用它读 messages 数组。
  Future<Object?> readSmallValue() async {
    final raw = await _scanValue(collect: true);
    try {
      return jsonDecode(raw);
    } catch (e) {
      throw FormatException('文件内容不是有效的 JSON:$e');
    }
  }

  /// 跳过一个完整值,不保留原文(用于未知顶层键)。
  Future<void> skipValue() => _scanValue(collect: false);

  /// 顶层对象已结束后调用:除空白外不允许还有内容(拦截拼接的坏文件)。
  Future<void> endObjectAndVerifyEof() async {
    await _skipWhitespace();
    if (await _peek() != null) throw const FormatException('文件末尾存在多余内容');
  }

  /// 取消底层流订阅;reader 在 finally 中调用,异常路径不泄漏文件句柄。
  Future<void> close() => _source.cancel();

  Future<String> _scanValue({required bool collect}) async {
    await _skipWhitespace();
    if (_pos >= _buf.length) {
      _compactIfNeeded();
      if (!await _fill()) throw const FormatException('文件被截断');
    }
    final c = _buf.codeUnitAt(_pos);
    final out = collect ? StringBuffer() : null;
    if (c == 0x22) {
      await _scanString(out);
      return out?.toString() ?? '';
    }
    if (c == 0x7B || c == 0x5B) {
      await _scanContainer(out);
      return out?.toString() ?? '';
    }
    var length = 0;
    while (true) {
      if (_pos >= _buf.length) {
        _compactIfNeeded();
        if (!await _fill()) break;
      }
      final ch = _buf.codeUnitAt(_pos);
      if (ch == 0x2C || ch == 0x5D || ch == 0x7D || _isWhitespace(ch)) break;
      out?.writeCharCode(ch);
      length++;
      _pos++;
      _compactIfNeeded();
    }
    if (length == 0) throw const FormatException('JSON 结构错误(缺少值)');
    return out?.toString() ?? '';
  }

  /// 扫描一个字符串(当前字符必须是开引号),原文(含引号)写入 [out]。
  /// 用 indexOf 跳到下一个引号/反斜杠,避免对几 MB 的 base64 逐字符处理。
  Future<void> _scanString(StringBuffer? out) async {
    if (_pos >= _buf.length) {
      _compactIfNeeded();
      if (!await _fill()) throw const FormatException('文件被截断');
    }
    if (_buf.codeUnitAt(_pos) != 0x22) throw const FormatException('JSON 结构错误(缺少字符串)');
    out?.writeCharCode(0x22);
    _pos++;
    while (true) {
      if (_pos >= _buf.length) {
        _compactIfNeeded();
        if (!await _fill()) throw const FormatException('文件被截断');
      }
      final quote = _buf.indexOf('"', _pos);
      final backslash = _buf.indexOf('\\', _pos);
      if (quote < 0 && backslash < 0) {
        out?.write(_buf.substring(_pos));
        _pos = _buf.length;
        continue;
      }
      final next = quote < 0
          ? backslash
          : backslash < 0
          ? quote
          : (quote < backslash ? quote : backslash);
      if (next > _pos) {
        out?.write(_buf.substring(_pos, next));
        _pos = next;
      }
      if (_buf.codeUnitAt(_pos) == 0x22) {
        out?.writeCharCode(0x22);
        _pos++;
        _compactIfNeeded();
        return;
      }
      // 反斜杠:原样复制它和紧随的一个字符(\uXXXX 的后 4 位按普通字符复制)。
      out?.writeCharCode(0x5C);
      _pos++;
      if (_pos >= _buf.length) {
        _compactIfNeeded();
        if (!await _fill()) throw const FormatException('文件被截断');
      }
      out?.writeCharCode(_buf.codeUnitAt(_pos));
      _pos++;
      _compactIfNeeded();
    }
  }

  /// 扫描对象/数组,按括号深度找到匹配的结束符;字符串内部由 [_scanString] 跳过。
  Future<void> _scanContainer(StringBuffer? out) async {
    if (_pos >= _buf.length) {
      _compactIfNeeded();
      if (!await _fill()) throw const FormatException('文件被截断');
    }
    final open = _buf.codeUnitAt(_pos);
    if (open != 0x7B && open != 0x5B) throw const FormatException('JSON 结构错误(缺少容器)');
    out?.writeCharCode(open);
    _pos++;
    var depth = 1;
    while (depth > 0) {
      if (_pos >= _buf.length) {
        _compactIfNeeded();
        if (!await _fill()) throw const FormatException('文件被截断');
      }
      final index = _nextStructural(_pos);
      if (index < 0) {
        out?.write(_buf.substring(_pos));
        _pos = _buf.length;
        continue;
      }
      if (index > _pos) {
        out?.write(_buf.substring(_pos, index));
        _pos = index;
      }
      final ch = _buf.codeUnitAt(_pos);
      if (ch == 0x22) {
        await _scanString(out);
        continue;
      }
      out?.writeCharCode(ch);
      _pos++;
      if (ch == 0x7B || ch == 0x5B) {
        depth++;
      } else if (ch == 0x7D || ch == 0x5D) {
        depth--;
      }
      _compactIfNeeded();
    }
  }

  int _nextStructural(int from) {
    var best = -1;
    for (final code in const [0x22, 0x7B, 0x7D, 0x5B, 0x5D]) {
      final index = _buf.indexOf(String.fromCharCode(code), from);
      if (index >= 0 && (best < 0 || index < best)) best = index;
    }
    return best;
  }
}

/// 第一遍扫描得到的归档头:结构校验、头部字段与消息条数。
///
/// `messages` 的重复键按 `jsonDecode` 的"后者覆盖"语义处理:
/// [messagesArrays] 记录出现次数,[messageCount] 是最后一个数组的长度。
class SessionArchiveHeader {
  /// 归档版本;缺失/非整数为 0(按 v1 处理)。
  final int version;

  /// 会话元数据与 token 用量;旧档可能缺失。
  final Map<String, dynamic>? session;

  /// 角色卡 JSON;缺失表示不是有效会话归档。
  final Map<String, dynamic>? character;

  /// 变量键值;旧档可能缺失。
  final Map<String, dynamic>? variables;

  /// v66 可选:变量键 → agent_access 字符串;旧档缺失为 null。
  final Map<String, dynamic>? variableAccess;

  /// v2 时代的会话级技能;v3 起不再写出。
  final List<dynamic>? skills;

  /// 角色背景图 base64;可选键,旧档缺失为 null。
  final String? characterBackgroundBase64;

  /// 会话记忆原文;缺失为 null。
  final String? memory;

  /// 最后一个 `messages` 数组的长度。
  final int messageCount;

  /// `messages` 键出现的次数(重复键按「后者覆盖」处理)。
  final int messagesArrays;

  const SessionArchiveHeader({
    required this.version,
    required this.session,
    required this.character,
    required this.variables,
    required this.variableAccess,
    required this.skills,
    required this.characterBackgroundBase64,
    required this.memory,
    required this.messageCount,
    required this.messagesArrays,
  });
}

/// 会话文件读取被取消(导入端据此回滚并提示"已取消")。
class ArchiveScanCancelled implements Exception {
  const ArchiveScanCancelled();
}

/// 会话归档的两遍读取:第一遍校验完整结构并读头部字段(截断文件在任何
/// 写库前报错),第二遍只重扫 `messages` 并逐条回调原文。两遍都走块级
/// 扫描,单条消息(主体是图片 base64)是内存占用的主要来源。
class SessionArchiveReader {
  final File file;
  const SessionArchiveReader(this.file);

  JsonStreamScanner _open() => JsonStreamScanner(
    // 非法 UTF-8 字节以替换字符读入,结构校验仍由扫描器负责;截断文件在
    // 扫描层报错,不会静默丢字节。
    file.openRead().transform(const Utf8Decoder(allowMalformed: true)),
  );

  /// 第一遍扫描:校验顶层结构与 EOF,读取头部字段与消息条数。
  ///
  /// 缺少 `messages` 或结构损坏抛 [FormatException];读到 EOF 才返回,
  /// 截断文件在这里就被拦下,调用方不会写半截数据。
  Future<SessionArchiveHeader> readHeader() async {
    final scanner = _open();
    try {
      await scanner.beginObject();
      var version = 0;
      Map<String, dynamic>? session;
      Map<String, dynamic>? character;
      Map<String, dynamic>? variables;
      Map<String, dynamic>? variableAccess;
      List<dynamic>? skills;
      String? background;
      String? memory;
      var messagesArrays = 0;
      var messageCount = 0;
      while (true) {
        final key = await scanner.nextKey();
        if (key == null) break;
        switch (key) {
          case 'version':
            final value = await scanner.readSmallValue();
            version = value is int ? value : 0;
          case 'messages':
            messagesArrays++;
            messageCount = await _countMessages(scanner);
          case 'session':
            final value = await scanner.readSmallValue();
            session = value is Map<String, dynamic> ? value : null;
          case 'character':
            final value = await scanner.readSmallValue();
            character = value is Map<String, dynamic> ? value : null;
          case 'characterBackgroundBase64':
            final value = await scanner.readSmallValue();
            background = value is String && value.isNotEmpty ? value : null;
          case 'variables':
            final value = await scanner.readSmallValue();
            variables = value is Map<String, dynamic> ? value : null;
          case 'variableAccess':
            final value = await scanner.readSmallValue();
            variableAccess = value is Map<String, dynamic> ? value : null;
          case 'memory':
            final value = await scanner.readSmallValue();
            memory = value is String ? value : null;
          case 'skills':
            final value = await scanner.readSmallValue();
            skills = value is List ? value : null;
          default:
            await scanner.skipValue();
        }
      }
      await scanner.endObjectAndVerifyEof();
      if (messagesArrays == 0) {
        throw const FormatException('不是会话导出文件(缺少 messages)');
      }
      return SessionArchiveHeader(
        version: version,
        session: session,
        character: character,
        variables: variables,
        variableAccess: variableAccess,
        skills: skills,
        characterBackgroundBase64: background,
        memory: memory,
        messageCount: messageCount,
        messagesArrays: messagesArrays,
      );
    } finally {
      await scanner.close();
    }
  }

  /// 逐条回调最后一个 `messages` 数组的元素原文;前面的重复数组跳过
  /// (与整文件 `jsonDecode` 的"后者覆盖"一致)。[skipArrays] 由调用方传
  /// `header.messagesArrays - 1`,便于测试直接控制。
  Future<void> forEachMessage({
    required int skipArrays,
    required int messageCount,
    required FutureOr<void> Function(String raw, int index) onMessage,
    bool Function()? isCancelled,
    void Function(int done, int total)? onProgress,
  }) async {
    final scanner = _open();
    try {
      await scanner.beginObject();
      var seen = 0;
      while (true) {
        final key = await scanner.nextKey();
        if (key == null) return;
        if (key != 'messages') {
          await scanner.skipValue();
          continue;
        }
        seen++;
        if (seen <= skipArrays) {
          await scanner.skipValue();
          continue;
        }
        await scanner.beginArray();
        var index = 0;
        while (true) {
          if (isCancelled?.call() ?? false) throw const ArchiveScanCancelled();
          final raw = await scanner.nextArrayElement();
          if (raw == null) break;
          await onMessage(raw, index);
          index++;
          onProgress?.call(index, messageCount);
        }
        return;
      }
    } finally {
      await scanner.close();
    }
  }

  static Future<int> _countMessages(JsonStreamScanner scanner) async {
    await scanner.beginArray();
    var count = 0;
    while (await scanner.nextArrayElement(collect: false) != null) {
      count++;
    }
    return count;
  }
}
