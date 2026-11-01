enum HookTriggerPoint { beforeContextAssembly, afterContextAssembly, beforeGenerate, afterStream, beforePersist }

class Hook {
  final int? id;
  final String name;
  final HookTriggerPoint triggerPoint;
  final String jsCode;
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
