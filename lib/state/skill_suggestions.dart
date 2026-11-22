/// 输入框 `@` 提及的候选技能解析:定位光标所在的 `@前缀`、筛选启用技能。
///
/// 只做纯文本判断,不持有控制器;调用方负责把选中的 `@技能名 ` 写回输入框。
/// 与发送端的触发判据(正文包含 `@技能名`)同构,这里只是更早给出候选。
library;

import '../models/skill.dart';

final RegExp _whitespace = RegExp(r'\s');

/// 光标所在的 `@` 提及:start 是 `@` 的绝对下标,query 是它与光标之间的文本。
class SkillMentionQuery {
  final int start;
  final String query;

  const SkillMentionQuery({required this.start, required this.query});

  @override
  bool operator ==(Object other) =>
      other is SkillMentionQuery &&
      other.start == start &&
      other.query == query;

  @override
  int get hashCode => Object.hash(start, query);
}

/// 定位光标前最近一个未闭合的 `@提及`;没有、已输入空白或光标在 `@` 之前时返回 null。
///
/// 只看向光标左侧:选中文字不会进入 query,插入时由调用方整体替换 `@前缀`。
SkillMentionQuery? skillMentionAt(String text, int cursorOffset) {
  if (text.isEmpty) return null;
  final cursor = cursorOffset.clamp(0, text.length);
  if (cursor == 0) return null;
  final at = text.lastIndexOf('@', cursor - 1);
  if (at < 0) return null;
  final query = text.substring(at + 1, cursor);
  if (_whitespace.hasMatch(query)) return null;
  return SkillMentionQuery(start: at, query: query);
}

/// 按前缀筛选可用于 `@` 提及的技能:只保留启用且名称非空的条目,
/// 空 query 返回全部,匹配不区分大小写。
List<Skill> suggestedSkills(Iterable<Skill> skills, String query) {
  final q = query.trim().toLowerCase();
  return [
    for (final skill in skills)
      if (skill.enabled &&
          skill.name.trim().isNotEmpty &&
          (q.isEmpty || skill.name.trim().toLowerCase().startsWith(q)))
        skill,
  ];
}
