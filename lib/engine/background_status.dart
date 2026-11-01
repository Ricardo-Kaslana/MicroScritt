/// 后台维护任务在一轮对话后的运行状态(随会话状态展示)。
///
/// 后台维护指主回复落库后由 `Orchestrator` 驱动的 `BackgroundEngine`,
/// 只维护变量与生图;其 token 用量与主写分开记账。UI 依据此状态展示
/// 运行中/成功/跳过/失败/已禁用。
library;

/// 后台维护的运行状态。
enum BackgroundStatus {
  /// 本会话尚未触发过后台维护(还没发过消息 / 刚打开)。
  idle,

  /// 后台维护正在运行(主回复已出,正在维护变量/生图)。
  running,

  /// 本轮后台维护成功完成(有有效结果并应用)。
  succeeded,

  /// 本轮无需维护(无有效回复、无对话或无新增等良性原因)。
  skipped,

  /// 后台调用出错或返回解析失败,按 best-effort 跳过。
  failed,

  /// 后台维护被用户中断(本轮运行被丢弃)。
  interrupted,

  /// 后台维护被用户关闭或未选中任何维护功能,本轮不运行。
  disabled,
}

/// 从持久化名称恢复状态;null/未知名称回落 [BackgroundStatus.idle]。
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
