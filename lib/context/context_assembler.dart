import 'dart:collection';

import '../models/character_card.dart';
import '../models/chat_message.dart';
import '../models/context_snapshot.dart';
import '../models/message.dart';
import '../models/prompt_item.dart';
import '../models/worldbook_entry.dart';

/// 上下文组装器(CW 批起引入 attachments 机制,参考 Claude Code)。
///
/// 线上布局(一次请求的完整字节序):
///
/// ```
/// system:  preset / rules / character / post_history / 常驻世界书   ← 稳定段
/// messages:
///   [0] 记忆(冻结副本,<system-reminder> 包裹,常驻首位)
///   [1] 压缩摘要(<summary> 标签块,无摘要时无此条)
///   [2…] 历史(真实对话 + 已落库的附件行,按 seq 交错;技能/世界书附件行
///        总在它所属的用户消息之前 —— 落库顺序保证,无需重排;通知类附件行
///        可能晚于所属用户消息落库(如发送中途的硬挡压缩),组装时经
///        [_correctNoticePositions] 校正到最新用户行之前)
///   末条恒为用户实际输入或最近的真实消息 —— 注入内容绝不排在用户话语之后
/// ```
///
/// 缓存视角:system 稳定段、记忆第 0 条、历史(含附件行)一旦写入即字节
/// 冻结(append-only),跨轮命中提示缓存;每轮新增的只有窗口尾部的新消息与
/// 新附件行,变化区收敛于前缀最末端。通知附件行校正后的数组位置跨轮稳定
/// (始终在其所属用户行之前),不破坏前缀缓存。
class ContextAssembler {
  /// 缓存优化:世界书键级匹配用的已编译 RegExp 缓存。
  ///
  /// 每次匹配都会遍历全部世界书条目并对 recent 文本做键匹配;
  /// 此前每个键每次都会重新 `RegExp(...)` 构造一次对象(`useRegex` / `matchWholeWords`
  /// 分支)。会话内条目与开关基本不变,重复编译同一 pattern 是无谓开销。
  ///
  /// 调用方常以 `ContextAssembler()` 重建实例(chat_controller 每轮 new 一次),
  /// 所以这里用**静态**缓存以跨调用复用编译结果;条目的 `(pattern, caseSensitive,
  /// wholeWord)` 三元组与每条文本匹配语义一一对应,条目编辑后键变化自然生成新
  /// key。用有序 Map 实现简单的容量上限(FIFO 淘汰),防止长期运行的进程/多次
  /// 会话把缓存撑到无限大。
  static const int _regexCacheCap = 2048;
  static final LinkedHashMap<String, RegExp> _regexCache =
      LinkedHashMap<String, RegExp>();

  /// 登记一个刚编译的 regex;若已到容量上限,先淘汰最旧的键。缓存满了只是少存
  /// 新键,不抛错、不影响正确性。
  static void _storeRegex(String key, RegExp re) {
    if (_regexCache.length >= _regexCacheCap) {
      _regexCache.remove(_regexCache.keys.first);
    }
    _regexCache[key] = re;
  }

  String _regexCacheKey(String pattern, bool caseSensitive, bool wholeWord) =>
      '${caseSensitive ? '+' : '-'}${wholeWord ? 'w' : 's'}\u0001$pattern';

  /// 段落标签包裹(CV 批):每个语义段落在线上文本中以
  /// `<标签>说明行\n正文</标签>` 整体包裹,开标签后紧跟一行中文说明点明该段
  /// 是做什么的,再换行接原文。这让模型能明确分辨「设定资料」与「对话内容」
  /// 的边界 —— 降低设定被当成对话复述、或对话被误当设定的概率;旁路段与摘要
  /// 的说明行额外带「非对话内容、回复时勿提及」提示。
  ///
  /// 标签全小写下划线、跨轮稳定(不参与任何变化),因此包裹不破坏缓存分段:
  /// 稳定段仍字节稳定,可变段的标签块也只在正文变化时变化。上下文面板
  /// ([ContextSegment]) 展示的仍是未包裹的段落原文,面板可读性与线上格式解耦。
  static String _wrap(String tag, String description, String content) =>
      '<$tag>$description\n$content</$tag>';

