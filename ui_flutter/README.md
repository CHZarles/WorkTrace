# Flutter UI（Windows）

这部分只提供 **UI 模板代码**（含 tokens 主题映射 + 调用 Core API 的页面骨架）。  
由于当前环境未安装 Flutter SDK，仓库里不包含 `flutter create` 生成的 platform 工程文件。

说明：文档里的示例仓库路径和默认数据目录现在都用 `WorkTrace`；Flutter 工程目录 `worktrace_ui/` 仍是当前内部目录名。

## Windows 前置条件（跑桌面端必需）
- 开启“开发者模式”（symlink 支持）：设置 → 隐私和安全性 → 开发者选项 → 开发人员模式
- 安装 Visual Studio 2022 并勾选 Workload：`Desktop development with C++`（含 MSVC、CMake tools、Windows 10/11 SDK）

## 快速开始（在你的 Windows / macOS / Linux 上）
1) 创建 Flutter app（生成 windows 平台目录）
```bash
flutter create --platforms=windows worktrace_ui
```
> 如果你想先用浏览器快速跑 UI：创建时把 `web` 也加上：
> `flutter create --platforms=windows,web worktrace_ui`
> 或在已有工程里执行：`flutter create --platforms=web .`
2) 用本仓库模板覆盖生成项目的 `lib/` 与 `pubspec.yaml`
macOS/Linux/WSL：
```bash
rsync -a --delete ui_flutter/template/lib/ worktrace_ui/lib/
cp ui_flutter/template/pubspec.yaml worktrace_ui/pubspec.yaml
```

Windows PowerShell：
```powershell
robocopy .\ui_flutter\template\lib .\worktrace_ui\lib /MIR
Copy-Item -Force .\ui_flutter\template\pubspec.yaml .\worktrace_ui\pubspec.yaml
```
或直接执行脚本（等价于上面两行）：
```powershell
powershell -ExecutionPolicy Bypass -File .\dev\overlay-ui.ps1
```
如果你在 WSL 开发且不方便跑 PowerShell，也可以在 WSL 执行（会把模板覆盖到 Windows 工程，并可选 watch）：
```bash
node dev/overlay-ui-to-windows.mjs /mnt/c/src/WorkTrace --watch
```
3) 运行（先确保 Core 在本机运行：`cargo run -p recorder_core -- --listen 127.0.0.1:17600`）
```bash
cd worktrace_ui
flutter pub get
flutter run -d windows
```

你现在能看到的页面（模板实现）：
- Today：Today Top（应用/域名聚合 + 图标 + 一键黑名单）+ Now（当前使用）+ Review due（到点复盘入口）
- Review：按天加载 blocks（时间轴）并支持关键词过滤；点开 block 进入详情（TopN 条形图 + Tags + 黑名单 + 删除本段 + Background audio；开启 L2 titles 后可按 tab 标题/VSCode workspace 更细粒度展示）
- Settings：Server URL、隐私规则、导出、Core settings、Danger zone

## “打包模式”（推荐的桌面应用形态）

UI 内置的 `Desktop agent (Windows)` 现在会 **优先使用“打包在应用目录旁”的二进制** 来启动 Core/Collector（不依赖 repoRoot、不依赖 PowerShell 脚本）。

推荐直接用打包脚本生成可分发目录（会把 Core/Collector 放到 UI 旁边）：

```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\package-windows.ps1 -InstallProtocol
```

约定：
- 把 `recorder_core.exe` 与 `windows_collector.exe` 放到 UI exe 同目录，或放到同目录下的 `bin/`。
  打包后的 UI 入口通常是 `WorkTrace.exe`；开发工程的 Flutter runner 输出仍可能是 `worktrace_ui.exe`。
- UI 会用 `Server URL` 的 host/port（默认 `http://127.0.0.1:17600`）启动 Core，并把数据库写到：
  - `%LOCALAPPDATA%\\WorkTrace\\recorder-core.db`（以及 `%LOCALAPPDATA%\\WorkTrace\\agent-pids.json`）

开发期想快速模拟“打包模式”，可以在 Windows 先 build Rust release，然后把 exe 拷到 Flutter Windows runner 的目录里（例如 `build\\windows\\x64\\runner\\Release\\`）再运行 UI。

### 如果你在用 `dev/sync-to-windows.mjs`
该脚本会用 rsync 镜像到 Windows（带 `--delete`）。我们已默认保护 `worktrace_ui/` 不会被删除；如果你在更新前已经启动过 sync，请重启该脚本后再创建 Flutter 工程。

### 在 Windows 上看到最新 UI
如果你在 WSL 改了 `ui_flutter/template/`，但 Windows 运行的 `worktrace_ui/` 没变化，这是正常的：模板不会自动覆盖真实工程。  
按 `WINDOWS_DEV.md` 里的 PowerShell 指令把模板覆盖到 `worktrace_ui/` 后再运行即可。
