# MicroScritt 架构与开发说明

> 更新:2026-11-01 · 版本 **2.3.0+3** · schema **v66(单一基线)** · `flutter analyze` 零告警
>
> 本文档描述当前架构、核心不变量与已知局限。变更记录见 `CHANGELOG.md`;面向 AI 编码代理的速查见 `AGENTS.md`。若本文与代码不一致,**以代码为准**。

## 项目是什么

移动端优先的极简 AI 角色扮演(RP)应用。纯客户端 Flutter,无后端服务 —— 对话、生图、Hook 执行、数据全部在本地。多 LLM 后端(OpenAI 兼容 / Anthropic,端点兼容选项:工具通道回复/提示词随机前缀),云生图统一走 JSON 插件(内置对话式网关与 Nai2API 两个协议插件,也可导入自定义插件)。默认 LLM provider 是一个**无密钥、可编辑**的 DeepSeek 示例;应用不内置任何可用密钥或代理服务,服务地址由用户配置。HTML 桌面面板功能已移除(2.2)——后台 agent 只维护变量与生图。

## 架构与分层

```
lib/
├── data/        # sqflite 持久化 + repository(schema v66 单一基线,20 张表;database.dart 主文件 + schema/seeds 两个 part 文件;旧版本库启动时自动归档重建;桌面端数据根固定 ~/.microscritt(models/DataRoot),首启自动从 Documents 搬迁;app_config_file.dart 维护同目录的 microscritt-config.json,ui_prefs_file.dart 维护同目录的 ui-prefs.json:UI 偏好独立小文件、坏文件 fail-safe)
├── backend/     # LlmBackend 抽象(OpenAI/Anthropic + SSE,provider 级「官方 OpenAI 参数风格」开关)+ 上游契约层(UpstreamErrorKind 七类错误分类 + LlmProbe 测试连接)+ ImageBackend 抽象(单一插件路径 PluginImageBackend:内置对话式网关/Nai2 亦为自带插件,同步 JS step 状态机 + Dart 受限 HTTP/sleep,支持 operation/params/url 结果/网络失败回传;运行链路只消费活跃配置)
├── context/     # ContextAssembler:纯文本 ContextSnapshot 组装;稳定段 <tag> 包裹,可变内容经 attachments 注入;attachment_budget 单轮注入限额
├── engine/      # ChatEngine(单写对话)+ BackgroundEngine/Orchestrator(变量严格校验/增量分批/版本条件写回/三档权限/显式删除/回收站/严格模式待确认;生图独立近期场景;失败不推进进度)+ Hook(QuickJS 沙箱)+ CompactService(合并式单一摘要,token 占用率驱动)
├── import/      # 角色卡(V1/V2/V3 + PNG 内嵌)与世界书导入(ST World Info 兼容);会话归档两遍流式扫描(json_stream_reader)
├── export/      # 会话/角色卡 JSON 与 PNG 导出(PNG 内嵌 chara/ccv3);世界书条目独立导出(ST 形态);会话归档分块流式 writer;五类文本资产统一信封导出
├── models/      # 纯 Dart 领域类型(无 Flutter 依赖);默认预设/Hook/风格种子全部为原创中性内容
├── state/       # Riverpod providers + ChatController(消息窗口化加载;显示窗口与组装窗口分离;reverse 消息列表)
└── ui/          # 屏幕 + widgets(冷启动品牌动画:三球落位→胶囊成形→字样;气泡/消息列表/面板/灵动岛/上下文面板/全屏图片查看器;聊天页会话内消息搜索:防抖检索、扩窗定位与短暂高亮;点击角色/用户头像弹出状态卡,直达角色卡编辑与个人设置)
```

**数据流**:`UI → ChatController → ContextAssembler(组装纯文本)→ ChatEngine(LlmBackend 流式)→ 落库`;回复落库后后台串行维护,忙时合并待处理对话。变量每批最多 12 条、每任务最多两轮,严格校验与版本条件写回成功后才确认进度;人工写入冲突/失败不推进,会话切换与历史改写使旧任务失效。后台只能经 `removeVariables` 显式请求删除,仓库按 `agent_access` 三档权限在事务内过滤并限制单轮 5 个;删除移入 `variable_trash` 可恢复,严格模式下只写 `variable_deletion_proposals` 等用户确认。变量仍不进主写,进度仅在当前会话周期保留;生图在末批读取最新六条活跃对话。`/rerun [修改方向]` 可重跑上一次成功维护:变量重放那一批对话、生图原地替换那一轮落库的图片(替换目标失效则追加),不动正常游标与生图间隔;命令后的文本作为修改方向,提示词以置于最末的 `<rerun_instruction>` 段标识重跑并附上一轮图片描述作为修订基线。后台 image 轮把任务契约与生图锚定拆为稳定 system 前缀并启用 Anthropic 提示缓存(易变尾部不写入缓存),变量-only 轮维持整串发送。

