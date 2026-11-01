# 贡献指南

感谢关注 MicroScritt!本文档说明如何参与开发。

## 行为准则

参与本项目即表示同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。保持友善与专业,讨论聚焦于代码、设计与用户体验本身。

## 开发环境

- Flutter SDK ≥ 3.35(稳定版通道)
- 平台:Android / Windows(当前维护重点);iOS 目录存在但未完整接线

```bash
git clone <你的 fork>
cd microscritt
flutter pub get
flutter analyze
flutter test
```

提交前请确保 `flutter analyze` 零告警、`flutter test` 全绿。

若本地通过 `PUB_HOSTED_URL` 使用依赖镜像,请用
`PUB_HOSTED_URL=https://pub.dev flutter pub get` 重新生成 `pubspec.lock`,再提交;
锁文件中的依赖地址必须指向 pub.dev,CI 会做检查。

## 分支与提交

- 主分支 `main` 保持可用;功能开发请切出分支(如 `feat/worldbook-search`)。
- 提交信息用[约定式提交](https://www.conventionalcommits.org/zh-hans/v1.0.0/):
  `feat:` / `fix:` / `test:` / `refactor:` / `docs:` / `chore:`,中文描述。
- 每个提交保持可构建、可测试。

## 内容红线

本仓库面向开源分发,以下内容一律不接受:

1. 规避模型安全策略的提示词、预设或「越狱」类素材;
2. 露骨成人内容的提示词、画师串或世界书资产;
3. 硬编码的可用密钥、鉴权绕过头或用户不可配置的第三方端点;默认种子仅允许无密钥、可编辑的示例 provider;
4. 未经授权的第三方项目素材(需兼容许可证)。

内置默认提示词必须为中性创作辅助内容。

## 代码约定

- **分层**:持久化层(`lib/data/`)与 LLM/生图层(`lib/backend/`)不互相
  import,只通过 `lib/models/` 的中立类型对接。
- **LLM 输入**:只接收纯文本 `ContextSnapshot`;HTML / 图片绝不进上下文。
- **数据库**:schema 变更走 `database_schema.dart` 的基线 DDL 并递增
  `schemaVersion`,在 `test/data/database_open_test.dart` 补基线断言;
  迁移增量部分属于 2.0 之前的机制,已移除,不再新增 onUpgrade 步骤。
- **新增生图服务** = 一个单文件 JSON 插件(manifest + 同步 JS `step(ctx)`),
  通过 UI 导入或放入 `examples/image_plugins/`;不改调用方或 Dart 源码。插件
  示例见 `examples/image_plugins/openai_images.json`。
- **fail-safe**:启动即水合的配置列解析必须容错(坏 JSON 回落默认值),
  脏值不允许炸掉启动。

## 测试

- 单测放在 `test/` 下,目录结构与 `lib/` 对应。
- 涉及真实 DB I/O 的 widget 测试用 `tester.runAsync` 包裹(见
  `test/ui/provider_edit_screen_test.dart`)。
- 仓库自带生图插件的 JS 必须被真实执行:相关测试经
  `test/support/plugin_js_engine.dart` 的 `probePluginJsEngine()`(QuickJS
  优先、回落 Node)求值,禁止 `if (runtime == null) return;` 式空转假绿;
  引擎确实不可用时用 `markTestSkipped`。QuickJS 不可用时 hook 求值测试会
  自动跳过,这是预期行为。

## 文档

- 用户可见的行为变更同步进 `CHANGELOG.md`(Keep a Changelog 格式)。
- 架构级变更同步 `docs/ARCHITECTURE.md` 对应小节。

## 提交 PR

1. Fork 并切出分支;
2. 保证 analyze / test 全绿;
3. PR 描述说明动机、方案与验证方式;
4. 关联相关 issue(如有)。

## 安全

不要在公开 issue 中报告安全漏洞或粘贴 API Key、配置文件和导出归档。报告方式见
[SECURITY.md](SECURITY.md)。
