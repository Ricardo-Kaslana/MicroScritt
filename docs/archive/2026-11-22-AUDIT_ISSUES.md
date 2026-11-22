# 代码审计问题清单

> 审计日期:2026-11-21
> 基线:`main` @ `84e465f`,工作区干净;`flutter analyze` 0 告警,`flutter test` 1909 通过 / 5 跳过
> 说明:本清单是修复台账。严重度按「数据正确性 > 用户可直接触发的数据丢失 > 安全/资源 > 功能不可达 > 体验」排序。
> 状态:`[ ]` 待修复,`[x]` 已修复并验证,`[-]` 确认不修(附原因)。
> 修复完成:2026-11-22。P0–P3(含后续补充的索引与列表字段编辑)已全部修复;`P3-23`/`P3-27` 并入其他项,`TBD-*` 已附处置结论。修复后基线:`flutter analyze` 0 告警,`flutter test` 2012 通过 / 6 跳过。

## 严重度图例

| 级别 | 含义 |
| --- | --- |
| P0 | 可直接造成不可逆数据丢失、跨会话数据污染或核心功能永久不可用 |
| P1 | 高危:常见操作可触发数据丢失/成本放大,或关键功能不可达、安全边界失效 |
| P2 | 中危:特定并发/异常路径下的错误、用量失真、性能或生命周期问题 |
| P3 | 低危:边界容错、统计口径、可维护性、防御性加固 |
| TBD | 需实机或真实上游验证后才能定性 |

---

## P0 严重

- [x] **P0-01 重新生成/重新发送连带删除压缩摘要,早期剧情永久退出上下文**
  - 位置:`lib/data/message_repository.dart:833-866`、`:1075-1106`;`lib/engine/compact_service.dart:120-132`;`lib/state/chat_controller_pipeline.dart:510-538/550-594/889-916/1269-1273`
  - 触发:长会话已压缩后,对摘要之前的回复「重新生成」或对早期用户消息「重新发送」。
  - 影响:摘要被 `seq >=` 条件删除,被折叠行仍 `is_compacted=1` 且不会再被摘要规划,模型永久遗忘该段历史;`compact_of` 悬空。
  - 修复:`deleteFrom` 事务内收集被删 system 摘要,删除后把指向这些摘要的存活行恢复为未折叠,保证历史可重新摘要。

- [x] **P0-02 流式期间切换会话,旧流写入新会话并锁死发送**
  - 位置:`lib/state/chat_controller_session.dart:43-48`;`lib/state/chat_controller_pipeline.dart:923-1334`;`lib/state/chat_controller_context.dart:101-108`;`lib/state/chat_controller_background.dart:13-16`
  - 触发:发送后返回列表/侧栏切到另一会话;旧会话流式收尾晚到。
  - 影响:A 的消息/草稿覆盖 B;A 的记忆写入 B 的 `frozenMemory` 并进入 B 的请求;后台以 B 的 sessionId + A 的 seq 启动;`_busy` 卡住 B 发送。
  - 修复:`load` 取消主写令牌并递增主写代次;发送/生成管线全部 await 后校验 `(sessionId, epoch, token)`;上下文/记忆/世界书刷新同样校验;用量按捕获的 sessionId 记账。

- [x] **P0-03 AI 制卡工作台同进程内永久卡 busy**
  - 位置:`lib/state/card_studio_controller.dart:97-98/372/875-888`;`lib/state/card_studio_state.dart:155-161`;provider 为非 autoDispose(`:1389-1392`)
  - 触发:在 preparing/running/applying 期间退出制卡页。
  - 影响:再次进入 `start()` 被 `if (state.busy) return` 挡住,phase 永远停留,草稿恢复被跳过,只能重启应用。
  - 修复:引入工作台会话代次;`detach` 递增代次并取消令牌;`start` 区分「本页在飞」与「上一页遗留」,遗留时复位;所有异步续体校验代次。

---

## P1 高危

- [x] **P1-01 历史中段「重新生成/重新发送」无确认,无撤销,且两个菜单项同名**
  - 位置:`lib/ui/chat/chat_screen_messages.dart:308-341`;`lib/state/chat_controller_pipeline.dart:510-524/889-908`
  - 影响:误触即物理删除其后全部消息;文本重生成与图片重绘都叫「重新生成」。
  - 修复:非最新条时弹确认并显示将删除条数;图片项改名「重新生成图片」;保留单条删除的撤销语义。

- [x] **P1-02 Provider 编辑页按 `id == 0` 匹配未保存模型**
  - 位置:`lib/ui/provider_edit_screen.dart:183-210`;`lib/models/llm_provider.dart:54-55`
  - 影响:编辑/删除一个新建模型会覆盖或删除全部未保存模型。
  - 修复:按对象身份或临时唯一键匹配,不再用 0 作唯一键。