  // 各段固定标签名与说明行。标签名即线上的 XML 式标记;说明行是给模型的
  // 一句话用途描述(与标签一一对应,改动任一处都属线上格式变更)。
  static const _descPreset = '这是全局预设提示词:定义本次对话的写作风格与基础指令';
  static const _descRules = '这是全局规则:模型在本会话中必须遵守的行为约束';
  static const _descCharacter = '这是当前角色卡的设定资料:角色的姓名、描述、性格、场景与示例对话';
  static const _descPostHistory = '这是剧情后注:角色卡携带的补充指令,与前述设定冲突时以其为准';
  static const _descWorldbookConstant = '这是常驻世界书:始终生效的世界观设定资料';
  static const _descSummary =
      '这是会话早期剧情的压缩摘要,非对话内容:其后是最近的真实对话,仅供衔接参考,回复时请勿提及或复述';

  // ── attachments 线上文本形态 ─────────────────────────────────────────
  // 附件/通知一律以 <system-reminder> 包裹(对齐 Claude Code):模型对这种
  // 形态已有"系统注入、非用户发言"的先验,不会当成对话内容复述。

  /// 记忆"第 0 条消息":冻结副本的线上形态。语义对齐 Claude Code 的项目记忆 —— 会话级
  /// 常驻资料,跨轮字节不变(修改经 diff 通知送达,副本只在压缩/主动刷新时更新)。
  static String memoryReminder(String memory) =>
      '<system-reminder>这是本会话的长期记忆,由用户维护的常驻资料(类似项目级'
      ' 常驻记忆):角色的固定外貌与身份、既定关系、世界观事实、用户偏好与长期'
      '目标。非对话内容,回复时请遵守其中事实,但勿提及或复述本段。\n'
      '$memory</system-reminder>';

  /// 世界书触发条目附件:发送管线在用户消息落库**前**计算命中并落库,
  /// 组装时按 seq 自然位于该用户消息之前。
  static String worldbookAttachment(String name, String content) =>
      '<system-reminder>以下是世界书条目「$name」,因最近对话命中其关键词而注入。'
      '非对话内容,仅供设定参考,回复时请勿提及或复述。\n$content</system-reminder>';

  /// @技能附件:仅当用户在输入中以 @技能名 主动提及时注入一次。
  static String skillAttachment(String name, String description, String content) =>
      '<system-reminder>以下是用户通过 @$name 主动调用的技能,供之后的写作参考使用。'
      '非对话内容,除非用户要求,勿在回复中复述其内容。\n'
      '${description.isEmpty ? name : '$name: $description'}\n$content</system-reminder>';

  /// 压缩通知:主动/自动压缩触发后,以附件行落库,注入压缩后的首次组装。
  static const String compactNoticeText =
      '<system-reminder>会话历史刚进行了一次压缩:更早的对话已被摘要替代(摘要在'
      '上下文开头的 <summary> 段),其后是最近的真实对话。请基于摘要衔接剧情,'
      '勿提及压缩本身。</system-reminder>';

  /// 记忆修改差异通知:记忆被用户修改后,冻结副本暂不更新,差异以本通知
  /// 落库为附件行送达(新增/删除按行集合差计算)。
  static String memoryDiffNotice(List<String> added, List<String> removed) {
    final parts = <String>[
      '<system-reminder>用户修改了本会话的长期记忆。上下文开头记忆段仍是修改前的'
      '版本,以下是与最新版本的差异,后续回复请以本差异为准(新增优先于旧记忆中'
      '的矛盾内容,删除的内容不再成立):',
      for (final line in added) '【新增】$line',
      for (final line in removed) '【删除】$line',
      '勿向用户提及本段。</system-reminder>',
    ];
    return parts.join('\n');
  }

