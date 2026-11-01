/// 内置默认显示层正则脚本种子。
///
/// 种子让「默认开启」的脚本在管理页可见、可开关、可改写;建库时按 name
/// 幂等种入,用户改过/删过的条目不会被覆盖。替换串只使用显示层富文本
/// 标记,不进入落库内容或 LLM 上下文。
library;

import 'regex_script.dart';

/// 内置默认正则脚本种子:让「默认开启」的显示层脚本在正则脚本管理页可见、
/// 可开关、可改写(v30 起幂等种入,按 name 判重,用户改过/删过的绝不覆盖)。
///
/// 与编辑页的 ActionChip 模板同源;时间戳胶囊同时匹配全角【】与半角 [],
/// 以配合「格式生成指导」规则提示模型输出的【】场景小注格式。
///
/// 星号脚本要点(v32 修订):
/// - 替换串不再回填星号 —— `*动作*` 显示为无星号纯斜体,而非"斜体+可见星号"。
/// - `[\s\S]` 代替 `.` 以匹配换行,跨多行的动作块也能整体斜体化。
/// - 加粗必须排在斜体之前(position 更小):否则 `\*(.+?)\*` 会先把
///   `**text**` 啃成 `**text*` 留下碎星号。
const List<RegexScript> kDefaultRegexScriptSeeds = [
  RegexScript(
    name: '加粗动作',
    findRegex: r'\*\*(.+?)\*\*',
    replace: r'<b>$1</b>',
    position: 0,
  ),
  RegexScript(
    name: '斜体动作',
    findRegex: r'\*([\s\S]+?)\*',
    replace: r'<i>$1</i>',
    position: 1,
  ),
  RegexScript(
    name: '时间戳胶囊',
    findRegex: r'[【\[]([^\[\]【】]+)[】\]]',
    replace: r'<chip>$1</chip>',
    position: 2,
  ),
];

/// v31 及以前种入的旧版「斜体动作」原文(2.0 迁移链重置后仅存档,不再有
/// 消费方)。
const ({String findRegex, String replace}) kLegacyItalicSeed = (
  findRegex: r'\*(.+?)\*',
  replace: r'<i>*$1*</i>',
);