## 核心不变量(改代码前必读)

- **LLM 只接收纯文本 `ContextSnapshot`**;图片与富媒体绝不进上下文,图片只出现在消息落库与 View 渲染。
- **持久化层与 LLM/生图层不互相 import**,只通过 `lib/models/` 类型对接。
- **消息逐行追加**,不做全文件重写。
- `LlmBackend.generate(LlmRequest) → Stream<LlmEvent>`;**UsageEvent 是每请求一次的终值快照**。
- **schema v66 单一基线**:2.0 起无增量迁移链;旧版本库自动归档重建。schema 变更 = 改基线 DDL + 递增版本号 + 补 `database_open_test.dart` 断言。
- **大卡规则**:`CharacterCard.toStorageJson()` 落库,列表查询按 UTF-8 字节阈值 SQL 级兜底;`characters.data_json/avatar_base64/background_base64` 与 `worldbook_entries.content/extra` 超 Android CursorWindow 时一律先查长度再 `substr` 分块读回(导出/编辑/世界书加载不再因单行过大失效)。角色卡导入/导出均有阶段进度;移动端导出走临时文件 + 系统另存为(原生按流复制)。
- **启动水合 fail-safe**:坏 JSON 回落默认,脏值不炸启动。端点兼容选项解析同样遵循:坏 JSON / 非对象 / 未知字段一律忽略。
- **文本配置文件**:`microscritt-config.json` 与数据库同目录(桌面 `~/.microscritt`,移动端应用私有 Documents),启动时以文件为准应用用户名与 LLM provider,UI 修改后回写;坏文件启动只打日志、保留文件与库。文件含**明文 API Key**,文档与设置页均提示勿公开分享;导出归档同样可能含密钥与图片。
- **会话归档流式 IO**:导出逐条写、图片按 1MB 分块转义(峰值内存≈单条消息);导入两遍扫描,截断/坏文件在任何写库前报错,消息每 8 条分块落库。归档结构仍是 v4;v66 起新增可选顶层键 `variableAccess`(变量键 → `agent_access`),导出随 active 变量写入、导入按档恢复,旧档/未知值/非字符串回落 `protected`。桌面端 `.part` 原子替换,移动端临时文件 + 用户选择「保存到本地」(`flutter_file_dialog`,原生按流复制)或系统分享(`share_plus`)。
- **生图走单一插件路径**:内置的对话式网关 / Nai2API 协议是仓库自带插件(`image_plugin_seeds.dart` 幂等种入 `image_plugins`);新增 HTTP(S) 服务只需导入单文件 JSON 插件,不改调用方或 Dart 源码。插件契约含 `operation`(generate/test/listModels)、标准 `params`、`settings` 与 `done` 图片(base64 或 url,url 交上层本地化);网络传输失败以 `response.error` 回传 JS 由其决定是否重试(宿主不自动重试,避免重复计费)。
- **仓库自带插件的 JS 必须被真实执行**:字段消毒、防重复计费、轮询节奏等关键不变量在 JS 里,Dart 侧没有对应实现。JS 相关测试一律经 `test/support/plugin_js_engine.dart` 的 `probePluginJsEngine()`(QuickJS 优先、回落 Node)求值,禁止 `if (runtime == null) return;` 式空转假绿;引擎确实不可用时用 `markTestSkipped`。
- **Hook** 经 `HookRuntime.evaluate(js)` 求值,`HookEngine.run` 用 JSON `__ctx` 往返;返回上下文剥离 `__` 前缀内部键。
- **内容红线**:内置默认提示词(`prompt_seeds.dart`/`hook_seeds.dart`/`image_prompt_guide.dart`/`image_style_preset.dart`)必须是本项目原创的中性创作辅助内容;不接受破限/越狱指令、露骨成人素材、未授权第三方文本。不得硬编码可用密钥、鉴权绕过头或用户不可配置的第三方端点;默认种子仅允许无密钥、可编辑的示例 provider。

## 数据模型(schema v66)

