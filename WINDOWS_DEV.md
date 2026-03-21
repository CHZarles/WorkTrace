# 在 Windows 查看最新开发进展（WSL 开发流）

你现在的工作方式是：**WSL 里改代码**，但很多“看效果”的动作（Flutter Windows、浏览器扩展、Windows 采集器）都发生在 **Windows**。  
这份文档把“如何在 Windows 看到 WSL 的最新改动”讲清楚，并给出可复制的命令。

说明：文档里的示例仓库路径和默认数据目录现在都用 `WorkTrace`；Flutter 工程目录 `recorderphone_ui/` 还保留旧标识。

如果你只是想“像普通桌面软件一样用”，不想折腾开发环境：
- 直接走 GitHub Releases 下载打包版：`RELEASING.md`

---

## 0) 关键点：模板 vs 真实 Flutter 工程

仓库里 `ui_flutter/template/` 只是 **模板源码**；你在 Windows 上运行的是 `recorderphone_ui/`（`flutter create` 生成的真实工程）。

因此：
- WSL 同步脚本会**同步整个仓库到 Windows**，但会**刻意排除** `recorderphone_ui/`（避免 rsync `--delete` 把你的 Windows 工程删掉）。
- **UI 变更要生效**：你需要把 `ui_flutter/template/` 的内容手动覆盖到 `recorderphone_ui/`。

如果你感觉“界面没变化”，通常就是因为只同步了仓库，但**没有覆盖到 `recorderphone_ui/lib`**（这是正常现象）。

---

## 1) WSL → Windows 镜像同步（推荐常驻）

在 WSL 执行（会持续监听文件变化并 rsync 到 Windows）：

```bash
cd /home/charles/WorkTrace
node dev/sync-to-windows.mjs /mnt/c/src/WorkTrace
```

对应 Windows 路径：
- WSL：`/mnt/c/src/WorkTrace`
- Windows：`C:\src\WorkTrace`

> 若提示没有 rsync：在 WSL 安装 `rsync` 后重试（例如 Ubuntu：`sudo apt-get update && sudo apt-get install -y rsync`）。

---

## 1.5) 一键启动（推荐）

你可以用仓库里的脚本把“Core / UI / Collector”快速拉起来：

### 方案 A：Windows 本地 Core（不依赖 WSL，推荐）
在 **Windows PowerShell** 一条命令启动：Core（本地）+ Windows Collector + Flutter UI：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\run-desktop.ps1 -SendTitle
```

说明：
- Core 会作为后台进程启动，监听 `http://127.0.0.1:17600`（日志在 `data\logs\core.log`，错误在 `data\logs\core.err.log`）。
- Collector 也会作为后台进程启动（日志在 `data\logs\collector.log`，错误在 `data\logs\collector.err.log`）。
- UI 仍然是前台 `flutter run -d windows`。

停止后台进程：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\stop-agent.ps1
```

> 如果你想确保全部重启：`.\dev\run-desktop.ps1 -RestartAgent -SendTitle`

### 方案 B：WSL 跑 Core（旧方案）
在 **WSL** 启动 Core：
```bash
cd /home/charles/WorkTrace
bash dev/run-core.sh 127.0.0.1:17600
```

在 **Windows PowerShell** 启动 UI（会自动 overlay 模板 UI + `flutter pub get`）：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\run-ui.ps1
```

如果你只启动了 UI，但 Core 没跑起来：你也可以在 UI 里 `Settings → Desktop agent (Windows)` 直接点击 `Start/Restart/Stop` 来启动/重启本机 Core + Collector（无需再开 WSL Core）。

在 **Windows PowerShell** 启动 Windows Collector（会先 build，再运行；可选发送窗口标题）：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\run-collector.ps1 -CoreUrl http://127.0.0.1:17600 -SendTitle
```

> 说明：Collector 的 `--send-title` 只有在 Core 开启 L2（Store titles）时才会被落库；否则会被 Core 丢弃。

---

## 2) 把模板 UI 覆盖到 Windows 的 Flutter 工程（每次 UI 改动后做）

在 **Windows PowerShell** 执行（可整段复制）：

```powershell
cd C:\src\WorkTrace

# 用模板覆盖真实工程的 lib/（会删除 lib/ 下模板没有的文件）
robocopy .\ui_flutter\template\lib .\recorderphone_ui\lib /MIR

