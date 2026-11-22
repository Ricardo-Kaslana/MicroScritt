/// 上下文窗口预算策略:自动压缩的三个挡位、token 估算与保留条数规划。
///
/// 占用率 = 请求输入估算 / 模型上下文容量;容量未配置时由
/// [ContextBudgetPolicy.fallbackCapacity] 兜底。字符到 token 统一走
/// `estimateTokensFromChars`,与上下文圆环同一把尺子。
library;

import '../models/app_settings.dart';
import '../models/chat_message.dart';
import '../models/llm_units.dart';
import '../models/message.dart';

/// 上下文窗口预算策略 —— 自动压缩(auto compact)的三个挡位。
///
/// 触发依据是**上下文窗口占用量**(输入估算 / 容量),不再按掉出窗口的
/// 消息条数计算;三挡协作:
///
/// - **目标挡 target 20%**:每次压缩把活跃历史(消息部分)压回 ≈20% 占用,
///   压缩后到下一次触发之间有自然滞回,不会轮轮压缩;
/// - **软挡 soft(默认 60%,用户可配 30%–90%)**:回复落库后估算占用 ≥ 该值
///   → 主动执行一次 LLM 摘要压缩(事后路径,best-effort);
/// - **硬挡 hard = max(80%, 软挡 + 5%)**:API 发送前预算检测 —— 估算输入 +
///   输出预留超过容量×硬挡时必须先压缩再发送;摘要重试仍失败则机械截断
///   窗口兜底,保证请求一定发得出去。
abstract final class ContextBudgetPolicy {
  /// 目标挡:压缩后活跃历史的目标占用(≈20%)。
  static const double target = 0.20;

  /// 默认软挡:回复落库后达到该占用即触发一次自动压缩。
  /// 实际触发线由 `AppSettings.autoCompactThreshold` 决定(可调)。
  static const double soft = AppSettings.defaultAutoCompactThreshold;

  /// 硬挡:API 发送前预算检测的强制线(不低于软挡 + [hardGap])。
  static const double hard = 0.80;

  /// 硬挡相对软挡的最小缓冲:用户把触发线调到 80% 以上时,强制线顺延,
  /// 保证发送前检测始终晚于事后压缩。
  static const double hardGap = 0.05;

  /// 给定软挡触发线时的实际硬挡:max(80%, 触发线 + 5%)。
  ///
  /// 结果按百分比精度取整,避免 0.90 + 0.05 的浮点尾差让边界判定失真
  /// (0.95 会小于 0.9500000000000001)。
  static double hardFor(double soft) {
    final s = soft.clamp(
      AppSettings.minAutoCompactThreshold,
      AppSettings.maxAutoCompactThreshold,
    );
    final shifted = ((s + hardGap) * 100).round() / 100;
    return shifted > hard ? shifted : hard;
  }

  /// 输出预留默认值:配置未设 maxTokens 时按此为回复预留输出空间。
  static const int defaultOutputReserveTokens = 2048;

  /// 摘要预留:新写入的压缩摘要行(渲染为 messages 数组首条的合成摘要消息)
  /// 的 token 估算上限。规划保留消息数时先扣掉它,避免摘要本身把预算吃穿。
  static const int summaryReserveTokens = 512;

  /// 机械截断/压缩规划至少保留的最新活跃消息条数(一问一答)。
  static const int minKeepMessages = 2;

  /// 模型容量未知时的兜底估算:容量未配置或 ≤0 时占用率三挡改用它作分母。
  ///
  /// 为什么必须有:占用率三挡都以容量作分母,直接跳过就等于**完全没有保护**
  /// —— 组装不再按条数裁剪,长会话会一路涨到上游报错。用户漏填容量是常见
  /// 配置,兜底保证自动压缩仍然生效。
  ///
  /// 取值刻意保守:容量填偏大只是失去保护,填偏小只是让压缩来得早一些 ——
  /// 而压缩有摘要承接,信息不会丢。用户仍应在 provider 配置里填真实容量。
  static const int fallbackCapacity = 16384;
}

/// 上下文占用量所处的挡位。
enum ContextBudgetLevel {
  /// 预算内(低于软挡):无需任何动作。
  ok,

  /// 达到软挡:适合在回复落库后主动压缩一次。
  soft,

  /// 达到硬挡:发送前必须先腾出空间。
  hard,
}

