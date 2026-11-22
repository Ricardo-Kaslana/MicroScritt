# 图片文件资产方案

## 目标与决策

图片字节统一存入应用私有文件目录，按 SHA-256 内容寻址；SQLite 只保存哈希、元数据和业务引用，不再保存 base64 或 BLOB。base64 仅存在于生图插件、第三方角色卡与旧归档等外部协议边界。

项目处于内测阶段，不保留旧图片列或双轨存储。schema 直接升级为 v73，旧库仍按既定规则归档后按基线重建。

核心目标：

- 删除数据库分块读取、base64 字符串拼接与解码的主渲染链路。
- 通过内容哈希去重，重复消息、头像和归档导入只保存一份原图。
- 聊天气泡读取显示尺寸预览，全屏才读取原图。
- 业务行与引用计数同事务更新，文件延迟回收，支持撤销与失败回滚。
- 会话归档升级为流式 ZIP v5，保留 v4 JSON 只读导入。

## 目录与文件

资产根目录与数据库同级：

```text
images/
  original/ab/cd/<sha256>
  preview/ab/<sha256>-v1-1600.jpg
  preview/ab/<sha256>-v1-1600.png
  tmp/<uuid>.part
```

原图不可变，路径只由哈希生成。格式由 magic bytes 和实际解码结果确定，不信任 Content-Type、扩展名或归档提供的路径。预览文件包含算法版本，可整体重建；有引用的原图不得作为缓存自动清理。

## 数据模型

新增 `image_assets`：

```sql
CREATE TABLE image_assets (
  hash TEXT PRIMARY KEY,
  byte_size INTEGER NOT NULL,
  mime TEXT NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  ref_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
```

业务列替换：

| 旧列 | 新列 |
| --- | --- |
| `messages.image_base64` | `messages.image_hash` |
| `characters.avatar_base64` | `characters.avatar_hash` |
| `characters.background_base64` | `characters.background_hash` |
| `user_profile.avatar_base64` | `user_profile.avatar_hash` |

`messages.image_url` 与 `messages.image_prompt` 保留。`lib/models/` 提供中立 `ImageRef`，Engine、UI 与持久化层通过它对接，不传递文件路径拼接逻辑或 base64。

## 写入与引用事务

新增资产按以下顺序执行：

1. 字节流写入唯一临时文件，同时计算 SHA-256、字节数并执行大小限制。
2. 校验真实图片格式、像素总量与边长。
3. 原子重命名到内容寻址路径；同哈希并发写入只保留一个最终文件。
4. `INSERT OR IGNORE image_assets` 元数据。
5. 在业务数据库事务中写业务行并增加 `ref_count`。

后续步骤失败时清理临时文件，未引用原图交给延迟 GC。

替换图片在同一事务中执行「增加新引用 → 更新业务行 → 释放旧引用」。删除消息、清图、删除会话或角色同样在业务事务内减少引用。SQLite 事务内不物理删除文件。

撤销快照只保存哈希；未引用原图有 24 小时宽限期，正常时长的导出不会与物理回收竞态。AI 制卡草稿在 JSON 中记录自身持有的哈希清单，成功落盘后按差集事务对账；重复重写不重复 acquire，重启恢复直接接管清单。应用、丢弃和删除角色时，只有草稿清理成功后才释放对应引用。

零引用资产经过 24 小时宽限期后才允许物理删除。启动时先按业务表与每份制卡草稿的真实持有重算引用计数，再清理临时文件、裁剪预览并回收零引用原图；草稿扫描或对账失败时本轮跳过回收。回收与同哈希 put 通过进程内串行区协调，避免重新写入并 acquire 后原图仍被旧回收任务删除。

原文件缺失时 UI 使用 URL 回退或重生成入口，不崩溃。URL 回退下载或磁盘缓存拿到字节后，只有内容哈希与消息引用一致才回填本地资产；哈希不一致说明远程内容已变化，只展示不改写业务行。

## 各业务链路

### 聊天生图

`ImageBackend` 不 import 持久化层。插件 base64 在 Backend 边界解码为字节；URL 通过标准 Dart 流/sink 流式下载；Orchestrator 负责资产化并调用消息仓储。

每条图片消息仍独立追加一行。重绘原地替换 hash。多图逐张处理，全部失败才返回图片错误。图片字节和哈希不进入 LLM 上下文。

### 角色、用户与制卡

头像规范化为长边不超过 1024，背景不超过 2048；解码同时限制目标宽高。`CharacterCard.toStorageJson()` 继续剥离顶层与 `data.avatar`，标准 V3 `assets[*].uri` 中的 data image 也资产化。未知扩展不盲目改写，但不得借未知字段写入超大内嵌图片。

