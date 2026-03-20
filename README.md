# RecorderPhone（Windows：可用）

RecorderPhone 是一套**本地优先**的“使用记录 + 分段复盘”工具：
- **Windows 桌面版**（推荐）：安装版 `RecorderPhone-*-setup.exe`（自动拉起本机 Core + Collector）
- **浏览器扩展**（可选但强烈建议）：记录活跃 Tab（默认**域名级**；可选标题/后台音频）

这仓库同时包含产品文档与实现代码（见 `PRD.md` / `IA_WIREFRAMES.md` / `VISUAL_STYLE.md` / `COMPONENTS_TOKENS.md`）。

---

## Windows 版：你能用它做什么

- **Now（正在用）**：基于“前台 focus + 后台音频”判断你此刻在用的 app / tab
- **Blocks（分段）**：按时间聚合（默认 45 分钟一段）+ TopN（应用/网站）占比
- **复盘闭环**：到点通知 → 一键 Quick Review（3 字段 + 标签 + 跳过）→ 变成可检索的工作日志素材
- **首页价值**：`0:00–24:00` 应用/网站泳道时间轴 + 今日 Top（信息密度优先）
- **隐私分级**（渐进式）：  
  - L1（默认）：只存应用/域名与时长  
  - L2：允许存窗口标题 / Tab 标题（才能区分 YouTube 不同视频等）  
  - L3：允许存 `exePath`（更敏感，用于识别与诊断）
- **黑名单**：从详情页一键加入（应用/域名），后续不再记录或聚合为隐藏项
- **导出与 Reports**：本地导出 `report-*.md`（给你读）+ 可选 `report-*.csv`（给你分析/导入）；可接 OpenAI-compatible 云端生成日报/周报（可选）
- **桌面化**：托盘常驻、开机自启（可选）、单实例、防重复记录、打包版内置更新

---

## Windows 快速使用（推荐：打包版，只点一个 exe）

1) 去 GitHub Releases 下载并运行最新 `RecorderPhone-<tag>-windows-setup.exe`  
2) 按向导安装（默认安装到 `%LOCALAPPDATA%\\Programs\\RecorderPhone`）  
3) 从开始菜单打开 `RecorderPhone`（会自动启动本机 `recorder_core.exe` + `windows_collector.exe`）  
4) 托盘图标：
   - 左键：`Open / Hide`
   - 右键：`Quick Review / Pause / Resume / Exit`（退出会停止后台采集）
5) （可选但强烈建议）安装浏览器扩展：加载 `extension/`（Chrome/Edge “加载已解压扩展”）  
   - 扩展默认上报：`http://127.0.0.1:17600/event`
   - popup 里 `Test /health` 显示 OK 即链路正常
6) 在 UI 的 `Settings` 里做一次“最小配置”：
   - `Privacy`：默认 L1；想区分同站点不同标题（如 YouTube 不同视频）→ 开启 L2（Store titles）
   - `Startup`：需要“全天不断档记录”→ 开启开机自启（可选）
   - `Updates`：点 `Check`；有新版本就 `Update & restart`
7) 想确认路径：
   - 托盘右键可直接点 `Open app folder` / `Open data folder`
   - 设置页 `Desktop agent (Windows)` 也会显示安装与数据库默认路径

数据默认落在（打包版）：
- `%LOCALAPPDATA%\\RecorderPhone\\recorder-core.db`

---

## 更新本地 Windows 应用

两种方式：
- **应用内更新**：`Settings → Updates` → `Check` → `Update & restart`（基于 GitHub Releases；Public 仓库无需 token）
- **手动更新**：下载新的 `RecorderPhone-<tag>-windows-setup.exe` 覆盖安装

详细发布/打包流程见：`RELEASING.md`。

---

## 开发者文档（源码构建/联调/发布）

如果你要从源码开发（而不是直接用打包版），请看：
- `DEVELOPING.md`（开发入口与目录说明）
- `WINDOWS_DEV.md`（Windows 开发与联调）
- `RELEASING.md`（GitHub Actions 打包与 Release）