- [x] **P1-03 会话装载窗口内发送被受理但输入被清空**
  - 位置:`lib/state/chat_controller_pipeline.dart:695-742`;`lib/ui/chat_screen.dart:523-547`
  - 影响:`trySend` 返回 true,UI 清空输入,管线因 `sessionId == null` 空跑,输入静默丢失。
  - 修复:`trySend` 校验会话/角色/后端就绪与 `busyCommand`/`regeneratingImageId`,不就绪返回 false 并提示;装载失败要有错误态。

- [x] **P1-04 「切换备用模型」按钮完全未接线**
  - 位置:`lib/ui/chat_screen.dart:1067-1100`;`lib/ui/widgets/chat_island.dart:164-183`;控制器 `chat_controller_pipeline.dart:634`
  - 影响:已实现的备用模型建议动作在 UI 不可达。
  - 修复:传入 `onSwitchFallbackModel` 回调并补测试。

- [x] **P1-05 `loadOlder` 跨会话无归属校验**
  - 位置:`lib/state/chat_controller_session.dart:162-199`
  - 影响:旧会话一页历史前拼进新会话,并改写 `_windowFloor`。
  - 修复:捕获会话/代次,await 返回后校验。

- [x] **P1-06 删除尾部消息后 `_windowFloor` 不重算**
  - 位置:`lib/state/chat_controller_session.dart:185`;`lib/state/chat_controller_pipeline.dart:519/905/1278`;`lib/data/message_repository.dart:230-239`
  - 影响:聊天页空窗口、无法补页,重新生成被「最后一条不是 user」提前返回。
  - 修复:删除/清空后重置窗口下界并重算 `canLoadOlder`;刷新路径更新分页状态。

- [x] **P1-07 配置文件快照写无串行队列,并发保存可用旧文件覆盖新库**
  - 位置:`lib/data/app_config_file.dart:130-141`;`lib/state/app_config_sync.dart:30-38`;对照 `ui_prefs_file.dart`/`card_studio_draft_file.dart`
  - 影响:共享 `$path.tmp` 互相覆盖;快照跨多次查询无一致性;后完成的旧写入删除新 dirty,重启时旧文件覆盖新库。
  - 修复:已实现写队列、写入代次与独立标脏版本,只有最后一棒可删 dirty;快照仍跨多次查询读取(各配置写点自身均为事务,混合窗口很窄),单读事务视图记为已知局限。

- [x] **P1-08 legacy 后台 `imagePrompts` 数量无上限且全部并行付费生图**
  - 位置:`lib/engine/background_engine.dart:1830-1842`;`lib/engine/orchestrator.dart:457-519/1234-1236`
  - 影响:模型可返回任意数量描述,`Future.wait` 全并行发起生图并逐条落库,成本无界。
  - 修复:按 `imageCount` 截断并记录告警;限制生图并发(与 agentic 校验口径一致)。

- [x] **P1-09 Anthropic 用量口径错误,缓存命中率可超 100%**
  - 位置:`lib/models/token_usage.dart:45-52`;`lib/ui/context_panel.dart:800-816`;`lib/state/chat_controller_pipeline.dart:1287-1306`
  - 影响:总输入应为 `input + cache_read + cache_creation`;当前命中率/上下文圆环失真,debug 下进度条断言崩溃。
  - 修复:按官方语义求和;命中率分母用总输入;更新测试 fixture。

- [x] **P1-10 终局帧后不结束读取,keep-alive 网关空等 120s**
  - 位置:`lib/backend/openai_backend.dart:203-207`;`lib/backend/anthropic_backend.dart:348-365`;`stream_timeout.dart`
  - 影响:已完成请求 120s 后误报超时,Done/Usage 丢失,agent 工具轮重试并重复计费。
  - 修复:收到 `[DONE]`/`message_stop`/流内 error 后 `break`;超时重试分支补 `!sawError`。

- [x] **P1-11 连接超时先关闭 client 再透明重试,重试必然失败**
  - 位置:`lib/backend/openai_backend.dart:154-166/388-399`
  - 影响:「零正文透明重试」从不生效,最终以未分类流错误暴露。
  - 修复:client 生命周期收敛到整次 generate,或重试前重建;测试 client 不再用 no-op close 掩盖。

- [x] **P1-12 Anthropic「测试连接」不透传 max_tokens,必然误报配置缺失**
  - 位置:`lib/ui/provider_edit_screen.dart:265-277`;`lib/backend/anthropic_backend.dart:76-85`;`lib/backend/llm_probe.dart:128-130`
  - 影响:Anthropic 探测 100% 失败并提示去补已填的字段。
  - 修复:探测请求带模型的最大输出 tokens;system 发送非空最小内容;补 Anthropic 探测测试。

- [x] **P1-13 URL 图片下载无大小/类型限制,默认跟随重定向,可盲 SSRF**
  - 位置:`lib/backend/image_downloader.dart:25-47`;`lib/backend/plugin_image_backend.dart:404-409`;`lib/import/session_importer.dart:811-816`;`lib/ui/widgets/message_bubble.dart:1024-1036`
  - 影响:整包缓冲可 OOM;插件 `done.url`/导入 URL 绕过 origin 白名单;重定向可访问内网。
  - 修复:流式读取并设字节上限;禁止重定向或逐跳校验;校验 content-type;拒绝私网/环回;导入来源不自动联网。

