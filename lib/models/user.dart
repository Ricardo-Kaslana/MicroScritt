/// 用户档案模型与显示层占位符替换。
///
/// 用户名只参与**显示**:存储与发送给 LLM 的内容始终保持 `{{user}}`
/// 占位符原样,避免改用户名导致历史消息与缓存失效。
library;

/// 用户档案(单行表 `user_profile`,id 恒为 1)。
/// 当前应用是纯客户端单用户,头像用于在用户气泡旁显示。
class UserProfile {
  final int? id;

  /// 用户名(显示名),可能为空(未设置)。
  final String name;

  /// 头像 base64(可能为 data URI 或纯 base64),可能为空(未上传)。
  final String? avatarBase64;

  const UserProfile({this.id, this.name = '', this.avatarBase64});

  UserProfile copyWith({int? id, String? name, String? avatarBase64}) => UserProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    avatarBase64: avatarBase64 ?? this.avatarBase64,
  );
}

/// 把正文中的 `{{user}}` 占位符替换为用户名,仅用于**显示**(不改写落库/上下文)。
/// 未设置用户名(空或 null)时原样返回,保留占位符。
String replaceUserPlaceholder(String text, String? userName) {
  if (userName == null || userName.isEmpty) return text;
  return text.replaceAll('{{user}}', userName);
}

