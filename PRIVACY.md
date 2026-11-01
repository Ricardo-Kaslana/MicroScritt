# 隐私说明 / Privacy

## 摘要

MicroScritt 不收集、不上传任何遥测数据;没有账号系统,也没有自有后端。所有
对话、角色卡、变量、图片与配置默认保存在你的设备上。

## 本地保存的数据

- 数据库:`microscritt.db`(会话、消息、角色卡、变量、记忆、提示词、Hook、
  provider 配置等)。
- 图片缓存与生成图:数据目录下的 `image_cache` 及消息内嵌图片。
- 配置文件:`microscritt-config.json`(用户名与 LLM provider,含**明文 API
  Key**)。
- UI 偏好:`ui-prefs.json`。

桌面端数据目录为 `~/.microscritt`(Windows 即 `C:\Users\<用户名>\.microscritt`);
移动端使用应用私有目录(Android/iOS 的应用数据区)。卸载应用或删除数据目录
会移除本地数据;请先自行导出需要保留的会话。

## 网络请求

应用只向**你自己配置的** LLM 与生图端点发起请求,发送内容可能包括系统提示词、
对话历史、角色卡信息、变量、生图提示词与参考图。生图结果如为 URL,应用会从
该 URL 下载图片并保存到本地。除此之外,应用不向任何服务器发送数据;第三方
端点如何处理这些数据,取决于其隐私政策与服务条款。

## API Key

API Key 以明文形式保存在本地 SQLite 与 `microscritt-config.json` 中,并在请求
时发送给你配置的端点。请限制数据目录的访问权限,不要提交、上传或分享配置
文件、数据库与导出归档。

## 导出与分享

会话归档、角色卡 JSON/PNG、配置导出可能包含聊天内容、图片、角色设定与 API
Key。分享前请自行检查并脱敏。

## 日志与诊断

应用不自动上传日志。错误横幅可能显示上游返回的错误文本;这些信息仅在本机
界面中展示,除非你主动复制或分享。

## 儿童与 AI 内容

本应用不是面向儿童的产品。AI 生成内容可能不准确或不符合预期,请自行判断并
遵守所配置服务的条款与当地法律。

## 变更

本说明会随应用行为变化更新;重要变更会记录在 `CHANGELOG.md`。

## English summary

MicroScritt collects no telemetry and has no account or backend. Chats, cards,
variables, images and configuration stay on your device. The app only contacts
the LLM and image endpoints you configure; those providers' privacy policies
apply. API keys are stored in plaintext locally, and exported archives/config
files may contain secrets. Review them before sharing. See `SECURITY.md` for
vulnerability reporting.
