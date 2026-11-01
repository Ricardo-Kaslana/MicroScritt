import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/context/context_assembler.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/context_snapshot.dart';
import 'package:microscritt/models/message.dart';
import 'package:microscritt/models/prompt_item.dart';
import 'package:microscritt/models/worldbook_entry.dart';

void main() {
  final assembler = ContextAssembler();

  test('withoutSkillTokens strips prefix-named skills whole, not substring-eaten', () {
    // 回归:「@fire」先把「@fireball」啃成「ball」残名漏进上下文;修复后
    // 单正则长度降序,长记号整体剥掉。多次提及、记号周围文本原样保留。
    expect(
      ContextAssembler.withoutSkillTokens('(@fireball)和(@fire)与(@fireball)', ['fire', 'fireball']),
      '()和()与()',
    );
    // 含正则元字符的技能名按字面处理(记号两侧空白保留,与旧行为一致)。
    expect(
      ContextAssembler.withoutSkillTokens('叫 @fire.m (Lv.9) 出来', ['fire.m']),
      '叫  (Lv.9) 出来',
    );
    expect(ContextAssembler.withoutSkillTokens('正文不涉及', []), '正文不涉及');
  });

  test('assembles system prompt from static segments in order', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'Alice', description: 'knight', personality: 'brave'),
      items: const [
        PromptItem(kind: PromptItemKind.preset, text: 'You are an RP assistant'),
        PromptItem(kind: PromptItemKind.rule, text: 'No OOC'),
      ],
      history: const [],
    );
    final sp = snapshot.systemPrompt;
    expect(sp.contains('You are an RP assistant'), isTrue);
    // CV 批起各段以 <tag> 标签块包裹;顺序即标签块顺序。
    expect(sp.indexOf('<rules>') < sp.indexOf('<character>'), isTrue);
    expect(sp.contains('Alice'), isTrue);
    expect(sp.contains('knight'), isTrue);
  });

  test('sends the whole active history — no per-count trimming', () {
    // 组装自 2026-09-28 批起不做按条数裁剪:上下文规模由压缩按 token 占用率
    // 控制(target/soft/hard 三挡),组装器只渲染调用方给的窗口。此前的 2x
    // 滞回裁剪会每轮把数组首条后移,使 messages 前缀每轮全变、提示缓存永久
    // 失效(实测命中率由 95% 掉到 30% 且不恢复)。
    final history = List.generate(
      60,
      (i) => Message(sessionId: 1, role: i.isEven ? 'user' : 'assistant', content: 'm$i', seq: i),
    );
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: history,
    );
    expect(snapshot.messages.length, 60);
    expect(snapshot.messages.first.content, 'm0');
    expect(snapshot.messages.first.role, ChatRole.user);
  });

  test('keeps the messages prefix append-only across turns (cache-stable)', () {
    // 本次修复的核心性质,也是旧测试漏掉的那一条:相邻两轮的 messages 数组必须
    // 满足「后一轮以前一轮为前缀」。提示缓存按逐字节前缀匹配(Anthropic 从断点
    // 向前回溯最多 20 个 block 找此前写入过的条目),只要前缀变了 —— 哪怕只把
    // 首条挪一条 —— 整段历史缓存就失效。旧实现每轮从全量窗口重算裁剪,首条
    // 每轮后移 2 条,前缀永久失效。
    List<Message> hist(int n) => List.generate(
      n,
      (i) => Message(sessionId: 1, role: i.isEven ? 'user' : 'assistant', content: 'm$i', seq: i),
    );
    final turn1 = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: hist(250),
    );
    final turn2 = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: [
        ...hist(250),
        Message(sessionId: 1, role: 'assistant', content: '回复', seq: 250),
        Message(sessionId: 1, role: 'user', content: '下一句', seq: 251),
      ],
    );
    expect(turn2.messages.length, turn1.messages.length + 2);
    expect(
      turn2.messages.take(turn1.messages.length).map((m) => m.content).toList(),
      turn1.messages.map((m) => m.content).toList(),
      reason: '相邻两轮的 messages 前缀必须逐条一致,否则提示缓存每轮失效',
    );
  });

  test('skips compacted messages', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'user', content: 'old', seq: 0, isCompacted: true),
        Message(sessionId: 1, role: 'user', content: 'new', seq: 1),
      ],
    );
    expect(snapshot.messages.map((m) => m.content).toList(), ['new']);
  });

  test('compacted summary rows stay out of the summary segment', () {
    // 合并式单一摘要:每次压缩把既有摘要吸收进新版并折叠旧行(is_compacted=1),
    // 摘要段只渲染未折叠 system 行 —— 线上永远只有最新一份、无矛盾的摘要。
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'system', content: '旧版摘要', seq: 0, isCompacted: true),
        Message(sessionId: 1, role: 'system', content: '现行摘要', seq: 1),
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 2),
      ],
    );
    expect(snapshot.leadingSummaryContent, contains('现行摘要'));
    expect(snapshot.leadingSummaryContent, isNot(contains('旧版摘要')));
    expect(snapshot.segmentSources['summary'], isNot(contains('旧版摘要')));
  });

  test('triggered worldbook no longer recomputed at assembly (attachments own it)', () {
    // CW 批:触发条目由发送管线命中后落库为附件行;组装器不再对历史做键匹配。
    // 同样的匹配文本经公开的 matchTriggered 由调用方完成。
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [Message(sessionId: 1, role: 'user', content: 'I draw my sword', seq: 0)],
      worldbook: const [
        WorldbookEntry(characterId: 1, keys: ['sword'], content: 'The sword is cursed'),
      ],
    );
    expect(snapshot.systemPrompt, isNot(contains('The sword is cursed')));
    expect(snapshot.messages.map((m) => m.content), isNot(contains('The sword is cursed')));
    // 匹配逻辑移交调用方:matchTriggered 返回非常驻命中条目。
    final matched = assembler.matchTriggered(
      snapshot.segments.isEmpty ? const [] : const [],
      'I draw my sword',
    );
    expect(matched, isEmpty);
  });

  test('matchTriggered returns enabled non-constant hits and skips constants/disabled', () {
    final entries = [
      const WorldbookEntry(id: 1, characterId: 1, keys: ['sword'], content: 'Sword lore'),
      const WorldbookEntry(id: 2, characterId: 1, keys: ['zzz'], content: 'Never matches'),
      const WorldbookEntry(id: 3, characterId: 1, keys: [], constant: true, content: 'Always'),
      const WorldbookEntry(id: 4, characterId: 1, keys: ['sword'], content: 'disabled', enabled: false),
    ];
    final hit = assembler.matchTriggered(entries, 'I draw my sword');
    expect(hit.map((e) => e.id), [1]);
    expect(hit.single.content, 'Sword lore');
  });

  test('attachment rows ride the history array at their seq position (before the user message)', () {
    // 附件行在发送管线中先于用户消息落库 → seq 更小 → 组装时天然位于用户消息
    // 之前;content 原样(<system-reminder> 包裹)进数组。
    final attContent = ContextAssembler.worldbookAttachment('剑之诅咒', 'The sword is cursed');
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: [
        Message(sessionId: 1, role: 'assistant', content: 'hello', seq: 0),
        Message(sessionId: 1, role: 'user', content: attContent, seq: 1, kind: MessageKind.attachment, refId: 'wb:7'),
        Message(sessionId: 1, role: 'user', content: 'I draw my sword', seq: 2),
      ],
    );
    final contents = snapshot.messages.map((m) => m.content).toList();
    expect(contents, ['hello', attContent, 'I draw my sword']);
    expect(contents[1], startsWith('<system-reminder>'));
    // 附件段:面板按注入顺序细分展示。
    final seg = snapshot.segments.firstWhere((s) => s.key == 'attachments');
    expect(seg.subEntries.length, 1);
    expect(seg.subEntries.single.label, startsWith('世界书'));
    // 历史段细分只含真实对话行。
    final historySeg = snapshot.segments.firstWhere((s) => s.key == 'history');
    expect(historySeg.subEntries.map((s) => s.content), ['hello', 'I draw my sword']);
  });

  test('attachments segment lists all attachment kinds with per-type labels (DG)', () {
    // DG 批:附件段展示全部类型(技能/世界书/压缩通知/记忆差异),段名不再
    // 限定"世界书触发/技能"。
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: [
        Message(
          sessionId: 1,
          role: 'user',
          content: ContextAssembler.skillAttachment('combat', 'd', 'sword moves'),
          seq: 0,
          kind: MessageKind.attachment,
          refId: 'skill:3',
        ),
        Message(
          sessionId: 1,
          role: 'user',
          content: ContextAssembler.worldbookAttachment('剑之诅咒', 'cursed'),
          seq: 1,
          kind: MessageKind.attachment,
          refId: 'wb:7',
        ),
        Message(
          sessionId: 1,
          role: 'user',
          content: ContextAssembler.compactNoticeText,
          seq: 2,
          kind: MessageKind.attachment,
          refId: 'notice:compact:1700000000000',
        ),
        Message(
          sessionId: 1,
          role: 'user',
          content: ContextAssembler.memoryDiffNotice(['a'], ['b']),
          seq: 3,
          kind: MessageKind.attachment,
          refId: 'notice:memdiff:42',
        ),
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 4),
      ],
    );
    final seg = snapshot.segments.firstWhere((s) => s.key == 'attachments');
    expect(seg.label, '附件');
    expect(seg.subEntries.map((s) => s.label.split(' · ').first).toList(),
        ['技能', '世界书', '压缩通知', '记忆差异']);
    // 世界书子项显示条目名(落库时名字已回退为触发关键词),而不只是"世界书"。
    expect(seg.subEntries[1].label, startsWith('世界书 · 剑之诅咒'));
  });

  test('constant worldbook entries always inject into the stable system segment', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [],
      worldbook: const [
        WorldbookEntry(characterId: 1, keys: [], constant: true, content: 'Always here'),
      ],
    );
    expect(snapshot.systemPrompt.contains('Always here'), isTrue);
    expect(snapshot.systemPrompt, contains('<worldbook_constant>'));
  });

  test('memory becomes the leading system-reminder message (slot 0, before summary)', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      frozenMemory: 'Met Bob yesterday',
      history: const [
        Message(sessionId: 1, role: 'system', content: 'Earlier: they met', seq: 0),
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 1),
      ],
    );
    // 第 0 条 = 记忆(冻结副本),其前没有别的消息;摘要在其后、真实历史之前。
    expect(snapshot.messages.first.content, startsWith('<system-reminder>'));
    expect(snapshot.messages.first.content, contains('Met Bob yesterday'));
    expect(snapshot.messages.first.role, ChatRole.user);
    expect(snapshot.messages[1].content, startsWith('<summary>'));
    expect(snapshot.messages[2].content, 'hi');
    // 记忆不进 system。
    expect(snapshot.systemPrompt, isNot(contains('Met Bob yesterday')));
    // 无记忆时不产生首条消息。
    final bare = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
    );
    expect(bare.messages.single.content, 'hi');
  });

  test('notice attachment rows persisted after the latest user row are corrected before it', () {
    // DG 批:通知落库为附件行;晚于最新用户行落库的(硬挡中途压缩/regenerate)
    // 组装时挪到该用户行之前,字节对齐旧合成插入位置。
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'user', content: 'q1', seq: 0),
        Message(sessionId: 1, role: 'assistant', content: 'a1', seq: 1),
        Message(sessionId: 1, role: 'user', content: 'q2', seq: 2),
        Message(
          sessionId: 1,
          role: 'user',
          content: ContextAssembler.compactNoticeText,
          seq: 3,
          kind: MessageKind.attachment,
          refId: 'notice:compact:1',
        ),
      ],
    );
    final contents = snapshot.messages.map((m) => m.content).toList();
    // 校正后:…, a1, 压缩通知, q2 —— 与旧合成插入逐字节一致。
    expect(contents.last, 'q2');
    expect(contents[contents.length - 2], ContextAssembler.compactNoticeText);
    expect(contents[contents.length - 3], 'a1');
  });

  test('notice attachment rows persisted before the latest user row keep position', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(
          sessionId: 1,
          role: 'user',
          content: ContextAssembler.compactNoticeText,
          seq: 0,
          kind: MessageKind.attachment,
          refId: 'notice:compact:1',
        ),
        Message(sessionId: 1, role: 'user', content: 'q1', seq: 1),
        Message(sessionId: 1, role: 'assistant', content: 'a1', seq: 2),
      ],
    );
    final contents = snapshot.messages.map((m) => m.content).toList();
    expect(contents, [ContextAssembler.compactNoticeText, 'q1', 'a1']);
  });

  test('notice attachment rows stay at the end when there is no user row', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'assistant', content: 'a1', seq: 0),
        Message(
          sessionId: 1,
          role: 'user',
          content: 'notice-body',
          seq: 1,
          kind: MessageKind.attachment,
          refId: 'notice:memdiff:7',
        ),
      ],
    );
    expect(snapshot.messages.last.content, 'notice-body');
  });

  test('memory diff notice renders added/removed lines', () {
    final text = ContextAssembler.memoryDiffNotice(
      ['新事实 A', '新事实 B'],
      ['旧事实 C'],
    );
    expect(text, startsWith('<system-reminder>'));
    expect(text, contains('【新增】新事实 A'));
    expect(text, contains('【新增】新事实 B'));
    expect(text, contains('【删除】旧事实 C'));
    expect(text, endsWith('</system-reminder>'));
  });

  test('skill attachment renders name/description/content inside system-reminder', () {
    final text = ContextAssembler.skillAttachment('combat', 'd', 'vivid blows');
    expect(text, startsWith('<system-reminder>'));
    expect(text, contains('@combat'));
    expect(text, contains('combat: d'));
    expect(text, contains('vivid blows'));
    expect(text, endsWith('</system-reminder>'));
  });

  test('skills never enter system or messages unless attached explicitly', () {
    // CW 批:技能不进 system 稳定段;只有用户 @ 主动触发的附件行(已落库)进数组。
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [],
    );
    expect(snapshot.systemPrompt, isNot(contains('<skills>')));
    expect(snapshot.segments.map((s) => s.key), isNot(contains('skills')));
  });

  test('compact summaries become the first message after the memory slot', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'system', content: 'Earlier: they met', seq: 0),
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 1),
        Message(sessionId: 1, role: 'assistant', content: 'hello', seq: 2),
      ],
    );
    expect(snapshot.systemPrompt, isNot(contains('Earlier: they met')));
    expect(snapshot.leadingSummaryContent, contains('Earlier: they met'));
    final contents = snapshot.messages.map((m) => m.content).toList();
    expect(contents.length, 3);
    // CV 批:摘要前置消息整段包 <summary> 标签块(开标签后是说明行,再是正文)。
    expect(contents.first, startsWith('<summary>'));
    expect(contents.first, endsWith('</summary>'));
    expect(contents.first, contains('Earlier: they met'));
    expect(contents[1], 'hi');
    expect(contents[2], 'hello');
    expect(snapshot.messages.first.role, ChatRole.user);
  });

  test('without summaries the message array contains only real history', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
    );
    expect(snapshot.leadingSummaryContent, isNull);
    expect(snapshot.messages.map((m) => m.content).toList(), ['hi']);
  });

  test('stripSkillNames removes @skill tokens from wire messages but keeps panel raw (DA)', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'user', content: '@剑术 我拔剑了', seq: 0),
        Message(sessionId: 1, role: 'assistant', content: '你挥出一道剑光', seq: 1),
      ],
      stripSkillNames: {'剑术'},
    );
    // 线上消息数组:@记号被剥掉(用户输入始终在请求最后,末条即剥离后的文本)。
    expect(snapshot.messages.map((m) => m.content).toList(), ['我拔剑了', '你挥出一道剑光']);
    // 面板分段保留本地可见的原文(面板可读性与线上格式解耦,CV 批原则)。
    final historySegment = snapshot.segments.firstWhere((s) => s.key == 'history');
    expect(historySegment.content, contains('@剑术'));
    // 空集合不剥离(缺省行为不变)。
    final untouched = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [Message(sessionId: 1, role: 'user', content: '@剑术 我拔剑了', seq: 0)],
    );
    expect(untouched.messages.single.content, '@剑术 我拔剑了');
  });

  test('excludes empty-content image messages from history', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 0),
        Message(sessionId: 1, role: 'assistant', content: '', seq: 1, imageBase64: 'aGVsbG8='),
        Message(sessionId: 1, role: 'assistant', content: 'hello', seq: 2),
      ],
    );
    expect(snapshot.messages.map((m) => m.content).toList(), ['hi', 'hello']);
  });

  test('never includes variables anywhere (main write excludes them)', () {
    // CL 批:变量只存在于后台 agent 的上下文;主写快照(system/messages/分段)
    // 一律不含变量 —— assemble 甚至不接受变量输入。
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [Message(sessionId: 1, role: 'user', content: 'hi', seq: 0)],
    );
    expect(snapshot.systemPrompt, isNot(contains('Variables:')));
    expect(snapshot.messages.map((m) => m.content), everyElement(isNot(contains('Variables:'))));
    expect(snapshot.segments.map((s) => s.key), isNot(contains('variables')));
    expect(snapshot.segmentSources.containsKey('variables'), isFalse);
  });

  test('stable prefix covers all static segments and excludes mutable content', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(
        name: 'Alice',
        description: 'knight',
        postHistoryInstructions: 'stay in character',
      ),
      items: const [
        PromptItem(kind: PromptItemKind.preset, text: 'You are an RP assistant'),
        PromptItem(kind: PromptItemKind.rule, text: 'No OOC'),
      ],
      frozenMemory: 'auto fact',
      history: const [
        Message(sessionId: 1, role: 'system', content: 'Earlier summary', seq: 0),
        Message(sessionId: 1, role: 'user', content: 'I draw my sword', seq: 1),
      ],
      worldbook: const [
        WorldbookEntry(characterId: 1, keys: [], constant: true, content: 'Always-on lore'),
      ],
    );

    final stable = snapshot.stableSystemPrompt;
    expect(stable, contains('<preset>'));
    expect(stable, contains('<rules>'));
    expect(stable, contains('<character>'));
    expect(stable, contains('<post_history_instructions>'));
    expect(stable, contains('<worldbook_constant>'));
    expect(stable, contains('Always-on lore'));
    expect(stable, isNot(contains('<summary>')));
    expect(stable, isNot(contains('<skills>')));
    expect(stable, isNot(contains('<memory>')));
    expect(stable, isNot(contains('auto fact')));
    // CW 批:system 即稳定段(可变内容全部移入 messages 数组)。
    expect(snapshot.systemPrompt, stable);
    // 摘要/记忆是数组头部合成消息,真实历史紧随其后。
    expect(snapshot.messages[0].content, startsWith('<system-reminder>'));
    expect(snapshot.messages[1].content, startsWith('<summary>'));
    expect(snapshot.messages[2].content, 'I draw my sword');
  });

  test('empty stable prompt leaves the system field blank', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(),
      items: const [PromptItem(kind: PromptItemKind.preset, text: 'You are an RP assistant')],
      history: const [],
    );
    // CV 批线上格式钉死:单一稳定段 = <preset>说明行\n正文</preset>。
    expect(
      snapshot.stableSystemPrompt,
      '<preset>这是全局预设提示词:定义本次对话的写作风格与基础指令\n'
      'You are an RP assistant</preset>',
    );
    expect(snapshot.systemPrompt, snapshot.stableSystemPrompt);
  });

  test('frozen memory bytes stay identical across turns (cache hit for slot 0)', () {
    // 记忆第 0 条 = 冻结副本:库中记忆变化(改经 diff 通知)不改这里 ——
    // 同一冻结文本连续两轮组装,数组首条字节完全一致。
    ContextSnapshot snap(String frozen) => assembler.assemble(
      character: const CharacterCard(name: 'Alice'),
      items: const [PromptItem(kind: PromptItemKind.preset, text: 'You are')],
      frozenMemory: frozen,
      history: const [Message(sessionId: 1, role: 'user', content: 'q', seq: 0)],
    );
    final a = snap('frozen fact');
    final b = snap('frozen fact');
    expect(a.messages.first.content, b.messages.first.content);
    expect(a.systemPrompt, b.systemPrompt);
  });

  test('keeps old attachment rows — nothing is trimmed out of the window', () {
    // 组装不再按条数裁剪,窗口内的附件行随其所在区块原样进上下文;条目退出
    // 上下文只可能因为被压缩折叠(发送管线的去重以活跃行 ref 为准)。
    final history = <Message>[
      Message(
        sessionId: 1,
        role: 'user',
        content: ContextAssembler.worldbookAttachment('旧条目', 'old lore'),
        seq: 0,
        kind: MessageKind.attachment,
        refId: 'wb:1',
      ),
      Message(sessionId: 1, role: 'user', content: 'm1', seq: 1),
      for (var i = 2; i < 24; i++)
        Message(sessionId: 1, role: i.isEven ? 'user' : 'assistant', content: 'm$i', seq: i),
    ];
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: history,
    );
    expect(snapshot.messages.first.content, contains('old lore'));
    expect(snapshot.messages.length, 24);
  });

  test('activeRows filters compacted/system/empty rows without trimming', () {
    // 与组装同一把尺子:排除 system 摘要行、已压缩行、空内容行,但**不裁剪**
    // (上下文规模由压缩控制,组装不再按条数砍)。
    final rows = <Message>[
      const Message(sessionId: 1, role: 'system', content: '摘要', seq: 0),
      const Message(sessionId: 1, role: 'user', content: 'm1', seq: 1),
      const Message(sessionId: 1, role: 'user', content: '旧', seq: 2, isCompacted: true),
      const Message(sessionId: 1, role: 'user', content: '', seq: 3),
      for (var i = 4; i < 25; i++)
        Message(sessionId: 1, role: 'user', content: 'm$i', seq: i),
    ];
    final active = ContextAssembler.activeRows(rows);
    expect(active.length, 22, reason: '25 行减去 system / 已压缩 / 空内容各一条');
    expect(active.first.content, 'm1');
    expect(active.last.content, 'm24');
  });

  test('collapseWorldbookDuplicates keeps only the newest row per entry name', () {
    // 存量收敛(2026-09-28 批):条目 id 曾经不稳定,同一条目在窗口里会留下
    // 多个 refId 的附件行 —— 按条目名只保留最新一条。
    final rows = <Message>[
      Message(sessionId: 1, role: 'user', content: 'q1', seq: 0),
      Message(
        sessionId: 1,
        role: 'user',
        content: ContextAssembler.worldbookAttachment('圣剑', '旧内容'),
        seq: 1,
        kind: MessageKind.attachment,
        refId: 'wb:1',
      ),
      Message(sessionId: 1, role: 'user', content: 'q2', seq: 2),
      Message(
        sessionId: 1,
        role: 'user',
        content: ContextAssembler.worldbookAttachment('圣剑', '新内容'),
        seq: 3,
        kind: MessageKind.attachment,
        refId: 'wb:9',
      ),
      Message(
        sessionId: 1,
        role: 'user',
        content: ContextAssembler.worldbookAttachment('王城', '另一条'),
        seq: 4,
        kind: MessageKind.attachment,
        refId: 'wb:5',
      ),
      Message(sessionId: 1, role: 'user', content: 'q3', seq: 5),
    ];
    final kept = ContextAssembler.collapseWorldbookDuplicates(rows);
    expect(kept.map((m) => m.seq).toList(), [0, 2, 3, 4, 5],
        reason: '同名旧行(seq 1)被丢弃,其余顺序不变');
    expect(kept.firstWhere((m) => m.refId == 'wb:9').content, contains('新内容'));
  });

  test('collapseWorldbookDuplicates leaves non-worldbook rows untouched', () {
    final rows = <Message>[
      Message(sessionId: 1, role: 'user', content: '普通对话', seq: 0),
      Message(
        sessionId: 1,
        role: 'user',
        content: ContextAssembler.compactNoticeText,
        seq: 1,
        kind: MessageKind.attachment,
        refId: 'notice:compact:1',
      ),
      Message(
        sessionId: 1,
        role: 'user',
        content: '<system-reminder>以下是世界书条目「无引用前缀」\nX</system-reminder>',
        seq: 2,
        kind: MessageKind.attachment,
      ),
    ];
    expect(ContextAssembler.collapseWorldbookDuplicates(rows).length, 3,
        reason: '通知行与 refId 缺失的行不参与收敛');
  });

  test('regex worldbook keys match via matchTriggered; malformed keys are skipped', () {
    final entries = [
      const WorldbookEntry(id: 1, characterId: 1, keys: [r'drag.n'], useRegex: true, content: 'Dragons breathe fire'),
      const WorldbookEntry(id: 2, characterId: 1, keys: ['['], useRegex: true, content: 'broken regex'),
      const WorldbookEntry(id: 3, characterId: 1, keys: ['hello'], content: 'matches fine'),
    ];
    final hit = assembler.matchTriggered(entries, 'hello there, the dragon flies');
    expect(hit.map((e) => e.id), containsAll([1, 3]));
    expect(hit.map((e) => e.id), isNot(contains(2)));
  });

  test('selective entries require both a main and a secondary key hit', () {
    WorldbookEntry entry({required List<String> keys, required List<String> secondaryKeys}) => WorldbookEntry(
      characterId: 1,
      keys: keys,
      secondaryKeys: secondaryKeys,
      selective: true,
      content: 'Selective lore',
    );
    final e = entry(keys: ['sword'], secondaryKeys: ['cursed']);
    expect(assembler.matchTriggered([e], 'I draw my sword'), isEmpty);
    expect(assembler.matchTriggered([e], 'A cursed ring'), isEmpty);
    expect(assembler.matchTriggered([e], 'my cursed sword').single.content, 'Selective lore');
  });

  test('case-sensitive keys match exactly', () {
    const e = WorldbookEntry(characterId: 1, keys: ['Sword'], caseSensitive: true, content: 'Case lore');
    expect(assembler.matchTriggered([e], 'a Sword appears'), isNotEmpty);
    expect(assembler.matchTriggered([e], 'a sword appears'), isEmpty);
  });

  test('whole-word keys match word boundaries, ASCII only; CJK falls back to substring', () {
    const word = WorldbookEntry(characterId: 1, keys: ['sword'], matchWholeWords: true, content: 'Whole word lore');
    const cjk = WorldbookEntry(characterId: 1, keys: ['图书馆'], matchWholeWords: true, content: 'CJK lore');
    expect(assembler.matchTriggered([word], 'my sword is sharp'), isNotEmpty);
    expect(assembler.matchTriggered([word], 'swordsmanship is hard'), isEmpty);
    expect(assembler.matchTriggered([cjk], '大图书馆的守门人'), isNotEmpty);
  });

  test('segments mirror the assembly order and drop empty ones', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(
        name: 'Alice',
        description: 'knight',
        postHistoryInstructions: 'stay in character',
      ),
      items: const [
        PromptItem(kind: PromptItemKind.preset, text: 'You are an RP assistant'),
        PromptItem(kind: PromptItemKind.rule, text: 'No OOC'),
      ],
      frozenMemory: 'auto fact',
      history: const [
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 0),
        Message(sessionId: 1, role: 'assistant', content: 'hello', seq: 1),
      ],
    );
    // 按实际组装顺序出现;空段(此处无 世界书/摘要)被剔除。
    final keys = snapshot.segments.map((s) => s.key).toList();
    expect(keys[0], 'preset');
    expect(keys[1], 'rules');
    expect(keys[2], 'character');
    expect(keys[3], 'postHistory');
    expect(keys, isNot(contains('worldbookConstant'))); // 无命中时不出现在列表
    expect(keys[4], 'memory'); // 第 0 条消息(冻结副本)
    expect(keys[5], 'history'); // 真实历史随 messages 数组
    expect(keys.last, 'history'); // 无附件时 attachments 段被剔除
    expect(keys, isNot(contains('summary')));
    expect(keys, isNot(contains('variables'))); // CL 批起变量不进主写分段
    expect(keys, isNot(contains('skills'))); // CW 批起技能不进分段(只有附件行)
  });

  test('summary segment is listed between memory and history segments', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      frozenMemory: 'auto fact',
      history: const [
        Message(sessionId: 1, role: 'system', content: 'Earlier summary', seq: 0),
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 1),
      ],
    );
    // 分段顺序镜像线上格式:稳定段 → 记忆(第 0 条)→ 摘要 → 历史 → 附件。
    final keys = snapshot.segments.map((s) => s.key).toList();
    expect(keys.indexOf('memory'), lessThan(keys.indexOf('summary')));
    expect(keys.indexOf('summary'), lessThan(keys.indexOf('history')));
  });

  test('history segment subdivides into per-message entries', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [
        Message(sessionId: 1, role: 'user', content: 'hi', seq: 0),
        Message(sessionId: 1, role: 'assistant', content: 'hello', seq: 1),
      ],
    );
    final history = snapshot.segments.firstWhere((s) => s.key == 'history');
    expect(history.hasSubEntries, isTrue);
    expect(history.content, contains('用户'));
    expect(history.content, contains('hi'));
    final subs = history.subEntries;
    expect(subs.length, 2);
    expect(subs[0].label, '用户');
    expect(subs[0].content, 'hi');
    expect(subs[1].label, '助手');
    expect(subs[1].content, 'hello');
  });

  test('constant worldbook segment subdivides per entry', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [],
      history: const [],
      worldbook: const [
        WorldbookEntry(characterId: 1, name: '世界观', keys: [], constant: true, content: 'Always present'),
        WorldbookEntry(characterId: 1, keys: ['dragon'], content: 'Never matches entry'),
      ],
    );
    final wbConst = snapshot.segments.firstWhere((s) => s.key == 'worldbookConstant');
    expect(wbConst.subEntries.length, 1);
    expect(wbConst.subEntries[0].label, '世界观');
    expect(wbConst.content, 'Always present');
    expect(wbConst.content, isNot(contains('dragon')));
  });

  test('preset and rules segments subdivide per item (rules same as presets)', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [
        PromptItem(kind: PromptItemKind.preset, name: '文风', text: 'Write prose'),
        PromptItem(kind: PromptItemKind.preset, text: 'Unnamed preset'),
        PromptItem(kind: PromptItemKind.rule, name: '禁止规则', text: 'No OOC'),
        PromptItem(kind: PromptItemKind.rule, text: 'No meta'),
      ],
      history: const [],
    );
    final preset = snapshot.segments.firstWhere((s) => s.key == 'preset');
    expect(preset.hasSubEntries, isTrue);
    expect(preset.subEntries.map((s) => s.label).toList(), ['文风', '预设 2']);
    expect(preset.subEntries.map((s) => s.content).toList(), ['Write prose', 'Unnamed preset']);

    // 规则与预设同款按条目划分:条目名作标签,无名回退「规则 N」。
    final rules = snapshot.segments.firstWhere((s) => s.key == 'rules');
    expect(rules.hasSubEntries, isTrue);
    expect(rules.subEntries.map((s) => s.label).toList(), ['禁止规则', '规则 2']);
    expect(rules.subEntries.map((s) => s.content).toList(), ['No OOC', 'No meta']);
    // 整段拼接内容不受细分影响(线上字节与面板分段文本同源)。
    expect(rules.content, 'No OOC\nNo meta');
  });

  test('CV: every non-empty stable segment is wrapped as <tag>说明行\\n正文</tag>', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(
        name: 'Alice',
        description: 'knight',
        postHistoryInstructions: 'stay in character',
      ),
      items: const [
        PromptItem(kind: PromptItemKind.preset, text: 'You are an RP assistant'),
        PromptItem(kind: PromptItemKind.rule, text: 'No OOC'),
      ],
      history: const [],
      worldbook: const [
        WorldbookEntry(characterId: 1, keys: [], constant: true, content: 'Always-on lore'),
      ],
    );
    // system 稳定段 = preset/rules/character/post-history/常驻世界书 五个标签块
    // 按序拼接(CW 批起技能移出 system)。
    const expectedTags = [
      'preset',
      'rules',
      'character',
      'post_history_instructions',
      'worldbook_constant',
    ];
    final sp = snapshot.systemPrompt;
    int pos = 0;
    for (final tag in expectedTags) {
      final open = sp.indexOf('<$tag>', pos);
      expect(open, greaterThanOrEqualTo(0), reason: '<$tag> 应按序出现');
      final descLine = sp.substring(open + '<$tag>'.length).split('\n').first;
      expect(descLine, isNotEmpty, reason: '$tag 的说明行不能为空');
      expect(descLine.startsWith('<'), isFalse, reason: '$tag 开标签后是中文说明而非嵌套标签');
      pos = open + 1;
    }
    expect(sp, contains('You are an RP assistant</preset>'));
    expect(sp, contains('No OOC</rules>'));
    expect(sp, contains('knight</character>'));
    expect(sp, contains('stay in character</post_history_instructions>'));
    expect(sp, contains('Always-on lore</worldbook_constant>'));
  });

  test('CV: panel segments stay untagged while the wire format wraps them', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(name: 'A'),
      items: const [PromptItem(kind: PromptItemKind.preset, text: 'plain preset body')],
      history: const [],
    );
    // 面板分段/来源仍是未包裹原文;线上文本才有标签 —— 两层格式解耦。
    final seg = snapshot.segments.firstWhere((s) => s.key == 'preset');
    expect(seg.content, 'plain preset body');
    expect(snapshot.segmentSources['preset'], 'plain preset body');
    expect(snapshot.systemPrompt, contains('<preset>'));
    expect(snapshot.systemPrompt, contains('</preset>'));
  });

  test('CV: empty segments emit no dangling tags anywhere', () {
    final snapshot = assembler.assemble(
      character: const CharacterCard(),
      items: const [],
      history: const [],
    );
    expect(snapshot.systemPrompt, isEmpty);
    const allTags = [
      'preset',
      'rules',
      'character',
      'post_history_instructions',
      'worldbook_constant',
      'skills',
      'summary',
    ];
    for (final t in allTags) {
      expect(snapshot.systemPrompt, isNot(contains('<$t>')));
      expect(snapshot.leadingSummaryContent ?? '', isNot(contains('<$t>')));
      expect(snapshot.leadingMemoryContent ?? '', isNot(contains('<$t>')));
    }
  });
}
