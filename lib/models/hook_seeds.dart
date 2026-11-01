import 'hook.dart';

/// 内置默认 Hook 种子(本项目原创):挂在 beforeContextAssembly 的用户输入
/// 改写钩子。改写后的文本才落库与进上下文(spec §12 数据流),用户在气泡里
/// 看到的就是发给模型的最终输入。
///
/// - 主导模式(main):输入以 `main` 开头(如 `main 我推门走进酒馆`)→ 剥掉
///   标志,附上「详细描写/篇幅加长/可适度替主角做决定/剧情要有推进」的本回合
///   指令。
/// - 时间快进(jump):输入以 `jump` 开头(如 `jump 三小时后`)→ 剥掉标志,
///   附上「时间快进一段(几分钟/几小时/一天/几天)、过渡自然」的本回合指令。
///
/// **@记号与标志同用**(v40):行首可带任意个 `@技能名` 记号(每个 = @ +
/// 一段非空白 + 空白,如「@剑术 main 我拔剑了」)—— 匹配时跳过、改写输出
/// 中原样保留(@按钮插入位置在标志前不再使 hook 失效;记号在组装请求的出口
/// 统一剥离,气泡里保持可见)。含空白的技能名不支持此前缀形式(记号按非空白
/// 切分);正文里的英文单词不会误触发。
///
/// 指令块用 `<tag>说明行\n正文</tag>` 标签包裹:开标签后首行是说明行,用户
/// 气泡据此把改写内容**折叠渲染**(默认收起为一枚 chip,点击展开)。标签避开
/// 显示层「时间戳胶囊」脚本的【】/[] 匹配与星号斜体/加粗,正文按普通文本走
/// 渲染管线。JS 只用 ES5 语法与 `[\s\S]` 跨行惯用法(不依赖 `(?s)` 旗标)。
const List<Hook> kDefaultHookSeeds = [
  Hook(
    name: '主导模式(main)',
    triggerPoint: HookTriggerPoint.beforeContextAssembly,
    jsCode: r'''
// 主导模式:输入以 main 开头时,剥掉标志并附上本回合写作要求。
// 行首可带 @技能名 记号(原样保留在输出头部,气泡可见);仅输入 main 本身
// 也视为开启主导模式(指令作为整条消息交给模型)。
var t = String(__ctx.userText == null ? '' : __ctx.userText);
var m = /^(\s*(?:@[^\s]+\s+)*)(?:main(?:\s+([\s\S]*))?)\s*$/i.exec(t);
if (m) {
  var head = m[1].trim();
  var body = (m[2] || '').trim();
  var out = head === '' ? body : (body ? head + ' ' + body : head);
  var note = '\n\n<main_note>主导模式\n本回合请详细描写——细腻呈现场景、动作与人物反应,篇幅加长;可适度替主角做出行动与决定;剧情要有实质推进,不要停在原地。</main_note>';
  __ctx.userText = out !== '' ? out + note : note.trim();
}
''',
  ),
  Hook(
    name: '时间快进(jump)',
    triggerPoint: HookTriggerPoint.beforeContextAssembly,
    jsCode: r'''
// 时间快进:输入以 jump 开头时,剥掉标志并附上时间推进指令。
// 正文(若有)通常写推进幅度,如「jump 三小时后」;不写则由模型依剧情
// 自行把握幅度(几分钟/几小时/一天/几天)。行首可带 @技能名 记号(原样
// 保留在输出头部),如「@剑术 jump 三小时后」。
var t = String(__ctx.userText == null ? '' : __ctx.userText);
var m = /^(\s*(?:@[^\s]+\s+)*)(?:jump(?:\s+([\s\S]*))?)\s*$/i.exec(t);
if (m) {
  var head = m[1].trim();
  var body = (m[2] || '').trim();
  var out = head === '' ? body : (body ? head + ' ' + body : head);
  var note = '\n\n<jump_note>时间快进\n请把故事时间自然推进一段——幅度依输入与剧情而定(几分钟、几小时、一天或几天均可),用简洁的过渡交代推进期间发生的变化,再从推进后的时间点继续详细描写。</jump_note>';
  __ctx.userText = out !== '' ? out + note : note.trim();
}
''',
  ),
];
