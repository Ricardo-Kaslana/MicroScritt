import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/display_regex.dart';
import 'package:microscritt/models/regex_script_seeds.dart';

void main() {
  test('default regex script seeds compile and apply as documented', () {
    final compiled = compileDisplayScripts(kDefaultRegexScriptSeeds);
    // 斜体动作:*…* → 无星号纯斜体(v32 起不再回填星号)。
    expect(applyDisplayScripts('她*低下头*说:“你好。”', compiled),
        '她<i>低下头</i>说:“你好。”');
    // 跨行动作块整体斜体化([\s\S] 吃换行)。
    expect(applyDisplayScripts('*她站起身,\n走向门口*', compiled), '<i>她站起身,\n走向门口</i>');
    // 加粗:必须先于斜体应用(position 更小),否则 **text** 被啃出碎星号。
    expect(applyDisplayScripts('她**重重地**拍下杯子', compiled), '她<b>重重地</b>拍下杯子');
    // 加粗与斜体混排互不干扰。
    expect(applyDisplayScripts('*轻声*而**坚定**', compiled), '<i>轻声</i>而<b>坚定</b>');
    // 孤立单星号(未成对)保持字面,不动。
    expect(applyDisplayScripts('2 * 3 = 6', compiled), '2 * 3 = 6');
    // 时间戳胶囊:全角【】与半角 [] 都收敛为居中胶囊。
    expect(applyDisplayScripts('【2024年·秋·晴 17:42】', compiled),
        '<chip>2024年·秋·晴 17:42</chip>');
    expect(applyDisplayScripts('[17:42]', compiled), '<chip>17:42</chip>');
    // 种子默认全部启用且应用序为 加粗→斜体→胶囊。
    expect(kDefaultRegexScriptSeeds.every((s) => s.enabled), isTrue);
    expect(kDefaultRegexScriptSeeds.map((s) => s.position).toList(), [0, 1, 2]);
  });
}
