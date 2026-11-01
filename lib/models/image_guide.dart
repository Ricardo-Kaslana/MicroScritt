/// 会话级生图指导(CW 批,schema v38 `image_guides` 表):后台agent 生成
/// 场景描述(imagePrompt/imagePrompts)时遵循的可编辑规范文本。
///
/// 与记忆(`memories` 表)刻意分离:
/// - 记忆是给**主写模型**看的长期事实,以"第 0 条消息"冻结进主写上下文;
/// - 生图指导是给**后台agent** 的生图指令底本,每轮后台维护时携带最新文本
///   (后台请求不做提示缓存,直接读库即可,无冻结语义)。
///
/// 维护方式与记忆对齐:用户手动编辑,或"生成初始指导"(依据角色卡 + 常驻
/// 世界书调用一次 LLM 产出,外貌定妆/风格基调),此后用户按需修改。
class ImageGuide {
  final int? id;
  final int sessionId;
  final String content;
  final int updatedAt;

  const ImageGuide({this.id, required this.sessionId, required this.content, required this.updatedAt});

  Map<String, Object?> toMap() => {'id': id, 'session_id': sessionId, 'content': content, 'updated_at': updatedAt};

  factory ImageGuide.fromMap(Map<String, Object?> m) => ImageGuide(
    id: m['id'] as int?,
    sessionId: m['session_id'] as int,
    content: m['content'] as String,
    updatedAt: m['updated_at'] as int,
  );
}
