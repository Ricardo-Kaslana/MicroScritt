# MicroScritt 开发速查

> 面向 AI 编码代理的项目速查:改代码前必须知道的不变量、约定与命令。完整分层说明见 `docs/ARCHITECTURE.md`,贡献规范见 `CONTRIBUTING.md`;若本文与代码不一致,以代码为准。

## 项目与分层

移动端优先的极简 AI 角色扮演应用,纯客户端 Flutter,无后端服务:

```
Data(sqflite) → Backend(LLM 抽象 + 生图抽象) → Context(组装管线)
→ Engine(单写对话 + 后台双写 + Hook) → Import/Export → UI(Riverpod)
```

- **分层铁律**:`lib/data`(持久化)与 `lib/backend`(LLM/生图)不互相 import,只通过 `lib/models/` 的中立类型对接;`test/layering_test.dart` 钉死该约束。
- **启动 fail-safe**:启动即水合的配置列解析必须容错,坏 JSON / 非对象 / 未知值一律回落默认,脏值不允许炸掉启动。

## 核心不变量

### LLM 与上下文

- LLM 只接收 `ContextSnapshot`(文本 `systemPrompt` + `List<ChatMessage>`,可含结构化工具调用块),绝不混入 HTML/图片;图片只出现在文件资产库与 View 渲染,不进上下文。
- 所有 LLM 请求走 `LlmBackend.generate(LlmRequest) → Stream<LlmEvent>`;生图走平行抽象 `ImageBackend.generateImage(prompt) → Future<ImageResult>`,配置是 `lib/models/` 的中立 `ImageConfig`。`FakeImageBackend` 仅测试用。

### 消息与主写

- 每条消息独立一行追加(`messages` 表),不做全文件重写。
- **剪尾必须恢复摘要覆盖的原文**:`deleteFrom` 收集被删的 `system` 摘要并把存活且指向它们的折叠行恢复为未折叠;否则摘要消失后,`is_compacted=1` 的历史既不再进上下文也无法被重新摘要。
- **主写会话归属**:`load` 取消主写令牌并递增 `_sessionEpoch`;发送/生成/压缩/上下文重算在每个 await 后校验 `(sessionId, epoch, token)`,数据库写始终用捕获的 sessionId。切会话后旧流的迟到结果绝不写新会话状态/记忆/后台槽。

### 数据库与 schema

- `schemaVersion = 75`(22 张表,**单一基线**)。2.0 起没有增量迁移链:检测到旧版本库时把原文件归档(`microscritt.db-legacy-v<版本>-<时间戳>.db`)后按基线重建;重建后启动时会把归档里的 `usage_records` 按列名交集与整行自然键去重回灌进新库(`.usage-salvaged` 标记保证每份归档只处理一次,同时补救此前升级遗留的归档;失败只打日志不阻塞启动),Token 统计不随升级归零。
- **schema 变更三步**:改 `database_schema.dart` 基线 DDL + 递增版本号 + 补 `test/data/database_open_test.dart` 断言;不新增 onUpgrade 步骤。
- 版本线速览:v63 生图插件表与 provider 关联;v64 内置生图协议改幂等种入插件(现行三条:对话式网关 / Nai2API / NovelAI 官方 API);v65 `messages.image_prompt`;v66 变量权限/回收站/严格模式;v67 会话置顶;v68 自动压缩触发线;v69 `usage_records` 逐请求用量;v70 移除端点兼容选项列;v71 `background_mode`(坏值回落 legacy);v72 图片文件资产化;v73 入库压缩开关;v74 Agentic 增强开关;v75 补四条外键索引。
- **大卡规则**:data_json 一律经 `CharacterCard.toStorageJson()` 落库(剥掉内嵌头像);头像只存 `avatar_hash` 列,图片字节由文件资产库管理,避免图片大行触发 Android SQLite 2MB CursorWindow 上限。

### 图片资产

