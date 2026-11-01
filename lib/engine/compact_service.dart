import 'dart:async';

import '../backend/llm_backend.dart';
import '../context/context_assembler.dart';
import '../data/message_repository.dart';
import '../models/chat_message.dart';
import '../models/message.dart';
import '../models/token_usage.dart';

/// 压缩被用户中断时 [_summarize] 抛出、[CompactService.compact] 捕获:
/// 按"未压缩"返回,不落库、不继续重试。
class _CompactInterrupted implements Exception {
  const _CompactInterrupted();
}

/// [_plan] 的产物:待压缩集合(原文/附件行)与会话现行未折叠摘要行。
typedef _CompactPlan = ({List<Message> toCompact, List<Message> prevSummaries});

/// 压缩会话较早的活跃对话为一条 LLM 摘要。
/// 被压缩的原文保留 `is_compacted=1`(不删除);摘要作为 `system` 角色行写入,
/// 由 ContextAssembler 渲染进系统提示。压缩在发送管线内联执行(P2;P3 后台
/// 引擎完成后仍保持内联)。
///
/// 合并式单一摘要:每次压缩把会话当前的未折叠摘要行作为「早期背景」一并
/// 送入模型,产出的新摘要自足、可完全替代旧摘要;旧摘要行与新摘要落库同
/// 一事务被折叠(`is_compacted=1`、`compact_of` 指向新摘要行)。因此线上
/// 摘要段永远只有一份最新版本 —— 不随压缩次数堆叠膨胀,也不出现新旧状态
/// 互相矛盾。组装器只渲染未折叠 system 行(见 ContextAssembler)。
class CompactService {
  final LlmBackend backend;
  final MessageRepository messages;
  CompactService(this.backend, this.messages);

  /// Summarizes all but the most recent [keep] live messages. Returns true if
  /// compaction happened, false if there was nothing to do (or summarization
  /// produced no text)。
  ///
  /// [minChunk]:仅有 [minChunk] 条以上消息掉出窗口才压缩(默认 1 保持旧行为)。
  /// [maxSummarizeAttempts]:摘要调用的总尝试次数(默认 1 = 失败不重试;
  /// 自动路径传 4 = 首次 + 3 次失败重试)。每次失败(ErrorEvent/异常/空输出)
  /// 都完整重试一遍摘要调用。
  /// [onUsage] 在摘要调用结束时回调其 token 用量(D2:压缩调用单独记账)。
  /// [stripSkillNames]:摘要转录里剥掉的 @技能名 记号(DA 批:记号只在转录
  /// 里保留供气泡/编辑,任何 LLM 出口都剥离)。
  /// [cancelSignal]:可选的用户中断信号 —— 触发即放弃本次压缩(取消底层
  /// LLM 请求、不重试、不落库),返回 false。硬挡压缩内联在发送管线里且
  /// 发生在流式开始之前,不设防时网络黑洞会让用户"连停止键都没有"。
  Future<bool> compact({
    required int sessionId,
    required String model,
    int keep = 20,
    int minChunk = 1,
    int maxSummarizeAttempts = 1,
    void Function(TokenUsage usage)? onUsage,
    Set<String> stripSkillNames = const {},
    Future<void>? cancelSignal,
  }) async {
    final plan = await _plan(sessionId, keep: keep, minChunk: minChunk);
    if (plan == null) return false;

    // 摘要失败重试:maxSummarizeAttempts 为总尝试次数,任一次成功即止;
    // 用户中断直接放弃(不重试、不落库)。
    String? summary;
    try {
      for (var attempt = 0; attempt < maxSummarizeAttempts && summary == null; attempt++) {
        summary = await _summarize(model, plan.toCompact, plan.prevSummaries, onUsage, stripSkillNames, cancelSignal: cancelSignal);
      }
    } on _CompactInterrupted {
      return false;
    }
    if (summary == null) return false;

    await _apply(sessionId: sessionId, content: summary, plan: plan);
    return true;
  }

  /// 机械截断兜底(发送前预算检测专用):**不经 LLM** —— 把除最新 [keep] 条
  /// 外的活跃消息直接标记折叠(`is_compacted=1`),写入一条简短系统注记行。
  /// 用于硬挡预算检测中摘要重试仍失败的场景:保证装不下的历史不会在后续每轮
  /// 反复挤占窗口(原文仍在库中可回溯,只是不再进上下文)。
  /// 合并式不变量同样成立:既有摘要文本随注记行一并承接(机械折叠时 LLM 不可用,
  /// 剧情摘要绝不能丢),旧摘要行与原文同事务折叠。
  /// 返回是否发生了折叠。
  Future<bool> foldToFit({required int sessionId, required int keep}) async {
    final plan = await _plan(sessionId, keep: keep, minChunk: 1);
    if (plan == null) return false;
    const baseNote =
        '【系统注记】上下文超出模型预算且自动摘要暂不可用,以下早期对话已被折叠为占位记录(未生成摘要,原文保留于会话存档)。';
    final prior = plan.prevSummaries.map((m) => m.content).join('\n\n');
    final note = prior.isEmpty
        ? baseNote
        : '$baseNote\n\n此前摘要仍然有效,一并承接:\n$prior';
    await _apply(sessionId: sessionId, content: note, plan: plan);
    return true;
  }

