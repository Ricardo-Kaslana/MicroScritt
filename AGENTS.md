# MicroScritt 开发速查

移动端优先的极简 AI 角色扮演应用。纯客户端 Flutter,分层:

Data(sqflite)→ Backend(LLM 抽象 + 生图抽象)→ Context(组装管线)→ Engine(单写对话 + 后台双写 + Hook)→ Import/Export → UI(Riverpod)。

## 核心不变量

- LLM 只接收 `ContextSnapshot`(文本 `systemPrompt` + `List<ChatMessage>`,可含结构化工具调用块),绝不混入 HTML/图片;图片只出现在消息落库(`messages.image_base64`)与 View 渲染,不进上下文。
- 持久化层与 LLM/生图层不互相 import,只通过 `lib/models/` 类型对接。
- 每条消息独立一行追加(`messages` 表),不做全文件重写。
- 所有 LLM 请求走 `LlmBackend.generate(LlmRequest) → Stream<LlmEvent>`;生图走平行抽象 `ImageBackend.generateImage(prompt) → Future<ImageResult>`,配置是 `lib/models/` 的中立 `ImageConfig`。**2.3 起 `imageBackendProvider` 只有单一插件路径**:内置的对话式网关 / Nai2API / NovelAI 官方 API 协议均为仓库自带插件(`image_plugin_seeds.dart` 幂等种入 `image_plugins`),旧的 `ChatCompletionsImageBackend`/`Nai2ImageBackend` Dart 实现已删除。生图插件是单文件 JSON(manifest + 同步 JS `step(ctx)`),Dart 宿主执行 `http/sleep/done/error` 状态机并强制 origin 权限、超时、大小限制与禁重定向;契约含 `operation`(generate/test/listModels)、`params`(标准生图参数,其中 `negative` 是**用户原始值**、与已兜底的 `negativePrompt` 并存)、合并了核心 baseUrl/apiKey/model 的 `settings`,`done` 图片支持 base64 或 url(url 交上层 `downloadImageBase64` 本地化),网络传输失败以 `response.error`+`receivedBytes` 回传 JS 由其决定是否重试(宿主绝不自动重试,复刻防重复计费)。`http` 动作可带 `timeoutMs`(按剩余总预算裁剪,**不得**再夹回 requestTimeout —— 分钟级排队的生成 POST 会被掐断)与 `stopWhen:{contains,regex}`(响应体里目标内容一到位即停读:网关出图后仍保活数十秒,不等关流;**截断按任意字节分片边界发生**,响应带 `partial:true` 且可能切在多字节字符中间,解析 SSE 的插件必须自行容错半截事件 —— 内置网关插件会从 partial 原始文本兜底取链接)。新增 HTTP(S) 服务只需导入插件,不改调用方或源码。`FakeImageBackend` 仅测试用。
- **仓库自带插件的 JS 必须被真实执行到位**:内置协议插件承载了字段消毒、防重复计费、轮询节奏等关键不变量,而这些不变量在 Dart 侧没有对应代码。Windows 的 `flutter test` 宿主加载不到 QuickJS 桥接库(`JsHookRuntime.probe()` 返回 null),所以 JS 相关测试一律经 `test/support/plugin_js_engine.dart` 的 `probePluginJsEngine()`(QuickJS 优先、回落 Node)求值,**禁止** `if (runtime == null) return;` 式的空转假绿;引擎确实不可用时用 `markTestSkipped`。求值器按 UTF-8 解码(node 的 stdout 恒 UTF-8,`systemEncoding` 在中文 Windows 是 GBK)。
- Hook 经 `HookRuntime.evaluate(js)` 求值,`HookEngine.run` 用 JSON `__ctx` 往返;返回上下文剥离 `__` 前缀内部键(如 `__hookError` 不泄漏)。
- 数据库 `schemaVersion = 71`(21 张表,**单一基线**;v63 新增 `image_plugins` 及生图 provider 插件关联/动态设置列;v64 把内置生图协议改为幂等种入的仓库自带插件(现行三条:对话式网关 / Nai2API / NovelAI 官方 API);v65 给 `messages` 增加 `image_prompt`;v66 给 `variables` 增加 `agent_access`,并新增 `variable_trash` / `variable_deletion_proposals` 与 `app_settings.background_deletion_confirm`;v67 给 `sessions` 增加 `pinned_at` 置顶时间;v68 给 `app_settings` 增加 `auto_compact_threshold` 自动压缩触发线;v69 新增 `usage_records` 逐请求用量明细,支撑全量统计面板与导出;v70 移除 `llm_providers.compat_flags` 端点兼容选项列;v71 新增 `app_settings.background_mode` 后台运行模式,legacy/agentic/hybrid,坏值回落 legacy)。2.0 起没有增量迁移链:检测到旧版本库时把原文件归档(`microscritt.db-legacy-v<版本>-<时间戳>.db`)后按基线重建。schema 变更 = 改 `database_schema.dart` 基线 DDL + 递增版本号 + 补 `test/data/database_open_test.dart` 断言。
- **大卡规则**:data_json 一律经 `CharacterCard.toStorageJson()` 落库(剥掉内嵌头像,头像只存 `avatar_base64` 列),保证单行远小于 Android SQLite 2MB CursorWindow;列表查询(CharacterRepository.all)另留 SQL 级兜底,超窗行以空串投影,绝不让一行拖垮列表。
- 后台引擎(`BackgroundEngine`)把 LLM 返回解析为状态更新;任何错误/解析失败返回失败原因,`Orchestrator` 据此跳过,不落库、不掉轮。后台只维护快状态(变量/生图;HTML 桌面面板功能已移除);记忆与生图指导由用户主动维护(状态面板),主写上下文的可变内容经 attachments 注入(`<system-reminder>` 附件行/记忆第 0 条/压缩通知)。
- **Agentic 后台(P2–P4)**:`Orchestrator.runAfterTurn` 按 `mode` 分流(默认 legacy 零行为变化;hybrid 每轮维护仍 legacy)。agentic 经通用内核(`lib/engine/agent/`,**只 import models/ 与 backend/**,读库经编排器注入的只读回调)+ 维护 profile(`background_agent.dart`)多步工具循环;暂存只在内存,finish 后走原 `compareAndApply` 一次原子提交,失败/取消/护栏全丢弃。**agent 转录是内存态,绝不落 `messages` 表**(主写单写不变量)。逐步用量经 `onAgentStep` 事件透出(每逻辑步一条 `usage_records`,失败/取消步 reported=false;控制器已接线,agentic 跳过轮级行,桶/游标/落定摘要语义不变;设置列 `background_mode` schema v71,三档切换按钮在状态面板「后台引擎」标题行)。agentic 不做 image-only 补调。提示词数据段经 `background_prompt.dart` 与 legacy 逐字同构,特征化测试钉死旧路径字节。**hybrid 周期审计(P4)**:每 5 个成功变量轮(`cursorSeq != null`)后,控制器在串行后台槽位经独立 `Orchestrator.runAudit` 发起审计(单槽换发令牌,同 memory/rerun,非第二并发槽);审计 profile(`AuditProfile`)读全量板 + 权限 + 最近 30 条宽窗取证,工具面去 `setImagePrompts`,契约合并近义键/修剪陈旧/修正矛盾(保守优先),finish 后同一 `compareAndApply`。**让位规则**:审计期间新对话(`_fireBackgroundMaintenance` 见 `_auditRunning`)即 cancel 审计令牌、丢弃暂存、先跑 delta,审计 finally 见 `_backgroundPending` 补跑维护,计数器不重置稍后重试。审计**永不推进 delta 游标、不生图、无 `/rerun`**;成功/失败/冲突/良性跳过重置计数器,取消(让位/interrupt)不重置;计数器 per-session 内存态(`load` 清零;`_invalidateBackground` 清 `_auditRunning` 但不清计数器),rerun 与历史改写不计数。审计逐步入账无轮级行/无失败零行,成功用量累加进后台桶,独立审计文案经 `backgroundSummary` 透传状态面板/灵动岛(UI 零结构改动)。
- **AI 制卡(card_studio)**:独立工作台(角色列表「添加 → AI 制卡」/角色菜单「AI 优化角色卡」),复用 agent 内核 + `CardProfile` 工具面(`readDraft`/`setCardFields`/`upsertWorldbookEntries`/`removeWorldbookEntries`/`setAvatarPrompt`);`readDraft` 支持条目分页与单字段原文分页(`field`/`fieldOffset`/`fieldLimit`,结果按 JSON 长度收缩),长卡改写前先读全文。写动作只进内存 `CardStaging`,finish 后快照为字段级/行级 diff,供逐项接受/拒绝/内联编辑(编辑后按决策值重算展示,全部拒绝禁用应用);应用时新卡 `insertWithWorldbook`、既有卡 `updateWithWorldbook` 单事务(世界书按 id 稳定增删改),冲突检测覆盖完整卡面 + 头像/背景 + 世界书;审阅页可按当前决策预览最终卡。头像在 Agent 完成后自动生图(未配置跳过;URL 本地化 + 缩图后落列),提示词未变时复用,应用后继续打磨仍复用。草稿按目标防抖存应用私有 `card-studio-draft-<id|new>.json`(原子写/串行队列/坏文件回落,不存 raw 与未选候选图),重进同目标自动恢复,应用或「丢弃当前草稿」后清理;应用后「继续打磨」的空闲会话同样落盘(无提案快照,仅恢复对话/复用头像提示词,基线以当前库为准);草稿不落库、不改 schema。多轮种子中的负临时 id 继续向下分配,`upsertWorldbookEntries` 对工作副本一律原地更新(避免重复追加)。每逻辑步写入 `usage_records`(`kind=card`,`session_id` 留空,失败/取消步 reported=false)。内核新增可选 `onTextDelta`/`AgentStepEvent.text`,后台 profile 不传则零行为变化;工作台输入卡复用聊天 `ChatComposer`(`showCommands=false`),模型/推理与聊天同源(当前活跃 provider/模型 + `app_settings.reasoning_level`),上下文圆环取 `AgentStepEvent.requestUsage`(单次请求口径,重试求和不计)。
- **变量删除必须显式**:LLM 只能经 `removeVariables` 精确键名数组请求删除,绝不能从 `variables` 的缺省键推断删除,也不能用 null 值表示删除。`variables.agent_access` 三档(`full` 可改可删 / `protected` 可改不可删 / `readonly` 不可改不可删)在**仓库事务内**二次校验,提示词里的 `<variable_access>` 只是减少无用输出;删除先进 `variable_trash`(可恢复),单轮至多 5 个。严格模式(`app_settings.background_deletion_confirm`)下删除只写 `variable_deletion_proposals`,用户在状态面板确认后才移动;人工编辑/删除/权限变更会清理该键的待确认建议。变量仍不进主写组装。
- **启动即水合的配置列解析必须 fail-safe**:坏 JSON / 非对象 / 未知值一律回落默认,脏值不允许炸掉启动。
- **文本配置文件**:`microscritt-config.json` 与数据库同目录(桌面 `~/.microscritt`,移动端应用私有 Documents),启动时以文件为准应用用户名与 LLM provider,UI 修改后回写(`state/app_config_sync.dart`)。文件含明文 API Key,属于既定取舍;坏文件启动只打日志、不改库。公开仓库不得提交本地配置、数据库、导出归档或任何密钥。
- **会话归档流式 IO**:导出逐条写、图片按 1MB 分块转义(峰值内存≈单条消息);导入走两遍扫描(`import/json_stream_reader.dart`),截断/坏文件在任何写库前报错,消息每 8 条分块落库、失败回滚。归档结构仍为 v4;v66 起新增可选顶层键 `variableAccess`(变量键 → `agent_access`),导出随 active 变量写入、导入按档恢复,旧档/未知值/非字符串回落 `protected`,额外键忽略。桌面端 `.part` 原子替换,移动端临时文件 + 用户选择「保存到本地」(`flutter_file_dialog`,原生按流复制)或系统分享(`share_plus`)。资源文件/头像仍保留 50MB 读取上限。

## 内容红线(开源仓库)

- 内置默认提示词(`prompt_seeds.dart`/`hook_seeds.dart`/`image_prompt_guide.dart`/`image_style_preset.dart`/`background_agent.dart` 的工具契约)必须是本项目原创的中性创作辅助内容;不接受破限/越狱指令、露骨成人素材、未授权第三方文本。
- 不硬编码任何可用密钥、鉴权绕过头或用户不可配置的第三方端点;默认种子仅允许无密钥、可编辑的示例 provider,端点由用户在设置页配置。

## 提交约定

- 约定式提交(`feat:` / `fix:` / `test:` / `refactor:` / `docs:` / `chore:`),中文描述;不附署名尾注。
- **提交前必须同步文档**:代码变更在提交前把对应内容更新到 `CHANGELOG.md`(Keep a Changelog 格式,Unreleased 段)。`docs/ARCHITECTURE.md` 记录当前架构、不变量与已知局限,仅当批次改变架构或现状时更新对应行。纯文档提交除外。
- **注释规范**:文件头、公共 API 文档、实现注释与版式的统一要求见 `CONTRIBUTING.md` 的「注释规范」;注释只解释为什么与约束,不逐行复述代码。

## 常用命令

- 测试:`flutter test`
- 单测某目录:`flutter test test/backend`
- 静态检查:`flutter analyze`(要求零告警)
- 锁文件:若本地设置了 `PUB_HOSTED_URL` 镜像,提交前执行
  `PUB_HOSTED_URL=https://pub.dev flutter pub get`,确保 `pubspec.lock` 只含 pub.dev 地址;CI 会拒绝镜像 URL。
- 发布:推送与 `pubspec.yaml` 版本一致的 `v*` tag 触发 `.github/workflows/release.yml`;Android 签名密钥只存 GitHub Secrets,流程见 `CONTRIBUTING.md`「发布」。
- 发布签名初始化:`tool/setup_android_signing.sh`(`gh` 已登录,密码交互输入)。

## 文档

- 架构与开发说明:`docs/ARCHITECTURE.md`
- 变更记录:`CHANGELOG.md`
- 贡献流程:`CONTRIBUTING.md`
- 隐私与安全:`PRIVACY.md` / `SECURITY.md`