20 张表:`characters` / `sessions` / `messages`(`kind`/`ref_id` 附件行;`image_prompt` 保存生图原始描述供图片重新生成) / `prompt_items`(preset/rule 两类) / `llm_providers` + `llm_models`(provider 分组配置;`extra_headers` 自定义请求头、`modern_params` 官方参数风格、`compat_flags` 端点兼容选项、每模型 `temperature`) / `image_plugins`(JSON 插件 manifest/code/启停;v64 起种入对话式网关+Nai2 两条内置协议插件) + `image_providers`(生图配置多行表;统一 `kind=plugin`,核心 `base_url/api_key/model` + `plugin_id/settings_json`) / `image_styles`(自定义生图风格) / `worldbook_entries`(`extra` 透传列捕获 ST 专有字段;`background` 列锚定进后台段) / `skills`(全局技能,@提及触发) / `variables`(`agent_access` 三档权限) + `variable_trash`(回收站,主键按会话+键唯一) + `variable_deletion_proposals`(严格模式待确认) + `memories` + `image_guides`(会话级后台状态) / `hooks`(5 触发点;默认 main/jump 输入改写两条) / `regex_scripts`(显示层正则) / `user_profile` / `app_settings`(单行偏好;含 `background_deletion_confirm`)。

默认 LLM provider 种子为 DeepSeek 官网示例(密钥留空,可编辑/删除)。

## 运行 / 测试

```bash
flutter pub get
flutter test                 # 全量测试
flutter test test/backend    # 单目录
flutter analyze              # 要求零告警
flutter build apk --release  # Android 构建
flutter build windows --release
```

需要 Flutter ≥ 3.35(Dart ≥ 3.9)。

**依赖锁文件**:`pubspec.lock` 必须使用 pub.dev 地址。若本地使用 `PUB_HOSTED_URL` 镜像,提交前用
`PUB_HOSTED_URL=https://pub.dev flutter pub get` 重生成,CI 会拒绝含镜像 URL 的锁文件。

QuickJS 不可用的环境下 hook 测试自动跳过(预期行为)。生图插件的 JS 走 `probePluginJsEngine()`:QuickJS 优先、否则回落 Node,所以 Windows 的 `flutter test` 里两条内置协议插件是真被执行的(桥接库缺失时曾是空转假绿)。

## 已知局限

- 移动端「保存到本地」系统对话框(`flutter_file_dialog`,会话归档与角色卡/图片/配置导出共用)与系统分享面板(`share_plus`)未在真机验证:桌面 `.part` 写入、移动端分支与流式读写已有单测/UI 测试覆盖,原生对话框本身需真机确认。
- iOS/macOS 的 JS runtime 未接线 —— 生图已全面走 JS 插件,故这些平台生图当前不可用(桌面/Android 不受影响)。
- PNG 角色卡导出以头像为图片本体;非 PNG 头像经平台解码器转码,无头像/坏图生成首字占位图。
- 图片重新生成依赖落库的原始描述(v65 起的新图携带);旧导出档案导入的图片没有描述,不显示重生成入口。
- 变量回收站与待确认删除只存在于当前库,不随会话归档导出/导入;v66 起归档通过可选 `variableAccess` 保真变量权限,旧档/缺键/未知值导入默认 `protected`(安全优先)。
- 严格模式的待确认建议在变量被人工编辑/删除/改权限时自动清理;后台可重新提议。用户在状态面板删除的键,后续剧情若明确 reintroduce,后台仍可能重新创建(现有确认文案已提示)。
- 生图排队进度不透出到 UI(插件缓冲响应体,靠 `stopWhen` 在图片链接到位时提前断流,而非逐事件回调)。
- 会话内搜索走 `messages.content LIKE`(无 FTS 索引),每次输入对当前会话全表扫描一次;常规会话瞬时返回,极长会话会有可感知的查询延迟。搜索只覆盖文本:纯图片消息、显示层正则改写后才出现的内容无法命中。
- `/rerun` 的重放窗口、图片替换目标与上一轮图片描述只存在于会话内存(不落库):重启或切会话后重跑回退为「最新一轮问答 + 追加新图」,修改方向也只随本次调用生效。
- 生图插件支持 HTTP(S) 与 base64/url 结果、test/listModels 操作、`timeoutMs`(按剩余预算裁剪)与 `stopWhen` 提前截断;仍无 JS 直接联网、原生 SDK/本地推理、SSE 实时进度与自动更新。
- Windows QuickJS 内存上限不生效(bridge 缺符号时仅保留 timeout 档)。

## 版本与兼容性

- **2.3.0** 起应用标识为 `io.github.ricardokaslana.microscritt`。Android/iOS 上视为新应用,旧安装数据不自动迁移;Windows 数据位于 `~/.microscritt`,不受标识变更影响。
- **2.0** 起数据库采用单一基线:检测到旧版本库时把原文件归档(`microscritt.db-legacy-v<版本>-<时间戳>.db`)后按基线重建,不再保留增量迁移链。升级前请先导出会话。

## 安全与隐私

应用不收集遥测,所有数据保存在本地;网络请求只发往用户配置的 LLM / 生图端点。API Key 以明文保存在 SQLite 与 `microscritt-config.json` 中,属于既定取舍。不要提交本地配置、数据库或导出归档到仓库。详见 `PRIVACY.md` 与 `SECURITY.md`。