  /// 组装主写引擎的上下文快照(纯文本 system + messages)。
  ///
  /// CW 批起:
  /// - 技能**不再**进 system(有且仅有用户 @技能名 主动触发时,经附件行注入);
  /// - 触发世界书**不再**逐轮重算进尾部旁路 —— 命中时作为附件行落库(append-only,
  ///   去重记账由发送管线负责),组装时按 seq 原样进数组;
  /// - 记忆改为 [frozenMemory] 的"第 0 条消息"(冻结副本,见 [memoryReminder])。
  ///
  /// DG 批起:压缩通知与记忆差异通知也落库为附件行(原合成插入路径退役);
  /// 晚于所属用户消息落库的通知行经 [_correctNoticePositions] 校正到最新
  /// 用户行之前,线上字节与原合成位置一致。
  ///
  /// 注意:变量(variables)自 CL 批起**有意不参与**主写组装 —— 只存在于
  /// 后台 agent 的上下文(`BackgroundEngine._buildPrompt` 按功能块注入),
  /// 本方法不接受也不产出任何变量内容。
  ContextSnapshot assemble({
    required CharacterCard character,
    required List<PromptItem> items,
    required List<Message> history,
    List<WorldbookEntry> worldbook = const [],
    String? frozenMemory,
    Set<String> stripSkillNames = const {},
  }) {
    final segmentSources = <String, String>{};
    // 面板分段:严格按实际组装顺序,带细分条目(世界书/会话历史)。
    final segments = <ContextSegment>[];

    final presetItems = items.where((i) => i.kind == PromptItemKind.preset).toList();
    final preset = presetItems.map((i) => i.text).join('\n\n');
    final ruleItems = items.where((i) => i.kind == PromptItemKind.rule).toList();
    final rules = ruleItems.map((i) => i.text).join('\n');

    final characterText = [
      if (character.name.isNotEmpty) 'Name: ${character.name}',
      if (character.description.isNotEmpty) 'Description:\n${character.description}',
      if (character.personality.isNotEmpty) 'Personality:\n${character.personality}',
      if (character.scenario.isNotEmpty) 'Scenario:\n${character.scenario}',
      if (character.mesExample.isNotEmpty) 'Example dialogue:\n${character.mesExample}',
    ].join('\n\n');

    // Summaries are system-role rows persisted by CompactService. They render as
    // the first synthetic user message of the array (after the memory slot),
    // immediately before the recent real history —— 摘要前置:模型先读"此前发生
    // 了什么",再读最近几条真实对话衔接剧情。
    // 合并式单一摘要(2026-09 批):每次压缩把既有摘要吸收进新版并折叠旧行
    // (is_compacted=1),这里只渲染未折叠 system 行 —— 线上摘要段永远只有一
    // 份最新摘要,不随压缩次数堆叠膨胀、无新旧状态互相矛盾。
    final summaryText = history
        .where((m) => m.role == 'system' && !m.isCompacted)
        .map((m) => m.content)
        .join('\n\n');
    final leadingSummaryContent =
        summaryText.isEmpty ? null : _wrap('summary', _descSummary, summaryText);

    // 记忆第 0 条:冻结副本(调用方保证会话内字节稳定);空记忆不产生首条消息。
    final memoryText = frozenMemory?.trim() ?? '';
    final leadingMemoryContent = memoryText.isEmpty ? null : memoryReminder(memoryText);

    // 历史窗口:真实对话与附件行共同参与(seq 顺序即注入顺序)。
    //
    // 组装**不做任何按条数的裁剪**(2026-09-28 批):窗口内全部未折叠活跃行
    // 原样发出 —— 上下文规模由压缩按 token 占用率控制(target/soft/hard 三挡),
    // 组装器只负责渲染调用方给的窗口。此前的 2x 滞回裁剪会每轮把数组首条
    // 后移,使 messages 前缀每轮全变、提示缓存永久失效;而且它按条数算,
    // 会砍掉压缩刚按 token 预算保留下来的活跃历史 —— 两处口径正交,已退役。
    // 窗口由 MessageRepository.sessionWindow 按"覆盖全部未折叠活跃行"取,
    // 因此这里看到的行集必然完整;缺行只可能来自窗口下界算错。
    final rows = collapseWorldbookDuplicates(activeRows(history));
    // 通知类附件行位置校正:晚于最新用户行落库的通知(如发送中途的硬挡压缩)
    // 挪到该用户行之前,线上字节与原合成插入位置一致(见 [_correctNoticePositions])。
    final ordered = _correctNoticePositions(rows);
    // @技能名 记号只在 LLM 边界剥离(CY 批后继:转录保留用户原话供气泡/编辑
    // 所见即所得,组装请求时才剥)。只作用于真实对话行;附件行与面板分段
    // (segmentSources)保持原样 —— 面板展示的是本地可见的原文。
    final recentMessages = [
      for (final m in ordered)
        if (m.isChat && stripSkillNames.isNotEmpty)
          ChatMessage(_role(m.role), withoutSkillTokens(m.content, stripSkillNames))
        else
          ChatMessage(_role(m.role), m.content),
    ];

    final messages = <ChatMessage>[
      if (leadingMemoryContent != null) ChatMessage(ChatRole.user, leadingMemoryContent),
      if (leadingSummaryContent != null) ChatMessage(ChatRole.user, leadingSummaryContent),
      ...recentMessages,
    ];

    // 常驻世界书(constant)字节稳定,进 system 稳定段参与缓存;
    // 触发条目已改为附件行(发送管线命中时落库),组装不再逐轮匹配。
    final constantEntries = worldbook.where((e) => e.enabled && e.constant).toList();
    final constantWorldbookText = constantEntries.map((e) => e.content).join('\n\n');

    // 系统提示词只剩稳定段:preset/rules/character/post-history/常驻世界书。
    // (技能、触发世界书、记忆全部移出 system,分别走附件行与第 0 条消息。)
    final stableParts = <String>[
      if (preset.isNotEmpty) _wrap('preset', _descPreset, preset),
      if (rules.isNotEmpty) _wrap('rules', _descRules, rules),
      if (characterText.isNotEmpty) _wrap('character', _descCharacter, characterText),
      if (character.postHistoryInstructions.isNotEmpty)
        _wrap('post_history_instructions', _descPostHistory, character.postHistoryInstructions),
      if (constantWorldbookText.isNotEmpty)
        _wrap('worldbook_constant', _descWorldbookConstant, constantWorldbookText),
    ];
    final systemPrompt = stableParts.join('\n\n');

    // 分段顺序严格镜像 parts 的顺序,即实际发往 LLM 的组装顺序。
    void push(String key, String label, String content, {List<ContextSubEntry> sub = const []}) {
      if (content.isEmpty && sub.isEmpty) return;
      segments.add(ContextSegment(key: key, label: label, content: content, subEntries: sub));
    }

    // 预设/规则都按条目细分(与世界书/会话历史一致),面板展开整段时逐条展示,
    // 点击单条才展开其完整文本 —— 避免多条拼接的长文本一次性铺满。
    push(
      'preset',
      '预设提示词',
      preset,
      sub: [
        for (final (i, item) in presetItems.indexed)
          ContextSubEntry(item.name.isNotEmpty ? item.name : '预设 ${i + 1}', item.text),
      ],
    );
    push(
      'rules',
      '规则',
      rules,
      sub: [
        for (final (i, item) in ruleItems.indexed)
          ContextSubEntry(item.name.isNotEmpty ? item.name : '规则 ${i + 1}', item.text),
      ],
    );
    push('character', '角色卡', characterText);
    push('postHistory', '剧情后注', character.postHistoryInstructions);
    push(
      'worldbookConstant',
      '世界书·常驻',
      constantWorldbookText,
      sub: constantEntries.map((e) => ContextSubEntry(_entryLabel(e), e.content)).toList(),
    );
    // 记忆是 messages 数组的第 0 条(冻结副本),排在摘要与真实历史之前。
    push('memory', '记忆(第 0 条)', memoryText);
    push('summary', '摘要', summaryText);
    // 真实历史随 messages 数组发出;细分条目只含真实对话行(不含附件/合成行)。
    final chatRows = rows.where((m) => m.isChat).toList();
    push(
      'history',
      '会话历史',
      chatRows.map((m) => '${_historyLabel(_role(m.role))}: ${m.content}').join('\n'),
      sub: chatRows.map((m) => ContextSubEntry(_historyLabel(_role(m.role)), m.content)).toList(),
    );
    // 附件段:窗口内已落库的附件行(技能/世界书触发/通知),按注入顺序逐条细分。
    final attachmentRows = rows.where((m) => !m.isChat).toList();
    push(
      'attachments',
      '附件',
      attachmentRows.map((m) => m.content).join('\n\n'),
      sub: [for (final m in attachmentRows) ContextSubEntry(_attachmentLabel(m), m.content)],
    );

    segmentSources['preset'] = preset;
    segmentSources['rules'] = rules;
    segmentSources['character'] = characterText;
    segmentSources['worldbookConstant'] = constantWorldbookText;
    segmentSources['summary'] = summaryText;
    segmentSources['memory'] = memoryText;

    return ContextSnapshot(
      systemPrompt: systemPrompt,
      messages: messages,
      segmentSources: segmentSources,
      segments: segments,
      stableSystemPrompt: systemPrompt,
      leadingMemoryContent: leadingMemoryContent,
      leadingSummaryContent: leadingSummaryContent,
      // 稳定前缀内容哈希:供上下文面板展示"稳定前缀是否变化"。
      stableSystemHash: systemPrompt.isEmpty ? 0 : systemPrompt.hashCode,
    );
  }

