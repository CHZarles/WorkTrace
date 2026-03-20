# Collectors（采集器）

采集器是“最小 Windows 依赖”的载体：只做 Win32 采集，然后把事件 POST 给 Core（`localhost`）。

## Windows Collector（前台应用/空闲 + 后台音频）
- 代码：`collectors/windows_collector/`
- 构建：建议在 Windows 上用 `cargo build -p windows_collector --release`
  - 采集敏感字段（窗口标题、exePath）需要显式参数开启；且 Core 侧还可通过 `store_titles` / `store_exe_path` 决定是否落库
  - 默认会尝试检测“后台播放音频的 App”（CoreAudio sessions）并发送 `app_audio`/`app_audio_stop`（可用 `--track-audio=false` 关闭）

如果你在 Windows 看到类似报错：
- `feature edition2024 is required` / `edition2024 is not stabilized in this version of Cargo`

说明你的 Rust 工具链太旧，先更新再构建：
```powershell
rustup update stable
```

> WSL/Linux 下不需要/也不能运行该采集器。

## 一键运行（Windows PowerShell）
```powershell
cd C:\src\WorkTrace
powershell -ExecutionPolicy Bypass -File .\dev\run-collector.ps1 -CoreUrl http://127.0.0.1:17600 -SendTitle
```
