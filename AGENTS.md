# MicroScritt 开发速查

移动端优先的极简 AI 角色扮演应用。纯客户端 Flutter,分层:

Data(sqflite)→ Backend(LLM 抽象 + 生图抽象)→ Context(组装管线)→ Engine(单写对话 + 后台双写 + Hook)→ Import/Export → UI(Riverpod)。

## 核心不变量

- LLM 只接收 `ContextSnapshot`(纯文本 `systemPrompt` + `List<ChatMessage>`),绝不混入 HTML/图片;图片只出现在消息落库(`messages.image_base64`)与 View 渲染,不进上下文。
- 持久化层与 LLM/生图层不互相 import,只通过 `lib/models/` 类型对接。
- 每条消息独立一行追加(`messages` 表),不做全文件重写。
- 端点兼容选项(`EndpointCompat`,provider 级声明式):replyViaTool(回复经工具参数通道输出,空回重试至多 3 次)/ noncePrefix(system 随机前缀,使每轮请求字节不同)。OpenAI 后端消费;anthropic 后端不消费。普通端点保持全关(部分端点对未知 tools 字段回 400)。
- 所有 LLM 请求走 `LlmBackend.generate(LlmRequest) → Stream<LlmEvent>`;生图走平行抽象 `ImageBackend.generateImage(prompt) → Future<ImageResult>`,配置是 `lib/models/` 的中立 `ImageConfig`。**2.3 起 `imageBackendProvider` 只有单一插件路径**:内置的对话式网关 / Nai2API 协议已改写为仓库自带插件(`image_plugin_seeds.dart` 幂等种入 `image_plugins`),旧的 `ChatCompletionsImageBackend`/`Nai2ImageBackend` Dart 实现已删除。生图插件是单文件 JSON(manifest + 同步 JS `step(ctx)`),Dart 宿主执行 `http/sleep/done/error` 状态机并强制 origin 权限、超时、大小限制与禁重定向;契约含 `operation`(generate/test/listModels)、`params`(标准生图参数,其中 `negative` 是**用户原始值**、与已兜底的 `negativePrompt` 并存)、合并了核心 baseUrl/apiKey/model 的 `settings`,`done` 图片支持 base64 或 url(url 交上层 `downloadImageBase64` 本地化),网络传输失败以 `response.error`+`receivedBytes` 回传 JS 由其决定是否重试(宿主绝不自动重试,复刻防重复计费)。`http` 动作可带 `timeoutMs`(按剩余总预算裁剪,**不得**再夹回 requestTimeout —— 分钟级排队的生成 POST 会被掐断)与 `stopWhen:{contains,regex}`(响应体里目标内容一到位即停读:网关出图后仍保活数十秒,不等关流;**截断按任意字节分片边界发生**,响应带 `partial:true` 且可能切在多字节字符中间,解析 SSE 的插件必须自行容错半截事件 —— 内置网关插件会从 partial 原始文本兜底取链接)。新增 HTTP(S) 服务只需导入插件,不改调用方或源码。`FakeImageBackend` 仅测试用。
- **仓库自带插件的 JS 必须被真实执行到位**:内置协议插件承载了字段消毒、防重复计费、轮询节奏等关键不变量,而这些不变量在 Dart 侧没有对应代码。Windows 的 `flutter test` 宿主加载不到 QuickJS 桥接库(`JsHookRuntime.probe()` 返回 null),所以 JS 相关测试一律经 `test/support/plugin_js_engine.dart` 的 `probePluginJsEngine()`(QuickJS 优先、回落 Node)求值,**禁止** `if (runtime == null) return;` 式的空转假绿;引擎确实不可用时用 `markTestSkipped`。求值器按 UTF-8 解码(node 的 stdout 恒 UTF-8,`systemEncoding` 在中文 Windows 是 GBK)。
- Hook 经 `HookRuntime.evaluate(js)` 求值,`HookEngine.run` 用 JSON `__ctx` 往返;返回上下文剥离 `__` 前缀内部键(如 `__hookError` 不泄漏)。
- 数据库 `schemaVersion = 66`(20 张表,**单一基线**;v63 新增 `image_plugins` 及生图 provider 插件关联/动态设置列;v64 把两个内置生图协议改为幂等种入的仓库自带插件;v65 给 `messages` 增加 `image_prompt`;v66 给 `variables` 增加 `agent_access`,并新增 `variable_trash` / `variable_deletion_proposals` 与 `app_settings.background_deletion_confirm`)。2.0 起没有增量迁移链:检测到旧版本库时把原文件归档(`microscritt.db-legacy-v<版本>-<时间戳>.db`)后按基线重建。schema 变更 = 改 `database_schema.dart` 基线 DDL + 递增版本号 + 补 `test/data/database_open_test.dart` 断言。
- **大卡规则**:data_json 一律经 `CharacterCard.toStorageJson()` 落库(剥掉内嵌头像,头像只存 `avatar_base64` 列),保证单行远小于 Android SQLite 2MB CursorWindow;列表查询(CharacterRepository.all)另留 SQL 级兜底,超窗行以空串投影,绝不让一行拖垮列表。
- 后台引擎(`BackgroundEngine`)把 LLM 返回解析为状态更新;任何错误/解析失败返回失败原因,`Orchestrator` 据此跳过,不落库、不掉轮。后台只维护快状态(变量/生图;HTML 桌面面板功能已移除);记忆与生图指导由用户主动维护(状态面板),主写上下文的可变内容经 attachments 注入(`<system-reminder>` 附件行/记忆第 0 条/压缩通知)。
- **变量删除必须显式**:LLM 只能经 `removeVariables` 精确键名数组请求删除,绝不能从 `variables` 的缺省键推断删除,也不能用 null 值表示删除。`variables.agent_access` 三档(`full` 可改可删 / `protected` 可改不可删 / `readonly` 不可改不可删)在**仓库事务内**二次校验,提示词里的 `<variable_access>` 只是减少无用输出;删除先进 `variable_trash`(可恢复),单轮至多 5 个。严格模式(`app_settings.background_deletion_confirm`)下删除只写 `variable_deletion_proposals`,用户在状态面板确认后才移动;人工编辑/删除/权限变更会清理该键的待确认建议。变量仍不进主写组装。
- **启动即水合的配置列解析必须 fail-safe**:坏 JSON / 非对象 / 未知值一律回落默认,脏值不允许炸掉启动。
- **文本配置文件**:`microscritt-config.json` 与数据库同目录(桌面 `~/.microscritt`,移动端应用私有 Documents),启动时以文件为准应用用户名与 LLM provider,UI 修改后回写(`state/app_config_sync.dart`)。文件含明文 API Key,属于既定取舍;坏文件启动只打日志、不改库。公开仓库不得提交本地配置、数据库、导出归档或任何密钥。
- **会话归档流式 IO**:导出逐条写、图片按 1MB 分块转义(峰值内存≈单条消息);导入走两遍扫描(`import/json_stream_reader.dart`),截断/坏文件在任何写库前报错,消息每 8 条分块落库、失败回滚。归档结构仍为 v4;v66 起新增可选顶层键 `variableAccess`(变量键 → `agent_access`),导出随 active 变量写入、导入按档恢复,旧档/未知值/非字符串回落 `protected`,额外键忽略。桌面端 `.part` 原子替换,移动端临时文件 + 用户选择「保存到本地」(`flutter_file_dialog`,原生按流复制)或系统分享(`share_plus`)。资源文件/头像仍保留 50MB 读取上限。

