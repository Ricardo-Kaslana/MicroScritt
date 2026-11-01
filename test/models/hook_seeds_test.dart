// 内置 Hook 种子测试:main/jump 触发正则、标志剥离与 QuickJS 端到端改写。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/engine/js_hook_runtime.dart';
import 'package:microscritt/models/hook.dart';
import 'package:microscritt/models/hook_seeds.dart';

/// 两条标志触发 hook(main/jump)的种子名。
const _flagHookNames = {'主导模式(main)', '时间快进(jump)'};

/// 从种子 jsCode 里抽出触发正则字面量(/…/i.exec),用 Dart RegExp 镜像验证
/// 触发语义:Dart 与 QuickJS 同属 ECMAScript 正则方言,`^ $ \s [\s\S] (?:)`
/// 语义一致,足以覆盖这些 ES5 种子的全部语法。
RegExp _triggerPatternOf(Hook hook) {
  final m = RegExp(r'/([^/\n]+)/i\s*\.exec').firstMatch(hook.jsCode);
  expect(m, isNotNull, reason: '${hook.name} 应包含 /…/i.exec 触发正则');
  return RegExp(m!.group(1)!, caseSensitive: false);
}

/// 触发时捕获的正文(剥掉标志与行首 @记号后的部分);null = 组未参与匹配。
String? _bodyOf(RegExp re, String input) =>
    re.firstMatch(input)?.group(2)?.trim();

/// 触发时捕获的行首 @记号头部(改写输出原样保留,气泡可见)。
String? _headOf(RegExp re, String input) =>
    re.firstMatch(input)?.group(1)?.trim();