/// 占用率 → 挡位。≥[hard] 为 [ContextBudgetLevel.hard],≥[soft] 为
/// [ContextBudgetLevel.soft],否则 [ContextBudgetLevel.ok]。
///
/// [soft]/[hard] 允许调用方传入用户配置的触发线与派生硬挡;不传时用默认策略
/// (60% / 80%),与历史行为一致。
ContextBudgetLevel budgetLevelFor(
  double occupancy, {
  double soft = ContextBudgetPolicy.soft,
  double hard = ContextBudgetPolicy.hard,
}) {
  if (occupancy >= hard) return ContextBudgetLevel.hard;
  if (occupancy >= soft) return ContextBudgetLevel.soft;
  return ContextBudgetLevel.ok;
}

/// 估算一次请求的输入 token:system 提示词 + messages 数组(含首条记忆/
/// 摘要合成消息与附件行,若有)—— 全部同属真实输入。
/// 字符→token 用 [estimateTokensFromChars](与上下文圆环同一把尺子)。
int estimateRequestTokens({
  required String systemPrompt,
  required List<ChatMessage> messages,
}) {
  var chars = systemPrompt.length;
  for (final m in messages) {
    chars += m.content.length;
  }
  return estimateTokensFromChars(chars);
}

/// 从最新往前规划"保留条数":把 [active](旧→新)里能装进 [budgetTokens]
/// 预算的最新消息留下,其余(更老的)交给调用方压缩/折叠。
///
/// 至少保留 [minKeep] 条 —— 即便单条就超预算也要保住最新的一问一答,
/// 否则请求连最后一条都发不出。返回值 ∈ [minKeep.clamp(0, len), active.length]。
int planKeepWithinBudget({
  required List<Message> active,
  required int budgetTokens,
  int minKeep = ContextBudgetPolicy.minKeepMessages,
}) {
  if (active.isEmpty) return 0;
  var kept = 0;
  var used = 0;
  for (var i = active.length - 1; i >= 0; i--) {
    final cost = estimateTokensFromChars(active[i].content.length);
    // 前 minKeep 条无条件保留;之后放不下即停(更老的不再保留)。
    if (kept >= minKeep && used + cost > budgetTokens) break;
    used += cost;
    kept++;
  }
  return kept;
}

/// 首个保留对话行之前的前导附件行(世界书/技能/通知):位于上一对话行与
/// 首个保留行之间。附件必须与所属用户消息同窗,预算规划与压缩切割必须
/// 使用同一组边界,否则一方计入了、另一方却把它折掉。
Iterable<Message> leadingAttachmentsBefore({
  required List<Message> active,
  required List<Message> chat,
  required int cutIndex,
}) sync* {
  if (cutIndex <= 0 || cutIndex >= chat.length) return;
  final prevSeq = chat[cutIndex - 1].seq;
  final firstKeptSeq = chat[cutIndex].seq;
  for (final m in active) {
    if (!m.isChat && m.seq > prevSeq && m.seq < firstKeptSeq) yield m;
  }
}

/// 与 [planKeepWithinBudget] 相同的保留条数规划,但把"首个保留对话行"的
/// 前导附件行(世界书/技能/通知)计入预算:附件必须与所属用户消息同窗,
/// 只按对话行估算会让压缩后占用超过目标挡,并在切割点拆散这一对。
int planKeepWithinBudgetWithAttachments({
  required List<Message> active,
  required int budgetTokens,
  int minKeep = ContextBudgetPolicy.minKeepMessages,
}) {
  final chat = active.where((m) => m.isChat).toList();
  if (chat.isEmpty) return 0;
  var keep = planKeepWithinBudget(
    active: chat,
    budgetTokens: budgetTokens,
    minKeep: minKeep,
  );
  // 每降一档保留数,都要把新暴露的前导附件组计入预算,直至稳定。
  for (var iter = 0; iter < chat.length; iter++) {
    final cutIndex = chat.length - keep;
    if (cutIndex <= 0) break;
    var groupChars = 0;
    for (final m in leadingAttachmentsBefore(
      active: active,
      chat: chat,
      cutIndex: cutIndex,
    )) {
      groupChars += m.content.length;
    }
    if (groupChars == 0) break;
    final next = planKeepWithinBudget(
      active: chat,
      budgetTokens: budgetTokens - estimateTokensFromChars(groupChars),
      minKeep: minKeep,
    );
    if (next >= keep) break;
    keep = next;
  }
  return keep;
}