- v72 起由 `ImageAssetStore` 管理内容寻址原图、预览与引用计数,业务表只保存 SHA-256 哈希。启动后异步维护:先按 messages/characters/user_profile 的真实引用与全部制卡草稿 `heldAssetHashes` 重算 `ref_count`,再清理过期 tmp、把预览裁到 256MiB LRU 上限、回收到期零引用资产;草稿扫描或对账失败时本轮跳过回收,失败只打日志。回收与同哈希 put 经进程内 per-hash 锁协调;设置页可查看存储统计并整理原图/预览/数据库。
- URL 回退渲染拿到字节后按内容哈希回填缺失原图,哈希不一致绝不把消息改指向另一张图。URL-only 消息首次下载或磁盘缓存命中后并入资产库并回写 `image_hash`(保留 URL 回退),同图仍按哈希去重;设置页可按会话查看去重资产数/图片消息数/占用。
- v73 起可选择在入库前压缩新图片(长边 2048,GIF 与透明图保留格式,默认关,已有原图不回溯;归档导入与按哈希修复绕过压缩以保持内容寻址一致);会话导入可选择「仅文本」跳过资产解包(消息的图片哈希/URL/生成描述与角色头像/背景全部清空,正文为空的图片消息整条略过)。

### 生图插件

- **2.3 起 `imageBackendProvider` 只有单一插件路径**:内置的对话式网关 / Nai2API / NovelAI 官方 API 协议均为仓库自带插件(`image_plugin_seeds.dart` 幂等种入 `image_plugins`),旧的 `ChatCompletionsImageBackend`/`Nai2ImageBackend` Dart 实现已删除。新增 HTTP(S) 服务只需导入插件,不改调用方或源码。
- 插件是单文件 JSON(manifest + 同步 JS `step(ctx)`),Dart 宿主执行 `http/sleep/done/error` 状态机并强制 origin 权限、超时、大小限制与禁重定向。契约含 `operation`(generate/test/listModels)、`params`(标准生图参数,其中 `negative` 是**用户原始值**、与已兜底的 `negativePrompt` 并存)、合并了核心 baseUrl/apiKey/model 的 `settings`;`done` 图片支持 base64 或 url(url 交上层 `downloadImageBytes` 本地化并资产化),网络传输失败以 `response.error`+`receivedBytes` 回传 JS 由其决定是否重试(宿主绝不自动重试,防重复计费)。
- `http` 动作可带 `timeoutMs`(按剩余总预算裁剪,**不得**再夹回 requestTimeout —— 分钟级排队的生成 POST 会被掐断)与 `stopWhen:{contains,regex}`(响应体里目标内容一到位即停读,不等网关保活关流;**截断按任意字节分片边界发生**,响应带 `partial:true` 且可能切在多字节字符中间,解析 SSE 的插件必须自行容错半截事件 —— 内置网关插件会从 partial 原始文本兜底取链接)。
- **仓库自带插件的 JS 必须被真实执行到位**:字段消毒、防重复计费、轮询节奏等关键不变量在 JS 里,Dart 侧没有对应实现。Windows 的 `flutter test` 宿主加载不到 QuickJS 桥接库(`JsHookRuntime.probe()` 返回 null),JS 相关测试一律经 `test/support/plugin_js_engine.dart` 的 `probePluginJsEngine()`(QuickJS 优先、回落 Node)求值,**禁止** `if (runtime == null) return;` 式的空转假绿;引擎确实不可用时用 `markTestSkipped`。求值器按 UTF-8 解码(node 的 stdout 恒 UTF-8,`systemEncoding` 在中文 Windows 是 GBK)。

### Hook

- Hook 经 `HookRuntime.evaluate(js)` 求值,`HookEngine.run` 用 JSON `__ctx` 往返;返回上下文剥离 `__` 前缀内部键(如 `__hookError` 不泄漏)。

### 后台引擎与 Agentic