  /// 一次读取同时定出「待压缩集合」与「既有未折叠摘要行」,供摘要调用与
  /// 原子落库共用(避免两次读之间被写入穿插)。无可压时返回 null。
  Future<_CompactPlan?> _plan(int sessionId, {required int keep, required int minChunk}) async {
    final all = await messages.bySession(sessionId);
    // 未折叠 system 行 = 现行版本摘要(可能含机械折叠的注记行);
    // 新摘要落库时它们一并折叠,线上摘要段始终只有一条。
    final prevSummaries = all.where((m) => m.role == 'system' && !m.isCompacted).toList();
    final active = all.where((m) => m.role != 'system' && !m.isCompacted && m.content.isNotEmpty).toList();
    final chatRows = active.where((m) => m.isChat).toList();
    if (chatRows.length <= keep) return null;
    final overflow = chatRows.length - keep;
    if (overflow < minChunk) return null;
    final cutSeq = chatRows[chatRows.length - keep].seq;
    final toCompact = active.where((m) => m.seq < cutSeq).toList();
    if (toCompact.isEmpty) return null;
    return (toCompact: toCompact, prevSummaries: prevSummaries);
  }

  Future<void> _apply({
    required int sessionId,
    required String content,
    required _CompactPlan plan,
  }) async {
    // Summary insert + originals marked compacted happen in ONE transaction so
    // a failure cannot leave an orphan summary (or unmarked originals).
    // 既有摘要行与原文同事务折叠(compact_of 指向新摘要行)—— 合并式单一摘要
    // 的不变量:落库成功后,会话里未折叠的 system 行恰好只有这一条新摘要。
    await messages.insertSystemAndCompact(
      sessionId: sessionId,
      content: content,
      compactIds: [
        ...plan.toCompact.map((m) => m.id!),
        ...plan.prevSummaries.map((m) => m.id!),
      ],
    );
  }