## 内容红线(开源仓库)

- 内置默认提示词(`prompt_seeds.dart`/`hook_seeds.dart`/`image_prompt_guide.dart`/`image_style_preset.dart`)必须是本项目原创的中性创作辅助内容;不接受破限/越狱指令、露骨成人素材、未授权第三方文本。
- 不硬编码任何可用密钥、鉴权绕过头或用户不可配置的第三方端点;默认种子仅允许无密钥、可编辑的示例 provider,端点由用户在设置页配置。

## 提交约定

- 约定式提交(`feat:` / `fix:` / `test:` / `refactor:` / `docs:` / `chore:`),中文描述;不附署名尾注。
- **提交前必须同步文档**:代码变更在提交前把对应内容更新到 `CHANGELOG.md`(Keep a Changelog 格式,Unreleased 段)。`docs/ARCHITECTURE.md` 记录当前架构、不变量与已知局限,仅当批次改变架构或现状时更新对应行。纯文档提交除外。

## 常用命令

- 测试:`flutter test`
- 单测某目录:`flutter test test/backend`
- 静态检查:`flutter analyze`(要求零告警)
- 锁文件:若本地设置了 `PUB_HOSTED_URL` 镜像,提交前执行
  `PUB_HOSTED_URL=https://pub.dev flutter pub get`,确保 `pubspec.lock` 只含 pub.dev 地址;CI 会拒绝镜像 URL。

## 文档

- 架构与开发说明:`docs/ARCHITECTURE.md`
- 变更记录:`CHANGELOG.md`
- 贡献流程:`CONTRIBUTING.md`
- 隐私与安全:`PRIVACY.md` / `SECURITY.md`