  /// 通知类附件行的位置校正:晚于最新真实用户行落库的通知附件行(典型来源:
  /// 发送中途硬挡压缩,用户消息已先落库),在当轮数组里挪到该用户行之前 ——
  /// 字节对齐 DG 批前合成插入的位置;通知之间保持原相对顺序。
  /// 没有用户行时原样返回(通知留在末尾);技能/世界书附件行落库顺序天然
  /// 在所属用户消息之前,不受影响。
  ///
  /// 缓存友好性:校正后的位置跨轮稳定(始终在所属用户行之前),后续新消息
  /// 只在尾部追加,前缀缓存不破坏。
  static List<Message> _correctNoticePositions(List<Message> rows) {
    final lastUserIdx = rows.lastIndexWhere((m) => m.isChat && m.role == 'user');
    if (lastUserIdx < 0) return rows;
    final tail = rows.sublist(lastUserIdx + 1);
    final misplaced = tail.where((m) => AttachmentRef.isNotice(m.refId)).toList();
    if (misplaced.isEmpty) return rows;
    return [
      ...rows.take(lastUserIdx),
      ...misplaced,
      rows[lastUserIdx],
      ...tail.where((m) => !AttachmentRef.isNotice(m.refId)),
    ];
  }

  /// 活跃历史行(单一真相,发送管线的附件去重共用同一把尺子):
  /// 排除 system 摘要行、已压缩行、空内容行。**不裁剪** —— 见 [assemble] 的
  /// 历史窗口注释(上下文规模由压缩按占用率控制,组装不再按条数砍)。
  static List<Message> activeRows(List<Message> history) {
    return history
        .where((m) => m.role != 'system' && !m.isCompacted && m.content.isNotEmpty)
        .toList();
  }