制卡草稿只保存 hash,并以 `heldAssetHashes` 记录自身持有的引用；成功落盘后按目标差集对账,重启恢复直接接管,不重复 acquire；应用、丢弃和删除角色时释放对应引用。

### URL-only 图片

消息只有 `image_url` 时仍先走远程渲染；首次从网络下载或磁盘缓存命中后，字节按内容哈希并入资产库并写回 `messages.image_hash`，URL 保留作本地资产被删除后的回退。已有哈希的消息只做内容一致的回填，绝不改指向另一张图。`DiskImageCache` 继续保留 256MiB LRU，只服务尚未资产化的首次加载与回退路径。

## 渲染与预览

聊天图片优先读取 preview，没有预览时先以原图降采样显示并在后台生成预览。预览长边 1600；不透明图片使用 JPEG，透明图片使用 PNG，编码在后台 isolate。预览总量超过 256MiB 时按文件修改时间从旧到新自动淘汰，复用已有预览不触发全目录扫描。全屏读取原图，最大解码边长仍为 2560。

保留 `cacheWidth/cacheHeight`。删除 base64 原始字节 LRU，解码帧由 Flutter ImageCache 管理。头像不额外生成预览文件，继续使用 384/768 解码宽度；角色编辑、用户资料和制卡审阅统一使用基于 hash 的 provider/FileImage。

## 大小与安全限制

| 项目 | 上限 |
| --- | ---: |
| 原始图片 | 16MiB |
| 解码像素 | 40MP |
| 单边尺寸 | 8192px |
| 单次生图 | 1–6 张 |
| 普通选图文件 | 50MiB，规范化后资产化 |

仅接受 PNG、JPEG、WebP、GIF。URL 下载同时执行 Content-Length 预检和流式计数。插件 HTTP body 上限同步调整以承载原始字节上限对应的 base64。超限、损坏或伪装图片明确失败，不落库。

## 会话归档 v5

默认导出 `.msarc` ZIP，采用流式 STORE，避免已压缩图片的无效再压缩和整包内存占用：

```text
meta.json
messages.ndjson
assets/<sha256>
```

`meta.json` 保存版本、会话、角色与变量权限；`messages.ndjson` 每行一条消息，图片只存 hash；`assets/` 每个引用资产只写一次。

导入先验证结构、路径安全、引用闭合、大小和哈希，再写业务数据。重复资产直接增加引用。取消或失败回滚本次会话、角色、引用与临时文件。拒绝绝对路径、`..` 和路径穿越。导入可选择「仅文本」：跳过资产解包与校验，消息的图片哈希/URL/生成描述与角色头像/背景全部清空（保留 URL 会让气泡继续渲染远程图片并被回填资产库），正文为空的图片消息整条略过（不留空气泡），业务状态照常恢复。

v4 JSON 只保留导入适配器，导入时流式 base64 解码并资产化，不再提供 v4 导出。

## 存储治理

设置页展示数据库、原图、预览和到期零引用资产大小。「按会话查看」按占用字节列出各会话的去重资产数、图片消息数与大小（同一图片跨会话重复引用分别计入）。「整理存储」依次回收到期零引用原图、清理临时文件与全部可重建预览，并执行 SQLite VACUUM；有引用的原图保留。

「压缩新图片」为可选设置，默认关闭（schema v73）；开启后新入库且长边超过 2048px 的图片在写入前重编码，GIF 保留动画、透明图保持 PNG，压缩后反而更大时保留原图。只影响之后的写入，已有原图与业务哈希不回溯；归档导入与按内容哈希修复显式跳过压缩，保证 `assets/<sha256>` 文件名与消息引用始终一致。

## 测试与验收

覆盖资产去重、并发写入、回收与同图重新 acquire 的竞态、启动维护、统计与整理、追加/重绘/清图/删除/撤销引用、宽限期、草稿持久引用与重启接管、文件缺失、预览更新、角色卡与草稿、v5 往返与取消回滚、v4 导入、URL 超限、伪装图片与窄长图、URL-only 资产化、按会话统计、仅文本导入、入库压缩开关与设置水合。设置区块另有 widget 测试;插件 JS 测试继续经真实 QuickJS/Node 执行。

完成标准：

- 数据库不再包含图片字节，内部主路径不再传递 base64。
- 同一图片重复导入多次仍只有一个原图文件。
- 单图与归档处理内存有明确上限。
- `flutter analyze` 零告警，`flutter test` 全量通过。
- 同步更新 AGENTS.md、ARCHITECTURE.md 与 CHANGELOG.md。
