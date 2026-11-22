/// 后台运行摘要的展示层解析:把控制器拼好的一句话拆成可分组渲染的条目。
///
/// 摘要字符串同时供灵动岛的运行后闪示与状态面板回看,这里只做展示层拆分;
/// 任何认不出的片段都返回 null,由调用方回退整段文本,避免把引擎诊断误拆成
/// 条目。变量值允许含空格(LLM 写入的自由文本),解析时续接到上一个键。
library;

/// 一条变量更新(key 与 value 分开保存,便于键值分色渲染)。
class BackgroundVariableChange {
  final String key;
  final String value;
  const BackgroundVariableChange(this.key, this.value);
}

/// 成功摘要的结构化结果;解析失败时 [parse] 返回 null。
class BackgroundSummaryParts {
  final String? headline;
  final String? noChange;
  final String? note;
  final String? imageState;
  final List<BackgroundVariableChange> updates;
  final List<String> removed;
  final List<String> proposed;
  final List<String> injected;
  final List<String> auditStats;

  const BackgroundSummaryParts._({
    this.headline,
    this.noChange,
    this.note,
    this.imageState,
    this.updates = const [],
    this.removed = const [],
    this.proposed = const [],
    this.injected = const [],
    this.auditStats = const [],
  });

  static const _rerun = '重跑完成';
  static const _pendingNote = '仍有对话待后续维护';
  static const _noChangeSuffix = '(无明显变化)';
  static final _auditStat = RegExp(r'^(更新|删除|建议删除) \d+ 键(待确认)?$');
  static final _spaces = RegExp(r'\s+');

  static BackgroundSummaryParts? parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    String? prefix;
    if (text == _rerun) {
      return const BackgroundSummaryParts._(headline: _rerun);
    }
    if (text.startsWith('$_rerun · ')) {
      prefix = _rerun;
      text = text.substring(_rerun.length + 3).trim();
    }

    String? note;
    if (text == _pendingNote) {
      return BackgroundSummaryParts._(headline: prefix, note: _pendingNote);
    }
    if (text.endsWith(' · $_pendingNote')) {
      note = _pendingNote;
      text = text.substring(0, text.length - _pendingNote.length - 3).trim();
    }
    if (text.isEmpty) return null;

    if (text.endsWith(_noChangeSuffix)) {
      final label = text
          .substring(0, text.length - _noChangeSuffix.length)
          .trim();
      if (label != '状态维护完成' && label != '审计完成') return null;
      return BackgroundSummaryParts._(
        headline: prefix == null ? label : '$prefix · $label',
        noChange: '无明显变化',
        note: note,
      );
    }

    if (text.startsWith('审计完成:')) {
      final stats = text
          .substring('审计完成:'.length)
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (stats.isEmpty || !stats.every(_auditStat.hasMatch)) return null;
      return BackgroundSummaryParts._(
        headline: prefix == null ? '审计完成' : '$prefix · 审计完成',
        note: note,
        auditStats: stats,
      );
    }

    final updates = <BackgroundVariableChange>[];
    final removed = <String>[];
    final proposed = <String>[];
    final injected = <String>[];
    String? imageState;
    var recognized = false;
    for (final segment in text.split(' · ')) {
      final part = segment.trim();
      if (part.isEmpty) return null;
      if (part == '图片生成中' ||
          part == '图片已生成' ||
          part == '图片已重绘') {
        if (imageState != null) return null;
        imageState = part;
        recognized = true;
        continue;
      }
      if (part.startsWith('变量 ')) {
        if (!_parseUpdates(part.substring('变量 '.length), updates)) {
          return null;
        }
        recognized = true;
        continue;
      }
      if (part.startsWith('移除变量 ')) {
        final names = _names(part.substring('移除变量 '.length));
        if (names.isEmpty) return null;
        removed.addAll(names);
        recognized = true;
        continue;
      }
      if (part.startsWith('建议删除变量 ')) {
        var body = part.substring('建议删除变量 '.length).trim();
        if (!body.endsWith(',待确认')) return null;
        body = body.substring(0, body.length - ',待确认'.length).trim();
        final names = _names(body);
        if (names.isEmpty) return null;
        proposed.addAll(names);
        recognized = true;
        continue;
      }
      if (part.startsWith('注入变量 ')) {
        final names = _names(part.substring('注入变量 '.length));
        if (names.isEmpty) return null;
        injected.addAll(names);
        recognized = true;
        continue;
      }
      return null;
    }
    if (!recognized) return null;
    return BackgroundSummaryParts._(
      headline: prefix,
      note: note,
      imageState: imageState,
      updates: updates,
      removed: removed,
      proposed: proposed,
      injected: injected,
    );
  }

  /// 解析 `k=v k2=v2`;值里允许空格,无 `=` 的 token 续接到上一个值。
  static bool _parseUpdates(
    String body,
    List<BackgroundVariableChange> out,
  ) {
    final tokens = body.trim().split(_spaces).where((e) => e.isNotEmpty);
    if (tokens.isEmpty) return false;
    final start = out.length;
    String? key;
    final value = <String>[];
    for (final token in tokens) {
      final eq = token.indexOf('=');
      if (eq > 0) {
        if (!_flushUpdate(key, value, out)) return false;
        key = token.substring(0, eq);
        value
          ..clear()
          ..add(token.substring(eq + 1));
      } else if (key != null) {
        value.add(token);
      } else {
        return false;
      }
    }
    if (!_flushUpdate(key, value, out)) return false;
    return out.length > start;
  }

  static bool _flushUpdate(
    String? key,
    List<String> value,
    List<BackgroundVariableChange> out,
  ) {
    if (key == null) return true;
    final joined = value.join(' ').trim();
    if (joined.isEmpty) return false;
    out.add(BackgroundVariableChange(key, joined));
    return true;
  }

  static List<String> _names(String body) => body
      .trim()
      .split(_spaces)
      .where((e) => e.isNotEmpty)
      .toList();
}
