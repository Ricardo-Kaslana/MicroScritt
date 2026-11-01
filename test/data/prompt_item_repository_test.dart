import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/prompt_item_repository.dart';
import 'package:microscritt/models/prompt_item.dart';
import 'package:microscritt/models/prompt_seeds.dart';
import '../support/test_database.dart';

void main() {
  test('inserts and filters enabled items', () async {
    final db = await openTestDb();
    final repo = PromptItemRepository(db);
    await repo.insert(const PromptItem(kind: PromptItemKind.rule, text: 'Be kind'));
    await repo.insert(const PromptItem(kind: PromptItemKind.rule, text: 'No violence', enabled: false));
    final enabled = await repo.allEnabled();
    // 库里有 2 条内置默认预设(角色扮演基调 / 格式生成指导,后者为 rule 类),
    // 全部启用;刚插入的「Be kind」位置 0,排在默认 rule(位置 1)之前。
    final ruleTexts = enabled.where((i) => i.kind == PromptItemKind.rule).map((i) => i.text).toList();
    expect(ruleTexts.first, 'Be kind');
    expect(ruleTexts, hasLength(2));
    expect(ruleTexts, containsAll(['Be kind', kDefaultPromptSeeds.firstWhere((s) => s.name == '格式生成指导').text]));
  });

  test('update modifies an existing item in place', () async {
    final db = await openTestDb();
    final repo = PromptItemRepository(db);
    final id = await repo.insert(const PromptItem(kind: PromptItemKind.rule, text: 'Be kind'));

    await repo.update(PromptItem(id: id, kind: PromptItemKind.preset, text: 'Be kinder', enabled: false, position: 3));

    final item = (await repo.all()).singleWhere((i) => i.id == id);
    expect(item.kind, PromptItemKind.preset);
    expect(item.text, 'Be kinder');
    expect(item.enabled, isFalse);
    expect(item.position, 3);
  });

  test('delete removes the item', () async {
    final db = await openTestDb();
    final repo = PromptItemRepository(db);
    final id = await repo.insert(const PromptItem(kind: PromptItemKind.rule, text: 'gone'));
    await repo.delete(id);
    expect((await repo.all()).where((i) => i.id == id), isEmpty);
  });

  test("legacy kind='memory' rows fall back to rule (kindFrom graceful fallback)", () async {
    // 历史库可能存有 prompt_items.kind='memory' 的旧行(本批起该枚举值已退役),
    // 读取时回退为 rule,内容按规则身份继续生效,不抛错、也不让该行凭空消失。
    final db = await openTestDb();
    await db.db.insert('prompt_items', {
      'kind': 'memory',
      'name': '历史记忆',
      'text': '曾经有过的人工记忆',
      'enabled': 1,
      'position': 7,
    });
    final all = await PromptItemRepository(db).all();
    final legacy = all.singleWhere((i) => i.text == '曾经有过的人工记忆');
    expect(legacy.kind, PromptItemKind.rule);
  });
}
