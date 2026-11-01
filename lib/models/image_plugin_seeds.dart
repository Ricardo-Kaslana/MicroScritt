/// 仓库自带的两个生图协议插件种子。
///
/// 2.3 起取代旧的 Dart 协议实现:内置的对话式网关与 Nai2API 均以 JSON 插件
/// 形式幂等种入 `image_plugins`。JS 为本项目原创、仓库受控、非用户可编辑;
/// 不含任何第三方端点或密钥,服务地址由用户在设置页填写。
///
/// 契约:同步 `step(ctx)` 按 `ctx.operation`(generate/test/listModels)与
/// `ctx.phase`(start/http/sleep)返回 http/sleep/done/error 动作;网络传输失败
/// 以 `ctx.response.error` + `receivedBytes` 回传,由插件自行决定是否重试
/// (宿主绝不自动重试),据此实现防重复计费与轮询竞态语义。
library;

import 'image_plugin.dart';

/// 对话式生图网关(OpenAI 兼容 /chat/completions,SSE 内嵌 Markdown 图片链接)。
const String _chatCode = r'''
// 消毒:先剥引号类字符再折叠空白 —— 顺序不能换,否则 `'` 两侧的空格在剥掉后
// 会并成两个空格(旧后端 _fieldSanitize 同序)。引号集也不得改动:反引号该剥,
// 反斜杠是 NovelAI tag 语法本身(转义),旧后端明确保留。
function sanitize(s){return String(s==null?'':s).trim().replace(/['"`′´’]/g,'').replace(/\s+/g,' ');}
function fieldLines(ctx){var p=ctx.params||{};return [
  '提示词:'+sanitize(ctx.prompt),
  '画师串:'+sanitize(p.artist),
  '尺寸:'+(p.size||'竖图'),
  '提示词引导值:'+(p.scale==null?6:p.scale),
  '缩放引导值:'+(p.cfg==null?0:p.cfg),
  '负面提示词:'+sanitize(ctx.negativePrompt),
  '采样器:'+sanitize(p.sampler)
].join('\n');}
// nai 覆盖对象只在**显式配置**时携带(旧后端逐字段 if!=null);p.negative 是
// 用户原始值(未填为 null),ctx.negativePrompt 是已兜底默认词的那一份 —— 覆盖
// 对象必须用前者,否则未配置负面词也会多出 nai.negative,实测部分网关会对未知
// 覆盖直接 400。
// steps 与 Nai2API 共用同一份标准参数,只能走 nai 覆盖:上面 7 行字段体是严格
// 协议,加行会破坏字段块。
function naiOverride(ctx){var p=ctx.params||{};var o={};
  if(p.size)o.size=p.size;
  if(p.scale!=null)o.scale=p.scale;
  if(p.cfg!=null)o.cfg=p.cfg;
  if(p.steps!=null)o.steps=p.steps;
  if(p.negative!=null)o.negative=sanitize(p.negative);
  if(p.sampler)o.sampler=p.sampler;
  if(p.nocache!=null)o.nocache=p.nocache;
  if(p.noiseSchedule)o.noise_schedule=p.noiseSchedule;
  return o;}
var LINK='!\\[[^\\]]*\\]\\((https?://[^)\\s]+)\\)';
function genRequest(ctx){var s=ctx.settings||{};
  var body={model:(s.model||'nai-diffusion-4-5-full:k_dpmpp_2m_sde'),messages:[{role:'user',content:fieldLines(ctx)}],stream:true};
  var nai=naiOverride(ctx);if(Object.keys(nai).length)body.nai=nai;
  // 排队+生成可达数分钟:该请求要 5 分钟(宿主按剩余预算再裁)。
  // stopWhen:图片链接一到位就断流 —— 实测部分流式实现出图后仍保活连接数十秒
  // 才关,傻等会把「链接早到手」拖成请求超时(旧后端在 SSE 里同序做这件事)。
  // 注意截断发生在**任意字节分片边界**(见 step 里 partial 兜底)。
  return {method:'POST',url:'chat/completions',headers:{Authorization:'Bearer '+(s.apiKey||'')},json:body,timeoutMs:300000,stopWhen:{contains:'](',regex:LINK}};}
function extractLinks(text){var re=new RegExp(LINK,'g');var out=[];var m;
  while((m=re.exec(text||''))!==null){if(out.indexOf(m[1])<0)out.push(m[1]);}return out;}
// SSE 分片会在 URL 中间切断链接,必须先按 OpenAI 事件形状重组 delta.content
// 再整体提取链接;直接在原始 SSE 文本上跑正则会截出半截 URL,下载必失败。
function extractContent(text){var out='';var lines=String(text||'').split('\n');var sawData=false;
  for(var i=0;i<lines.length;i++){var t=lines[i].replace(/\r$/,'').trim();
    if(t.indexOf('data:')!==0)continue;sawData=true;
    var payload=t.slice(5).trim();if(!payload||payload==='[DONE]')continue;
    try{var obj=JSON.parse(payload);var ch=obj.choices&&obj.choices[0];if(!ch)continue;var d=ch.delta||ch.message;if(d&&typeof d.content==='string')out+=d.content;}catch(e){}}
  if(out||sawData)return out;
  try{var o=JSON.parse(text);var c=o.choices&&o.choices[0];var d=c&&(c.message||c.delta);if(d&&typeof d.content==='string')return d.content;}catch(e){}
  return text||'';}
// 服务端拒绝优先回显自己的中文原因;JSON 里没 message 时回落原始正文(旧后端
// _errorMessage 同规则),否则 400 只剩一个状态码,用户无从自查字段格式。
function httpError(r,action){var t=typeof r.text==='string'?r.text:'';var detail='';
  try{var o=JSON.parse(t);var e=o&&o.error;var m=e&&(e.message||e);if(typeof m==='string'&&m)detail=m;}catch(e){}
  if(!detail&&t)detail=t.length>300?t.slice(0,300):t;
  return action+'失败:HTTP '+(r.status==null?'?':r.status)+(detail?(': '+detail):'');}
function finishModels(ctx){var r=ctx.response||{};
  if(r.error)return {action:'error',message:'连接生图网关失败(网络中断或超时)'};
  if(r.status<200||r.status>=300)return {action:'error',message:httpError(r,'拉取模型列表')};
  var ids=[];try{var data=JSON.parse(r.text).data||[];for(var i=0;i<data.length;i++){if(data[i]&&data[i].id)ids.push(data[i].id);}}catch(e){ids=[];}
  var nai=ids.filter(function(x){return x.indexOf('nai-')===0;});
  if(ctx.operation==='listModels')return {action:'done',models:nai};
  return {action:'done',message:'连接成功:共 '+ids.length+' 个模型,其中生图 '+nai.length+' 个'};}
function step(ctx){var s=ctx.settings||{};
  if(ctx.operation==='test'||ctx.operation==='listModels'){
    if(ctx.phase!=='start')return finishModels(ctx);
    return {action:'http',state:null,request:{method:'GET',url:'models',headers:{Authorization:'Bearer '+(s.apiKey||'')},timeoutMs:30000}};
  }
  var st=ctx.state||{retried:false};
  if(ctx.phase==='start')return {action:'http',state:{retried:false},request:genRequest(ctx)};
  var r=ctx.response||{};
  // 只在「一个字节都没收到」时重试一次:收到过任何 SSE 分片(排队进度也算)
  // 说明服务端很可能已在出图,重试就是重复计费(旧后端逐分片置位同规则)。
  if(r.error){
    if(!r.receivedBytes&&!st.retried)return {action:'http',state:{retried:true},request:genRequest(ctx)};
    return {action:'error',message:'生图请求失败:'+(r.error==='timeout'?'请求超时':r.error==='tooLarge'?'响应过大':'网络中断')};
  }
  if(r.status<200||r.status>=300)return {action:'error',message:httpError(r,'生图服务')};
  var urls=extractLinks(extractContent(r.text));
  // 宿主 stopWhen 在**任意字节分片边界**截断响应,最后一个 SSE 事件常只收到
  // 半截 JSON(甚至半截多字节字符):extractContent 解析不出它,链接连同整次
  // 生图被误判失败 —— 分片边界随内容长度变化,表现为偶发生图失败、同一轮
  // 重跑可能复现而下一轮又正常。截断(partial)且完整事件里没取到链接时,
  // 退回原始文本直接提取(JSON 允许转义斜杠,先还原)。
  if(urls.length===0&&r.partial)urls=extractLinks(String(r.text||'').replace(/\\\//g,'/'));
  if(urls.length===0)return {action:'error',message:'生图响应中未找到图片链接'};
  return {action:'done',images:urls.map(function(u){return {url:u};})};}
''';

