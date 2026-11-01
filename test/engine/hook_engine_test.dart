// Hook 执行引擎测试:触发点过滤、串行改写、畸形输出容错与 __ 内部键剥离。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/models/hook.dart';

class _FakeRuntime implements HookRuntime {
  String? result;
  @override
  Future<String?> evaluate(String js) async => result;
}

class _RecordingRuntime implements HookRuntime {
  final List<String> scripts = [];
  @override
  Future<String?> evaluate(String js) async {
    scripts.add(js);
    return '{"ok": true}';
  }
}

void main() {
  test('runs only enabled hooks for the given trigger point', () async {
    final runtime = _FakeRuntime()..result = '{"changed":true}';
    final engine = HookEngine(runtime);

    final ctx = await engine.run(
      point: HookTriggerPoint.beforeGenerate,
      hooks: const [
        Hook(name: 'a', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '1'),
        Hook(name: 'b', triggerPoint: HookTriggerPoint.afterStream, jsCode: '2'),
        Hook(name: 'c', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '3', enabled: false),
      ],
      context: const {'changed': false},
    );

    expect(ctx['changed'], isTrue);
  });

  test('returns the original context when no hooks match', () async {
    final runtime = _FakeRuntime();
    final engine = HookEngine(runtime);
    final ctx = await engine.run(
      point: HookTriggerPoint.afterStream,
      hooks: const [Hook(name: 'a', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '1')],
      context: const {'keep': 'me'},
    );
    expect(ctx, {'keep': 'me'});
  });

  test('ignores malformed hook output', () async {
    final runtime = _FakeRuntime()..result = 'not json';
    final engine = HookEngine(runtime);
    final ctx = await engine.run(
      point: HookTriggerPoint.beforeGenerate,
      hooks: const [Hook(name: 'a', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '1')],
      context: const {'x': 1},
    );
    expect(ctx, {'x': 1});
  });

  test('only evaluates enabled hooks for the matching trigger point', () async {
    final runtime = _RecordingRuntime();
    final engine = HookEngine(runtime);
    await engine.run(
      point: HookTriggerPoint.beforeGenerate,
      hooks: const [
        Hook(name: 'a', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '1'),
        Hook(name: 'b', triggerPoint: HookTriggerPoint.afterStream, jsCode: '2'),
        Hook(name: 'c', triggerPoint: HookTriggerPoint.beforeGenerate, jsCode: '3', enabled: false),
      ],
      context: const {},
    );
    expect(runtime.scripts.length, 1);
    expect(runtime.scripts.single.contains('1'), isTrue); // 只有 hook 'a' 被求值
  });

  test('strips __-prefixed internal markers from the returned context', () async {
    final runtime = _FakeRuntime()..result = '{"text":"rewritten","__hookError":"boom"}';
    final engine = HookEngine(runtime);
    final ctx = await engine.run(
      point: HookTriggerPoint.afterStream,
      hooks: const [Hook(name: 'a', triggerPoint: HookTriggerPoint.afterStream, jsCode: '1')],
      context: const {'text': 'original'},
    );
    expect(ctx['text'], 'rewritten');
    expect(ctx.containsKey('__hookError'), isFalse);
  });
}