- [x] **P1-14 入库压缩在尺寸校验前整图解码,可 OOM**
  - 位置:`lib/data/image_asset_store.dart:106/174-204`;`lib/data/image_compressor.dart:20`
  - 影响:16MiB 高压缩比图在 `decodeImage` 阶段打穿内存。
  - 修复:先读文件头校验边长/像素,再做受控解码;预览解码按目标尺寸降采样;限制并行解码数。

- [x] **P1-15 PNG 文本块仅单块限额,累计解压可 OOM**
  - 位置:`lib/import/png_chunk_reader.dart:25/81-114/136-167`
  - 影响:小文件多块高压缩 zTXt 可产生 GB 级字符串;且不校验 CRC。
  - 修复:全局解压字节预算 + 块数量/总文本长度上限,超限判坏卡;可选 CRC 校验。

- [x] **P1-16 v5 `messages.ndjson` 无单行长度与条数上限**
  - 位置:`lib/import/session_importer.dart:463-492`;`lib/import/json_stream_reader.dart:142-149/396-413`
  - 影响:单行可 OOM;海量消息可长时间写库/膨胀数据库;v4 头部值同样无上限。
  - 修复:单行字节上限、消息总数上限、v4 值大小上限,超限在预检阶段失败。

- [x] **P1-17 `readDraft(entryId)` 只读世界书正文前 2000 字且无条目正文分页**
  - 位置:`lib/engine/card_studio/card_agent.dart:54-55/259-279`;提示词 `:866-871`
  - 影响:模型基于截断视图重写长条目会静默丢后文。
  - 修复:增加 `contentOffset/contentLimit` 分页,或在正文超限时拒绝重写并提示分页读取。

- [x] **P1-18 工具结果 4000 字符硬截断,多条 JSON 路径未做预算**
  - 位置:`lib/engine/agent/agent_runner.dart:111/352-355`;`lib/engine/card_studio/card_agent.dart:265-330`;`lib/engine/background_agent.dart:286-299`
  - 影响:合法 JSON 被截成半截,模型重试烧 token,甚至整轮失败。
  - 修复:所有返回 JSON 的工具统一走 payload 预算/分页;硬帽改为按结构安全截断。

- [x] **P1-19 后台轮早退分支不写终态,`backgroundStatus` 永久 running**
  - 位置:`lib/state/chat_controller_background.dart:411-416/584-598/837-860`
  - 影响:状态面板/灵动岛永远显示维护中,停止键无效。
  - 修复:所有早退/空转分支写终态;finally 在 owned 且无终态时兜底;`interrupt()` 无在飞轮时同步恢复。

- [x] **P1-20 桌面 `.part` 替换先删目标再 rename,失败时新旧文件同时丢失**
  - 位置:`lib/ui/common/session_file_helper.dart:200-211`
  - 影响:旧归档已删、staging 被 finally 清理,用户同时失去两份数据。
  - 修复:旧目标先 rename 为 `.bak`,staging 成功后删 bak,失败回滚;或保留 staging 供恢复。

- [x] **P1-21 配置导入解析在 try 外,且校验前写 `.dirty`,失败后覆盖用户文件**
  - 位置:`lib/ui/settings/settings_actions.dart:189-218/250-256`;`lib/data/app_config_file.dart:164-173`
  - 影响:坏文件无提示;失败后下次启动以库覆盖用户手改的配置文件。
  - 修复:选文件→解码→预览全部纳入 try;`markDirty` 移到校验通过之后;失败清理本次 dirty。

---

## P2 中危

### 数据与配置

- [x] **P2-01 会话/角色级联删除漏掉 `variable_trash` 与 `variable_deletion_proposals`**
  - 位置:`lib/data/session_repository.dart:192-216`;`lib/data/character_repository.dart:152-183`;DDL `database_schema.dart:178-199`
  - 修复:两个级联事务补删两表(按 session_id);补测试。

- [x] **P2-02 消息缓存失效时机不完整:写方法先失效后提交,级联删除绕过缓存**
  - 位置:`lib/data/message_repository.dart:26-46/814-829/918-937/944-967/1075-1106`;级联删除两处
  - 修复:事务提交后再失效;提供公开的按会话失效入口供级联删除调用;查询加读取代次防旧快照回填。

- [x] **P2-03 配置批量应用可删除仍被 `image_providers` 引用的自定义插件**
  - 位置:`lib/data/app_config_file.dart:289-316/443-449`;`lib/data/image_plugin_repository.dart:102-154`
  - 修复:应用前做反向引用校验;批量替换与单条删除都拒绝删除在用插件。

- [x] **P2-04 `ImagePluginRepository.delete` 的检查后删除非原子**
  - 位置:`lib/data/image_plugin_repository.dart:139-154`
  - 修复:检查与删除放入同一事务,或条件 DELETE 并校验受影响行数。

- [x] **P2-05 图片资产回收先删元数据再删文件;rename 后插入失败留下孤儿**
  - 位置:`lib/data/image_asset_store.dart:215-237/380-405`
  - 修复:先删文件成功再删元数据;单文件失败不中断整轮;插入失败删除已落位文件;增加孤儿文件清扫兜底。

