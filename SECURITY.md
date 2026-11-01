# 安全策略 / Security Policy

## 支持的版本

安全修复面向当前发布分支与最新版本(2.3.x)。旧版本请先升级。

## 报告漏洞

请**不要**在公开 issue 中披露安全漏洞、API Key、配置文件或导出归档。

- 首选:GitHub 私有漏洞报告
  <https://github.com/Ricardo-Kaslana/MicroScritt/security/advisories/new>
- 报告中请包含:影响版本、平台、复现步骤、影响范围与建议修复方向。
- 不要在报告中粘贴真实 API Key;如需展示配置,请先脱敏。
- 维护者会尽力在合理时间内确认与修复;本项目不提供漏洞赏金。

## 安全模型

MicroScritt 是纯客户端应用:没有账号、遥测或后端服务,数据保存在本地。以下
属于**既定设计**,不是漏洞:

- API Key 以明文保存在本地 SQLite 与 `microscritt-config.json` 中。请保护数据
  目录与导出文件,不要提交或公开分享。
- 会话归档、配置文件与图片导出可能包含 API Key、聊天内容与图片。
- 网络请求会发往用户自己配置的 LLM / 生图端点;这些第三方服务的数据处理受
  其各自隐私政策与服务条款约束。
- 生图插件在受限 JS 沙箱中执行,只能访问插件声明的 origin;但插件仍可能读取
  其权限范围内的请求与响应。只导入你信任的插件。

## 不在范围内

- 第三方 LLM / 生图服务自身的安全问题与服务条款纠纷。
- 用户自行修改提示词、插件或构建产物导致的问题。
- 已明确标注为既定取舍的明文密钥存储。

## 英文摘要

Please report vulnerabilities privately through GitHub Security Advisories, not
in public issues. Include the affected version, platform, reproduction steps and
impact. Never paste real API keys or private archives. MicroScritt is a local-only
client: plaintext API key storage, user-configured endpoints and exported
archives containing secrets are documented design choices, not vulnerabilities.
