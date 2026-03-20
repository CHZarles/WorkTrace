# Windows Collector（最小 Win32 采集器）

职责：只做 Win32 采集（前台应用/可选窗口标题）→ POST 给 Core（`/event`）。

## 构建（Windows）
在 Windows（PowerShell）里：
```powershell
cd C:\src\WorkTrace
cargo build -p windows_collector --release
```

如果构建时报错 `edition2024`（Cargo 太旧），先更新工具链：
```powershell
rustup update stable
```

## 运行
```powershell
.\target\release\windows_collector.exe --core-url http://127.0.0.1:17600
```

可选参数：
- `--send-title`：发送窗口标题（隐私级别 L2，默认关闭）
- `--send-exe-path`：发送完整 exe 路径（更高敏，默认关闭）
- `--heartbeat-seconds 60`：同一应用不切换时的心跳（用于时长归因）
- `--track-audio=false`：关闭“后台音频 App”检测（默认开启）。开启时会发送 `app_audio`/`app_audio_stop`，用于在 UI 的 Now/Timeline 里看到 QQ 音乐等后台播放
- `--review-notify=false`：关闭“复盘到点提醒”的 Windows Toast（默认开启，best-effort；支持点击后通过 `worktrace://` 直达 Quick Review，也支持 `Skip` / `Pause 15m` 按钮，需要先安装协议）
- `--review-notify-check-seconds 30`：复盘提醒轮询频率
- `--review-notify-repeat-minutes 10`：同一个 due block 最短重复提醒间隔
- `--idle-cutoff-seconds 300`：系统空闲 ≥ 该阈值后停止上报（避免把长时间空闲归因给最后一个应用）
- `--poll-ms 1000`：轮询频率

说明：
 - `--send-title` / `--send-exe-path` 只决定“采集器是否发送”。Core 侧还可以通过 `POST /settings`（或 UI 的 Core Settings）控制是否真正落库（`store_titles` / `store_exe_path`）。
 - `--idle-cutoff-seconds` 仅影响 `app_active`（避免空闲时长误归因）。后台音频（`app_audio`）仍会按音频会话状态上报。
 - `--review-notify` 目前使用 PowerShell/Explorer 作为兜底来源（无需安装器/快捷方式也能弹），所以系统里可能显示来源为 PowerShell；后续做 MSIX/托盘 Agent 时可替换为真实 AppUserModelID。
 - 复盘提醒会轮询 Core 的 `GET /blocks/due`（若返回 `data=null` 则不提醒）。
 - 要让 Toast 点击后打开 UI，需要先在 Windows 注册协议：在 `C:\\src\\WorkTrace` 运行 `powershell -ExecutionPolicy Bypass -File .\\dev\\install-worktrace-protocol.ps1`

## 事件结构
schema 参考：`schemas/ingest-event.schema.json`