  Future<String?> _summarize(
    String model,
    List<Message> msgs,
    List<Message> prevSummaries,
    void Function(TokenUsage usage)? onUsage,
    Set<String> stripSkillNames, {
    Future<void>? cancelSignal,
  }) async {
    // 摘要转录只送真实对话:附件行是 <system-reminder> 注入资料,不是剧情,
    // 混进摘要输入只会污染摘要输出(被压缩条目里的设定本就源于世界书/技能库)。
    // 对话行先剥离 @技能名 记号(记号不进任何 LLM 出口)。
    final transcript = msgs
        .where((m) => m.isChat)
        .map((m) => '${m.role}: ${ContextAssembler.withoutSkillTokens(m.content, stripSkillNames)}')
        .join('\n');
    // 既有摘要作「早期背景」前置:提示词的合并纪律要求模型把它吸收进新摘要
    // (冲突处以更新的对话为准),配合 _apply 折叠旧行实现单一自足最新摘要。
    final prior = prevSummaries.map((m) => m.content).join('\n\n');
    final userContent = prior.isEmpty
        ? transcript
        : '【既有摘要 —— 仅作早期背景,与下方对话冲突处以对话为准】\n$prior\n\n【待摘要对话】\n$transcript';
    final request = LlmRequest(
      model: model,
      systemPrompt: _summarySystemPrompt,
      messages: [ChatMessage(ChatRole.user, userContent)],
    );
    final buffer = StringBuffer();
    var inTok = 0, outTok = 0, cachedTok = 0;
    var sawError = false;
    var interrupted = false;
    // 流结束/出错/中断三路都汇聚到 finished,主流程只 await 它 —— 与
    // chat_controller 主写同款结构;中断时取消订阅断开底层连接。
    final finished = Completer<void>();
    late final StreamSubscription<LlmEvent> sub;
    sub = backend.generate(request).listen(
      (event) {
        switch (event) {
          case TextDelta(:final text):
            buffer.write(text);
          case UsageEvent(:final usage):
            inTok += usage.inputTokens;
            outTok += usage.outputTokens;
            cachedTok += usage.cachedInputTokens;
          case DoneEvent():
            break;
          case ErrorEvent():
            sawError = true;
        }
      },
      onError: (Object _) {
        sawError = true;
        if (!finished.isCompleted) finished.complete();
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
      cancelOnError: true,
    );
    if (cancelSignal != null) {
      unawaited(cancelSignal.then((_) {
        interrupted = true;
        if (!finished.isCompleted) finished.complete();
      }));
    }
    await finished.future;
    // 善后取消:中断时断链;自然完成后的补位取消无害(订阅已结束)。
    unawaited(sub.cancel());
    if (interrupted) throw const _CompactInterrupted();
    if (sawError) return null;
    if (onUsage != null && (inTok > 0 || outTok > 0 || cachedTok > 0)) {
      onUsage(TokenUsage(inputTokens: inTok, outputTokens: outTok, cachedInputTokens: cachedTok));
    }
    final raw = buffer.toString().trim();
    if (raw.isEmpty) return null;
    final summary = formatCompactSummary(raw);
    return summary.isEmpty ? null : summary;
  }
}

/// 压缩摘要的结构化提示词 —— 为「本应用的主写模型据此续写同一角色、同一剧情」
/// 这一读取场景专门设计(合并式单一摘要,2026-09 批):
/// - 【定位】摘要是"剧情状态文档"而非"对话日志" —— 按故事时间线记录事件、
///   人物现场状态,不复述谁说了什么;
/// - 【七分段】主线/现场/角色关系/信息边界/既定设定/伏笔承诺/叙事风格,逐段
///   对齐 RP 续写的实际需求:「当前现场」是续写衔接点,「信息边界」防角色说出
///   其不应知道的信息(RP 独有的穿帮来源),「既定设定」保住不可违背的事实;
/// - 【指令保真】用户指令性原话引号逐字保留,防止续写意图漂移;
/// - 【两段式】先 `<analysis>` 草稿自查、再 `<summary>` 正式摘要,草稿落库前
///   由 [formatCompactSummary] 剥离,只存干净正文;
/// - 【合并纪律】输入可能带「既有摘要」背景块,新摘要必须自足、可完全替代
///   旧摘要,并抑制无界增长(摘要注入后续每一轮请求、长期占用预算)。
const String _summarySystemPrompt = '''
你是会话摘要助手。请把下面提供的角色扮演对话片段浓缩为一份结构化中文摘要。这份摘要之后会与角色卡一同注入后续每一轮请求,供模型站在"续写者"视角无缝接写同一角色、同一剧情 —— 因此请记录"剧情状态",不要记"对话流水账"。

先输出一段 <analysis> 草稿:按故事时间线梳理关键事件与因果、盘点登场角色、自查现场与伏笔有无遗漏;然后以 <summary> 标签包裹输出正式摘要。正式摘要必须包含以下分段:

1. 剧情主线:按因果顺序的关键事件链(谁做了什么、导致了什么);已完结且对后续无影响的次要事件一笔带过
2. 当前现场:故事此刻停在何处 —— 时间、地点、在场人物、正在进行的事件或未完成的对话;续写将从这里直接衔接
3. 角色与关系:每个在场角色的当前处境、目标与动机、性格与言行的演变、角色之间的关系走向
4. 信息边界:哪些角色已经知道哪些关键信息、哪些角色尚不知情 —— 续写中角色不得利用其不应知道的信息
5. 既定设定与事实:对话中确立的世界观、地名、物品、规则与时间线等必须精确保留的事实;用户的指令性原话用引号逐字保留,避免续写时意图漂移
6. 未解决的伏笔与承诺:尚未兑现的伏笔、待续的剧情方向,以及用户明确要求继续的内容
7. 语气与风格:当前对话的人称与时态、句式节奏、称呼与用词习惯,便于续写保持一致

纪律:
- 摘要会注入后续每一轮请求、长期占用上下文:只保留续写必需的信息,表达精炼,不无界增长。
- 只归纳对话中真实发生的内容,不虚构、不脑补、不替剧情做决定。
- 若输入附带「既有摘要」,将其作为早期背景吸收进新摘要;与更新的对话冲突处,一律以对话为准。新摘要必须自足,可完全替代旧摘要。
- 只输出 <analysis> 与 <summary> 两部分,<summary> 内不要重复 <analysis> 的内容。
''';

/// 剥离 `<analysis>` 草稿与 XML 标签,返回可供落库的纯文本摘要。
/// 若模型未按标签输出(宽松回退),则原样返回去掉首尾空白的内容。
String formatCompactSummary(String summary) {
  var s = summary.trim();

  // 剥掉 <analysis> 草稿区(它只是提升质量的 scratchpad,无落库价值)。
  s = s.replaceAll(RegExp(r'<analysis>[\s\S]*?<\/analysis>'), '');

  // 若存在 <summary> 标签,取出其中内容作为正式摘要,去掉标签外壳。
  final summaryMatch = RegExp(r'<summary>([\s\S]*?)<\/summary>').firstMatch(s);
  if (summaryMatch != null) {
    s = summaryMatch.group(1)!.trim();
  }

  // 清理段间多余空行,保留单空行分段。
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}
