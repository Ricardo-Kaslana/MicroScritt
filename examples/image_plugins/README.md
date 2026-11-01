# 生图插件示例

`openai_images.json` 是一个**无预置端点、无密钥**的单文件生图插件示例,适配
OpenAI Images 风格的 `POST images/generations` 接口。服务地址、API Key 与模型
由用户在「设置 → 生图服务」中填写。

## 导入

1. 打开「设置 → 生图服务」;
2. 选择「导入插件」并选中本文件;
3. 新建生图配置,填写 Base URL、API Key 与模型名;
4. 使用「测试连接」验证后再启用。

## 插件结构

单文件 JSON,包含 `formatVersion`、`id`、`name`、`version`、`settings`、
`permissions` 与 `code`。`code` 是同步 `step(ctx)` 函数,由 Dart 宿主按
`http / sleep / done / error` 状态机执行;宿主负责网络、超时、大小限制与
origin 权限校验。完整契约见仓库根目录的 `AGENTS.md`。

仓库还内置两个协议插件(OpenAI 兼容对话式网关 / Nai2API),它们与服务端地址
一样由用户配置,不包含任何可用密钥或代理服务。