Future<void> main() async {
  // 组合用例跑真实 QuickJS(ES5 正则语义与生产求值一致);宿主缺动态库时
  // probe 探活失败 → 跳过而不是用空转 runtime 假绿。
  final jsAvailable = await JsHookRuntime.probe() != null;

  test('seeds: two flag hooks, all enabled, unique names', () {
    expect(kDefaultHookSeeds.length, 2);
    for (final s in kDefaultHookSeeds) {
      expect(s.triggerPoint, HookTriggerPoint.beforeContextAssembly);
      expect(s.jsCode, isNotEmpty);
      expect(s.enabled, isTrue);
    }
    expect(
      kDefaultHookSeeds.map((s) => s.name).toSet(),
      _flagHookNames,
    );
    // 名字唯一(_seedDefaultHooks 按 name 幂等依赖此性质)。
    expect(kDefaultHookSeeds.map((s) => s.name).toSet().length, 2);
  });

  test('main hook: prefix marker triggers and captures the body', () {
    final hook = kDefaultHookSeeds.firstWhere((s) => s.name.startsWith('主导模式'));
    final re = _triggerPatternOf(hook);

    expect(_bodyOf(re, 'main 我推门走进酒馆'), '我推门走进酒馆');
    expect(_bodyOf(re, '  Main  压低声音 '), '压低声音'); // 大小写不敏感 + 前后空白
    expect(_bodyOf(re, 'main 第一行\n第二行'), '第一行\n第二行'); // 正文跨行
    expect(re.hasMatch('main'), isTrue); // 仅标志也触发(无正文,指令即整条消息)
    expect(_bodyOf(re, 'main'), isNull);

    expect(re.hasMatch('mainly 走开'), isFalse); // main 须独立成词,不吃 main 字
    expect(re.hasMatch('他说 main 很重要'), isFalse); // 必须是整条输入的前缀
    expect(re.hasMatch('jump 三小时后'), isFalse); // 不吃别的标志
  });

  test('main hook: leading @skill tokens are tolerated and captured', () {
    final hook = kDefaultHookSeeds.firstWhere((s) => s.name.startsWith('主导模式'));
    final re = _triggerPatternOf(hook);

    // @按钮插入在标志之前不再使 hook 失效;记号进组 1、正文进组 2。
    expect(re.hasMatch('@剑术 main 我拔剑了'), isTrue);
    expect(_headOf(re, '@剑术 main 我拔剑了'), '@剑术');
    expect(_bodyOf(re, '@剑术 main 我拔剑了'), '我拔剑了');
    // 多个记号 + 无正文。
    expect(_headOf(re, '@剑术 @盾牌 Main'), '@剑术 @盾牌');
    expect(_bodyOf(re, '@剑术 main'), isNull);
    // 无记号的旧形态完全不变(组 1 空串)。
    expect(_headOf(re, 'main 走'), '');
    expect(_bodyOf(re, 'main 走'), '走');

    // 记号后没有标志 → 不触发;@main 整体是记号、后面无第二个标志 → 不触发;
    // 标志与记号间无空白 → 不触发(记号按非空白切分)。
    expect(re.hasMatch('@剑术 我拔剑了'), isFalse);
    expect(re.hasMatch('@main 走'), isFalse);
    expect(re.hasMatch('@剑术main x'), isFalse);
  });

  test('jump hook: prefix marker triggers and captures the body', () {
    final hook = kDefaultHookSeeds.firstWhere((s) => s.name.startsWith('时间快进'));
    final re = _triggerPatternOf(hook);

    expect(_bodyOf(re, 'jump 三小时后'), '三小时后');
    expect(_bodyOf(re, 'JUMP'), isNull); // 仅标志触发,无正文
    expect(re.hasMatch('JUMP'), isTrue);
    expect(re.hasMatch('main 走开'), isFalse);
    expect(re.hasMatch('jumpstart'), isFalse);
    expect(re.hasMatch('去 jump 一下'), isFalse);

    // @记号前缀同样容忍。
    expect(_headOf(re, '@剑术 jump 三小时后'), '@剑术');
    expect(_bodyOf(re, '@剑术 jump 三小时后'), '三小时后');
  });

  test('jsCode rewrites __ctx.userText from the captured body', () {
    for (final s in kDefaultHookSeeds) {
      // 正文取自捕获组 2(标志被剥掉),行首 @记号(组 1)原样保留在输出头部;
      // 仅标志时指令独立成条。
      expect(s.jsCode, contains("var head = m[1].trim();"));
      expect(s.jsCode, contains("var body = (m[2] || '').trim();"));
      expect(
        s.jsCode,
        contains("__ctx.userText = out !== '' ? out + note : note.trim();"),
      );
    }
  });

  test('instruction block wrapped in a lowercase <tag> with a label line', () {
    final main = kDefaultHookSeeds.firstWhere((s) => s.name.startsWith('主导模式'));
    expect(main.jsCode, contains('<main_note>主导模式\\n'));
    expect(main.jsCode, contains('</main_note>'));

    final jump = kDefaultHookSeeds.firstWhere((s) => s.name.startsWith('时间快进'));
    expect(jump.jsCode, contains('<jump_note>时间快进\\n'));
    expect(jump.jsCode, contains('</jump_note>'));

    for (final s in kDefaultHookSeeds) {
      // 标签内的正文不出现「时间戳胶囊」会吃掉的【】/[] 与触发斜体/加粗的
      // 星号,仍按普通文本走气泡渲染管线(JS 正则里的 * 不在此列)。
      final open = s.jsCode.indexOf('<');
      final close = s.jsCode.indexOf('</', open);
      expect(open, greaterThanOrEqualTo(0), reason: '${s.name} 应有 <tag> 指令块');
      final note = s.jsCode.substring(open, close);
      expect(note.contains(RegExp(r'[【\[\]]')), isFalse);
      expect(note.contains('*'), isFalse);
    }
  });

  test(
    'main hook end-to-end in QuickJS rewrites the user text',
    () async {
      final hooks = kDefaultHookSeeds.map((s) => Hook(
        name: s.name,
        triggerPoint: s.triggerPoint,
        jsCode: s.jsCode,
      )).toList();
      final ctx = await HookEngine(JsHookRuntime()).run(
        point: HookTriggerPoint.beforeContextAssembly,
        hooks: hooks,
        context: const {'userText': 'main 我推门走进酒馆', 'userName': '阿芸'},
      );
      final out = ctx['userText'] as String;
      expect(out, startsWith('我推门走进酒馆'));
      expect(out, contains('<main_note>'));
      expect(out, contains('</main_note>'));
      // jump 标志未输入 → jump hook 不改写、不注入。
      expect(out.contains('jump_note'), isFalse);
    },
    skip: jsAvailable ? false : 'quickjs 动态库不可用(宿主环境缺 DLL)',
  );
}
