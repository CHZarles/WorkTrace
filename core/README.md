# Core（跨平台本机服务）

Core 是“本机中枢”：接收事件（扩展/采集器）、落库 SQLite、按天聚合成 blocks、提供导出接口。默认只监听 `localhost`。

## 运行（WSL / Linux / macOS）
```bash
cargo run -p recorder_core -- --listen 127.0.0.1:17600 --db ./data/recorder-core.db
```

## 端口与接口
- `GET /health`
- `POST /event`（扩展/采集器上报，schema 参考 `schemas/ingest-event.schema.json`）
- `GET /events?limit=50`
- `GET /now?limit=200`（返回 “Now” 专用快照：最近的 app/tab/audio 事件 + 少量 title 提示，供 UI 高频轮询）
- `GET /tracking/status`（`paused` / `paused_until_ts`）
- `POST /tracking/pause`（`{ minutes?: number, until_ts?: string }`；都不填=手动暂停）
- `POST /tracking/resume`
- `GET /settings`（当前 Core 设置：`block_seconds` / `idle_cutoff_seconds` / `store_titles` / `store_exe_path`）
- `POST /settings`（更新 Core 设置：`{ block_seconds?: number, idle_cutoff_seconds?: number, store_titles?: boolean, store_exe_path?: boolean }`）
- `GET /timeline/day?date=YYYY-MM-DD&tz_offset_minutes=0`（按“本地日”返回 focus/audio 的时间轴 segments，供 UI 画 Timeline/统计）
- `GET /blocks/today?date=YYYY-MM-DD&tz_offset_minutes=0`（`tz_offset_minutes` 用于“按本地日”查询）
- `GET /blocks/due?date=YYYY-MM-DD&tz_offset_minutes=0`（返回“当前到点需要复盘”的 block；若没有则 `data=null`，供通知/Agent 使用）
- `POST /blocks/review`（对某个 block 写复盘）
- `POST /blocks/delete`（删除某个 block 时间段内的 events + review；支持 `{ start_ts, end_ts }`）
- `GET /privacy/rules`（黑名单/脱敏规则）
- `POST /privacy/rules`（`{ kind: "domain"|"app", value: "...", action: "drop"|"mask" }`）
- `DELETE /privacy/rules/:id`
- `POST /data/delete_day`（按本地日删除：`{ date: "YYYY-MM-DD", tz_offset_minutes?: number }`）
- `POST /data/wipe`（一键全清：删除所有 events + block reviews；保留 privacy rules + settings）
- `GET /export/markdown?date=YYYY-MM-DD&tz_offset_minutes=0`
- `GET /export/csv?date=YYYY-MM-DD&tz_offset_minutes=0`
- `GET /reports/settings` / `POST /reports/settings`
- `POST /reports/generate/daily` / `POST /reports/generate/weekly`
- `GET /reports` / `GET /reports/:id` / `DELETE /reports/:id`
- `GET /reports/todos` / `POST /reports/todos` / `DELETE /reports/todos/:id`（日报/周报的 TODO 驱动输入）

说明：
- `domain` 规则会匹配子域名（例如 `youtube.com` 也会命中 `m.youtube.com`）
- `app` 规则目前是精确匹配（MVP）
- Core 默认隐私更严格：即使 Collector/扩展发送了 `title`/`exePath`，只要 `store_titles=false` / `store_exe_path=false`，Core 也不会把这些字段落库。
- 浏览器事件可能包含 `activity`：
  - `focus`：浏览器在前台，用户正在看的 tab
  - `audio`：浏览器不在前台，但某个 tab 在播放音频（作为“后台使用”附加到 block 上）
- 扩展还可能发送 `event=tab_audio_stop`：后台音频停止标记（更准确结束统计/让 UI 的 “Now” 及时消失）
- Windows 采集器还可能发送：
  - `event=app_audio`：非浏览器 App 在后台播放音频（CoreAudio sessions），用于识别 QQ 音乐等“正在使用”的后台播放
  - `event=app_audio_stop`：后台音频停止标记（让 UI 的 “Now/Timeline” 及时结束）

## 与浏览器扩展联调
1) 启动 Core（见上）  
2) 在 Windows 浏览器加载 `extension/` → popup `Test /health`  
3) 切换网页 tab：`GET /events` 会出现域名事件；`GET /blocks/today` 会出现聚合 block