- [x] **P2-06 后台重试与解析失败的 token 用量被丢弃**
  - 位置:`lib/engine/background_engine.dart:385-446/513-645/776-810`;`lib/engine/orchestrator.dart:463-510`
  - 修复:跨尝试累加用量;失败结果携带已计量 usage 并统一入账。

- [x] **P2-07 后台取消轮与 CAS 冲突轮不记用量**
  - 位置:`lib/engine/background_engine.dart:752-762`;`lib/state/chat_controller_background.dart:773-790`
  - 修复:取消/冲突分支写 `reported:false` 记录并尽量带回 partial usage。

- [x] **P2-08 压缩预算只算对话行,`cutSeq` 会拆开附件与所属用户消息**
  - 位置:`lib/engine/compact_service.dart:120-132`;`lib/state/chat_controller_pipeline.dart:70-78/206-214`
  - 修复:预算计入附件;切割点下移到首个保留对话行前导附件组之前。

- [x] **P2-09 关闭自动压缩后发送前硬挡检测与机械截断兜底完全消失**
  - 位置:`lib/state/chat_controller_pipeline.dart:29-30`;`lib/models/app_settings.dart:197-201`
  - 修复:硬挡预算检测恒开,仅 LLM 摘要部分受开关控制;`foldToFit` 始终可用;统一三处文案。

- [x] **P2-10 SSE 边界容错:多行 data 必然失败,非对象 JSON 走未分类异常**
  - 位置:`lib/backend/sse_parser.dart:22-35`;`lib/backend/openai_backend.dart:208-220`;`lib/backend/anthropic_backend.dart:265-277`
  - 修复:非对象 JSON 归契约错误;多行 data 兼容;仅去掉一个前导空格。

- [x] **P2-11 非 2xx 错误体读取无超时和大小上限**
  - 位置:`lib/backend/openai_backend.dart:169`;`lib/backend/anthropic_backend.dart:227`
  - 修复:idle 超时包裹错误体读取并限制字节数。

- [x] **P2-12 OpenAI tool_calls 缺 index 时多个调用被合并;Anthropic start 块 input 未读取**
  - 位置:`lib/backend/openai_backend.dart:262-284/488-498`;`lib/backend/anthropic_backend.dart:284-299`
  - 修复:缺 index 时按 id 建槽;新非空 id 新建;重复完整块覆盖;start 块 input 作 fallback。

- [x] **P2-13 失败/取消时 ErrorEvent 先于 UsageEvent,已计量用量归零**
  - 位置:`lib/backend/openai_backend.dart:411-429`;`lib/backend/anthropic_backend.dart:392-401`;`lib/engine/agent/agent_transport.dart:92-107`;`lib/engine/background_engine.dart:708-717`
  - 修复:先发 UsageEvent 再发 ErrorEvent;或失败落定前合并最后一次快照。

- [x] **P2-14 上下文超长 400 被归类为契约漂移;流内确定性错误会重试**
  - 位置:`lib/backend/upstream_error.dart:127-145`;`lib/state/chat_controller_pipeline.dart:1163-1184`;`lib/engine/agent/agent_runner.dart:215-223`
  - 修复:新增上下文超长分类并提示压缩;流内无状态码 invalid_request 归非瞬态。

- [x] **P2-15 正常收尾的零正文空回静默失败**
  - 位置:`lib/backend/openai_backend.dart:325-379`;`lib/backend/anthropic_backend.dart:348-365`;`lib/state/chat_controller_pipeline.dart:1312-1316`
  - 修复:正常收尾且无正文/推理/工具调用时补 contentFlag/契约错误。

- [x] **P2-16 Anthropic thinking/redacted_thinking 回放顺序错乱**
  - 位置:`lib/backend/anthropic_backend.dart:288-326`
  - 修复:按块 index 统一暂存,message_stop 时按 index 排序回放。

- [x] **P2-17 配置导入文件解析在 try 之外(同 P1-21 的解析部分)**
  - 位置:`lib/ui/settings/settings_actions.dart:189-205`
  - 修复:纳入统一 try/catch 并提示。

### 图片

- [x] **P2-18 压缩「长边 ≤2048」对竖图不成立,EXIF 旋转图会再放大**
  - 位置:`lib/data/image_compressor.dart:24-41`
  - 修复:按长边选择缩放轴,处理 EXIF 方向。

- [x] **P2-19 开启压缩后 URL 回退的按哈希修复永不成功**
  - 位置:`lib/data/message_repository.dart:696`;`lib/engine/orchestrator.dart:1284-1286`
  - 修复:URL 入库统一 `compress:false`,与归档/修复口径一致。

- [x] **P2-20 头像/背景缩图按旧 base64 预算重编码:小图放大、边界误判、GIF 丢动画**
  - 位置:`lib/data/shrink_image.dart:67-108`;`lib/data/image_asset_input.dart:12-20`
  - 修复:文件入库去掉 base64 预算;`<=maxDim` 原样返回;禁止放大;GIF 保留原字节。