  /// 世界书附件行的**同条目收敛**(2026-09-28 批):同一世界书条目在窗口里
  /// 只保留**最新**的一条,其余丢弃。
  ///
  /// 为什么需要:去重账本以 `wb:<worldbook_entries.id>` 记账,而条目 id 曾经
  /// 不稳定(保存世界书走「全删再全插」,`AUTOINCREMENT` 让全表 id 前移)——
  /// 每次编辑都让同一条目多出一个 refId,账本认不出旧行,于是同一条目在
  /// 窗口里并存多份、面板上的附件数远超条目数。
  /// 数据侧已改为按 id 增删改(不再新增重复),但**存量旧行仍在库里** ——
  /// 这里做读取侧收敛:不改数据(旧行仍可回溯/导出),只让发送内容干净。
  ///
  /// 判定按**条目名**(附件行文本由 [worldbookAttachment] 固定生成,名字在
  /// 「」内)。解析不出名字的行原样保留,不做猜测。
  static List<Message> collapseWorldbookDuplicates(List<Message> rows) {
    final seen = <String>{};
    final kept = <Message>[];
    // 从新到旧走:每个条目名第一次遇到的就是最新那条。
    for (final m in rows.reversed) {
      final name = worldbookEntryNameOf(m);
      if (name != null && !seen.add(name)) continue;
      kept.add(m);
    }
    return kept.reversed.toList();
  }