- `BackgroundEngine` 把 LLM 返回解析为状态更新;任何错误/解析失败返回失败原因,`Orchestrator` 据此跳过,不落库、不掉轮。后台只维护快状态(变量/生图;HTML 桌面面板功能已移除);记忆与生图指导由用户主动维护(状态面板:初始化/全量重生成/手动编辑),主写上下文的可变内容经 attachments 注入(`<system-reminder>` 附件行/记忆第 0 条/压缩通知)。
- 单张图片提示词改写是用户主动触发的一次性后台调用(旧描述 + 目标图片 seq 之前的对话 + 用户方向 → 新英文 tag),确认后只重绘该行并更新 `image_prompt` 与 `/rerun` 的替换目标,不推游标。
- **Agentic(P2–P4)**:`Orchestrator.runAfterTurn` 按 `mode` 分流(默认 legacy 零行为变化;hybrid 每轮维护仍 legacy)。agentic 经通用内核(`lib/engine/agent/`,**只 import models/ 与 backend/**,读库经编排器注入的只读回调)+ 维护 profile(`background_agent.dart`)多步工具循环;暂存只在内存,finish 后走原 `compareAndApply` 一次原子提交,失败/取消/护栏全丢弃。**agent 转录是内存态,绝不落 `messages` 表**(主写单写不变量)。逐步用量经 `onAgentStep` 事件透出(每逻辑步一条 `usage_records`,失败/取消步 reported=false;agentic 跳过轮级行,桶/游标/落定摘要语义不变;设置列 `background_mode` schema v71,三档切换按钮在状态面板「后台引擎」标题行)。Agentic 不做 image-only 补调。
- **Agentic 增强(v74,默认关)**:`setVariableInjection` 选键、提交后按最终变量板生成 `notice:varinj` 附件行,随下一条用户输入注入主写(依赖变量维护);`setNextSuggestions` 产出 1–3 条用户口吻建议,经 `ChatState.nextSuggestions` 让聊天页自动弹底单,点击即发送、关闭/忽略即丢弃(纯内存);二者在 `/rerun` 的 Agentic 轮同样生效,审计 profile 不注册。提示词数据段经 `background_prompt.dart` 与 legacy 逐字同构,特征化测试钉死旧路径字节。
- **hybrid 周期审计(P4)**:每 5 个成功变量轮(`cursorSeq != null`)后,控制器在串行后台槽位经独立 `Orchestrator.runAudit` 发起审计(单槽换发令牌,同 memory/rerun,非第二并发槽);审计 profile(`AuditProfile`)读全量板 + 权限 + 最近 30 条宽窗取证,工具面去 `setImagePrompts`,契约合并近义键/修剪陈旧/修正矛盾(保守优先),finish 后同一 `compareAndApply`。**让位规则**:审计期间新对话(`_fireBackgroundMaintenance` 见 `_auditRunning`)即 cancel 审计令牌、丢弃暂存、先跑 delta,审计 finally 见 `_backgroundPending` 补跑维护,计数器不重置稍后重试。审计**永不推进 delta 游标、不生图、无 `/rerun`**;成功/失败/冲突/良性跳过重置计数器,取消(让位/interrupt)不重置;计数器 per-session 内存态(`load` 清零;`_invalidateBackground` 清 `_auditRunning` 但不清计数器),rerun 与历史改写不计数。审计逐步入账无轮级行/无失败零行,成功用量累加进后台桶,独立审计文案经 `backgroundSummary` 透传状态面板/灵动岛(UI 零结构改动)。

### 变量治理

- **变量删除必须显式**:LLM 只能经 `removeVariables` 精确键名数组请求删除,绝不能从 `variables` 的缺省键推断删除,也不能用 null 值表示删除。`variables.agent_access` 三档(`full` 可改可删 / `protected` 可改不可删 / `readonly` 不可改不可删)在**仓库事务内**二次校验,提示词里的 `<variable_access>` 只是减少无用输出;删除先进 `variable_trash`(可恢复),单轮至多 5 个。严格模式(`app_settings.background_deletion_confirm`)下删除只写 `variable_deletion_proposals`,用户在状态面板确认后才移动;人工编辑/删除/权限变更会清理该键的待确认建议。
- 变量默认不进主写组装;仅 Agentic 开启变量注入时,后台选中的键以 `notice:varinj` 附件行在提交后一次性注入(随历史保留到压缩),而非整板进入。

### AI 制卡(card_studio)

- 独立工作台(角色列表「添加 → AI 制卡」/角色菜单「AI 优化角色卡」),复用 agent 内核 + `CardProfile` 工具面(`readDraft`/`setCardFields`/`upsertWorldbookEntries`/`removeWorldbookEntries`/`setAvatarPrompt`);`readDraft` 支持条目分页与单字段原文分页(`field`/`fieldOffset`/`fieldLimit`,结果按 JSON 长度收缩),长卡改写前先读全文。
- 写动作只进内存 `CardStaging`,finish 后快照为字段级/行级 diff,供逐项接受/拒绝/内联编辑(编辑后按决策值重算展示,全部拒绝禁用应用);应用时新卡 `insertWithWorldbook`、既有卡 `updateWithWorldbook` 单事务(世界书按 id 稳定增删改),冲突检测覆盖完整卡面 + 头像/背景 + 世界书;审阅页可按当前决策预览最终卡。
- 头像在 Agent 完成后自动生图(未配置跳过;URL 本地化 + 缩图后落列),提示词未变时复用,应用后继续打磨仍复用。草稿按目标防抖存应用私有 `card-studio-draft-<id|new>.json`(原子写/串行队列/坏文件回落,不存 raw 与未选候选图),重进同目标自动恢复,应用或「丢弃当前草稿」后清理;应用后「继续打磨」的空闲会话同样落盘(无提案快照,仅恢复对话/复用头像提示词,基线以当前库为准);草稿不落库、不改 schema;JSON 记录自身持有的头像/背景哈希清单,成功写入后事务差集对账,恢复直接接管不重复 acquire,应用、丢弃与删除角色时清理并释放,草稿图片不依赖 24 小时宽限期。
- 多轮种子中的负临时 id 继续向下分配,`upsertWorldbookEntries` 对工作副本一律原地更新(避免重复追加)。每逻辑步写入 `usage_records`(`kind=card`,`session_id` 留空,失败/取消步 reported=false)。内核新增可选 `onTextDelta`/`AgentStepEvent.text`,后台 profile 不传则零行为变化;工作台输入卡复用聊天 `ChatComposer`(`showCommands=false`),模型/推理与聊天同源(当前活跃 provider/模型 + `app_settings.reasoning_level`),上下文圆环取 `AgentStepEvent.requestUsage`(单次请求口径,重试求和不计)。

### 配置文件

- `microscritt-config.json`(v2)与数据库同目录(桌面 `~/.microscritt`,移动端应用私有 Documents),启动时以文件为准应用用户名、LLM 与生图 provider/插件/画风,UI 修改后回写(`state/app_config_sync.dart`)。内置插件只随配置保存 id/版本/启停,自定义插件内嵌完整 manifest+JS;导入为**单 SQLite 事务**,先校验插件引用与动态设置再写库,内置插件 id 不可被用户包覆盖;批量导入在事务内反向校验,不允许留下引用不存在插件的生图 provider。
- 所有配置写点先落 `.dirty` 标记,快照成功才删除;启动见标记即从库重建,绝不让旧文件覆盖新库。快照回写经进程内写队列串行执行,写入代次 + 独立标脏版本共同决定谁可删 `.dirty`;导入失败撤销本次新建的 dirty。
- 文件含明文 API Key 与可执行插件代码,属于既定取舍;坏文件启动只打日志、不改库。公开仓库不得提交本地配置、数据库、导出归档或任何密钥。

### 会话归档

- 默认导出 v5 ZIP STORE `.msarc`,消息逐行写 `messages.ndjson`,图片按 hash 去重并以二进制流式写入 `assets/`;导入先校验结构、CRC、引用闭合与真实图片,再创建业务数据,消息每 8 条分块落库、失败回滚。保留 v1–v4 JSON 只读导入,旧格式走两遍扫描(`import/json_stream_reader.dart`)并在边界把 base64 资产化;截断/坏文件在任何业务写库前报错。
- `variableAccess` 记录变量权限,旧档/未知值/非字符串回落 `protected`,额外键忽略。桌面端 `.part` 替换先把旧档改名为 `.bak` 再落位,失败回滚;移动端临时文件 + 用户选择「保存到本地」(`flutter_file_dialog`,原生按流复制)或系统分享(`share_plus`)。v5 导入为 NDJSON 单行/总条数设上限,PNG 文本块设全局解压/文本预算;URL 图片下载流式限额、禁重定向并拒绝私网字面量。资源文件/头像仍保留 50MB 读取上限。

## 测试约定

- 提交前 `flutter analyze` 零告警、`flutter test` 全绿。
- 涉及真实 DB I/O 的 widget 测试用 `tester.runAsync` 包裹(见 `test/ui/provider_edit_screen_test.dart`)。
- 测试文件用 `//` 文件头说明覆盖目标,不强制 `library;`;用例名用中文描述行为。
- QuickJS 不可用时 hook 求值测试自动跳过(预期行为);生图插件 JS 测试必须真实执行,见上文「生图插件」。

## 内容红线(开源仓库)

- 内置默认提示词(`prompt_seeds.dart`/`hook_seeds.dart`/`image_prompt_guide.dart`/`image_style_preset.dart`/`background_agent.dart` 的工具契约)必须是本项目原创的中性创作辅助内容;不接受破限/越狱指令、露骨成人素材、未授权第三方文本。
- 不硬编码任何可用密钥、鉴权绕过头或用户不可配置的第三方端点;默认种子仅允许无密钥、可编辑的示例 provider,端点由用户在设置页配置。

## 提交约定

- 约定式提交(`feat:` / `fix:` / `test:` / `refactor:` / `docs:` / `chore:`),中文描述;不附署名尾注。
- **提交前必须同步文档**:代码变更在提交前把对应内容更新到 `CHANGELOG.md`(Keep a Changelog 格式,Unreleased 段)。`docs/ARCHITECTURE.md` 记录当前架构、不变量与已知局限,仅当批次改变架构或现状时更新对应行。纯文档提交除外。
- **注释规范**:文件头、公共 API 文档、实现注释与版式的统一要求见 `CONTRIBUTING.md` 的「注释规范」;注释只解释为什么与约束,不逐行复述代码。

## 常用命令

- 测试:`flutter test`;单测某目录:`flutter test test/backend`
- 静态检查:`flutter analyze`(要求零告警)
- 锁文件:若本地设置了 `PUB_HOSTED_URL` 镜像,提交前执行 `PUB_HOSTED_URL=https://pub.dev flutter pub get`,确保 `pubspec.lock` 只含 pub.dev 地址;CI 会拒绝镜像 URL。
- 发布:推送与 `pubspec.yaml` 版本一致的 `v*` tag 触发 `.github/workflows/release.yml`;Android 签名密钥只存 GitHub Secrets,流程见 `CONTRIBUTING.md`「发布」。
- 发布签名初始化:`tool/setup_android_signing.sh`(`gh` 已登录,密码交互输入)。

## 文档索引

- 架构与开发说明:`docs/ARCHITECTURE.md`
- 变更记录:`CHANGELOG.md`
- 用户入口:`README.md`(中英双语)
- 贡献流程:`CONTRIBUTING.md`
- 隐私与安全:`PRIVACY.md` / `SECURITY.md`
- 生图插件示例:`examples/image_plugins/`