- [x] **P2-21 DiskImageCache 缓存任意 200 响应,坏图永不失效;失败 `.tmp` 泄漏**
  - 位置:`lib/backend/disk_image_cache.dart:146-156/199-207`;`lib/ui/widgets/message_bubble.dart:997-1062`;`image_viewer.dart:106-127`
  - 修复:写盘前校验图片魔数;解码失败删除缓存并允许重下;临时文件唯一化并清理。

- [x] **P2-22 插件 `stopWhen.regex` 在 UI isolate 同步执行,无超时**
  - 位置:`lib/backend/plugin_image_backend.dart:518-582`
  - 修复:匹配移入 isolate 或限制匹配窗口/时间预算。

- [x] **P2-23 制卡草稿单文件损坏被静默跳过,对账随后回收其独占图片**
  - 位置:`lib/data/card_studio_draft_file.dart:112-147`;`lib/data/image_asset_store.dart:323-327/782-825`
  - 修复:扫描报告「是否有文件失败」,有失败则跳过回收;或宽松提取 heldAssetHashes 兜底。

### 制卡与 Agent

- [x] **P2-24 无参工具空参数(`""`/`"null"`)被判非法,可触发 guardrail**
  - 位置:`lib/engine/agent/agent_action.dart:26-34`;`lib/engine/agent/agent_runner.dart:266-278/327-336`
  - 修复:空串/空白/字面 null 归一为 `{}`,仅非空畸形 JSON 判非法。

- [x] **P2-25 工具调用缺 id/name 时仍执行/回放,上游可能 400**
  - 位置:`lib/backend/openai_backend.dart:48-53/487-499`;`lib/engine/agent/agent_runner.dart:266-316`;`lib/backend/anthropic_backend.dart:290-292`
  - 修复:边界判协议错误并诊断,或为缺失 id 合成稳定 id;空 name 拒绝。

- [x] **P2-26 `setNextSuggestions([])` 无法清空且三次尝试会丢弃整轮暂存**
  - 位置:`lib/engine/background_agent.dart:955-971`
  - 修复:空数组语义化为清空,或返回语义拒绝而非 `AgentToolFailure`。

- [x] **P2-27 `validateStaged` 在严格删除模式下误报注入键将被丢弃**
  - 位置:`lib/engine/background_agent.dart:737-749`;`lib/engine/orchestrator.dart:696-704`
  - 修复:严格模式下计算 missing 不剔除仅暂存删除的键,或单独提示。

- [x] **P2-28 制卡应用前校验不覆盖 AI 侧上限,内联编辑可绕过**
  - 位置:`lib/engine/card_studio/card_diff.dart:639-655`;`lib/state/card_studio_controller.dart:566-578/665-676`;`lib/engine/card_studio/card_agent.dart:27-50`
  - 修复:提交校验复用字段/总量/条目上限,UI 编辑同样复查。

- [x] **P2-29 `setImagePrompts` 少于 `imageCount` 仍提交并清掉待补机会**
  - 位置:`lib/engine/background_agent.dart:867-881`;`lib/engine/orchestrator.dart:718-734`;`lib/state/chat_controller_background.dart:725-727`
  - 修复:finish 前按目标数量终裁;不足时保留待补机会或明确拒绝。

- [x] **P2-30 制卡头像提示词账本与图片哈希脱钩**
  - 位置:`lib/state/card_studio_controller.dart:307-309/390-468/619-650/1141-1170`
  - 修复:`_generatedAvatarPrompt` 与生成的 avatarHash 成对记录;生成中继续调整时先取消并清空账本。

- [x] **P2-31 `CardStudioController.apply` 的 applying 置位晚于两次 DB await,可双击重入**
  - 位置:`lib/state/card_studio_controller.dart:655-707`;`lib/state/card_studio_state.dart:209-213`
  - 修复:入口同步置 applying 或自增代次,重入拒绝。

- [x] **P2-32 `startWithGreeting` 无重入门控,双击重复落库/与发送竞争乱序**
  - 位置:`lib/state/chat_controller_commands.dart:40-59`
  - 修复:入口同步置 busy 或专用标志,完成后 finally 复位;事务内复查仍为空。

- [x] **P2-33 会话装载窗口内发送被吞(同 P1-03)**
  - 位置:`lib/state/chat_controller_pipeline.dart:695-742`
  - 修复:同 P1-03。

### 导入导出

- [x] **P2-34 导出 meta.json 无体积核算,导入端 64MiB 硬限,大卡备份无法恢复**
  - 位置:`lib/export/session_archive_writer.dart:111-167`;`lib/import/session_importer.dart:49/312-314`
  - 修复:导出前按同一上限核算并明确报错,或把大字段移出 meta/流式解析。

- [x] **P2-35 `depth_prompt.prompt` 缺失被解析成字符串 `"null"` 并写回导出**
  - 位置:`lib/models/character_card.dart:135/410-415`
  - 修复:仅接受字符串,缺失回落空串。

