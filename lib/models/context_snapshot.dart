import 'chat_message.dart';

/// 上下文组成里的一条细分条目。用于把一段上下文拆成可逐条查看的子项,
/// 如世界书的单条命中条目、会话历史的单条消息。
class ContextSubEntry {
  final String label;
  final String content;

  const ContextSubEntry(this.label, this.content);
}

/// 上下文的一个组成段落,保存组装时的真实顺序与内容。
///
/// [content] 是该段的**原文**(未加标签包裹)。线上发送时各段由组装器以
/// `<标签>说明行\n原文</标签>` 包裹;面板保持展示原文,可读性更好。
/// [subEntries] 提供把这整段再按条目拆开的粒度(世界书的每条命中 /
/// 会话历史的每条消息),为空时按纯文本展示。
class ContextSegment {
  final String key;
  final String label;
  final String content;
  final List<ContextSubEntry> subEntries;

  const ContextSegment({required this.key, required this.label, required this.content, this.subEntries = const []});

  /// 是否有可逐条展开的子项。
  bool get hasSubEntries => subEntries.isNotEmpty;
}

class ContextSnapshot {
  final String systemPrompt;
  final List<ChatMessage> messages;
  final Map<String, String> segmentSources;
  final List<ContextSegment> segments;

  /// 缓存优化:system 提示词的稳定前缀(preset + rules + character +
  /// post-history + 常驻世界书)。CW 批起技能不再进 system(改为 @ 触发附件),
  /// 触发世界书/记忆全部移出 system(分别改为附件行与第 0 条消息)——
  /// system 只剩几乎不随轮次变化的稳定段。Anthropic 后端据此在 system 字段内
  /// 放置 cache_control 断点,使稳定前缀跨轮命中缓存。
  final String stableSystemPrompt;

  /// 会话记忆的"第 0 条消息"形态(CW 批):生效中的记忆冻结副本以
  /// `<system-reminder>` 包裹,作为 messages 数组**首条**合成 user 消息发出,
  /// 排在压缩摘要与全部真实历史之前(对齐 Claude Code 项目记忆的常驻位置)。
  ///
  /// 冻结语义:会话进行中即使记忆被修改,这里也保持字节不变(改动的差异经
  /// 落库的记忆差异通知附件行送达);只在压缩触发后或用户主动刷新时更新
  /// —— 保证第 0 条消息跨轮字节稳定,不破坏其后全部历史的缓存命中。
  /// null/空表示无记忆(不产生首条消息)。
  final String? leadingMemoryContent;

  /// 压缩摘要在消息数组里的前置形态:全部 system 摘要行拼接后包上
  /// `<summary>` 标签块,作为 messages 数组首条(记忆之后)的合成 user 消息
  /// 发出。null 表示无摘要。
  final String? leadingSummaryContent;

  /// 缓存优化:稳定 system 前缀([stableSystemPrompt])的内容哈希。
  ///
  /// 用于在上下文面板直观判断"两轮之间稳定前缀是否变化":同一会话里,只要
  /// preset/rules/角色卡/剧情后注/常驻世界书没变,该哈希就不变 —— 说明本轮请求
  /// 在 LLM 提示缓存的重用区(stableSystemPrompt + 历史前段)字节一致、可命中。
  /// 只做会话内"变没变"的对照,不做跨进程持久语义(用 Dart 字符串 hashCode
  /// 即可,同内容同运行期内稳定)。
  final int stableSystemHash;

  const ContextSnapshot({
    required this.systemPrompt,
    required this.messages,
    this.segmentSources = const {},
    this.segments = const [],
    this.stableSystemPrompt = '',
    this.leadingMemoryContent,
    this.leadingSummaryContent,
    this.stableSystemHash = 0,
  });
}
