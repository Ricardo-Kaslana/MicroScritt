import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/hook.dart';

void main() {
  test('toMap/fromMap round-trips', () {
    const h = Hook(id: 5, name: 'strip', triggerPoint: HookTriggerPoint.afterStream, jsCode: 'return 1;', enabled: false);
    final r = Hook.fromMap(h.toMap());
    expect(r.id, 5);
    expect(r.name, 'strip');
    expect(r.triggerPoint, HookTriggerPoint.afterStream);
    expect(r.jsCode, 'return 1;');
    expect(r.enabled, isFalse);
  });

  test('triggerPointFrom round-trips the wire name', () {
    expect(Hook.triggerPointFrom(HookTriggerPoint.beforeGenerate.name), HookTriggerPoint.beforeGenerate);
  });

  test('enabled defaults to true', () {
    const h = Hook(name: 'n', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '1');
    expect(h.enabled, isTrue);
  });
}