- [x] **P2-36 会话导入不重映射附件行 `refId`,id 碰撞会错误抑制注入**
  - 位置:`lib/import/session_importer.dart:794-827`;`lib/data/message_repository.dart:971-1002`;`lib/state/chat_controller_pipeline.dart:806-861`
  - 修复:导入丢弃或按名称重建附件 `ref_id`;至少校验同名条目。

- [x] **P2-37 仅文本导入时 `compact_of` 可能写成 `-1`**
  - 位置:`lib/import/session_importer.dart:895-930`;`lib/data/message_repository.dart:1007-1025`
  - 修复:`linkCompactOf` 跳过 `rowIds <= 0`。

### 状态与 UI

- [x] **P2-38 上下文/冻结记忆/世界书刷新在 await 后不校验会话身份**
  - 位置:`lib/state/chat_controller_context.dart:101-108/243-282`
  - 修复:捕获 `(sessionId, epoch)` 后校验再写 state。

- [x] **P2-39 后台开关先改内存后落库且无异常处理**
  - 位置:`lib/state/providers.dart:302-361`;调用 `lib/ui/status_screen.dart:209-230/312-322`
  - 修复:先落库再改内存(或失败回滚)并提示。

- [x] **P2-40 配置导入后桌面「用户」表单不同步,保存会覆盖导入值**
  - 位置:`lib/ui/user_profile_form.dart:47-55/89-106`;`lib/ui/settings/settings_actions.dart:154-175`;`settings_desktop_screen.dart:63-74`
  - 修复:监听 provider,非编辑态同步 controller 与初始值。

- [x] **P2-41 变量行内编辑目标被后台删除后工作区卡死**
  - 位置:`lib/ui/status/status_variables_workspace.dart:455-467/197-229/569-571`
  - 修复:编辑目标不存在时自动取消编辑,或编辑态固定渲染目标行。

- [x] **P2-42 桌面侧栏对全量聚合 provider 过度失效**
  - 位置:`lib/ui/chat_screen.dart:830-837`;`lib/state/chat_controller_session.dart:30-35`;`lib/state/providers.dart:443-467`
  - 修复:分页仅同步条数基线不失效全局聚合;按角色失效或拆分预览刷新。

- [x] **P2-43 会话重命名对话框在退场动画前 dispose 控制器**
  - 位置:`lib/ui/sessions_screen.dart:92/117-118`;对照 `chat_screen_overlays.dart:182-201`
  - 修复:controller 移入 dialog State 随路由销毁。

- [x] **P2-44 批量删除撤销 SnackBar 持有已销毁页面 ref**
  - 位置:`lib/ui/chat/chat_screen_messages.dart:92-102`;`lib/ui/common/app_snack_bar.dart:26`
  - 修复:await 前捕获 notifier 或安全回调。

- [x] **P2-45 回顶循环在页面销毁后仍写 ValueNotifier**
  - 位置:`lib/ui/chat/chat_screen_scroll.dart:290-346`;`lib/ui/chat_screen.dart:457`
  - 修复:finally 中检查 mounted 再写。

- [x] **P2-46 启动链(数据库/配置/偏好/草稿)无兜底,任一失败即无 UI 退出**
  - 位置:`lib/main.dart:34-65`
  - 修复:启动关键步骤 try/catch,渲染最小错误页/重试入口。

- [x] **P2-47 后台生图任务脱离轮次后不可取消,历史改写后仍落库旧会话**
  - 位置:`lib/engine/orchestrator.dart:512-519/1225-1371`;`lib/state/chat_controller_background.dart:195-226/1670-1705`
  - 修复:任务注入 `shouldCancel`/epoch,落库前检查;陈旧结果丢弃。

- [x] **P2-48 Hook 抛错时部分改写仍生效,`__hookError` 被剥离后无日志**
  - 位置:`lib/engine/hook_runtime.dart:43-61`;`lib/state/chat_controller_context.dart:16-28`
  - 修复:抛错时回滚到 hook 前上下文并记录错误。

---

## P3 低危

- [x] **P3-01 glossary 整词判定过宽,`C++`/`e.g.` 等词条永不命中**
  - 位置:`lib/engine/glossary.dart:76-80/104-106`;对照 `context_assembler.dart:608`
  - 修复:统一按 `[A-Za-z0-9_]+` 判定是否包裹 `\b`。

- [x] **P3-02 世界书附件按名字去重,同名不同条目可被永久排除**
  - 位置:`lib/state/chat_controller_pipeline.dart:811-817/858-862`;`lib/context/context_assembler.dart:466-491`
  - 修复:refId + 名字双键判定;冲突时用 `wb:<id>` 标签。

- [x] **P3-03 display_regex 无复杂度/超时保护,灾难性回溯可卡死 UI**
  - 位置:`lib/engine/display_regex.dart:28-67`;`lib/ui/widgets/rich_message_text.dart:455-477`
  - 修复:替换加长度上限/回溯预算,或编辑页拒绝嵌套量词。