# 同步模板 assets/（例如托盘图标 tray.ico）
robocopy .\ui_flutter\template\assets .\recorderphone_ui\assets /MIR

# 覆盖 pubspec.yaml（PowerShell 用 Copy-Item，别用 copy /Y）
Copy-Item -Force .\ui_flutter\template\pubspec.yaml .\recorderphone_ui\pubspec.yaml

cd .\recorderphone_ui
flutter pub get
```

也可以直接跑脚本（等价于上面的命令）：
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\overlay-ui.ps1
```

如果你 **不想/不能** 在 PowerShell 里跑命令（比如执行策略限制），可以在 **WSL** 跑一条命令把模板覆盖到 Windows 工程：
```bash
cd /home/charles/WorkTrace
node dev/overlay-ui-to-windows.mjs /mnt/c/src/WorkTrace --watch
```
> 需要 WSL 已安装 `rsync`（同 1)）。

然后运行 UI：
```powershell
flutter run -d windows
```

快速自检（确认你确实覆盖成功）：
- 打开 `C:\src\WorkTrace\recorderphone_ui\lib\screens\today_screen.dart`，搜索 `Block details`。
- 如果没有这个字符串，说明模板还没覆盖到真实工程。

---

## 3) Core（Rust 服务）怎么跑，Windows 怎么验证

在 WSL 启动 Core（推荐带端口）：
```bash
cargo run -p recorder_core -- --listen 127.0.0.1:17600
```

在 Windows 验证：
- 浏览器打开 `http://127.0.0.1:17600/health` 应返回 `{"ok":true,...}`
- 再验证一次：`http://127.0.0.1:17600/settings` 应返回 `{"ok":true,"data":{...}}`
- 或者扩展 popup 点 `Test /health` 显示 `OK`

> 如果 Windows 访问不到 WSL 的 Core：把监听改为 `0.0.0.0:17600` 再试：  
> `cargo run -p recorder_core -- --listen 0.0.0.0:17600`

### /settings 返回 404 怎么办？
如果你在 Windows 执行：
```powershell
curl.exe -sS -i http://127.0.0.1:17600/settings
```
看到 `HTTP/1.1 404 Not Found`，说明 **当前监听 17600 的进程不是最新版 recorder_core**（可能是旧 binary，或你启动了 `dev/ingest-server.mjs` 这种只支持 `/health`/`/event`/`/events` 的服务）。

先查一下是谁占用了端口：
```powershell
netstat -ano | findstr :17600
```
拿到 PID 后看进程名（任选其一）：
```powershell
tasklist /FI "PID eq <PID>"
# 或
Get-Process -Id <PID>
```
如果确认是旧进程，直接关掉：
```powershell
taskkill /PID <PID> /F
```
然后回到 WSL 重新启动 recorder_core，再重试 `/settings`。

---

## 4) 浏览器扩展如何看最新

扩展代码同步到 Windows 镜像后（`C:\src\WorkTrace\extension`），在 Edge/Chrome 的“加载已解压”页面：
- 选择目录：`C:\src\WorkTrace\extension`
- 改了扩展代码后：点“重新加载”按钮（或关闭/打开扩展）

---

## 5) 我怎么确认“我看到的是最新进展”

推荐按下面顺序做一次“最短闭环”：
1. WSL：Core 正常运行（`/health` OK）
2. Windows：Flutter 先执行一次“模板覆盖”命令，再 `flutter run -d windows`
3. Windows：扩展重新加载，切换几个 tab
4. Flutter：`Today` 页能看到 `Today Top`（应用/域名列表，带时长条形图）
5. Flutter：去 `Review` 页打开任意 block，弹出 `Block details`，能看到 TopN 条形图/Tags/黑名单按钮（含 Background audio）
6. Flutter：`Timeline` 支持 `Ctrl + 鼠标滚轮` 缩放、鼠标拖拽横向平移；点条形段 → 直达对应 block 详情；点 `Now` 后可用 `Back` 回到原视图

---

## 6) Windows Toast 点击后直达 Quick Review（可选）

Windows 采集器会在“某个 block 到点且还没复盘”时弹出 Toast。为了让 **点击 Toast 直接打开 UI 的 Quick Review**，需要在 Windows 注册一次自定义协议：`worktrace://`

在 **Windows PowerShell** 运行（可整段复制）：

```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\install-worktrace-protocol.ps1
```

如果脚本提示找不到 `recorderphone_ui.exe`：
- 先运行一次 Windows UI（会生成 exe）：
  - `cd C:\src\WorkTrace\recorderphone_ui`
  - `flutter run -d windows`