/// Nai2API 图像生成工作台(job 提交 + 轮询,`x-user-token` 鉴权)。
const String _nai2Code = r'''
function tryParse(t){try{var v=JSON.parse(t);return (v&&typeof v==='object')?v:null;}catch(e){return null;}}
function parse(r){return tryParse(r.text)||{};}
function asInt(v){return typeof v==='number'?Math.round(v):null;}
// 错误详情只取服务端自己的 error 串,绝不回显原始正文:/api/me 的正文里就带着
// 密钥本身,把它拼进横幅等于把凭据显示出来。
function errText(r,action){var m=parse(r).error;return 'Nai2API '+action+'失败:'+(typeof m==='string'&&m?m:'HTTP '+r.status);}
function abs(ctx,raw){if(/^https?:\/\//i.test(raw))return raw;var b=(ctx.settings||{}).baseUrl||'';var m=/^(https?:\/\/[^\/]+)/i.exec(b);var origin=m?m[1]:b.replace(/\/+$/,'');return raw.charAt(0)==='/'?origin+raw:origin+'/'+raw;}
function submitReq(ctx){var s=ctx.settings||{};var p=ctx.params||{};
  var body={token:s.apiKey,tag:(ctx.prompt||'').trim(),model:(s.model||'nai-diffusion-4-5-full'),artist:p.artist||'',size:p.size||'竖图',steps:p.steps==null?28:p.steps,scale:p.scale==null?6:p.scale,cfg:p.cfg==null?0:p.cfg,sampler:p.sampler||'k_dpmpp_2m_sde',negative:ctx.negativePrompt||'',nocache:'1',noise_schedule:p.noiseSchedule||'karras'};
  return {method:'POST',url:'api/web/jobs',headers:{'x-user-token':s.apiKey||''},json:body,timeoutMs:30000};}
function pollReq(ctx,st){var s=ctx.settings||{};
  return {method:'GET',url:'api/jobs/'+encodeURIComponent(st.jobId),headers:{'x-user-token':s.apiKey||''},timeoutMs:30000};}
// 轮询节奏对齐旧后端:排队 1s / 生成中与瞬态失败 500ms–1s。**必须等** —— 不带
// 节奏地连着问会空转打服务端,并在几分钟内把宿主步数上限吃光(表现为「步数超过
// 上限」而不是正常等到出图)。任务已受理,任何失败都只继续问,绝不重新提交。
function pollSoon(ctx,st,ms,donePolls){return {action:'sleep',state:{jobId:st.jobId,donePolls:donePolls==null?(st.donePolls||0):donePolls},milliseconds:ms};}
function nonJson(path){return {action:'error',message:'Nai2API '+path+' 响应不是 JSON 对象'};}
function nai2Test(ctx){var s=ctx.settings||{};var st=ctx.state||{};
  if(ctx.phase==='start')return {action:'http',state:{step:1},request:{method:'GET',url:'api/me',headers:{'x-user-token':s.apiKey||''},timeoutMs:30000}};
  var r=ctx.response||{};
  if(r.error)return {action:'error',message:'连接失败(网络中断或超时)'};
  var body=tryParse(r.text);
  // 严格 2xx 判定(旧 _getJson 同规则):3xx 是重定向/登录页,当成功报「密钥有效」
  // 就是把没验证成的凭据说成验证过了。
  if(r.status<200||r.status>=300){
    var detail=(body&&typeof body.error==='string'&&body.error)?body.error:'HTTP '+r.status;
    return {action:'error',message:'Nai2API '+(st.step===1?'密钥校验':'服务')+'不可用:'+detail};
  }
  if(st.step===1){
    if(!body)return nonJson('/api/me');
    if(body.enabled===false)return {action:'error',message:'Nai2API 密钥已被禁用(服务端 enabled=false)'};
    return {action:'http',state:{step:2,balance:asInt(body.balance)},request:{method:'GET',url:'api/settings',timeoutMs:30000}};
  }
  if(!body)return nonJson('/api/settings');
  var parts=['密钥有效'];if(st.balance!=null)parts.push('余额 '+st.balance+' 点');
  if(asInt(body.costPerImage)!=null)parts.push('单张 '+body.costPerImage+' 点');
  if(asInt(body.accountConcurrency)!=null)parts.push('服务端并发 '+body.accountConcurrency);
  // defaultModel 走 done 的独立字段:设置页会自己拼「,默认模型 X」,再内联一次
  // 就成同一条横幅里出现两遍。
  var dm=typeof body.defaultModel==='string'&&body.defaultModel?body.defaultModel:null;
  return {action:'done',message:parts.join(' · '),defaultModel:dm};}
function step(ctx){
  if(ctx.operation==='test')return nai2Test(ctx);
  if(ctx.operation==='listModels')return {action:'done',models:['nai-diffusion-4-5-full','nai-diffusion-5-full']};
  var st=ctx.state||{};
  if(ctx.phase==='start')return {action:'http',state:{submitting:true,retried:false},request:submitReq(ctx)};
  if(ctx.phase==='sleep')return {action:'http',state:{jobId:st.jobId,donePolls:st.donePolls||0},request:pollReq(ctx,st)};
  var r=ctx.response||{};
  if(st.submitting){
    if(r.error){
      // 提交超时:请求已发出、结果未知,任务可能已受理 —— 重试就是重复出图重复
      // 计费,直接报错(旧后端同规则)。连接级失败(请求没送达)才安全重试一次。
      if(r.error==='timeout')return {action:'error',message:'Nai2API 提交超时(任务可能已受理,未自动重试)'};
      if(!st.retried&&!r.receivedBytes)return {action:'http',state:{submitting:true,retried:true},request:submitReq(ctx)};
      return {action:'error',message:'Nai2API 提交失败(网络中断'+(st.retried?',已自动重试一次':'')+')'};
    }
    if(r.status<200||r.status>=300)return {action:'error',message:errText(r,'提交生图任务')};
    var id=parse(r).id;
    if(typeof id!=='string'||!id)return {action:'error',message:'Nai2API 未返回任务 id'};
    return {action:'sleep',state:{jobId:id,donePolls:0},milliseconds:1000};
  }
  if(r.error)return pollSoon(ctx,st,1000);
  if(r.status>=500)return pollSoon(ctx,st,1000);
  if(r.status<200||r.status>=300)return {action:'error',message:errText(r,'查询生图任务')};
  var job=tryParse(r.text);
  // 2xx 却拿不到 JSON 对象是确定性失败(旧后端同规则)—— 当成「还没好」继续问
  // 只会闷头轮到超时,把编程缺陷伪装成慢。
  if(!job)return nonJson('/api/jobs');
  if(job.status==='done'){
    var raw=job.imageUrl;
    if(typeof raw==='string'&&raw)return {action:'done',images:[{url:abs(ctx,raw)}]};
    // 实测竞态:done 可能先于 imageUrl 落库到达。此刻判失败会白扔一张已出好且
    // 已计费的图 → 有限次追问(500ms 一次,最多 5 次)。
    var dp=(st.donePolls||0)+1;
    if(dp>=5)return {action:'error',message:'Nai2API 任务完成但未返回图片链接'};
    return pollSoon(ctx,st,500,dp);
  }
  if(job.status==='failed'){var e2=job.error;return {action:'error',message:'Nai2API 生成失败:'+(typeof e2==='string'&&e2?e2:'任务失败')};}
  return pollSoon(ctx,st,job.status==='queued'?1000:500);}
''';

/// 全新建库时幂等种入的两条内置插件(均默认启用)。
///
/// id 是插件身份的一部分,发布后不得更改或复用;升级插件应递增 version 并
/// 保留对旧配置的兼容。
const List<ImagePlugin> kDefaultImagePluginSeeds = [
  ImagePlugin(
    id: 'microscritt.chat-completions',
    name: '对话式生图网关(OpenAI 兼容)',
    version: '1.0.1',
    code: _chatCode,
    usesStandardParams: true,
    supportsTest: true,
    supportsListModels: true,
    permissions: ImagePluginPermissions(endpointSetting: 'baseUrl'),
  ),
  ImagePlugin(
    id: 'microscritt.nai2',
    name: 'Nai2API(NovelAI 代理)',
    version: '1.0.0',
    code: _nai2Code,
    usesStandardParams: true,
    supportsTest: true,
    supportsListModels: true,
    permissions: ImagePluginPermissions(endpointSetting: 'baseUrl'),
  ),
];

/// 内置插件 id 集合:启动时按 id 幂等重种,因此 UI 不提供删除入口。
final Set<String> kBuiltinImagePluginIds = Set.unmodifiable({
  for (final plugin in kDefaultImagePluginSeeds) plugin.id,
});