- [x] **P3-04 上游错误体可能回显 Authorization,错误横幅未统一脱敏**
  - 位置:`lib/backend/openai_backend.dart:177-180`;`lib/backend/anthropic_backend.dart:235-239`;`llm_probe.dart:193-197`
  - 修复:错误文本统一脱敏 API Key。

- [x] **P3-05 `llm_probe` 成功路径不关闭 http.Client**
  - 位置:`lib/backend/llm_probe.dart:104-123/175-190`
  - 修复:探测结束统一 close。

- [x] **P3-06 `ChatEngine` 重建 `LlmRequest` 时漏传 `tools`**
  - 位置:`lib/engine/chat_engine.dart:22-33`
  - 修复:透传 tools。

- [x] **P3-07 max_tokens 边界:`'0'` 可产生 0 请求,超大数字串抛 UnsupportedError**
  - 位置:`lib/models/llm_units.dart:9-22`;`lib/ui/model_edit_sheet.dart:129-157`
  - 修复:要求 >0;解析有限数并给出可见错误。

- [x] **P3-08 高频筛选列缺索引(sessions.character_id/worldbook_entries.character_id/llm_models.provider_id/image_providers.plugin_id)**
  - 位置:`lib/data/database_schema.dart:22-38/79-101/126-158`
  - 修复:schema v75 在基线补四个索引。内测阶段无用户,旧库按既有单基线策略归档重建,不再顾虑迁移成本。

- [x] **P3-09 `usage_records` 归档回灌按旧 id `OR IGNORE`,失败重试期新增行可能冲突丢记录**
  - 位置:`lib/data/database.dart:246-291`
  - 修复:改按自然键去重(时间+provider+model+kind+数值),或回灌前删除未标记归档的冲突行。

- [x] **P3-10 `onDowngrade` 空操作,旧应用可写入更高版本 schema**
  - 位置:`lib/data/database.dart:137-143`
  - 修复:启动检测 `user_version > schemaVersion` 时拒绝打开并提示升级应用。

- [x] **P3-11 v1–v4 会话 JSON 不校验版本上限**
  - 位置:`lib/import/session_importer.dart:108-110`;`lib/import/json_stream_reader.dart:387-389`
  - 修复:只接受 1–4,版本类型错误直接失败。

- [x] **P3-12 角色卡顶层类型强转抛 TypeError,空名角色可导入**
  - 位置:`lib/import/character_card_importer.dart:57-61`;`lib/ui/character_screen.dart:119-146`;对照 `session_importer.dart:613-622`
  - 修复:类型校验 + 统一要求非空 name。

- [x] **P3-13 桌面导出文件名未清洗**
  - 位置:`lib/ui/common/export_helper.dart:57-64/146-148`;`lib/ui/common/session_file_helper.dart:173-184`
  - 修复:所有保存路径统一清洗非法字符。

- [x] **P3-14 `pickedFilePath` 内联字节兜底写出的临时归档永不清理**
  - 位置:`lib/ui/common/pick_file_bytes.dart:70-79`;`lib/ui/sessions_screen.dart:211/231-241`
  - 修复:放入受管理目录并在导入完成后 finally 删除。

- [x] **P3-15 v1–v4 base64 计数容忍空白但解码前不剥离,换行 base64 导致整档失败**
  - 位置:`lib/import/session_importer.dart:594-606`;`lib/data/image_codec.dart:14-26`
  - 修复:解码前删除所有空白。

- [x] **P3-16 预览 LRU 实为 FIFO,统计口径失真,清理会删在写 `.part`**
  - 位置:`lib/data/image_asset_store.dart:77-90/465-536/603-614`
  - 修复:命中时刷新 mtime;清理跳过 `.part` 并逐文件容错;统一统计口径。

- [x] **P3-17 制卡草稿资产账本在重叠保存时引用计数漂移**
  - 位置:`lib/state/card_studio_controller.dart:999/1024-1033`;`lib/state/card_studio_draft_assets.dart:15-31`
  - 修复:入队时同步更新目标集合,或队列内按执行时账本计算 diff。

- [x] **P3-18 QuickJS 超时只放弃 isolate 不终止,极端情况持续泄漏线程**
  - 位置:`lib/engine/js_hook_runtime.dart:59-99`
  - 修复:记录超时并熔断,或长驻 isolate + 可 kill 任务。

- [x] **P3-19 备用开场白/标签经文本投影往返会被拆条**
  - 位置:`lib/state/card_studio_controller.dart:566-578`;`lib/engine/card_studio/card_diff.dart:350-364/508-524`
  - 修复:审阅页对列表字段改用逐元素编辑底单(`showListEditSheet`),决策以 `FieldDecision.editedList` 保存,元素内部的换行/逗号原样保留;草稿编解码持久化该字段,旧草稿的文本投影编辑值仍兼容读取。

- [x] **P3-20 旧草稿恢复时重映射临时条目 id,审阅决策按旧 id 键控导致「拒绝」丢失**
  - 位置:`lib/state/card_studio_controller.dart:190-204/1277-1317`;`lib/engine/card_studio/card_diff.dart:579-604`
  - 修复:重映射时同步迁移决策,或决策改用内容稳定键。