  /// 世界书附件行的条目名提取正则。**静态复用** —— 组装对每个附件行都要取一次
  /// 名字(收敛去重 + 面板标签),每次现编译会白白烧掉大量正则对象。与
  /// [_regexCache] 同一条思路:能复用就别重建。
  static final RegExp _worldbookEntryNameRe =
      RegExp(r'以下是世界书条目「(.+?)」');

  /// 世界书附件行的条目名;非世界书附件行(或名字解析不出)返回 null。
  /// 名字来自 [worldbookAttachment] 写入的固定前缀,面板标签同源。
  static String? worldbookEntryNameOf(Message m) {
    if (m.isChat) return null;
    final ref = m.refId ?? '';
    if (!ref.startsWith('wb:')) return null;
    return _worldbookEntryNameRe.firstMatch(m.content)?.group(1);
  }

  /// 把 @技能名 记号从 LLM 可见文本中剥离:记号是本地调用语法,只在转录
  /// (气泡/编辑所见即所得)里保留,进上下文前在组装出口剥掉。多次提及全剥,
  /// 各记号后的原有空白不收缩;[names] 为空时原样返回。
  ///
  /// 合并为单正则一次替换(名字按字面转义),备选分支**长度降序**:逐名
  /// `replaceAll` 且按 Set 迭代序执行时,「@fire」会把「@fireball」啃成
  /// 「ball」—— 残名漏进 LLM 上下文;组装/摘要/后台转录三个出口共用此函数。
  static String withoutSkillTokens(String text, Iterable<String> names) {
    final cleaned = [
      for (final n in names)
        if (n.trim().isNotEmpty) n.trim(),
    ]..sort((a, b) => b.length.compareTo(a.length));
    if (cleaned.isEmpty) return text.trim();
    final tokens = RegExp(cleaned.map((n) => '@${RegExp.escape(n)}').join('|'));
    return text.replaceAll(tokens, '').trim();
  }

  /// 触发型世界书匹配(发送管线用):对 [text](最近对话 + 即将发送的用户输入)
  /// 做键匹配,返回命中的**非常驻**条目。常驻条目不在此列 —— 它们始终进
  /// system 稳定段,不做成附件。
  List<WorldbookEntry> matchTriggered(List<WorldbookEntry> entries, String text) {
    final matched = <WorldbookEntry>[];
    for (final e in entries) {
      if (!e.enabled || e.constant) continue;
      if (_matches(e, text)) matched.add(e);
    }
    return matched;
  }