- 然后再重新跑安装脚本

自检：
- `Win + R` 输入：`worktrace://review`（应能启动 WorkTrace UI）
 - Toast 的按钮（如果开启了 `windows_collector --review-notify`）：`Quick Review` / `Skip` / `Pause 15m` 都会通过 `worktrace://...` 深链触发

---

## 7) 打包模式（桌面应用形态）

目标：做成**点开一个 exe**（WorkTrace）就能自动拉起本机 `recorder_core` + `windows_collector`，不需要你手动跑 WSL Core / PowerShell 脚本。

### 一条命令打包（推荐）
在 **Windows PowerShell** 可整段复制：

```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\package-windows.ps1 -Installer -InstallProtocol
```

说明：
- 该脚本会（打包前/打包后）自动停止正在运行的 `WorkTrace.exe / recorder_core.exe / windows_collector.exe`，避免文件占用导致“拒绝访问/无法覆盖/编译失败”。
- 输出目录会生成 `build-info.json`（包含 git commit、core/collector 版本与 sha256），并会在打包完成后对 `recorder_core.exe/windows_collector.exe` 做 sha256 校验；校验失败会直接报错，避免你误跑到旧 core。
- 若仍提示文件被占用：先退出 WorkTrace（托盘里 Exit），或执行：`powershell -ExecutionPolicy Bypass -File .\dev\stop-agent.ps1 -KillAllByName`，再重试打包。

产物：
- `C:\src\WorkTrace\dist\windows\WorkTrace\WorkTrace.exe`
- `C:\src\WorkTrace\dist\windows\WorkTrace-Setup.exe`（安装版，推荐分发）

运行方式：
- 安装版：运行 `WorkTrace-Setup.exe`，默认安装到 `%LOCALAPPDATA%\Programs\WorkTrace`
- 或直接从 `dist\windows\WorkTrace\WorkTrace.exe` 本地验证
- 默认 `Server URL` 是 `http://127.0.0.1:17600`，UI 启动后会 **best-effort 自动确保本机 Agent 运行**（Core/Collector 都会起来）。

> `-InstallProtocol` 是为了让 Windows Toast 的按钮（Quick Review / Skip / Pause）可以通过 `worktrace://...` 直达 UI；如果你暂时不需要 Toast 深链，可以去掉它。

### 打包约定（UI 如何识别“打包模式”）
当 `recorder_core.exe` 与 `windows_collector.exe` **放在 UI exe 同目录**（或同目录的 `bin/`）时，UI 会优先用这些二进制启动 Core/Collector（不依赖 repoRoot、不依赖 PowerShell）。

---

## 8) 开机自启（登录后最小化到托盘）

在 WorkTrace UI：
- `Settings → Server → Start with Windows` 打开开关

效果：
- 下次 Windows 登录后会自动启动 WorkTrace（带 `--minimized`，默认不弹窗口）
- UI 会 best-effort 自动确保本机 Agent（Core/Collector）运行

关闭方式：
- 回到同一开关关闭即可（会删除注册表 Run 项）

---

## 9) 每日/每周 LLM 报表（OpenAI-compatible 云端）

你可以让 WorkTrace **每天自动生成昨天的日报表格**、每周自动生成上周周报表格（输出 Markdown，存到 Core 的 `/reports`）。

配置入口：
- UI 底部/侧边栏 `Reports` → 展开 `Report settings`

需要填的字段：
- `API Base URL`：例如 `https://api.openai.com/v1`（也可换成任意 OpenAI-compatible 服务的 `/v1`）
- `API Key`：Bearer token
- `Model`：例如 `gpt-4o-mini`

定时：
- `Daily (yesterday)`：每天本地时间到点后生成“昨天”的日报
- `Weekly (last week)`：每周到点后生成“上周”的周报（可选周几 + 时间）

查看输出：
- UI 底部/侧边栏 `Reports` 标签页

提示：
- 报表输入 JSON 会遵循 `Privacy L1/L2/L3`：L1 基本只看到域名/应用聚合；L2 才会包含标题粒度（比如 YouTube 视频标题、VS Code workspace 名称）。

数据落盘位置：
- DB：`%LOCALAPPDATA%\\WorkTrace\\recorder-core.db`
- PID：`%LOCALAPPDATA%\\WorkTrace\\agent-pids.json`
