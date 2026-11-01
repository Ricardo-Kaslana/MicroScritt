import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/state/slash_commands.dart';

void main() {
  test('slashCommandFromText parses all commands', () {
    expect(slashCommandFromText('/test'), SlashCommand.test);
    expect(slashCommandFromText('/continue'), SlashCommand.continueStory);
    expect(slashCommandFromText('/clear'), SlashCommand.clearHistory);
    expect(slashCommandFromText('/compact'), SlashCommand.compact);
    expect(slashCommandFromText('/rerun'), SlashCommand.rerun);
  });

  test('slashCommandFromText is case-insensitive and ignores trailing text', () {
    expect(slashCommandFromText('/TEST'), SlashCommand.test);
    expect(slashCommandFromText('/Compact 忽略这段'), SlashCommand.compact);
    expect(slashCommandFromText('/RERUN 忽略这段'), SlashCommand.rerun);
  });

  test('slashCommandFromText rejects non-command text and lookalikes', () {
    expect(slashCommandFromText('hello /test'), isNull); // 不以 / 开头
    expect(slashCommandFromText('/testx'), isNull); // 前缀但非完整命令
    expect(slashCommandFromText('/rerunx'), isNull);
    expect(slashCommandFromText('/draw 一只猫'), isNull); // 已移除的命令
    expect(slashCommandFromText('/'), isNull);
    expect(slashCommandFromText(''), isNull);
  });

  test('slashCommandMatch keeps the trailing direction text', () {
    final match = slashCommandMatch('/rerun 画面更暗, 构图更近');
    expect(match?.command, SlashCommand.rerun);
    expect(match?.args, '画面更暗, 构图更近');

    // 命令名大小写不敏感,但参数原样保留大小写。
    expect(slashCommandMatch('/RERUN Make It Darker')?.args, 'Make It Darker');
    expect(slashCommandMatch('/rerun')?.args, isEmpty);
    expect(slashCommandMatch('/rerun   ')?.args, isEmpty);

    // 只有命令名后跟空白才是参数;紧贴的非空白字符仍是无效命令。
    expect(slashCommandMatch('/rerunx'), isNull);
    expect(slashCommandMatch('/test something')?.command, SlashCommand.test);
  });

  test('slashSuggestions suggests by prefix, none after a space', () {
    expect(slashSuggestions('/t'), [SlashCommand.test]);
    expect(slashSuggestions('/c'), [SlashCommand.continueStory, SlashCommand.clearHistory, SlashCommand.compact]);
    expect(slashSuggestions('/r'), [SlashCommand.rerun]);
    expect(slashSuggestions('/d'), isEmpty); // draw 已移除
    expect(slashSuggestions('/test '), isEmpty); // 已带空格 → 用户继续输入
  });

  test('allSlashCommands exposes five commands with labels and descriptions', () {
    expect(allSlashCommands, hasLength(5));
    expect(allSlashCommands.last, SlashCommand.rerun);
    expect(slashCommandLabel[SlashCommand.compact], '主动压缩');
    expect(slashCommandDescription[SlashCommand.compact], contains('主动压缩'));
    expect(slashCommandLabel[SlashCommand.rerun], '重跑后台');
    expect(slashCommandDescription[SlashCommand.rerun], contains('重跑'));
    expect(slashCommandDescription[SlashCommand.rerun], contains('修改方向'));
  });
}
