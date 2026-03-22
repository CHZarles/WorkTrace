# Developing WorkTrace

README 面向“普通用户”（如何下载/运行/更新）。本文件面向开发者。

说明：产品对外名称和桌面深链现在都用 `WorkTrace` / `worktrace://`，但仓库目录和部分内部标识仍保留旧名字。

## 目录结构（开发视角）
```
core/              Rust 本机服务（recorder_core）
collectors/        Windows 采集器（windows_collector）
extension/         Chrome/Edge MV3 扩展（Tab 域名/标题/音频上报）
ui_flutter/        Flutter UI 模板（真实工程用 overlay 覆盖）
worktrace_ui/  你本机生成的 Flutter 工程（运行/打包用，通常不提交）
dev/               开发/打包脚本（overlay/sync/package/run）
schemas/           事件 schema（供扩展/采集器对齐）
```

## Windows 开发入口
- 跑 UI / 覆盖模板：见 `WINDOWS_DEV.md`
- 一键启动（本机 Core + Collector + UI）：`dev/run-desktop.ps1`
- 打包成便携目录（含 Core/Collector/UI）：`dev/package-windows.ps1`

## 发布（GitHub Releases）
- 见 `RELEASING.md`（tag 触发 `.github/workflows/release-windows.yml`）
