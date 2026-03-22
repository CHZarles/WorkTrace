# WSL 开发建议（跨平台架构）

在当前架构里：
- Core 是跨平台（Rust），**可以直接在 WSL 跑**；
- 浏览器扩展跑在 Windows 浏览器里；
- Windows Collector 需要在 Windows 上编译/运行；
- Flutter UI 建议在装了 Flutter SDK 的环境里开发（可在 WSL 或 Windows）。

## 方案 A（推荐）：WSL 跑 Core + Windows 浏览器跑扩展
1) 在 WSL 启动 Core：
```bash
cargo run -p recorder_core -- --listen 127.0.0.1:17600
```
2) 在 Windows 浏览器加载 `extension/`，popup 里 `Test /health` 应显示 OK（访问 `http://127.0.0.1:17600/health`）
3) 切换网页 tab：访问 `http://127.0.0.1:17600/events` 能看到域名事件

> 若 Windows 侧访问不到 WSL 服务：把 server 监听改为 `HOST=0.0.0.0` 重试：  
> `cargo run -p recorder_core -- --listen 0.0.0.0:17600`

## 方案 B：在 Windows 上编译/运行 Collector（源码仍在 WSL）
- 建议把仓库镜像到 Windows 文件系统（例如 `C:\\src\\WorkTrace`），便于 `cargo build --release` 与运行 exe

## 方案 B.5（推荐）：Windows 本地 Core + 一键启动（不依赖 WSL）
如果你希望 **Windows 端完全本地跑 Core/Collector/UI**（不需要单独起 WSL Core），直接在 Windows PowerShell：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\run-desktop.ps1 -SendTitle
```

停止后台 Core/Collector：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\stop-agent.ps1
```

## 方案 B.6（推荐）：Windows 打包版（只点一个 exe）
先在 Windows PowerShell 生成打包目录：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\package-windows.ps1 -InstallProtocol
```
然后双击运行：`dist\windows\WorkTrace\WorkTrace.exe`。

说明：
- 打包脚本会 best-effort 停掉正在运行的 WorkTrace/Core/Collector，并清理 `dist\windows\WorkTrace` 后再拷贝，便于反复覆盖升级。
- 如果仍提示文件被占用：先退出托盘（Exit），或执行 `.\dev\stop-agent.ps1 -KillAllByName` 后重试。

## 方案 C：自动同步到 Windows 路径（“async”/长期推荐）
如果你想 **在 WSL 编辑**，但让 **Windows 侧构建/运行**（Collector/Flutter Windows）更稳/性能更好，用 rsync 自动镜像：
```bash
mkdir -p /mnt/c/src/WorkTrace
node dev/sync-to-windows.mjs /mnt/c/src/WorkTrace
```
然后在 Windows 里直接用 `C:\\src\\WorkTrace` 这份镜像来构建/运行。

注意：
- `dev/sync-to-windows.mjs` 默认会做 `--delete` 镜像，**会删除 Windows 侧额外创建的文件夹**。
- 已内置保护 `C:\\src\\WorkTrace\\worktrace_ui`（Flutter 工作副本）不会被删除；若你在更新前已经启动过 sync，记得重启该脚本使排除规则生效。

## 方案 D：临时替代（Node 接收服务）
如果你暂时不想装 Rust 工具链，可用简化接收服务联调扩展：
```bash
node dev/ingest-server.mjs
```

## 在 Windows 看“最新进展”
如果你在 WSL 开发、但需要在 Windows 上运行 Flutter/扩展看效果，直接看：`WINDOWS_DEV.md`。

补充：模板 UI 覆盖到 Windows Flutter 工程可用脚本：`dev/overlay-ui.ps1`。
