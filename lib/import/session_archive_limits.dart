/// v5 会话归档的共享大小上限。
///
/// 导入预检与导出核算必须使用同一组数值:导出端若产出超过导入端上限的
/// meta 或消息行,用户会得到一份「导出成功却永远导不回来」的归档。
library;

/// v5 归档(v1–v4 JSON 头部值同样复用 meta 上限)的硬上限。
abstract final class SessionArchiveLimits {
  /// `meta.json` / v4 单个头部值:64MiB。角色卡含大型世界书与头像 base64
  /// 时仍远低于此值;再大说明归档异常或恶意。
  static const int maxMetaBytes = 64 * 1024 * 1024;

  /// `messages.ndjson` 单行(单条消息)上限:32MiB。消息正文是纯文本,
  /// 图片以 hash 引用,不会有正常消息接近这个体积。
  static const int maxMessageLineBytes = 32 * 1024 * 1024;

  /// v5 消息总条数上限:两百万条。超过后导入会长时间写库并膨胀本地库,
  /// 在预检阶段直接拒绝。
  static const int maxMessages = 2000000;
}
