/// Hook 模型(`hooks` 表):触发点 + 同步 JS 代码。
///
/// Hook 由 QuickJS 求值,返回的上下文经 JSON 往返;执行失败不阻断主流程,
/// 错误信息随上下文内部键回传后剥离。
library;

/// Hook 的触发时机;顺序与主写管线一致。
enum HookTriggerPoint {
  /// 上下文组装前;可改写用户输入。
  beforeContextAssembly,

  /// 上下文组装后;可调整最终上下文。
  afterContextAssembly,

  /// 请求发出前。
  beforeGenerate,

  /// 流式响应结束后。
  afterStream,

  /// 消息落库前。
  beforePersist,
}

/// 一条 Hook 配置。
class Hook {
  /// 库内自增 id;null 表示尚未落库。
  final int? id;

  /// 显示名。
  final String name;

  /// 触发点。
  final HookTriggerPoint triggerPoint;

  /// 同步 JS 源码;经沙箱求值,不允许联网。
  final String jsCode;

  /// 是否启用。
  final bool enabled;

  const Hook({
    this.id,
    required this.name,
    required this.triggerPoint,
    required this.jsCode,
    this.enabled = true,
  });

  String get triggerPointWire => triggerPoint.name;

  static HookTriggerPoint triggerPointFrom(String s) =>
      HookTriggerPoint.values.firstWhere((p) => p.name == s);

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'trigger_point': triggerPointWire,
        'js_code': jsCode,
        'enabled': enabled ? 1 : 0,
      };

  factory Hook.fromMap(Map<String, Object?> m) => Hook(
        id: m['id'] as int?,
        name: m['name'] as String,
        triggerPoint: triggerPointFrom(m['trigger_point'] as String),
        jsCode: m['js_code'] as String,
        enabled: (m['enabled'] as int? ?? 1) != 0,
      );
}