  /// 附件行的面板标签:按 ref 前缀给出类别,拼内容长度。
  /// 世界书行额外从正文解析条目名(发送管线落库时名字已回退为触发关键词),
  /// 面板能直接看出是哪一条,而不只是"世界书"。
  static String _attachmentLabel(Message m) {
    final ref = m.refId ?? '';
    if (ref.startsWith('wb:')) {
      // 与收敛判据同源([worldbookEntryNameOf]):面板显示的名字,就是去重时
      // 用的那个名字 —— 两处各写一份正则迟早会漂移。
      final name = worldbookEntryNameOf(m);
      return '世界书${name != null && name.isNotEmpty ? ' · $name' : ''} · ${m.content.length} 字符';
    }
    final kindLabel = ref.startsWith('skill:')
        ? '技能'
        : ref.startsWith('notice:compact:')
            ? '压缩通知'
            : ref.startsWith('notice:memdiff:')
                ? '记忆差异'
                : '附件';
    return '$kindLabel · ${m.content.length} 字符';
  }

  String _entryLabel(WorldbookEntry e) {
    // 优先显示条目名;空名回退到原"恒定/触发关键词"标签(与模型注释约定一致)。
    if (e.name.trim().isNotEmpty) return e.name;
    final hit = e.keys.where((k) => k.isNotEmpty).take(2).join('、');
    final label = e.constant ? '恒定' : (hit.isNotEmpty ? '触发: $hit' : '触发');
    return '$label · ${e.content.length} 字符';
  }

  String _historyLabel(ChatRole r) => switch (r) {
    ChatRole.user => '用户',
    ChatRole.assistant => '助手',
    ChatRole.system => '系统',
  };

  /// 条目命中判定,对齐参考实现(Scritt lorebook):selective(主键+次键双命中)
  /// 优先于 useRegex/case_sensitive/match_whole_words 的键级匹配。
  bool _matches(WorldbookEntry e, String text) {
    if (e.selective) {
      return _hitAny(e.keys, text, e) && _hitAny(e.secondaryKeys, text, e);
    }
    return _hitAny(e.keys, text, e);
  }

  bool _hitAny(List<String> keys, String text, WorldbookEntry e) {
    final haystack = e.caseSensitive ? text : text.toLowerCase();
    for (final k in keys) {
      if (k.isEmpty) continue;
      if (e.useRegex) {
        // 命中缓存优先,避免每轮重复编译同一 regex(畸形 regex 仍逐次 try/catch)。
        final re = _cachedKeyRegex(k, e.caseSensitive, wholeWord: false);
        if (re != null && re.hasMatch(text)) return true;
      } else if (e.matchWholeWords && _isAsciiWord(k)) {
        // 整词匹配仅对纯 ASCII 词键生效,\b 在 CJK 邻接处不可靠,CJK 键回退子串。
        final re = _cachedKeyRegex(k, e.caseSensitive, wholeWord: true);
        if (re != null && re.hasMatch(text)) return true;
      } else if (e.caseSensitive ? text.contains(k) : haystack.contains(k.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  /// 编译并缓存单个世界书键的匹配正则。畸形(regex 编译失败)返回 null,调用方
  /// 跳过该键,与旧行为一致。`wholeWord=true` 时按整词边界模式转义并匹配(供
  /// 纯 ASCII 词键使用),否则按原始 pattern 使用(供 `useRegex` 直接匹配)。
  RegExp? _cachedKeyRegex(String k, bool caseSensitive, {required bool wholeWord}) {
    final key = _regexCacheKey(k, caseSensitive, wholeWord);
    final cached = _regexCache[key];
    if (cached != null) return cached;
    try {
      final re = RegExp(
        wholeWord ? '(?:^|\\W)${RegExp.escape(k)}(?:\\W|\$)' : k,
        caseSensitive: caseSensitive,
      );
      _storeRegex(key, re);
      return re;
    } on FormatException {
      // 畸形 regex 从导入卡继承而来 —— 跳过该键,不缓存失败结果。
      return null;
    }
  }

  bool _isAsciiWord(String s) => RegExp(r'^[A-Za-z0-9_]+$').hasMatch(s);

  ChatRole _role(String r) => switch (r) {
    'user' => ChatRole.user,
    'assistant' => ChatRole.assistant,
    // Unknown roles land in the messages array; map to user, never system
    // (a system message inside Anthropic's messages array is a 400).
    _ => ChatRole.user,
  };
}