- [x] **P3-21 消息气泡 ImageInfo 从不 dispose,换源失败继续显示旧帧**
  - 位置:`lib/ui/widgets/message_bubble.dart:858-934`
  - 修复:替换/dispose 时释放;onError 先清 `_info`。

- [x] **P3-22 多个编辑页保存异常无提示,部分页面缺未保存防护**
  - 位置:`provider_edit_screen.dart:148-168`;`image_provider_edit_screen.dart:474-511`;`character_edit_screen.dart:241-273`;`hooks_screen.dart:218-248`;`skills_screen.dart:210-249`;`prompt_items_screen.dart:271-308`;`regex_scripts_screen.dart:293-324`;`worldbook_screen.dart:376-421`;`user_screen.dart:11-26`
  - 修复:统一 catch + SnackBar;给缺失页面补 `UnsavedChangesGuard`。

- [-] **P3-23 后台功能注入选择无持久化提示等杂项(见下)**
  - 处置:本项并入各子系统修复,不单列。

- [x] **P3-24 `app_config` 应用时为 remap `background_model_id` 回写整份 AppSettings,并发时可回退他人设置**
  - 位置:`lib/data/app_config_file.dart:227/424-440`
  - 修复:仅更新 `background_model_id` 单列,不整份覆盖。

- [x] **P3-25 角色读取失败 fail-open 返回降级卡,保存可能覆盖原卡**
  - 位置:`lib/data/character_repository.dart:186-298`
  - 修复:读取失败向上抛,不返回可被保存的降级卡;或标记只读。

- [x] **P3-26 `updateWithWorldbook` 在角色不存在时仍写世界书孤儿行**
  - 位置:`lib/data/character_repository.dart:119-148`
  - 修复:更新受影响行数为 0 时回滚并报错/跳过世界书写入。

- [-] **P3-27 `llm_probe`/上游错误体密钥脱敏(同 P3-04)**
  - 处置:并入 P3-04。

- [x] **P3-28 多开场白角色新建会话后无法另选开场白**
  - 位置:`lib/ui/sessions_screen.dart:59-71`;`lib/ui/chat/chat_screen_sessions.dart:260-275`;`lib/ui/widgets/chat_empty_state.dart:105-160`
  - 修复:只有单条开场白才自动作为助手首条消息落库;有多条时新会话保持空态,首屏列 3 条并提供「查看全部开场白」底单,每次新会话都可重选,选择只写入该会话消息,不持久化选择状态。

---

## 待确认(需实机或真实上游验证)

- [-] **TBD-01 内置插件 8MB 响应体与 QuickJS 16MB 堆上限冲突**
  - 位置:`lib/backend/plugin_image_backend.dart:58-187/334-343`;`lib/engine/js_hook_runtime.dart:42-88`
  - 说明:Windows 桥接可能回退无内存上限档;需 Android/iOS 实机与大图网关验证。
  - 处置:本轮增加「插件求值内存上限可配置」的防御性参数,不改变默认行为;待真机回归。

- [-] **TBD-02 无参工具空参数在真实网关的触发率**
  - 说明:按 P2-24 已做兼容;触发率数据待线上观察。

- [-] **TBD-03 缺失 tool_call id 的网关触发率**
  - 说明:按 P2-25 已做边界校验;实际上游行为待观察。

- [-] **TBD-04 旧草稿决策键失配(仅旧版草稿可达)**
  - 说明:按 P3-20 已做迁移;历史草稿损坏样本待用户反馈。

- [-] **TBD-05 `character get/all` fail-open 是否符合产品预期**
  - 说明:按 P3-25 改为报错;若产品需要可用性优先需回退。

- [-] **TBD-06 后台生图保留语义(已计费图片是否必须保留)**
  - 说明:按 P2-47 增加取消;若产品要求保留,则仅丢弃陈旧回调状态、不取消落库。

- [-] **TBD-07 上游错误体回显 Authorization 的实际风险**
  - 说明:P3-04 已统一脱敏;无需实机。

- [-] **TBD-08 旧版应用打开更高 schema 库**
  - 说明:P3-10 已加拒绝逻辑;不需实机。

---

## 已核查未发现问题的关键点

- SQL 全部参数化,LIKE 已转义;DDL 与代码列一致;schemaVersion=74 与 22 张表基线一致。
- 变量删除流程:显式键名、事务内二次校验权限、回收站、单轮 5 个上限、严格模式提案均正确。
- ref_count 行级增减对称(消息增删/角色换图/用户换头像/导入导出),未发现负计数或行级泄漏。
- ZIP 读取:仅 STORE、拒绝 Zip64/加密/路径穿越/NUL/重复条目,CRC 与偏移校验完整;v5 预检顺序正确。
- Agent 取消语义、逐步用量 `reported` 标志、暂存原子性、CardStaging 负临时 id 与冲突检测整体正确。
- Hook `__ctx` JSON 往返类型保真、内部键剥离正确;并发求值隔离。
- 启动水合解析均 fail-safe;配置文件明文密钥为既定取舍。
