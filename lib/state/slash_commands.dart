/// 快捷命令系统定义:斜杠命令 + 输入栏按钮共用的元数据。
/// 目前五个:/test /continue /clear /compact /rerun。
library;

/// 命令枚举,便于在 UI 与 controller 间传递。
enum SlashCommand { test, continueStory, clearHistory, compact, rerun }

/// 命令在输入框里对应的斜杠文本(不含斜杠)。
const Map<SlashCommand, String> slashCommandText = {
  SlashCommand.test: 'test',
  SlashCommand.continueStory: 'continue',
  SlashCommand.clearHistory: 'clear',
  SlashCommand.compact: 'compact',
  SlashCommand.rerun: 'rerun',
};

/// 命令显示用的斜杠字符串(含斜杠,如 "/test")。
String slashCommandSlash(SlashCommand c) => '/${slashCommandText[c]}';

/// 命令在按钮/菜单里的中文标签。
const Map<SlashCommand, String> slashCommandLabel = {
  SlashCommand.test: '测试生成',
  SlashCommand.continueStory: '推动剧情',
  SlashCommand.clearHistory: '清空历史',
  SlashCommand.compact: '主动压缩',
  SlashCommand.rerun: '重跑后台',
};

/// 命令的短描述(按钮副标题/菜单项提示)。
const Map<SlashCommand, String> slashCommandDescription = {
  SlashCommand.test: '/test 测试生成',
  SlashCommand.continueStory: '/continue 自动推动剧情',
  SlashCommand.clearHistory: '/clear 清空历史',
  SlashCommand.compact: '/compact 主动压缩',
  SlashCommand.rerun: '/rerun [修改方向] 重跑上次后台维护',
};

/// 所有命令(保持稳定顺序,用于按钮行与斜杠建议)。
const List<SlashCommand> allSlashCommands = [
  SlashCommand.test,
  SlashCommand.continueStory,
  SlashCommand.clearHistory,
  SlashCommand.compact,
  SlashCommand.rerun,
];

/// 一次斜杠命令匹配:[command] 是识别出的命令,[args] 是命令名之后的原始
/// 文本(已 trim,大小写原样保留;没有参数时为空串)。
class SlashCommandMatch {
  final SlashCommand command;
  final String args;

  const SlashCommandMatch(this.command, [this.args = '']);
}

/// 斜杠文本 → 命令 + 参数(`/test`、`/test 任意附加文本` 都识别为 test)。
/// 无法识别返回 null。命令名大小写不敏感;参数只做首尾 trim,内容原样保留
/// (如 `/RERUN Make It Darker` 的 args 是 `Make It Darker`)。
SlashCommandMatch? slashCommandMatch(String text) {
  final t = text.trim();
  if (!t.startsWith('/')) return null;
  final body = t.substring(1).trimLeft();
  for (final c in allSlashCommands) {
    final name = slashCommandText[c]!;
    if (body.length < name.length) continue;
    // 只把命令名本身转小写比较 —— 整段 toLowerCase 在个别字符上会改变长度,
    // 导致参数切片错位。
    if (body.substring(0, name.length).toLowerCase() != name) continue;
    if (body.length == name.length) return SlashCommandMatch(c);
    if (body[name.length].trim().isEmpty) {
      return SlashCommandMatch(c, body.substring(name.length).trim());
    }
  }
  return null;
}

/// 斜杠文本 → 命令,丢弃参数(只需判定命令类型的调用方使用)。
SlashCommand? slashCommandFromText(String text) =>
    slashCommandMatch(text)?.command;

/// 输入 `/xx`(尚未输入空格)且能按前缀匹配到命令时,返回建议的命令列表
/// (供斜杠自动补全)。无匹配时返回空。基于原始文本判断:一旦输入了空格,
/// 就不再给建议。
List<SlashCommand> slashSuggestions(String text) {
  if (!text.startsWith('/')) return const [];
  final rest = text.substring(1);
  if (rest.contains(' ')) return const [];
  final query = rest.trim().toLowerCase();
  return allSlashCommands.where((c) => slashCommandText[c]!.startsWith(query)).toList();
}
