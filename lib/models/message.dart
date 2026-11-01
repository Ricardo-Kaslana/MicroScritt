/// 消息行模型:真实对话、附件合成行与图片元数据。
///
/// 每条消息在 `messages` 表中独立一行、只追加;附件行与对话行通过
/// [MessageKind] 区分,所有面向聊天流/摘要/后台的读取都必须按
/// `kind == chat` 过滤。
library;

/// 消息行的种类。
///
/// - [chat]:真实对话消息(user/assistant),聊天流渲染、参与摘要转录;
/// - [attachment]:attachments 机制的附件合成行:世界书触发条目、@技能等
///   内容以 `<system-reminder>` 包裹后落库,组装时按 seq 自然排在它所属的
///   用户消息**之前**(落库顺序:附件先于用户消息)。附件行是 append-only
///   的 —— 一经写入字节冻结,跨轮命中提示缓存;聊天流与摘要转录都不包含
///   它(`kind != chat` 处处过滤)。
enum MessageKind {
  chat,
  attachment;

  static MessageKind fromWire(String s) =>
      MessageKind.values.where((k) => k.name == s).firstOrNull ?? MessageKind.chat;

  String get wire => name;
}

/// 附件行的结构化标识([Message.refId]),用于去重记账:同一来源的附件
/// 已在当前上下文窗口内时不再重复注入。
extension type const AttachmentRef(String value) {
  /// 世界书触发条目:`wb:<worldbook_entries.id>`。
  static AttachmentRef worldbook(int entryId) => AttachmentRef('wb:$entryId');

  /// @技能附件:`skill:<skills.id>`。
  static AttachmentRef skill(int skillId) => AttachmentRef('skill:$skillId');

  /// 压缩通知(落库,替代原「发出即消失」的合成行):
  /// `notice:compact:<发生时刻毫秒>`。每次压缩事件唯一,不参与窗口去重
  /// (一次性事件,置位标志是唯一权威)。
  static AttachmentRef noticeCompact(int stampMs) => AttachmentRef('notice:compact:$stampMs');

  /// 记忆修改差异通知:`notice:memdiff:<新版本内容哈希>`。
  static AttachmentRef noticeMemoryDiff(int hash) => AttachmentRef('notice:memdiff:$hash');

  /// 是否通知类附件(压缩/记忆差异):组装期需做位置校正(可能落在所属
  /// 用户消息之后),面板标签也单列。
  static bool isNotice(String? ref) => ref != null && ref.startsWith('notice:');
}

/// 一条消息(不可变);空 [id] 表示尚未落库。
class Message {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 所属会话 id。
  final int sessionId;

  /// 消息角色:`user` / `assistant` / `system`。
  final String role;

  /// 消息正文(纯文本;图片不进入此字段)。
  final String content;

  /// 会话内单调递增序号,决定组装与显示顺序。
  final int seq;

  /// 是否为已被压缩折叠的历史消息。
  final bool isCompacted;

  /// 压缩摘要指向的原始消息 id(仅摘要行使用)。
  final int? compactOf;

  /// 内嵌图片(base64);大图不在列表查询中加载,由 [hasImage] 标记。
  final String? imageBase64;

  /// 远程图片 URL;仅用于短暂渲染,最终仍会本地化落库。
  final String? imageUrl;

  /// 生成该图时使用的原始描述(用户触发的重新生成按它重绘;导入/手工图片为 null)。
  final String? imagePrompt;

  /// 库里有图但字节未随列表加载(轻量查询)——渲染层按 id 惰性读取。
  final bool hasImage;

  /// 行种类:真实对话([MessageKind.chat])或附件合成行([MessageKind.attachment])。
  final MessageKind kind;

  /// 附件行的来源标识(如 `wb:12` / `skill:3`);仅 [MessageKind.attachment]
  /// 行使用,普通对话行为 null。
  final String? refId;

  const Message({
    this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.seq,
    this.isCompacted = false,
    this.compactOf,
    this.imageBase64,
    this.imageUrl,
    this.imagePrompt,
    this.hasImage = false,
    this.kind = MessageKind.chat,
    this.refId,
  });

  /// 是否真实对话行(非附件、非 system 摘要)。聊天流渲染、活跃对话统计、
  /// 摘要转录、后台 agent 转录统一用这个口径过滤。
  bool get isChat => kind == MessageKind.chat;

  /// 是否有关联图片可展示/可重生成:本地字节、惰性标记或远程 URL 任一即可。
  bool get hasVisualImage =>
      hasImage || (imageBase64 != null && imageBase64!.isNotEmpty) ||
      (imageUrl != null && imageUrl!.isNotEmpty);

  Message copyWith({
    int? id,
    int? sessionId,
    String? role,
    String? content,
    int? seq,
    bool? isCompacted,
    int? compactOf,
    String? imageBase64,
    String? imageUrl,
    String? imagePrompt,
  }) => Message(
    id: id ?? this.id,
    sessionId: sessionId ?? this.sessionId,
    role: role ?? this.role,
    content: content ?? this.content,
    seq: seq ?? this.seq,
    isCompacted: isCompacted ?? this.isCompacted,
    compactOf: compactOf ?? this.compactOf,
    imageBase64: imageBase64 ?? this.imageBase64,
    imageUrl: imageUrl ?? this.imageUrl,
    imagePrompt: imagePrompt ?? this.imagePrompt,
    hasImage: hasImage || imageBase64 != null,
    kind: kind,
    refId: refId,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'session_id': sessionId,
    'role': role,
    'content': content,
    'seq': seq,
    'is_compacted': isCompacted ? 1 : 0,
    'compact_of': compactOf,
    if (imageBase64 != null) 'image_base64': imageBase64,
    if (imageUrl != null) 'image_url': imageUrl,
    if (imagePrompt != null) 'image_prompt': imagePrompt,
    'kind': kind.wire,
    'ref_id': refId,
  };

  factory Message.fromMap(Map<String, Object?> m) => Message(
    id: m['id'] as int?,
    sessionId: m['session_id'] as int,
    role: m['role'] as String,
    content: m['content'] as String,
    seq: m['seq'] as int,
    isCompacted: (m['is_compacted'] as int? ?? 0) != 0,
    compactOf: m['compact_of'] as int?,
    imageBase64: m['image_base64'] as String?,
    imageUrl: m['image_url'] as String?,
    imagePrompt: m['image_prompt'] as String?,
    // 与 SQL 口径一致:image_base64 非空**串**才算有图(空串可能是历史
    // 写入/导入残留),否则空串行走一次取图(取回空)的空调用。
    hasImage: (m['image_base64'] != null && (m['image_base64'] as String).isNotEmpty) ||
        (m['has_image'] as int? ?? 0) != 0,
    kind: MessageKind.fromWire(m['kind'] as String? ?? 'chat'),
    refId: m['ref_id'] as String?,
  );
}
