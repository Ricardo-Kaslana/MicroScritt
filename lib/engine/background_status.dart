/// 后台agent 在一轮对话后的运行状态。
///
/// 后台agent = 主回复落库后由 Orchestrator 驱动的 BackgroundEngine(状态维护),
/// 独立记账 token(spec §6)。UI 依据此状态展示运行中/成功/跳过/失败/已禁用。
enum BackgroundStatus {
  /// 本会话尚未触发过后台维护(还没发过消息 / 刚打开)。
  idle,

  /// 后台agent 正在运行(主回复已出,正在维护 skills/变量/memory/面板/生图)。
  running,

  /// 本轮后台维护成功完成(有有效结果并应用)。
  succeeded,

  /// 主回复为空(无产出)→ 后台维护被跳过。
  skipped,

  /// 后台调用出错或返回解析失败,按 best-effort 跳过。
  failed,

  /// 后台agent 被用户中断(本轮运行被丢弃)。
  interrupted,

  /// 后台agent 被用户全局关闭,本轮不运行。
  disabled,
}

BackgroundStatus backgroundStatusFromName(String? name) =>
    BackgroundStatus.values.where((s) => s.name == name).firstOrNull ??
    BackgroundStatus.idle;

/// 每个状态的中文标签(UI 展示)。
String backgroundStatusLabel(BackgroundStatus s) => switch (s) {
  BackgroundStatus.idle => '待机',
  BackgroundStatus.running => '运行中',
  BackgroundStatus.succeeded => '已完成',
  BackgroundStatus.skipped => '已跳过',
  BackgroundStatus.failed => '失败',
  BackgroundStatus.interrupted => '已中断',
  BackgroundStatus.disabled => '已禁用',
};
